CREATE TYPE public.shipping_status AS ENUM (
    'NOT_REQUESTED',
    'REQUESTED',
    'LABEL_CREATED',
    'IN_TRANSIT',
    'DELIVERED',
    'FAILED'
);

ALTER TABLE public.orders
    ADD COLUMN shipping_status public.shipping_status NOT NULL DEFAULT 'NOT_REQUESTED';

CREATE FUNCTION private.prevent_used_shipping_region_identity_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF (
        TG_OP = 'DELETE'
        OR NEW.provider IS DISTINCT FROM OLD.provider
        OR NEW.provider_region_code IS DISTINCT FROM OLD.provider_region_code
    ) AND EXISTS (
        SELECT 1
        FROM public.orders AS order_record
        WHERE order_record.snapshot_json #>> '{shipping_region,region_id}'
            = OLD.region_id::text
    ) THEN
        RAISE EXCEPTION 'shipping region identity is fixed after checkout'
            USING ERRCODE = '55000';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION private.prevent_used_shipping_region_identity_change()
    FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER shipping_regions_identity_immutable_after_checkout
    BEFORE UPDATE OF provider, provider_region_code OR DELETE ON public.shipping_regions
    FOR EACH ROW EXECUTE FUNCTION private.prevent_used_shipping_region_identity_change();

CREATE TABLE private.sourcing_completion_events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL UNIQUE
        REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    actor_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    idempotency_key uuid NOT NULL UNIQUE,
    occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE private.shipping_shipments (
    shipment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL UNIQUE
        REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    region_id uuid NOT NULL
        REFERENCES public.shipping_regions (region_id) ON DELETE RESTRICT,
    provider text NOT NULL CHECK (provider IN ('BOSTA', 'EGYPTIAN_POST')),
    provider_region_code text NOT NULL
        CHECK (char_length(provider_region_code) BETWEEN 1 AND 100),
    provider_shipment_id text NOT NULL UNIQUE
        CHECK (provider_shipment_id ~ '^SANDBOX-[0-9A-F]{24}$'),
    tracking_number text
        CHECK (tracking_number IS NULL OR tracking_number ~ '^[A-Za-z0-9._-]{1,100}$'),
    status public.shipping_status NOT NULL DEFAULT 'REQUESTED'
        CHECK (status <> 'NOT_REQUESTED'),
    sandbox_only boolean NOT NULL DEFAULT true CHECK (sandbox_only),
    requested_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE private.shipping_events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shipment_id uuid NOT NULL
        REFERENCES private.shipping_shipments (shipment_id) ON DELETE RESTRICT,
    provider text NOT NULL CHECK (provider IN ('BOSTA', 'EGYPTIAN_POST')),
    provider_event_id text NOT NULL
        CHECK (provider_event_id ~ '^[A-Za-z0-9._:-]{1,200}$'),
    status public.shipping_status NOT NULL
        CHECK (status NOT IN ('NOT_REQUESTED', 'REQUESTED')),
    tracking_number text
        CHECK (tracking_number IS NULL OR tracking_number ~ '^[A-Za-z0-9._-]{1,100}$'),
    request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    occurred_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, provider_event_id)
);

CREATE INDEX shipping_events_shipment_history_idx
    ON private.shipping_events (shipment_id, occurred_at, event_id);

CREATE TRIGGER shipping_events_append_only
    BEFORE UPDATE OR DELETE ON private.shipping_events
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();
CREATE TRIGGER sourcing_completion_events_append_only
    BEFORE UPDATE OR DELETE ON private.sourcing_completion_events
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

ALTER TABLE private.sourcing_completion_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.sourcing_completion_events FORCE ROW LEVEL SECURITY;
ALTER TABLE private.shipping_shipments ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.shipping_shipments FORCE ROW LEVEL SECURITY;
ALTER TABLE private.shipping_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.shipping_events FORCE ROW LEVEL SECURITY;

REVOKE ALL ON private.sourcing_completion_events,
    private.shipping_shipments,
    private.shipping_events
    FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.confirm_order_sourced(
    p_order_id uuid,
    p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_scope text;
    v_request_hash text;
    v_existing_hash text;
    v_existing_state text;
    v_existing_response jsonb;
    v_order public.orders%ROWTYPE;
    v_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'authenticated administrator identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM public.app_user_roles AS user_role
        WHERE user_role.user_id = v_actor_id
          AND user_role.role IN ('ADMIN', 'SUPER_ADMIN')
    ) THEN
        RAISE EXCEPTION 'administrator role is required'
            USING ERRCODE = '42501';
    END IF;
    IF p_order_id IS NULL OR p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'order and UUID idempotency key are required'
            USING ERRCODE = '22023';
    END IF;

    v_scope := 'sourcing.complete.' || v_actor_id::text;
    v_request_hash := encode(
        sha256(convert_to(jsonb_build_object('order_id', p_order_id)::text, 'UTF8')),
        'hex'
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_scope || ':' || p_idempotency_key::text, 0)
    );

    SELECT request_sha256, state, response_json
    INTO v_existing_hash, v_existing_state, v_existing_response
    FROM private.idempotency_keys
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key::text
    FOR UPDATE;
    IF FOUND THEN
        IF v_existing_hash <> v_request_hash THEN
            RAISE EXCEPTION 'sourcing idempotency key was reused for a different order'
                USING ERRCODE = '23505';
        END IF;
        IF v_existing_state = 'SUCCEEDED' THEN
            RETURN v_existing_response;
        END IF;
        RAISE EXCEPTION 'sourcing request is not in a replayable state'
            USING ERRCODE = '55000';
    END IF;

    SELECT *
    INTO v_order
    FROM public.orders
    WHERE order_id = p_order_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order does not exist'
            USING ERRCODE = '22023';
    END IF;
    IF v_order.payment_status <> 'SUCCEEDED'
        OR v_order.sourcing_status <> 'SOURCING'
        OR v_order.order_status IN ('CANCELLED', 'REFUND_PENDING', 'REFUNDED')
    THEN
        RAISE EXCEPTION 'only paid orders currently being sourced can be confirmed'
            USING ERRCODE = '55000';
    END IF;

    INSERT INTO private.idempotency_keys (
        scope, idempotency_key, request_sha256, state
    )
    VALUES (v_scope, p_idempotency_key::text, v_request_hash, 'PROCESSING');

    UPDATE public.orders
    SET sourcing_status = 'SOURCED'
    WHERE order_id = p_order_id;
    INSERT INTO private.sourcing_completion_events (
        order_id, actor_id, idempotency_key
    )
    VALUES (p_order_id, v_actor_id, p_idempotency_key);

    v_response := jsonb_build_object('order_id', p_order_id, 'status', 'SOURCED');
    UPDATE private.idempotency_keys
    SET state = 'SUCCEEDED',
        response_json = v_response,
        completed_at = clock_timestamp()
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key::text;

    INSERT INTO private.transactional_outbox (
        aggregate_type,
        aggregate_id,
        event_type,
        payload
    )
    VALUES (
        'order',
        p_order_id,
        'sourcing.goods_received',
        jsonb_build_object('order_id', p_order_id, 'confirmed_by', v_actor_id)
    );
    RETURN v_response;
END;
$$;

CREATE FUNCTION public.create_sandbox_shipment(
    p_order_id uuid,
    p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_scope text;
    v_request_hash text;
    v_existing_hash text;
    v_existing_state text;
    v_existing_response jsonb;
    v_order public.orders%ROWTYPE;
    v_region_id uuid;
    v_region record;
    v_shipment private.shipping_shipments%ROWTYPE;
    v_has_shipment boolean;
    v_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'authenticated administrator identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM public.app_user_roles AS user_role
        WHERE user_role.user_id = v_actor_id
          AND user_role.role IN ('ADMIN', 'SUPER_ADMIN')
    ) THEN
        RAISE EXCEPTION 'administrator role is required'
            USING ERRCODE = '42501';
    END IF;
    IF p_order_id IS NULL OR p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'order and UUID idempotency key are required'
            USING ERRCODE = '22023';
    END IF;

    v_scope := 'shipping.create.' || v_actor_id::text;
    v_request_hash := encode(
        sha256(convert_to(jsonb_build_object('order_id', p_order_id)::text, 'UTF8')),
        'hex'
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_scope || ':' || p_idempotency_key::text, 0)
    );

    SELECT request_sha256, state, response_json
    INTO v_existing_hash, v_existing_state, v_existing_response
    FROM private.idempotency_keys
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key::text
    FOR UPDATE;
    IF FOUND THEN
        IF v_existing_hash <> v_request_hash THEN
            RAISE EXCEPTION 'shipping idempotency key was reused for a different order'
                USING ERRCODE = '23505';
        END IF;
        IF v_existing_state = 'SUCCEEDED' THEN
            RETURN v_existing_response;
        END IF;
        RAISE EXCEPTION 'shipping request is not in a replayable state'
            USING ERRCODE = '55000';
    END IF;

    SELECT *
    INTO v_order
    FROM public.orders
    WHERE order_id = p_order_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order does not exist'
            USING ERRCODE = '22023';
    END IF;
    IF v_order.payment_status <> 'SUCCEEDED'
        OR v_order.sourcing_status <> 'SOURCED'
        OR v_order.order_status IN ('CANCELLED', 'REFUND_PENDING', 'REFUNDED')
    THEN
        RAISE EXCEPTION 'only paid, sourced, non-cancelled orders can be shipped'
            USING ERRCODE = '55000';
    END IF;

    IF v_order.snapshot_json #>> '{shipping_region,region_id}'
        !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    THEN
        RAISE EXCEPTION 'order has no valid shipping region snapshot'
            USING ERRCODE = '55000';
    END IF;
    v_region_id := (v_order.snapshot_json #>> '{shipping_region,region_id}')::uuid;

    SELECT region.region_id,
           region.provider,
           region.provider_region_code,
           region.shipping_minor
    INTO v_region
    FROM public.shipping_regions AS region
    WHERE region.region_id = v_region_id
      AND region.is_active
    FOR SHARE;
    IF NOT FOUND OR v_region.shipping_minor <> v_order.shipping_minor THEN
        RAISE EXCEPTION 'shipping region or its price changed after checkout'
            USING ERRCODE = '55000';
    END IF;

    SELECT *
    INTO v_shipment
    FROM private.shipping_shipments AS shipment
    WHERE shipment.order_id = p_order_id
    FOR UPDATE;
    v_has_shipment := FOUND;

    INSERT INTO private.idempotency_keys (
        scope, idempotency_key, request_sha256, state
    )
    VALUES (v_scope, p_idempotency_key::text, v_request_hash, 'PROCESSING');

    IF NOT v_has_shipment THEN
        INSERT INTO private.shipping_shipments (
            order_id,
            region_id,
            provider,
            provider_region_code,
            provider_shipment_id,
            requested_by
        )
        VALUES (
            p_order_id,
            v_region.region_id,
            v_region.provider,
            v_region.provider_region_code,
            'SANDBOX-' || upper(substr(
                encode(
                    sha256(convert_to(
                        v_region.provider || ':' || p_order_id::text || ':'
                            || p_idempotency_key::text,
                        'UTF8'
                    )),
                    'hex'
                ),
                1,
                24
            )),
            v_actor_id
        )
        RETURNING * INTO v_shipment;

        UPDATE public.orders
        SET shipping_status = 'REQUESTED'
        WHERE order_id = p_order_id;

        INSERT INTO private.transactional_outbox (
            aggregate_type,
            aggregate_id,
            event_type,
            payload
        )
        VALUES (
            'shipping_shipment',
            v_shipment.shipment_id,
            'shipping.shipment_requested',
            jsonb_build_object(
                'order_id', p_order_id,
                'shipment_id', v_shipment.shipment_id,
                'provider', v_shipment.provider,
                'provider_shipment_id', v_shipment.provider_shipment_id,
                'provider_region_code', v_shipment.provider_region_code,
                'sandbox_only', true
            )
        );
    END IF;

    v_response := jsonb_build_object(
        'shipment_id', v_shipment.shipment_id,
        'provider', v_shipment.provider,
        'provider_shipment_id', v_shipment.provider_shipment_id,
        'tracking_number', v_shipment.tracking_number,
        'status', v_shipment.status,
        'sandbox_only', true
    );
    UPDATE private.idempotency_keys
    SET state = 'SUCCEEDED',
        response_json = v_response,
        completed_at = clock_timestamp()
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key::text;
    RETURN v_response;
END;
$$;

CREATE FUNCTION public.ingest_sandbox_shipping_event(
    p_shipment_id uuid,
    p_provider_event_id text,
    p_status text,
    p_tracking_number text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
    v_shipment private.shipping_shipments%ROWTYPE;
    v_request_hash text;
    v_existing_hash text;
    v_next_status public.shipping_status;
    v_event_id uuid;
BEGIN
    IF p_shipment_id IS NULL
        OR p_provider_event_id IS NULL
        OR p_provider_event_id !~ '^[A-Za-z0-9._:-]{1,200}$'
        OR p_status IS NULL
        OR p_status NOT IN ('LABEL_CREATED', 'IN_TRANSIT', 'DELIVERED', 'FAILED')
        OR (p_tracking_number IS NOT NULL
            AND p_tracking_number !~ '^[A-Za-z0-9._-]{1,100}$')
        OR (p_status = 'LABEL_CREATED' AND p_tracking_number IS NULL)
    THEN
        RAISE EXCEPTION 'invalid sandbox shipping event'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_shipment
    FROM private.shipping_shipments AS shipment
    WHERE shipment.shipment_id = p_shipment_id
      AND shipment.sandbox_only
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'sandbox shipment does not exist'
            USING ERRCODE = '22023';
    END IF;

    v_request_hash := encode(
        sha256(convert_to(jsonb_build_object(
            'shipment_id', p_shipment_id,
            'status', p_status,
            'tracking_number', p_tracking_number
        )::text, 'UTF8')),
        'hex'
    );
    SELECT request_sha256
    INTO v_existing_hash
    FROM private.shipping_events
    WHERE provider = v_shipment.provider
      AND provider_event_id = p_provider_event_id;
    IF FOUND THEN
        IF v_existing_hash <> v_request_hash THEN
            RAISE EXCEPTION 'shipping event id was reused with different contents'
                USING ERRCODE = '23505';
        END IF;
        RETURN jsonb_build_object('status', v_shipment.status, 'duplicate', true);
    END IF;

    v_next_status := p_status::public.shipping_status;
    IF NOT (
        v_next_status = v_shipment.status
        OR (v_shipment.status = 'REQUESTED'
            AND v_next_status IN ('LABEL_CREATED', 'FAILED'))
        OR (v_shipment.status = 'LABEL_CREATED'
            AND v_next_status IN ('IN_TRANSIT', 'FAILED'))
        OR (v_shipment.status = 'IN_TRANSIT'
            AND v_next_status IN ('DELIVERED', 'FAILED'))
    ) THEN
        RAISE EXCEPTION 'shipping status transition is not allowed'
            USING ERRCODE = '55000';
    END IF;

    INSERT INTO private.shipping_events (
        shipment_id,
        provider,
        provider_event_id,
        status,
        tracking_number,
        request_sha256
    )
    VALUES (
        p_shipment_id,
        v_shipment.provider,
        p_provider_event_id,
        v_next_status,
        p_tracking_number,
        v_request_hash
    )
    RETURNING event_id INTO v_event_id;

    IF v_next_status <> v_shipment.status THEN
        UPDATE private.shipping_shipments
        SET status = v_next_status,
            tracking_number = coalesce(p_tracking_number, tracking_number),
            updated_at = clock_timestamp()
        WHERE shipment_id = p_shipment_id;

        UPDATE public.orders
        SET shipping_status = v_next_status,
            order_status = CASE
                WHEN v_next_status = 'IN_TRANSIT' THEN 'SHIPPED'::public.order_status
                WHEN v_next_status = 'DELIVERED' THEN 'DELIVERED'::public.order_status
                ELSE order_status
            END
        WHERE order_id = v_shipment.order_id;
    END IF;

    INSERT INTO private.transactional_outbox (
        aggregate_type,
        aggregate_id,
        event_type,
        payload
    )
    VALUES (
        'shipping_event',
        v_event_id,
        'shipping.status_changed',
        jsonb_build_object(
            'shipment_id', p_shipment_id,
            'status', v_next_status,
            'sandbox_only', true
        )
    );

    RETURN jsonb_build_object('status', v_next_status, 'duplicate', false);
END;
$$;

CREATE FUNCTION public.get_my_shipping_status(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_result jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'authenticated identity is required'
            USING ERRCODE = '28000';
    END IF;

    SELECT jsonb_build_object(
        'provider', shipment.provider,
        'status', shipment.status,
        'tracking_number', shipment.tracking_number,
        'sandbox_only', shipment.sandbox_only
    )
    INTO v_result
    FROM private.shipping_shipments AS shipment
    JOIN public.orders AS order_record USING (order_id)
    WHERE order_record.order_id = p_order_id
      AND (
          order_record.customer_id = v_actor_id
          OR EXISTS (
              SELECT 1
              FROM public.app_user_roles AS user_role
              WHERE user_role.user_id = v_actor_id
                AND user_role.role IN ('ADMIN', 'SUPER_ADMIN')
          )
      );

    IF v_result IS NULL THEN
        RAISE EXCEPTION 'shipment is unavailable'
            USING ERRCODE = '42501';
    END IF;
    RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.create_sandbox_shipment(uuid, uuid)
    FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.confirm_order_sourced(uuid, uuid)
    FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.ingest_sandbox_shipping_event(uuid, text, text, text)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_my_shipping_status(uuid)
    FROM PUBLIC, anon, service_role;

GRANT EXECUTE ON FUNCTION public.create_sandbox_shipment(uuid, uuid)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_order_sourced(uuid, uuid)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_sandbox_shipping_event(uuid, text, text, text)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.get_my_shipping_status(uuid)
    TO authenticated;
