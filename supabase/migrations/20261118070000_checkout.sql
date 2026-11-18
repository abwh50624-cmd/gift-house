ALTER TABLE private.inventory_reservations
    ADD COLUMN expires_at timestamptz;

CREATE FUNCTION public.get_checkout_terms()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = pg_catalog
AS $$
    SELECT jsonb_build_object(
        'version', 'prepaid-order-v1',
        'text', 'أقر بأن هذا الطلب مسبق الدفع، ولا يصبح مؤكداً إلا بعد التحقق من نجاح الدفع. لا يتوفر الدفع عند الاستلام.',
        'sha256', encode(
            sha256(convert_to(
                'أقر بأن هذا الطلب مسبق الدفع، ولا يصبح مؤكداً إلا بعد التحقق من نجاح الدفع. لا يتوفر الدفع عند الاستلام.',
                'UTF8'
            )),
            'hex'
        )
    );
$$;

CREATE FUNCTION public.create_checkout_order(
    p_items jsonb,
    p_idempotency_key text,
    p_payment_method text,
    p_shipping_region_id uuid,
    p_terms_version text,
    p_terms_sha256 text
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

    IF p_idempotency_key IS NULL
        OR p_idempotency_key !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN
        RAISE EXCEPTION 'a UUID idempotency key is required'
            USING ERRCODE = '22023';
    END IF;

    IF p_items IS NULL
        OR jsonb_typeof(p_items) IS DISTINCT FROM 'array'
        OR jsonb_array_length(p_items) NOT BETWEEN 1 AND 50
        OR octet_length(p_items::text) > 16384
    THEN
        RAISE EXCEPTION 'checkout cart is empty or exceeds its allowed size'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_items) AS item(value)
        WHERE jsonb_typeof(item.value) IS DISTINCT FROM 'object'
            OR jsonb_typeof(item.value -> 'variant_id') IS DISTINCT FROM 'string'
            OR item.value ->> 'variant_id' !~*
                '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
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
        )
        ORDER BY (item.value ->> 'variant_id')::uuid
    )
    INTO v_canonical_items
    FROM jsonb_array_elements(p_items) AS item(value);

    v_scope := 'order.create.' || v_customer_id::text;
    v_request := jsonb_build_object(
        'items', v_canonical_items,
        'payment_method', p_payment_method,
        'shipping_region_id', p_shipping_region_id,
        'terms_version', p_terms_version,
        'terms_sha256', p_terms_sha256
    );
    v_request_hash := encode(sha256(convert_to(v_request::text, 'UTF8')), 'hex');

    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_scope || ':' || p_idempotency_key, 0)
    );

    SELECT request_sha256, state, response_json
    INTO v_existing_hash, v_existing_state, v_existing_response
    FROM private.idempotency_keys
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key
    FOR UPDATE;

    IF FOUND THEN
        IF v_existing_hash <> v_request_hash THEN
            RAISE EXCEPTION 'idempotency key was reused with a different checkout request'
                USING ERRCODE = '23505';
        END IF;
        IF v_existing_state = 'SUCCEEDED' THEN
            RETURN v_existing_response;
        END IF;
        RAISE EXCEPTION 'checkout request is not in a replayable state'
            USING ERRCODE = '55000';
    END IF;

    INSERT INTO private.idempotency_keys (
        scope, idempotency_key, request_sha256, state
    )
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
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'shipping region is unavailable'
            USING ERRCODE = '22023';
    END IF;

    FOR v_line IN
        SELECT
            (item.value ->> 'variant_id')::uuid AS variant_id,
            (item.value ->> 'quantity')::bigint AS quantity
        FROM jsonb_array_elements(v_canonical_items) AS item(value)
        ORDER BY (item.value ->> 'variant_id')::uuid
    LOOP
        SELECT
            product.product_id,
            product.category_id,
            product.name,
            product.description,
            variant.variant_name,
            variant.weight_grams,
            variant.price_minor
        INTO
            v_product_id,
            v_category_id,
            v_product_name,
            v_product_description,
            v_variant_name,
            v_weight_grams,
            v_unit_price_minor
        FROM public.product_variants AS variant
        JOIN public.products AS product
          ON product.product_id = variant.product_id
        JOIN public.categories AS category
          ON category.category_id = product.category_id
        WHERE variant.variant_id = v_line.variant_id
          AND variant.is_active
          AND product.status = 'PUBLISHED'
          AND category.is_active
        FOR SHARE OF variant, product, category;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'a checkout variant is no longer available'
                USING ERRCODE = '22023';
        END IF;

        v_line_total := v_line.quantity::numeric * v_unit_price_minor::numeric;
        v_subtotal := v_subtotal + v_line_total;
        IF v_line_total > 9223372036854775807::numeric
            OR v_subtotal > 9223372036854775807::numeric
        THEN
            RAISE EXCEPTION 'checkout amount exceeds supported limits'
                USING ERRCODE = '22003';
        END IF;

        v_item_snapshot := jsonb_build_object(
            'product_id', v_product_id,
            'category_id', v_category_id,
            'product_name', v_product_name,
            'description', v_product_description,
            'variant_id', v_line.variant_id,
            'variant_name', v_variant_name,
            'weight_grams', v_weight_grams,
            'quantity', v_line.quantity,
            'unit_price_minor', v_unit_price_minor,
            'line_total_minor', v_line_total::bigint,
            'currency_code', 'EGP'
        );
        v_order_lines := v_order_lines || jsonb_build_array(v_item_snapshot);
    END LOOP;

    v_total := v_subtotal + v_shipping_minor::numeric;
    IF v_subtotal <= 0 OR v_total > 9223372036854775807::numeric THEN
        RAISE EXCEPTION 'checkout total exceeds supported limits'
            USING ERRCODE = '22003';
    END IF;

    v_snapshot := jsonb_build_object(
        'schema_version', 1,
        'currency_code', 'EGP',
        'payment_method', p_payment_method,
        'subtotal_minor', v_subtotal::bigint,
        'shipping_minor', v_shipping_minor,
        'total_minor', v_total::bigint,
        'shipping_region', jsonb_build_object(
            'name', v_shipping_name,
            'region_id', p_shipping_region_id
        ),
        'terms', jsonb_build_object(
            'version', v_terms ->> 'version',
            'sha256', v_terms ->> 'sha256',
            'accepted_at', clock_timestamp()
        ),
        'items', v_order_lines
    );
    v_snapshot_sha256 := encode(sha256(convert_to(v_snapshot::text, 'UTF8')), 'hex');

    INSERT INTO public.orders (
        customer_id,
        payment_method,
        currency_code,
        subtotal_minor,
        shipping_minor,
        total_minor,
        snapshot_schema_version,
        snapshot_json,
        snapshot_sha256
    )
    VALUES (
        v_customer_id,
        p_payment_method,
        'EGP',
        v_subtotal::bigint,
        v_shipping_minor,
        v_total::bigint,
        1,
        v_snapshot,
        v_snapshot_sha256
    )
    RETURNING order_id INTO v_order_id;

    FOR v_line IN
        SELECT item.value
        FROM jsonb_array_elements(v_order_lines) AS item(value)
    LOOP
        v_reservation_id := private.reserve_inventory(
            v_order_id,
            (v_line.value ->> 'variant_id')::uuid,
            (v_line.value ->> 'quantity')::bigint
        );

        UPDATE private.inventory_reservations
        SET expires_at = v_expires_at
        WHERE reservation_id = v_reservation_id;

        INSERT INTO public.order_items (
            order_id,
            variant_id,
            quantity,
            unit_price_minor,
            line_total_minor,
            item_snapshot
        )
        VALUES (
            v_order_id,
            (v_line.value ->> 'variant_id')::uuid,
            (v_line.value ->> 'quantity')::bigint,
            (v_line.value ->> 'unit_price_minor')::bigint,
            (v_line.value ->> 'line_total_minor')::bigint,
            v_line.value
        );
    END LOOP;

    INSERT INTO public.customer_contract_confirmations (
        customer_id,
        order_id,
        terms_version,
        terms_sha256
    )
    VALUES (
        v_customer_id,
        v_order_id,
        v_terms ->> 'version',
        v_terms ->> 'sha256'
    );

    INSERT INTO private.transactional_outbox (
        aggregate_type,
        aggregate_id,
        event_type,
        payload
    )
    VALUES (
        'order',
        v_order_id,
        'checkout.payment_requested',
        jsonb_build_object(
            'order_id', v_order_id,
            'customer_id', v_customer_id,
            'payment_method', p_payment_method,
            'amount_minor', v_total::bigint,
            'currency_code', 'EGP'
        )
    );

    v_response := jsonb_build_object(
        'order_id', v_order_id,
        'order_status', 'PAYMENT_PENDING',
        'payment_status', 'PENDING',
        'payment_method', p_payment_method,
        'currency_code', 'EGP',
        'subtotal_minor', v_subtotal::bigint,
        'shipping_minor', v_shipping_minor,
        'total_minor', v_total::bigint,
        'payment_expires_at', v_expires_at
    );

    UPDATE private.idempotency_keys
    SET state = 'SUCCEEDED',
        response_json = v_response,
        completed_at = clock_timestamp()
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key;

    RETURN v_response;
END;
$$;

CREATE FUNCTION private.expire_pending_checkout_orders(p_batch_size integer DEFAULT 100)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
    v_order_id uuid;
    v_reservation_id uuid;
    v_expired_count integer := 0;
BEGIN
    IF p_batch_size IS NULL OR p_batch_size NOT BETWEEN 1 AND 500 THEN
        RAISE EXCEPTION 'checkout expiry batch size must be between 1 and 500'
            USING ERRCODE = '22023';
    END IF;

    FOR v_order_id IN
        SELECT order_record.order_id
        FROM public.orders AS order_record
        WHERE order_record.order_status = 'PAYMENT_PENDING'
          AND EXISTS (
              SELECT 1
              FROM private.inventory_reservations AS reservation
              WHERE reservation.order_id = order_record.order_id
                AND reservation.status = 'RESERVED'
                AND reservation.expires_at <= clock_timestamp()
          )
        ORDER BY order_record.created_at, order_record.order_id
        LIMIT p_batch_size
        FOR UPDATE OF order_record SKIP LOCKED
    LOOP
        FOR v_reservation_id IN
            SELECT reservation.reservation_id
            FROM private.inventory_reservations AS reservation
            WHERE reservation.order_id = v_order_id
              AND reservation.status = 'RESERVED'
            ORDER BY reservation.variant_id
            FOR UPDATE
        LOOP
            PERFORM private.release_inventory_reservation(v_reservation_id);
        END LOOP;

        UPDATE public.orders
        SET order_status = 'CANCELLED'
        WHERE order_id = v_order_id
          AND order_status = 'PAYMENT_PENDING';

        v_expired_count := v_expired_count + 1;
    END LOOP;

    RETURN v_expired_count;
END;
$$;

REVOKE ALL ON FUNCTION public.get_checkout_terms() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_checkout_order(jsonb, text, text, uuid, text, text)
    FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION private.expire_pending_checkout_orders(integer)
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_checkout_terms() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_checkout_order(jsonb, text, text, uuid, text, text)
    TO authenticated;
GRANT EXECUTE ON FUNCTION private.expire_pending_checkout_orders(integer) TO service_role;
