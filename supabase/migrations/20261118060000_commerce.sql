CREATE TYPE public.order_status AS ENUM (
    'PAYMENT_PENDING',
    'CONFIRMED',
    'PROCESSING',
    'SHIPPED',
    'DELIVERED',
    'CANCELLED',
    'REFUND_PENDING',
    'REFUNDED'
);

CREATE TYPE public.payment_status AS ENUM (
    'UNKNOWN',
    'PENDING',
    'SUCCEEDED',
    'FAILED',
    'PARTIALLY_REFUNDED',
    'REFUNDED'
);

CREATE TYPE public.sourcing_status AS ENUM (
    'PENDING',
    'SOURCING',
    'SOURCED',
    'FAILED',
    'CANCELLED'
);

CREATE TABLE public.orders (
    order_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    order_status public.order_status NOT NULL DEFAULT 'PAYMENT_PENDING',
    payment_status public.payment_status NOT NULL DEFAULT 'PENDING',
    sourcing_status public.sourcing_status NOT NULL DEFAULT 'PENDING',
    payment_method text NOT NULL CHECK (
        payment_method IN ('CARD', 'MOBILE_WALLET', 'BANK_TRANSFER')
    ),
    currency_code text NOT NULL DEFAULT 'EGP' CHECK (currency_code = 'EGP'),
    subtotal_minor bigint NOT NULL CHECK (subtotal_minor > 0),
    shipping_minor bigint NOT NULL DEFAULT 0 CHECK (shipping_minor >= 0),
    discount_minor bigint NOT NULL DEFAULT 0 CHECK (discount_minor >= 0),
    total_minor bigint NOT NULL CHECK (
        total_minor > 0 AND
        total_minor::numeric =
            subtotal_minor::numeric + shipping_minor::numeric - discount_minor::numeric
    ),
    sourcing_window_ends_at timestamptz NOT NULL
        DEFAULT (now() + interval '2 days'),
    snapshot_schema_version smallint NOT NULL CHECK (snapshot_schema_version > 0),
    snapshot_json jsonb NOT NULL CHECK (jsonb_typeof(snapshot_json) = 'object'),
    snapshot_sha256 text NOT NULL CHECK (snapshot_sha256 ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (
        sourcing_window_ends_at >= created_at + interval '2 days'
        AND sourcing_window_ends_at <= created_at + interval '3 days'
    ),
    CHECK (discount_minor <= subtotal_minor + shipping_minor),
    CHECK (
        order_status NOT IN ('CONFIRMED', 'PROCESSING', 'SHIPPED', 'DELIVERED')
        OR payment_status IN ('SUCCEEDED', 'PARTIALLY_REFUNDED')
    )
);

CREATE INDEX orders_customer_created_idx
    ON public.orders (customer_id, created_at DESC);
CREATE INDEX orders_status_created_idx
    ON public.orders (order_status, created_at DESC);

CREATE TABLE public.order_items (
    order_item_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    variant_id uuid NOT NULL REFERENCES public.product_variants (variant_id) ON DELETE RESTRICT,
    quantity bigint NOT NULL CHECK (quantity > 0),
    unit_price_minor bigint NOT NULL CHECK (unit_price_minor > 0),
    line_total_minor bigint NOT NULL CHECK (
        line_total_minor::numeric = quantity::numeric * unit_price_minor::numeric
    ),
    item_snapshot jsonb NOT NULL CHECK (jsonb_typeof(item_snapshot) = 'object'),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (order_id, variant_id)
);

CREATE INDEX order_items_order_idx ON public.order_items (order_id, order_item_id);

CREATE TABLE public.customer_contract_confirmations (
    confirmation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    order_id uuid REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    terms_version text NOT NULL CHECK (char_length(terms_version) BETWEEN 1 AND 64),
    terms_sha256 text NOT NULL CHECK (terms_sha256 ~ '^[0-9a-f]{64}$'),
    accepted_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX customer_contracts_customer_idx
    ON public.customer_contract_confirmations (customer_id, accepted_at DESC);

CREATE TABLE public.shipping_regions (
    region_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_region_id uuid REFERENCES public.shipping_regions (region_id) ON DELETE RESTRICT,
    provider text NOT NULL CHECK (provider IN ('BOSTA', 'EGYPTIAN_POST')),
    provider_region_code text NOT NULL CHECK (
        char_length(provider_region_code) BETWEEN 1 AND 100
    ),
    name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
    shipping_minor bigint NOT NULL CHECK (shipping_minor >= 0),
    currency_code text NOT NULL DEFAULT 'EGP' CHECK (currency_code = 'EGP'),
    is_active boolean NOT NULL DEFAULT false,
    updated_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_region_id IS NULL OR parent_region_id <> region_id),
    UNIQUE (provider, provider_region_code)
);

CREATE INDEX shipping_regions_parent_idx
    ON public.shipping_regions (parent_region_id, provider, is_active);

CREATE TABLE private.payment_webhook_events (
    event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{0,63}$'),
    provider_event_id text NOT NULL CHECK (
        char_length(provider_event_id) BETWEEN 1 AND 200
    ),
    order_id uuid REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    event_type text NOT NULL CHECK (char_length(event_type) BETWEEN 1 AND 100),
    event_payload jsonb NOT NULL CHECK (
        jsonb_typeof(event_payload) = 'object'
        AND octet_length(event_payload::text) <= 65536
    ),
    signature_verified boolean NOT NULL CHECK (signature_verified),
    amount_minor bigint CHECK (amount_minor IS NULL OR amount_minor > 0),
    currency_code text CHECK (currency_code IS NULL OR currency_code = 'EGP'),
    received_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, provider_event_id)
);

CREATE TABLE private.idempotency_keys (
    idempotency_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope text NOT NULL CHECK (scope ~ '^[a-z][a-z0-9_.-]{0,127}$'),
    idempotency_key text NOT NULL CHECK (
        char_length(idempotency_key) BETWEEN 1 AND 200
    ),
    request_sha256 text NOT NULL CHECK (request_sha256 ~ '^[0-9a-f]{64}$'),
    state text NOT NULL DEFAULT 'PROCESSING'
        CHECK (state IN ('PROCESSING', 'SUCCEEDED', 'FAILED')),
    response_json jsonb CHECK (
        response_json IS NULL OR jsonb_typeof(response_json) = 'object'
    ),
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz,
    UNIQUE (scope, idempotency_key),
    CHECK (
        (state = 'PROCESSING' AND completed_at IS NULL)
        OR (state IN ('SUCCEEDED', 'FAILED') AND completed_at IS NOT NULL)
    )
);

CREATE TABLE private.transactional_outbox (
    outbox_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type text NOT NULL CHECK (aggregate_type ~ '^[a-z][a-z0-9_]{0,63}$'),
    aggregate_id uuid NOT NULL,
    event_type text NOT NULL CHECK (event_type ~ '^[a-z][a-z0-9_.-]{0,127}$'),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    state text NOT NULL DEFAULT 'PENDING'
        CHECK (state IN ('PENDING', 'PROCESSING', 'DELIVERED', 'FAILED')),
    attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    available_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    delivered_at timestamptz,
    UNIQUE (aggregate_type, aggregate_id, event_type),
    CHECK (
        (state = 'DELIVERED' AND delivered_at IS NOT NULL)
        OR (state <> 'DELIVERED' AND delivered_at IS NULL)
    )
);

CREATE INDEX transactional_outbox_pending_idx
    ON private.transactional_outbox (available_at, created_at)
    WHERE state IN ('PENDING', 'FAILED');

CREATE TABLE private.refund_approvals (
    refund_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    amount_minor bigint NOT NULL CHECK (amount_minor > 0),
    currency_code text NOT NULL DEFAULT 'EGP' CHECK (currency_code = 'EGP'),
    idempotency_key text NOT NULL UNIQUE CHECK (
        char_length(idempotency_key) BETWEEN 1 AND 200
    ),
    requested_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    approved_by uuid REFERENCES auth.users (id) ON DELETE RESTRICT,
    state text NOT NULL DEFAULT 'REQUESTED'
        CHECK (state IN ('REQUESTED', 'APPROVED', 'REJECTED', 'COMPLETED')),
    reason text NOT NULL CHECK (char_length(reason) BETWEEN 1 AND 1000),
    created_at timestamptz NOT NULL DEFAULT now(),
    decided_at timestamptz,
    CHECK (approved_by IS NULL OR approved_by <> requested_by),
    CHECK (
        (state = 'REQUESTED' AND approved_by IS NULL AND decided_at IS NULL)
        OR (state <> 'REQUESTED' AND approved_by IS NOT NULL AND decided_at IS NOT NULL)
    )
);

CREATE TABLE private.loyalty_ledger (
    loyalty_entry_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    entry_type text NOT NULL CHECK (
        entry_type IN ('EARN', 'REDEEM', 'EXPIRE', 'REFERRAL', 'WELCOME', 'REVERSAL')
    ),
    points_delta integer NOT NULL CHECK (points_delta <> 0),
    source_type text NOT NULL CHECK (source_type ~ '^[a-z][a-z0-9_]{0,63}$'),
    source_id text NOT NULL CHECK (char_length(source_id) BETWEEN 1 AND 200),
    earned_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source_type, source_id, customer_id),
    CHECK (
        (points_delta > 0 AND expires_at = earned_at + interval '30 days')
        OR (points_delta < 0 AND expires_at IS NULL)
    )
);

CREATE INDEX loyalty_ledger_customer_expiry_idx
    ON private.loyalty_ledger (customer_id, expires_at, earned_at)
    WHERE points_delta > 0;

CREATE TABLE private.customer_referrals (
    referral_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    referrer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    invitee_id uuid NOT NULL UNIQUE REFERENCES auth.users (id) ON DELETE RESTRICT,
    referral_code text NOT NULL CHECK (char_length(referral_code) BETWEEN 1 AND 100),
    phone_verified_at timestamptz,
    first_successful_order_id uuid REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    reward_eligible_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (referrer_id <> invitee_id),
    CHECK (
        (reward_eligible_at IS NULL AND first_successful_order_id IS NULL)
        OR (reward_eligible_at IS NOT NULL AND first_successful_order_id IS NOT NULL)
    )
);

CREATE TABLE private.supplier_telegram_mappings (
    supplier_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_code text NOT NULL UNIQUE CHECK (supplier_code ~ '^[A-Z0-9_-]{1,64}$'),
    supplier_name text NOT NULL CHECK (char_length(supplier_name) BETWEEN 1 AND 160),
    telegram_chat_id bigint NOT NULL UNIQUE,
    authorized_telegram_user_ids bigint[] NOT NULL
        CHECK (cardinality(authorized_telegram_user_ids) > 0),
    is_active boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (array_position(authorized_telegram_user_ids, NULL) IS NULL)
);

CREATE TABLE private.supplier_submissions (
    submission_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    supplier_id uuid NOT NULL REFERENCES private.supplier_telegram_mappings (supplier_id)
        ON DELETE RESTRICT,
    telegram_message_id bigint NOT NULL,
    submitted_by_telegram_user_id bigint NOT NULL,
    product_name text NOT NULL CHECK (char_length(product_name) BETWEEN 1 AND 300),
    supplier_cost_minor bigint CHECK (supplier_cost_minor IS NULL OR supplier_cost_minor > 0),
    currency_code text NOT NULL DEFAULT 'EGP' CHECK (currency_code = 'EGP'),
    image_object_key text CHECK (
        image_object_key IS NULL
        OR (
            char_length(image_object_key) BETWEEN 1 AND 512
            AND image_object_key !~ '(^/|(^|/)\.\.?(/|$))'
        )
    ),
    submitted_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (supplier_id, telegram_message_id)
);

CREATE INDEX supplier_submissions_supplier_idx
    ON private.supplier_submissions (supplier_id, submitted_at DESC);

CREATE TABLE private.inventory_snapshots (
    snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    variant_id uuid NOT NULL REFERENCES private.inventory_balances (variant_id)
        ON DELETE RESTRICT,
    physical_quantity bigint NOT NULL CHECK (physical_quantity >= 0),
    reserved_quantity bigint NOT NULL CHECK (
        reserved_quantity >= 0 AND reserved_quantity <= physical_quantity
    ),
    captured_at timestamptz NOT NULL DEFAULT now(),
    CHECK (physical_quantity >= reserved_quantity),
    UNIQUE (variant_id, captured_at)
);

CREATE OR REPLACE FUNCTION private.prevent_commerce_record_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, private
AS $$
BEGIN
    RAISE EXCEPTION 'immutable commerce records cannot be changed'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER order_items_append_only
    BEFORE UPDATE OR DELETE ON public.order_items
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE TRIGGER customer_contracts_append_only
    BEFORE UPDATE OR DELETE ON public.customer_contract_confirmations
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE TRIGGER payment_webhook_events_append_only
    BEFORE UPDATE OR DELETE ON private.payment_webhook_events
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE TRIGGER loyalty_ledger_append_only
    BEFORE UPDATE OR DELETE ON private.loyalty_ledger
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE TRIGGER inventory_snapshots_append_only
    BEFORE UPDATE OR DELETE ON private.inventory_snapshots
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE FUNCTION public.set_commerce_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER orders_set_updated_at
    BEFORE UPDATE ON public.orders
    FOR EACH ROW EXECUTE FUNCTION public.set_commerce_updated_at();

CREATE TRIGGER shipping_regions_set_updated_at
    BEFORE UPDATE ON public.shipping_regions
    FOR EACH ROW EXECUTE FUNCTION public.set_commerce_updated_at();

CREATE TRIGGER orders_snapshot_immutable
    BEFORE UPDATE OF snapshot_schema_version, snapshot_json, snapshot_sha256 ON public.orders
    FOR EACH ROW
    WHEN (
        OLD.snapshot_schema_version IS DISTINCT FROM NEW.snapshot_schema_version
        OR OLD.snapshot_json IS DISTINCT FROM NEW.snapshot_json
        OR OLD.snapshot_sha256 IS DISTINCT FROM NEW.snapshot_sha256
    )
    EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE FUNCTION public.set_contract_confirmation_identity()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    NEW.customer_id := (SELECT auth.uid());
    IF NEW.customer_id IS NULL THEN
        RAISE EXCEPTION 'authenticated customer identity is required'
            USING ERRCODE = '28000';
    END IF;
    NEW.accepted_at := now();
    NEW.created_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER customer_contracts_set_identity
    BEFORE INSERT ON public.customer_contract_confirmations
    FOR EACH ROW EXECUTE FUNCTION public.set_contract_confirmation_identity();

ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders FORCE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items FORCE ROW LEVEL SECURITY;
ALTER TABLE public.customer_contract_confirmations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_contract_confirmations FORCE ROW LEVEL SECURITY;
ALTER TABLE public.shipping_regions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shipping_regions FORCE ROW LEVEL SECURITY;

CREATE POLICY orders_customer_read
    ON public.orders FOR SELECT TO authenticated
    USING (customer_id = (SELECT auth.uid()));

CREATE POLICY orders_admin_read
    ON public.orders FOR SELECT TO authenticated
    USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY order_items_customer_read
    ON public.order_items FOR SELECT TO authenticated
    USING (
        EXISTS (
            SELECT 1
            FROM public.orders AS order_record
            WHERE order_record.order_id = order_items.order_id
              AND (
                  order_record.customer_id = (SELECT auth.uid())
                  OR public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN')
              )
        )
    );

CREATE POLICY contracts_customer_read
    ON public.customer_contract_confirmations FOR SELECT TO authenticated
    USING (customer_id = (SELECT auth.uid()));

CREATE POLICY contracts_customer_insert
    ON public.customer_contract_confirmations FOR INSERT TO authenticated
    WITH CHECK (customer_id = (SELECT auth.uid()));

CREATE POLICY shipping_regions_public_read
    ON public.shipping_regions FOR SELECT TO anon, authenticated
    USING (is_active);

CREATE POLICY shipping_regions_admin_read
    ON public.shipping_regions FOR SELECT TO authenticated
    USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY shipping_regions_super_admin_insert
    ON public.shipping_regions FOR INSERT TO authenticated
    WITH CHECK (public.get_my_role() = 'SUPER_ADMIN');

CREATE POLICY shipping_regions_super_admin_update
    ON public.shipping_regions FOR UPDATE TO authenticated
    USING (public.get_my_role() = 'SUPER_ADMIN')
    WITH CHECK (public.get_my_role() = 'SUPER_ADMIN');

CREATE POLICY shipping_regions_super_admin_delete
    ON public.shipping_regions FOR DELETE TO authenticated
    USING (public.get_my_role() = 'SUPER_ADMIN');

REVOKE ALL ON public.orders, public.order_items, public.customer_contract_confirmations,
    public.shipping_regions FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.orders, public.order_items TO authenticated;
GRANT SELECT, INSERT ON public.customer_contract_confirmations TO authenticated;
GRANT SELECT ON public.shipping_regions TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.shipping_regions TO authenticated;

ALTER TABLE private.payment_webhook_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.payment_webhook_events FORCE ROW LEVEL SECURITY;
ALTER TABLE private.idempotency_keys ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.idempotency_keys FORCE ROW LEVEL SECURITY;
ALTER TABLE private.transactional_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.transactional_outbox FORCE ROW LEVEL SECURITY;
ALTER TABLE private.refund_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.refund_approvals FORCE ROW LEVEL SECURITY;
ALTER TABLE private.loyalty_ledger ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.loyalty_ledger FORCE ROW LEVEL SECURITY;
ALTER TABLE private.customer_referrals ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.customer_referrals FORCE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_telegram_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_telegram_mappings FORCE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_submissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.supplier_submissions FORCE ROW LEVEL SECURITY;
ALTER TABLE private.inventory_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.inventory_snapshots FORCE ROW LEVEL SECURITY;

REVOKE ALL ON ALL TABLES IN SCHEMA private FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA private FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION private.prevent_commerce_record_mutation()
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_commerce_updated_at() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.set_contract_confirmation_identity()
    FROM PUBLIC, anon, authenticated;
