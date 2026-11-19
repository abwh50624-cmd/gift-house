CREATE TABLE public.delivery_addresses (
    address_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE CASCADE,
    shipping_region_id uuid NOT NULL REFERENCES public.shipping_regions (region_id) ON DELETE RESTRICT,
    governorate text NOT NULL CHECK (char_length(governorate) BETWEEN 2 AND 160),
    street_address text NOT NULL CHECK (char_length(street_address) BETWEEN 5 AND 500),
    landmark text CHECK (landmark IS NULL OR char_length(landmark) <= 160),
    latitude double precision CHECK (latitude IS NULL OR latitude BETWEEN -90 AND 90),
    longitude double precision CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.delivery_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.delivery_addresses FORCE ROW LEVEL SECURITY;

CREATE POLICY delivery_addresses_customer_read
    ON public.delivery_addresses FOR SELECT TO authenticated
    USING (customer_id = (SELECT auth.uid()));
CREATE POLICY delivery_addresses_customer_insert
    ON public.delivery_addresses FOR INSERT TO authenticated
    WITH CHECK (customer_id = (SELECT auth.uid()));

REVOKE ALL ON public.delivery_addresses FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT, INSERT ON public.delivery_addresses TO authenticated;

INSERT INTO public.shipping_regions (
    provider, provider_region_code, name, shipping_minor, is_active
) VALUES
    ('BOSTA', 'EG-Cairo', 'القاهرة', 4500, true),
    ('BOSTA', 'EG-Giza', 'الجيزة', 5000, true),
    ('BOSTA', 'EG-Alexandria', 'الإسكندرية', 6500, true),
    ('BOSTA', 'EG-Delta', 'الدلتا', 7000, true),
    ('BOSTA', 'EG-Canal', 'قناة السويس', 7000, true),
    ('BOSTA', 'EG-UpperEgypt', 'صعيد مصر', 8500, true),
    ('EGYPTIAN_POST', 'EG-Cairo', 'القاهرة', 3500, true),
    ('EGYPTIAN_POST', 'EG-Giza', 'الجيزة', 4000, true),
    ('EGYPTIAN_POST', 'EG-Alexandria', 'الإسكندرية', 5000, true),
    ('EGYPTIAN_POST', 'EG-Delta', 'الدلتا', 5500, true),
    ('EGYPTIAN_POST', 'EG-Canal', 'قناة السويس', 5500, true),
    ('EGYPTIAN_POST', 'EG-UpperEgypt', 'صعيد مصر', 6500, true)
ON CONFLICT (provider, provider_region_code) DO UPDATE
SET name = EXCLUDED.name,
    shipping_minor = EXCLUDED.shipping_minor,
    is_active = true,
    updated_at = clock_timestamp();

CREATE FUNCTION public.get_shipping_rates(
    p_governorate text DEFAULT NULL,
    p_provider text DEFAULT NULL
)
RETURNS TABLE (
    region_id uuid,
    governorate text,
    provider text,
    provider_region_code text,
    shipping_minor bigint,
    currency_code text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
    SELECT region.region_id,
           region.name,
           region.provider,
           region.provider_region_code,
           region.shipping_minor,
           region.currency_code
    FROM public.shipping_regions AS region
    WHERE region.is_active
      AND (p_governorate IS NULL OR region.name = p_governorate)
      AND (p_provider IS NULL OR region.provider = p_provider)
    ORDER BY region.name, region.provider;
$$;

REVOKE ALL ON FUNCTION public.get_shipping_rates(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_shipping_rates(text, text) TO anon, authenticated;

DROP FUNCTION public.create_checkout_order(
    jsonb, text, text, uuid, text, text
);

CREATE FUNCTION public.create_checkout_order(
    p_items jsonb,
    p_idempotency_key text,
    p_payment_method text,
    p_shipping_region_id uuid,
    p_terms_version text,
    p_terms_sha256 text,
    p_governorate text DEFAULT NULL,
    p_street_address text DEFAULT NULL,
    p_landmark text DEFAULT NULL,
    p_latitude double precision DEFAULT NULL,
    p_longitude double precision DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_customer_id uuid := auth.uid();
    v_scope text;
    v_request jsonb;
    v_request_hash text;
    v_canonical_items jsonb;
    v_existing_hash text;
    v_existing_state text;
    v_existing_response jsonb;
    v_line record;
    v_product_id uuid;
    v_category_id uuid;
    v_product_name text;
    v_product_description text;
    v_variant_name text;
    v_weight_grams integer;
    v_unit_price_minor bigint;
    v_shipping_name text;
    v_shipping_minor bigint;
    v_subtotal numeric := 0;
    v_total numeric;
    v_line_total numeric;
    v_order_lines jsonb := '[]'::jsonb;
    v_item_snapshot jsonb;
    v_snapshot jsonb;
    v_snapshot_sha256 text;
    v_order_id uuid;
    v_response jsonb;
    v_terms jsonb;
    v_reservation_id uuid;
    v_address_id uuid;
    v_expires_at timestamptz := clock_timestamp() + interval '15 minutes';
BEGIN
    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'authenticated customer identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF p_payment_method IS NULL
       OR p_payment_method NOT IN ('CARD', 'MOBILE_WALLET', 'BANK_TRANSFER')
    THEN
        RAISE EXCEPTION 'unsupported prepaid payment method'
            USING ERRCODE = '22023';
    END IF;
    IF p_governorate IS NULL OR char_length(p_governorate) NOT BETWEEN 2 AND 160
       OR p_street_address IS NULL OR char_length(p_street_address) NOT BETWEEN 5 AND 500
       OR (p_landmark IS NOT NULL AND char_length(p_landmark) > 160)
       OR (p_latitude IS NOT NULL AND p_latitude NOT BETWEEN -90 AND 90)
       OR (p_longitude IS NOT NULL AND p_longitude NOT BETWEEN -180 AND 180)
    THEN
        RAISE EXCEPTION 'a valid Egyptian delivery address is required'
            USING ERRCODE = '22023';
    END IF;
    IF p_idempotency_key IS NULL
       OR p_idempotency_key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       OR p_items IS NULL OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 50
       OR octet_length(p_items::text) > 16384
    THEN
        RAISE EXCEPTION 'invalid checkout request'
            USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_items) AS item(value)
        WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'object'
           OR jsonb_typeof(item.value -> 'variant_id') IS DISTINCT FROM 'string'
           OR item.value ->> 'variant_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           OR jsonb_typeof(item.value -> 'quantity') IS DISTINCT FROM 'number'
           OR item.value ->> 'quantity' !~ '^[1-9][0-9]{0,17}$'
    ) THEN
        RAISE EXCEPTION 'checkout cart contains an invalid variant or quantity'
            USING ERRCODE = '22023';
    END IF;
    IF (
        SELECT count(*) <> count(DISTINCT item.value ->> 'variant_id')
        FROM jsonb_array_elements(p_items) AS item(value)
    ) THEN
        RAISE EXCEPTION 'checkout cart must contain each variant only once'
            USING ERRCODE = '22023';
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'variant_id', item.value ->> 'variant_id',
            'quantity', (item.value ->> 'quantity')::bigint
        ) ORDER BY (item.value ->> 'variant_id')::uuid
    ) INTO v_canonical_items
    FROM jsonb_array_elements(p_items) AS item(value);

    v_scope := 'order.create.' || v_customer_id::text;
    v_request := jsonb_build_object(
        'items', v_canonical_items,
        'payment_method', p_payment_method,
        'shipping_region_id', p_shipping_region_id,
        'governorate', p_governorate,
        'street_address', p_street_address,
        'landmark', p_landmark,
        'latitude', p_latitude,
        'longitude', p_longitude,
        'terms_version', p_terms_version,
        'terms_sha256', p_terms_sha256
    );
    v_request_hash := encode(sha256(convert_to(v_request::text, 'UTF8')), 'hex');
    PERFORM pg_advisory_xact_lock(hashtextextended(v_scope || ':' || p_idempotency_key, 0));

    SELECT request_sha256, state, response_json
    INTO v_existing_hash, v_existing_state, v_existing_response
    FROM private.idempotency_keys
    WHERE scope = v_scope AND idempotency_key = p_idempotency_key
    FOR UPDATE;
    IF FOUND THEN
        IF v_existing_hash <> v_request_hash THEN
            RAISE EXCEPTION 'idempotency key was reused with a different checkout request'
                USING ERRCODE = '23505';
        END IF;
        IF v_existing_state = 'SUCCEEDED' THEN RETURN v_existing_response; END IF;
        RAISE EXCEPTION 'checkout request is not in a replayable state' USING ERRCODE = '55000';
    END IF;
    INSERT INTO private.idempotency_keys (scope, idempotency_key, request_sha256, state)
    VALUES (v_scope, p_idempotency_key, v_request_hash, 'PROCESSING');

    v_terms := public.get_checkout_terms();
    IF p_terms_version IS DISTINCT FROM v_terms ->> 'version'
       OR p_terms_sha256 IS DISTINCT FROM v_terms ->> 'sha256'
    THEN
        RAISE EXCEPTION 'checkout terms have changed; review and accept the current terms'
            USING ERRCODE = '22023';
    END IF;

    SELECT region.name, region.shipping_minor
    INTO v_shipping_name, v_shipping_minor
    FROM public.shipping_regions AS region
    WHERE region.region_id = p_shipping_region_id
      AND region.is_active
      AND region.name = p_governorate
    FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'shipping region is unavailable' USING ERRCODE = '22023'; END IF;

    FOR v_line IN
        SELECT (item.value ->> 'variant_id')::uuid AS variant_id,
               (item.value ->> 'quantity')::bigint AS quantity
        FROM jsonb_array_elements(v_canonical_items) AS item(value)
        ORDER BY (item.value ->> 'variant_id')::uuid
    LOOP
        SELECT product.product_id, product.category_id, product.name, product.description,
               variant.variant_name, variant.weight_grams, variant.price_minor
        INTO v_product_id, v_category_id, v_product_name, v_product_description,
             v_variant_name, v_weight_grams, v_unit_price_minor
        FROM public.product_variants AS variant
        JOIN public.products AS product ON product.product_id = variant.product_id
        WHERE variant.variant_id = v_line.variant_id
          AND variant.is_active AND product.is_published;
        IF NOT FOUND THEN RAISE EXCEPTION 'cart contains unavailable variant' USING ERRCODE = '55000'; END IF;
        v_line_total := v_unit_price_minor::numeric * v_line.quantity;
        v_subtotal := v_subtotal + v_line_total;
        v_item_snapshot := jsonb_build_object(
            'variant_id', v_line.variant_id, 'product_id', v_product_id,
            'category_id', v_category_id, 'product_name', v_product_name,
            'product_description', v_product_description, 'variant_name', v_variant_name,
            'weight_grams', v_weight_grams, 'quantity', v_line.quantity,
            'unit_price_minor', v_unit_price_minor, 'line_total_minor', v_line_total::bigint
        );
        v_order_lines := v_order_lines || jsonb_build_array(v_item_snapshot);
    END LOOP;

    v_total := v_subtotal + v_shipping_minor::numeric;
    IF v_subtotal <= 0 OR v_total > 9223372036854775807::numeric
    THEN RAISE EXCEPTION 'checkout total exceeds supported limits' USING ERRCODE = '22003'; END IF;

    INSERT INTO public.delivery_addresses (
        customer_id, shipping_region_id, governorate, street_address, landmark, latitude, longitude
    ) VALUES (
        v_customer_id, p_shipping_region_id, p_governorate, p_street_address,
        p_landmark, p_latitude, p_longitude
    ) RETURNING address_id INTO v_address_id;

    v_snapshot := jsonb_build_object(
        'schema_version', 2, 'currency_code', 'EGP', 'payment_method', p_payment_method,
        'subtotal_minor', v_subtotal::bigint, 'shipping_minor', v_shipping_minor,
        'total_minor', v_total::bigint,
        'shipping_region', jsonb_build_object('name', v_shipping_name, 'region_id', p_shipping_region_id),
        'delivery_address', jsonb_build_object(
            'address_id', v_address_id, 'governorate', p_governorate,
            'street_address', p_street_address, 'landmark', p_landmark,
            'latitude', p_latitude, 'longitude', p_longitude
        ),
        'terms', jsonb_build_object(
            'version', v_terms ->> 'version', 'sha256', v_terms ->> 'sha256',
            'accepted_at', clock_timestamp()
        ),
        'items', v_order_lines
    );
    v_snapshot_sha256 := encode(sha256(convert_to(v_snapshot::text, 'UTF8')), 'hex');
    INSERT INTO public.orders (
        customer_id, payment_method, currency_code, subtotal_minor, shipping_minor, total_minor,
        snapshot_schema_version, snapshot_json, snapshot_sha256
    ) VALUES (
        v_customer_id, p_payment_method, 'EGP', v_subtotal::bigint, v_shipping_minor,
        v_total::bigint, 2, v_snapshot, v_snapshot_sha256
    ) RETURNING order_id INTO v_order_id;

    FOR v_line IN SELECT item.value FROM jsonb_array_elements(v_order_lines) AS item(value) LOOP
        v_reservation_id := private.reserve_inventory(
            v_order_id, (v_line.value ->> 'variant_id')::uuid,
            (v_line.value ->> 'quantity')::bigint
        );
        UPDATE private.inventory_reservations
        SET expires_at = v_expires_at WHERE reservation_id = v_reservation_id;
    END LOOP;

    v_response := jsonb_build_object(
        'order_id', v_order_id, 'order_status', 'CREATED',
        'payment_status', 'PENDING', 'payment_method', p_payment_method,
        'currency_code', 'EGP', 'subtotal_minor', v_subtotal::bigint,
        'shipping_minor', v_shipping_minor, 'total_minor', v_total::bigint,
        'payment_expires_at', v_expires_at
    );
    UPDATE private.idempotency_keys
    SET state = 'SUCCEEDED', response_json = v_response, completed_at = clock_timestamp()
    WHERE scope = v_scope AND idempotency_key = p_idempotency_key;
    RETURN v_response;
END;
$$;

REVOKE ALL ON FUNCTION public.create_checkout_order(
    jsonb, text, text, uuid, text, text, text, text, text, double precision, double precision
) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.create_checkout_order(
    jsonb, text, text, uuid, text, text, text, text, text, double precision, double precision
) TO authenticated;
