CREATE TABLE private.supplier_variant_mappings (
    mapping_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id uuid NOT NULL
        REFERENCES private.supplier_telegram_mappings (supplier_id) ON DELETE RESTRICT,
    variant_id uuid NOT NULL
        REFERENCES public.product_variants (variant_id) ON DELETE RESTRICT,
    supplier_item_code text NOT NULL CHECK (
        supplier_item_code ~ '^[A-Z0-9_-]{1,64}$'
    ),
    is_active boolean NOT NULL DEFAULT true,
    changed_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (supplier_id, variant_id),
    UNIQUE (supplier_id, supplier_item_code)
);

CREATE TABLE private.supplier_mapping_events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    mapping_id uuid NOT NULL
        REFERENCES private.supplier_variant_mappings (mapping_id) ON DELETE RESTRICT,
    actor_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    old_item_code text,
    new_item_code text NOT NULL CHECK (new_item_code ~ '^[A-Z0-9_-]{1,64}$'),
    occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE private.supplier_telegram_mapping_events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id uuid NOT NULL
        REFERENCES private.supplier_telegram_mappings (supplier_id) ON DELETE RESTRICT,
    actor_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    previous_chat_id bigint,
    new_chat_id bigint NOT NULL CHECK (new_chat_id <> 0),
    previous_authorized_user_ids bigint[],
    new_authorized_user_ids bigint[] NOT NULL,
    occurred_at timestamptz NOT NULL DEFAULT now(),
    CHECK (cardinality(new_authorized_user_ids) BETWEEN 1 AND 50)
);

CREATE TABLE private.supplier_telegram_updates (
    update_id bigint PRIMARY KEY CHECK (update_id > 0),
    supplier_id uuid NOT NULL
        REFERENCES private.supplier_telegram_mappings (supplier_id) ON DELETE RESTRICT,
    telegram_chat_id bigint NOT NULL,
    telegram_user_id bigint NOT NULL,
    telegram_message_id bigint NOT NULL,
    result_status text NOT NULL CHECK (
        result_status IN (
            'RECORDED',
            'UNMAPPED_ITEM',
            'UNSUPPORTED_MESSAGE',
            'INVALID_MESSAGE'
        )
    ),
    received_at timestamptz NOT NULL DEFAULT now(),
    CHECK (telegram_chat_id <> 0 AND telegram_user_id > 0 AND telegram_message_id > 0)
);

CREATE TABLE private.supplier_availability_reports (
    report_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    mapping_id uuid NOT NULL
        REFERENCES private.supplier_variant_mappings (mapping_id) ON DELETE RESTRICT,
    telegram_update_id bigint NOT NULL UNIQUE
        REFERENCES private.supplier_telegram_updates (update_id) ON DELETE RESTRICT,
    telegram_message_id bigint NOT NULL CHECK (telegram_message_id > 0),
    reported_by_telegram_user_id bigint NOT NULL CHECK (reported_by_telegram_user_id > 0),
    available_quantity bigint NOT NULL CHECK (
        available_quantity BETWEEN 0 AND 1000000000
    ),
    supplier_cost_minor bigint CHECK (
        supplier_cost_minor IS NULL OR supplier_cost_minor > 0
    ),
    currency_code text NOT NULL DEFAULT 'EGP' CHECK (currency_code = 'EGP'),
    reported_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL DEFAULT (now() + interval '48 hours'),
    CHECK (expires_at = reported_at + interval '48 hours'),
    CHECK (
        (available_quantity = 0 AND supplier_cost_minor IS NULL)
        OR (available_quantity > 0 AND supplier_cost_minor IS NOT NULL)
    )
);

CREATE INDEX supplier_availability_current_idx
    ON private.supplier_availability_reports (mapping_id, reported_at DESC);

CREATE TABLE private.sourcing_batches (
    batch_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    window_start timestamptz NOT NULL,
    window_end timestamptz NOT NULL,
    status text NOT NULL CHECK (
        status IN ('PROPOSED', 'NEEDS_REVIEW', 'APPROVED', 'CANCELLED')
    ),
    created_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    approved_by uuid REFERENCES auth.users (id) ON DELETE RESTRICT,
    created_at timestamptz NOT NULL DEFAULT now(),
    approved_at timestamptz,
    CHECK (window_start < window_end),
    CHECK (window_end - window_start <= interval '48 hours'),
    CHECK (approved_by IS NULL OR approved_by <> created_by),
    CHECK (
        (status = 'APPROVED' AND approved_by IS NOT NULL AND approved_at IS NOT NULL)
        OR (status <> 'APPROVED' AND approved_by IS NULL AND approved_at IS NULL)
    )
);

CREATE UNIQUE INDEX sourcing_batches_one_open_idx
    ON private.sourcing_batches ((true))
    WHERE status IN ('PROPOSED', 'NEEDS_REVIEW');

CREATE TABLE private.sourcing_allocations (
    allocation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id uuid NOT NULL REFERENCES private.sourcing_batches (batch_id) ON DELETE RESTRICT,
    order_id uuid NOT NULL REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    order_item_id uuid NOT NULL
        REFERENCES public.order_items (order_item_id) ON DELETE RESTRICT,
    report_id uuid NOT NULL
        REFERENCES private.supplier_availability_reports (report_id) ON DELETE RESTRICT,
    mapping_id uuid NOT NULL
        REFERENCES private.supplier_variant_mappings (mapping_id) ON DELETE RESTRICT,
    quantity bigint NOT NULL CHECK (quantity > 0),
    supplier_cost_minor bigint NOT NULL CHECK (supplier_cost_minor > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (batch_id, order_item_id, mapping_id)
);

CREATE INDEX sourcing_allocations_mapping_idx
    ON private.sourcing_allocations (mapping_id, batch_id);

CREATE TABLE private.sourcing_gaps (
    gap_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id uuid NOT NULL REFERENCES private.sourcing_batches (batch_id) ON DELETE RESTRICT,
    order_id uuid NOT NULL REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    order_item_id uuid NOT NULL
        REFERENCES public.order_items (order_item_id) ON DELETE RESTRICT,
    required_quantity bigint NOT NULL CHECK (required_quantity > 0),
    missing_quantity bigint NOT NULL CHECK (
        missing_quantity > 0 AND missing_quantity <= required_quantity
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (batch_id, order_item_id)
);

CREATE TABLE private.sourcing_batch_events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id uuid NOT NULL REFERENCES private.sourcing_batches (batch_id) ON DELETE RESTRICT,
    event_type text NOT NULL CHECK (
        event_type IN ('PLAN_CREATED', 'APPROVED', 'CANCELLED')
    ),
    actor_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    event_payload jsonb NOT NULL DEFAULT '{}'::jsonb
        CHECK (jsonb_typeof(event_payload) = 'object'),
    occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX sourcing_batch_events_history_idx
    ON private.sourcing_batch_events (batch_id, occurred_at, event_id);

DO $$
DECLARE
    v_table_name text;
BEGIN
    FOREACH v_table_name IN ARRAY ARRAY[
        'supplier_mapping_events',
        'supplier_telegram_mapping_events',
        'supplier_telegram_updates',
        'supplier_availability_reports',
        'sourcing_allocations',
        'sourcing_gaps',
        'sourcing_batch_events'
    ]
    LOOP
        EXECUTE format(
            'CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON private.%I '
            'FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation()',
            v_table_name || '_append_only',
            v_table_name
        );
    END LOOP;
END;
$$;

ALTER TABLE private.supplier_variant_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_variant_mappings FORCE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_mapping_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_mapping_events FORCE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_telegram_mapping_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_telegram_mapping_events FORCE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_telegram_updates ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_telegram_updates FORCE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_availability_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_availability_reports FORCE ROW LEVEL SECURITY;
ALTER TABLE private.sourcing_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.sourcing_batches FORCE ROW LEVEL SECURITY;
ALTER TABLE private.sourcing_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.sourcing_allocations FORCE ROW LEVEL SECURITY;
ALTER TABLE private.sourcing_gaps ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.sourcing_gaps FORCE ROW LEVEL SECURITY;
ALTER TABLE private.sourcing_batch_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.sourcing_batch_events FORCE ROW LEVEL SECURITY;

REVOKE ALL ON private.supplier_variant_mappings,
    private.supplier_mapping_events,
    private.supplier_telegram_mapping_events,
    private.supplier_telegram_updates,
    private.supplier_availability_reports,
    private.sourcing_batches,
    private.sourcing_allocations,
    private.sourcing_gaps,
    private.sourcing_batch_events
    FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.configure_supplier_telegram_mapping(
    p_supplier_code text,
    p_supplier_name text,
    p_telegram_chat_id bigint,
    p_authorized_telegram_user_ids bigint[]
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_supplier_id uuid;
    v_previous_chat_id bigint;
    v_previous_authorized_user_ids bigint[];
BEGIN
    IF v_actor_id IS NULL
        OR NOT EXISTS (
            SELECT 1
            FROM public.app_user_roles AS user_role
            WHERE user_role.user_id = v_actor_id
              AND user_role.role = 'SUPER_ADMIN'
        )
    THEN
        RAISE EXCEPTION 'super administrator role is required'
            USING ERRCODE = '42501';
    END IF;

    IF p_supplier_code IS NULL
        OR p_supplier_code !~ '^[A-Z0-9_-]{1,64}$'
        OR p_supplier_name IS NULL
        OR char_length(btrim(p_supplier_name)) NOT BETWEEN 1 AND 160
        OR p_telegram_chat_id IS NULL
        OR p_telegram_chat_id = 0
        OR abs(p_telegram_chat_id::numeric) > 9007199254740991
        OR p_authorized_telegram_user_ids IS NULL
        OR cardinality(p_authorized_telegram_user_ids) NOT BETWEEN 1 AND 50
        OR EXISTS (
            SELECT 1
            FROM unnest(p_authorized_telegram_user_ids) AS authorized(user_id)
            WHERE authorized.user_id IS NULL
               OR authorized.user_id <= 0
               OR authorized.user_id > 9007199254740991
        )
        OR cardinality(p_authorized_telegram_user_ids) <> (
            SELECT count(DISTINCT authorized.user_id)::integer
            FROM unnest(p_authorized_telegram_user_ids) AS authorized(user_id)
        )
    THEN
        RAISE EXCEPTION 'invalid supplier Telegram mapping'
            USING ERRCODE = '22023';
    END IF;

    SELECT supplier.supplier_id,
           supplier.telegram_chat_id,
           supplier.authorized_telegram_user_ids
    INTO v_supplier_id, v_previous_chat_id, v_previous_authorized_user_ids
    FROM private.supplier_telegram_mappings AS supplier
    WHERE supplier.supplier_code = p_supplier_code
    FOR UPDATE;

    INSERT INTO private.supplier_telegram_mappings (
        supplier_code,
        supplier_name,
        telegram_chat_id,
        authorized_telegram_user_ids,
        is_active
    )
    VALUES (
        p_supplier_code,
        btrim(p_supplier_name),
        p_telegram_chat_id,
        p_authorized_telegram_user_ids,
        true
    )
    ON CONFLICT (supplier_code) DO UPDATE
    SET supplier_name = EXCLUDED.supplier_name,
        telegram_chat_id = EXCLUDED.telegram_chat_id,
        authorized_telegram_user_ids = EXCLUDED.authorized_telegram_user_ids,
        is_active = true,
        updated_at = clock_timestamp()
    RETURNING supplier_id INTO v_supplier_id;

    INSERT INTO private.supplier_telegram_mapping_events (
        supplier_id,
        actor_id,
        previous_chat_id,
        new_chat_id,
        previous_authorized_user_ids,
        new_authorized_user_ids
    )
    VALUES (
        v_supplier_id,
        v_actor_id,
        v_previous_chat_id,
        p_telegram_chat_id,
        v_previous_authorized_user_ids,
        p_authorized_telegram_user_ids
    );

    RETURN v_supplier_id;
END;
$$;

CREATE FUNCTION public.configure_supplier_variant_mapping(
    p_supplier_id uuid,
    p_variant_id uuid,
    p_supplier_item_code text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_mapping_id uuid;
    v_previous_item_code text;
BEGIN
    IF v_actor_id IS NULL
        OR NOT EXISTS (
            SELECT 1
            FROM public.app_user_roles AS user_role
            WHERE user_role.user_id = v_actor_id
              AND user_role.role = 'SUPER_ADMIN'
        )
    THEN
        RAISE EXCEPTION 'super administrator role is required'
            USING ERRCODE = '42501';
    END IF;

    IF p_supplier_id IS NULL
        OR p_variant_id IS NULL
        OR p_supplier_item_code IS NULL
        OR p_supplier_item_code !~ '^[A-Z0-9_-]{1,64}$'
    THEN
        RAISE EXCEPTION 'invalid supplier variant mapping'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM private.supplier_telegram_mappings AS supplier
        WHERE supplier.supplier_id = p_supplier_id
          AND supplier.is_active
    ) THEN
        RAISE EXCEPTION 'active supplier does not exist'
            USING ERRCODE = '23503';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.product_variants AS variant
        JOIN public.products AS product USING (product_id)
        WHERE variant.variant_id = p_variant_id
          AND variant.is_active
          AND product.status = 'PUBLISHED'
    ) THEN
        RAISE EXCEPTION 'active published product variant does not exist'
            USING ERRCODE = '23503';
    END IF;

    SELECT mapping.mapping_id, mapping.supplier_item_code
    INTO v_mapping_id, v_previous_item_code
    FROM private.supplier_variant_mappings AS mapping
    WHERE mapping.supplier_id = p_supplier_id
      AND mapping.variant_id = p_variant_id
    FOR UPDATE;

    INSERT INTO private.supplier_variant_mappings (
        supplier_id,
        variant_id,
        supplier_item_code,
        changed_by
    )
    VALUES (
        p_supplier_id,
        p_variant_id,
        p_supplier_item_code,
        v_actor_id
    )
    ON CONFLICT (supplier_id, variant_id) DO UPDATE
    SET supplier_item_code = EXCLUDED.supplier_item_code,
        is_active = true,
        changed_by = EXCLUDED.changed_by,
        updated_at = clock_timestamp()
    RETURNING mapping_id INTO v_mapping_id;

    INSERT INTO private.supplier_mapping_events (
        mapping_id,
        actor_id,
        old_item_code,
        new_item_code
    )
    VALUES (
        v_mapping_id,
        v_actor_id,
        v_previous_item_code,
        p_supplier_item_code
    );

    RETURN v_mapping_id;
END;
$$;

CREATE FUNCTION public.ingest_supplier_telegram_update(
    p_update_id bigint,
    p_chat_id bigint,
    p_user_id bigint,
    p_message_id bigint,
    p_text text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
    v_supplier_id uuid;
    v_mapping_id uuid;
    v_supplier_code text;
    v_item_code text;
    v_quantity bigint;
    v_cost_minor bigint;
    v_status text;
    v_update_id bigint;
    v_existing_status text;
    v_report_id uuid;
    v_match text[];
BEGIN
    IF p_update_id IS NULL OR p_update_id <= 0 OR p_update_id > 9007199254740991
        OR p_chat_id IS NULL OR p_chat_id = 0
        OR abs(p_chat_id::numeric) > 9007199254740991
        OR p_user_id IS NULL OR p_user_id <= 0 OR p_user_id > 9007199254740991
        OR p_message_id IS NULL OR p_message_id <= 0
        OR p_message_id > 9007199254740991
        OR p_text IS NULL OR char_length(p_text) > 256
    THEN
        RAISE EXCEPTION 'invalid supplier Telegram update'
            USING ERRCODE = '22023';
    END IF;

    SELECT supplier.supplier_id, supplier.supplier_code
    INTO v_supplier_id, v_supplier_code
    FROM private.supplier_telegram_mappings AS supplier
    WHERE supplier.telegram_chat_id = p_chat_id
      AND supplier.is_active
      AND p_user_id = ANY (supplier.authorized_telegram_user_ids);

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'UNAUTHORIZED', 'duplicate', false);
    END IF;

    v_match := regexp_match(
        btrim(p_text),
        '^/available ([A-Z0-9_-]{1,64}) ([0-9]{1,9}) ([0-9]{1,18})$',
        'i'
    );

    IF v_match IS NULL THEN
        v_status := CASE
            WHEN btrim(p_text) ~ '^/available([[:space:]]|$)'
                THEN 'INVALID_MESSAGE'
            ELSE 'UNSUPPORTED_MESSAGE'
        END;
    ELSE
        v_item_code := upper(v_match[1]);
        v_quantity := v_match[2]::bigint;
        v_cost_minor := v_match[3]::bigint;
        IF (v_quantity = 0 AND v_cost_minor <> 0)
            OR (v_quantity > 0 AND v_cost_minor = 0)
        THEN
            v_status := 'INVALID_MESSAGE';
        ELSE
            SELECT mapping.mapping_id
            INTO v_mapping_id
            FROM private.supplier_variant_mappings AS mapping
            WHERE mapping.supplier_id = v_supplier_id
              AND mapping.supplier_item_code = v_item_code
              AND mapping.is_active;

            v_status := CASE
                WHEN v_mapping_id IS NULL THEN 'UNMAPPED_ITEM'
                ELSE 'RECORDED'
            END;
        END IF;
    END IF;

    INSERT INTO private.supplier_telegram_updates (
        update_id,
        supplier_id,
        telegram_chat_id,
        telegram_user_id,
        telegram_message_id,
        result_status
    )
    VALUES (
        p_update_id,
        v_supplier_id,
        p_chat_id,
        p_user_id,
        p_message_id,
        v_status
    )
    ON CONFLICT (update_id) DO NOTHING
    RETURNING update_id INTO v_update_id;

    IF v_update_id IS NULL THEN
        SELECT event.result_status
        INTO v_existing_status
        FROM private.supplier_telegram_updates AS event
        WHERE event.update_id = p_update_id
          AND event.supplier_id = v_supplier_id
          AND event.telegram_chat_id = p_chat_id
          AND event.telegram_user_id = p_user_id
          AND event.telegram_message_id = p_message_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Telegram update id conflicts with a different message'
                USING ERRCODE = '23505';
        END IF;

        RETURN jsonb_build_object(
            'status', v_existing_status,
            'duplicate', true
        );
    END IF;

    IF v_status = 'RECORDED' THEN
        INSERT INTO private.supplier_availability_reports (
            mapping_id,
            telegram_update_id,
            telegram_message_id,
            reported_by_telegram_user_id,
            available_quantity,
            supplier_cost_minor
        )
        VALUES (
            v_mapping_id,
            p_update_id,
            p_message_id,
            p_user_id,
            v_quantity,
            CASE WHEN v_quantity = 0 THEN NULL ELSE v_cost_minor END
        )
        RETURNING report_id INTO v_report_id;

        IF v_quantity = 0 THEN
            INSERT INTO private.transactional_outbox (
                aggregate_type,
                aggregate_id,
                event_type,
                payload
            )
            VALUES (
                'supplier_availability_report',
                v_report_id,
                'supplier.availability_gap',
                jsonb_build_object(
                    'supplier_code', v_supplier_code,
                    'supplier_item_code', v_item_code,
                    'report_id', v_report_id,
                    'telegram_update_id', p_update_id
                )
            )
            ON CONFLICT (aggregate_type, aggregate_id, event_type) DO NOTHING;
        END IF;
    ELSIF v_status = 'UNMAPPED_ITEM' THEN
        INSERT INTO private.transactional_outbox (
            aggregate_type,
            aggregate_id,
            event_type,
            payload
        )
        VALUES (
            'supplier_telegram_update',
            gen_random_uuid(),
            'supplier.mapping_required',
            jsonb_build_object(
                'supplier_code', v_supplier_code,
                'supplier_item_code', v_item_code,
                'telegram_update_id', p_update_id
            )
        )
        ON CONFLICT (aggregate_type, aggregate_id, event_type) DO NOTHING;
    END IF;

    RETURN jsonb_build_object(
        'status', v_status,
        'duplicate', false,
        'report_id', v_report_id
    );
END;
$$;

CREATE FUNCTION public.create_sourcing_batch(
    p_window_start timestamptz,
    p_window_end timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_batch_id uuid;
    v_item record;
    v_candidate record;
    v_required bigint;
    v_remaining bigint;
    v_available bigint;
    v_take bigint;
    v_gap_count integer := 0;
    v_allocation_count integer := 0;
    v_status text;
BEGIN
    IF v_actor_id IS NULL
        OR NOT EXISTS (
            SELECT 1
            FROM public.app_user_roles AS user_role
            WHERE user_role.user_id = v_actor_id
              AND user_role.role = 'SUPER_ADMIN'
        )
    THEN
        RAISE EXCEPTION 'super administrator role is required'
            USING ERRCODE = '42501';
    END IF;

    IF p_window_start IS NULL
        OR p_window_end IS NULL
        OR p_window_start >= p_window_end
        OR p_window_end > clock_timestamp()
        OR p_window_start < clock_timestamp() - interval '3 days'
        OR p_window_end - p_window_start > interval '48 hours'
    THEN
        RAISE EXCEPTION 'sourcing window must be a past window of at most 48 hours'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended('sourcing.batch.create', 0));

    INSERT INTO private.sourcing_batches (
        window_start,
        window_end,
        status,
        created_by
    )
    VALUES (
        p_window_start,
        p_window_end,
        'PROPOSED',
        v_actor_id
    )
    RETURNING batch_id INTO v_batch_id;

    FOR v_item IN
        SELECT
            order_record.order_id,
            order_item.order_item_id,
            order_item.variant_id,
            order_item.quantity
        FROM public.orders AS order_record
        JOIN public.order_items AS order_item USING (order_id)
        WHERE order_record.order_status = 'CONFIRMED'
          AND order_record.payment_status = 'SUCCEEDED'
          AND order_record.sourcing_status = 'PENDING'
          AND order_record.created_at >= p_window_start
          AND order_record.created_at < p_window_end
          AND order_record.sourcing_window_ends_at > clock_timestamp()
        ORDER BY order_record.created_at, order_record.order_id, order_item.order_item_id
    LOOP
        v_required := v_item.quantity;
        v_remaining := v_required;

        FOR v_candidate IN
            SELECT
                mapping.mapping_id,
                mapping.supplier_id,
                mapping.supplier_item_code,
                report.report_id,
                report.available_quantity,
                report.supplier_cost_minor,
                supplier.supplier_code
            FROM private.supplier_variant_mappings AS mapping
            JOIN private.supplier_telegram_mappings AS supplier
              ON supplier.supplier_id = mapping.supplier_id
             AND supplier.is_active
            JOIN LATERAL (
                SELECT availability.report_id,
                       availability.available_quantity,
                       availability.supplier_cost_minor,
                       availability.reported_at,
                       availability.expires_at
                FROM private.supplier_availability_reports AS availability
                WHERE availability.mapping_id = mapping.mapping_id
                  AND availability.expires_at > clock_timestamp()
                ORDER BY availability.reported_at DESC, availability.report_id DESC
                LIMIT 1
            ) AS report ON true
            WHERE mapping.variant_id = v_item.variant_id
              AND mapping.is_active
              AND report.available_quantity > 0
            ORDER BY report.supplier_cost_minor, supplier.supplier_code, mapping.mapping_id
        LOOP
            SELECT greatest(
                v_candidate.available_quantity::numeric
                - coalesce((
                    SELECT sum(allocation.quantity)
                    FROM private.sourcing_allocations AS allocation
                    JOIN private.sourcing_batches AS batch
                      ON batch.batch_id = allocation.batch_id
                    WHERE allocation.mapping_id = v_candidate.mapping_id
                      AND batch.status = 'APPROVED'
                      AND batch.approved_at > (
                          SELECT availability.reported_at
                          FROM private.supplier_availability_reports AS availability
                          WHERE availability.report_id = v_candidate.report_id
                      )
                ), 0)::numeric
                - coalesce((
                    SELECT sum(allocation.quantity)
                    FROM private.sourcing_allocations AS allocation
                    WHERE allocation.batch_id = v_batch_id
                      AND allocation.mapping_id = v_candidate.mapping_id
                ), 0)::numeric,
                0
            )::bigint
            INTO v_available;

            IF v_available <= 0 THEN
                CONTINUE;
            END IF;

            v_take := least(v_remaining, v_available);

            INSERT INTO private.sourcing_allocations (
                batch_id,
                order_id,
                order_item_id,
                report_id,
                mapping_id,
                quantity,
                supplier_cost_minor
            )
            VALUES (
                v_batch_id,
                v_item.order_id,
                v_item.order_item_id,
                v_candidate.report_id,
                v_candidate.mapping_id,
                v_take,
                v_candidate.supplier_cost_minor
            );

            v_remaining := v_remaining - v_take;
            v_allocation_count := v_allocation_count + 1;
            EXIT WHEN v_remaining = 0;
        END LOOP;

        IF v_remaining > 0 THEN
            INSERT INTO private.sourcing_gaps (
                batch_id,
                order_id,
                order_item_id,
                required_quantity,
                missing_quantity
            )
            VALUES (
                v_batch_id,
                v_item.order_id,
                v_item.order_item_id,
                v_required,
                v_remaining
            );
            v_gap_count := v_gap_count + 1;
        END IF;
    END LOOP;

    IF v_allocation_count = 0 AND v_gap_count = 0 THEN
        RAISE EXCEPTION 'no eligible paid orders found in the sourcing window'
            USING ERRCODE = 'P0002';
    END IF;

    v_status := CASE WHEN v_gap_count = 0 THEN 'PROPOSED' ELSE 'NEEDS_REVIEW' END;
    UPDATE private.sourcing_batches
    SET status = v_status
    WHERE batch_id = v_batch_id;

    INSERT INTO private.sourcing_batch_events (
        batch_id,
        event_type,
        actor_id,
        event_payload
    )
    VALUES (
        v_batch_id,
        'PLAN_CREATED',
        v_actor_id,
        jsonb_build_object(
            'allocation_count', v_allocation_count,
            'gap_count', v_gap_count
        )
    );

    INSERT INTO private.transactional_outbox (
        aggregate_type,
        aggregate_id,
        event_type,
        payload
    )
    VALUES (
        'sourcing_batch',
        v_batch_id,
        'sourcing.plan_created',
        jsonb_build_object(
            'batch_id', v_batch_id,
            'status', v_status,
            'allocation_count', v_allocation_count,
            'gap_count', v_gap_count
        )
    );

    RETURN jsonb_build_object(
        'batch_id', v_batch_id,
        'status', v_status,
        'allocation_count', v_allocation_count,
        'gap_count', v_gap_count
    );
END;
$$;

CREATE FUNCTION public.approve_sourcing_batch(p_batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_batch private.sourcing_batches%ROWTYPE;
    v_supplier_payload jsonb;
BEGIN
    IF v_actor_id IS NULL
        OR NOT EXISTS (
            SELECT 1
            FROM public.app_user_roles AS user_role
            WHERE user_role.user_id = v_actor_id
              AND user_role.role = 'SUPER_ADMIN'
        )
    THEN
        RAISE EXCEPTION 'super administrator role is required'
            USING ERRCODE = '42501';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended('sourcing.batch.create', 0));

    SELECT *
    INTO v_batch
    FROM private.sourcing_batches
    WHERE batch_id = p_batch_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'sourcing batch does not exist'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_batch.status <> 'PROPOSED' THEN
        RAISE EXCEPTION 'only a complete proposed sourcing batch can be approved'
            USING ERRCODE = '55000';
    END IF;
    IF v_batch.created_by = v_actor_id THEN
        RAISE EXCEPTION 'sourcing plan creator cannot approve the same plan'
            USING ERRCODE = '42501';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM private.sourcing_gaps AS gap
        WHERE gap.batch_id = p_batch_id
    ) THEN
        RAISE EXCEPTION 'sourcing plan has unresolved availability gaps'
            USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM private.sourcing_allocations AS allocation
        JOIN private.supplier_availability_reports AS report
          ON report.report_id = allocation.report_id
        WHERE allocation.batch_id = p_batch_id
          AND (
              report.expires_at <= clock_timestamp()
              OR report.report_id IS DISTINCT FROM (
                  SELECT latest.report_id
                  FROM private.supplier_availability_reports AS latest
                  WHERE latest.mapping_id = allocation.mapping_id
                  ORDER BY latest.reported_at DESC, latest.report_id DESC
                  LIMIT 1
              )
              OR report.available_quantity < (
                  SELECT coalesce(sum(committed.quantity), 0)
                  FROM private.sourcing_allocations AS committed
                  JOIN private.sourcing_batches AS committed_batch
                    ON committed_batch.batch_id = committed.batch_id
                  WHERE committed.mapping_id = allocation.mapping_id
                    AND committed_batch.status = 'APPROVED'
                    AND committed_batch.approved_at > report.reported_at
              ) + (
                  SELECT sum(current_batch.quantity)
                  FROM private.sourcing_allocations AS current_batch
                  WHERE current_batch.batch_id = p_batch_id
                    AND current_batch.mapping_id = allocation.mapping_id
              )
          )
    ) THEN
        RAISE EXCEPTION 'supplier availability changed or expired; rebuild the sourcing plan'
            USING ERRCODE = '23514';
    END IF;

    SELECT jsonb_agg(
        jsonb_build_object(
            'supplier_code', supplier_items.supplier_code,
            'supplier_id', supplier_items.supplier_id,
            'items', supplier_items.items
        )
        ORDER BY supplier_items.supplier_code
    )
    INTO v_supplier_payload
    FROM (
        SELECT
            supplier.supplier_id,
            supplier.supplier_code,
            jsonb_agg(
                jsonb_build_object(
                    'item_code', item_totals.item_code,
                    'quantity', item_totals.quantity
                )
                ORDER BY item_totals.item_code
            ) AS items
        FROM (
            SELECT
                supplier.supplier_id,
                supplier.supplier_code,
                mapping.supplier_item_code AS item_code,
                sum(allocation.quantity) AS quantity
            FROM private.sourcing_allocations AS allocation
            JOIN private.supplier_variant_mappings AS mapping
              ON mapping.mapping_id = allocation.mapping_id
            JOIN private.supplier_telegram_mappings AS supplier
              ON supplier.supplier_id = mapping.supplier_id
            WHERE allocation.batch_id = p_batch_id
            GROUP BY
                supplier.supplier_id,
                supplier.supplier_code,
                mapping.supplier_item_code
        ) AS item_totals
        JOIN private.supplier_telegram_mappings AS supplier
          ON supplier.supplier_id = item_totals.supplier_id
        GROUP BY supplier.supplier_id, supplier.supplier_code
    ) AS supplier_items;

    UPDATE private.sourcing_batches
    SET status = 'APPROVED',
        approved_by = v_actor_id,
        approved_at = clock_timestamp()
    WHERE batch_id = p_batch_id;

    UPDATE public.orders AS order_record
    SET sourcing_status = 'SOURCING'
    WHERE order_record.order_id IN (
        SELECT allocation.order_id
        FROM private.sourcing_allocations AS allocation
        WHERE allocation.batch_id = p_batch_id
    );

    INSERT INTO private.sourcing_batch_events (
        batch_id,
        event_type,
        actor_id,
        event_payload
    )
    VALUES (
        p_batch_id,
        'APPROVED',
        v_actor_id,
        jsonb_build_object('supplier_count', jsonb_array_length(v_supplier_payload))
    );

    INSERT INTO private.transactional_outbox (
        aggregate_type,
        aggregate_id,
        event_type,
        payload
    )
    VALUES (
        'sourcing_batch',
        p_batch_id,
        'sourcing.orders_prepared',
        jsonb_build_object(
            'batch_id', p_batch_id,
            'approved_by', v_actor_id,
            'suppliers', coalesce(v_supplier_payload, '[]'::jsonb)
        )
    );

    RETURN jsonb_build_object('batch_id', p_batch_id, 'status', 'APPROVED');
END;
$$;

CREATE FUNCTION public.cancel_sourcing_batch(p_batch_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_batch private.sourcing_batches%ROWTYPE;
BEGIN
    IF v_actor_id IS NULL
        OR NOT EXISTS (
            SELECT 1
            FROM public.app_user_roles AS user_role
            WHERE user_role.user_id = v_actor_id
              AND user_role.role = 'SUPER_ADMIN'
        )
    THEN
        RAISE EXCEPTION 'super administrator role is required'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
    INTO v_batch
    FROM private.sourcing_batches
    WHERE batch_id = p_batch_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'sourcing batch does not exist'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_batch.status NOT IN ('PROPOSED', 'NEEDS_REVIEW') THEN
        RAISE EXCEPTION 'only an unapproved sourcing batch can be cancelled'
            USING ERRCODE = '55000';
    END IF;

    UPDATE private.sourcing_batches
    SET status = 'CANCELLED'
    WHERE batch_id = p_batch_id;

    INSERT INTO private.sourcing_batch_events (
        batch_id,
        event_type,
        actor_id
    )
    VALUES (p_batch_id, 'CANCELLED', v_actor_id);

    RETURN jsonb_build_object('batch_id', p_batch_id, 'status', 'CANCELLED');
END;
$$;

REVOKE ALL ON FUNCTION private.prevent_commerce_record_mutation()
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.configure_supplier_telegram_mapping(text, text, bigint, bigint[])
    FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.configure_supplier_variant_mapping(uuid, uuid, text)
    FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.ingest_supplier_telegram_update(bigint, bigint, bigint, bigint, text)
    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_sourcing_batch(timestamptz, timestamptz)
    FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.approve_sourcing_batch(uuid)
    FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.cancel_sourcing_batch(uuid)
    FROM PUBLIC, anon, service_role;

GRANT EXECUTE ON FUNCTION public.configure_supplier_variant_mapping(uuid, uuid, text)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.configure_supplier_telegram_mapping(text, text, bigint, bigint[])
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_supplier_telegram_update(bigint, bigint, bigint, bigint, text)
    TO service_role;
GRANT EXECUTE ON FUNCTION public.create_sourcing_batch(timestamptz, timestamptz)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_sourcing_batch(uuid)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_sourcing_batch(uuid)
    TO authenticated;
