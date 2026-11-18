CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

ALTER TABLE private.customer_referrals
    ADD COLUMN tier_level smallint NOT NULL DEFAULT 1
        CHECK (tier_level BETWEEN 1 AND 3),
    ADD COLUMN expires_at timestamptz,
    ADD COLUMN reward_points integer NOT NULL DEFAULT 0
        CHECK (reward_points >= 0),
    ADD COLUMN reward_status text NOT NULL DEFAULT 'PENDING'
        CHECK (reward_status IN ('PENDING', 'EARNED', 'EXPIRED', 'REVERSED'));

CREATE TABLE private.referral_codes (
    referral_code_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    referrer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    code_hash text NOT NULL UNIQUE CHECK (code_hash ~ '^[0-9a-f]{64}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    CHECK (expires_at > created_at),
    CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE INDEX referral_codes_referrer_idx
    ON private.referral_codes (referrer_id, created_at DESC);

CREATE TABLE private.referral_rpc_idempotency (
    operation text NOT NULL CHECK (operation IN ('register_customer_referral', 'record_referral_qualifying_order')),
    idempotency_key text NOT NULL CHECK (char_length(idempotency_key) BETWEEN 1 AND 200),
    actor_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    payload_hash text NOT NULL CHECK (payload_hash ~ '^[0-9a-f]{64}$'),
    result jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (operation, idempotency_key)
);

CREATE TABLE public.consumer_return_requests (
    return_request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    order_id uuid NOT NULL REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    refund_amount_minor bigint NOT NULL CHECK (refund_amount_minor > 0),
    reason text NOT NULL CHECK (char_length(reason) BETWEEN 10 AND 1000),
    contract_confirmation_id uuid NOT NULL
        REFERENCES public.customer_contract_confirmations (confirmation_id) ON DELETE RESTRICT,
    status text NOT NULL DEFAULT 'REQUESTED'
        CHECK (status IN ('REQUESTED', 'APPROVED', 'REJECTED', 'COMPLETED', 'CANCELLED')),
    requested_by uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    approved_by uuid REFERENCES auth.users (id) ON DELETE RESTRICT,
    refund_id uuid REFERENCES private.refund_approvals (refund_id) ON DELETE RESTRICT,
    idempotency_key text NOT NULL UNIQUE CHECK (char_length(idempotency_key) BETWEEN 1 AND 200),
    created_at timestamptz NOT NULL DEFAULT now(),
    decided_at timestamptz,
    completed_at timestamptz,
    CHECK (approved_by IS NULL OR approved_by <> requested_by),
    CHECK (
        (status = 'REQUESTED' AND approved_by IS NULL AND decided_at IS NULL)
        OR (status = 'APPROVED' AND approved_by IS NOT NULL AND decided_at IS NOT NULL)
        OR (status = 'REJECTED' AND approved_by IS NOT NULL AND decided_at IS NOT NULL)
        OR (status = 'COMPLETED' AND approved_by IS NOT NULL AND decided_at IS NOT NULL AND completed_at IS NOT NULL)
        OR (status = 'CANCELLED' AND approved_by IS NULL AND decided_at IS NULL)
    )
);

CREATE INDEX consumer_return_requests_customer_created_idx
    ON public.consumer_return_requests (customer_id, created_at DESC);
CREATE INDEX consumer_return_requests_queue_idx
    ON public.consumer_return_requests (status, created_at);

CREATE TABLE private.loyalty_redemption_allocations (
    allocation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    positive_entry_id uuid NOT NULL REFERENCES private.loyalty_ledger (loyalty_entry_id) ON DELETE RESTRICT,
    redemption_entry_id uuid NOT NULL REFERENCES private.loyalty_ledger (loyalty_entry_id) ON DELETE RESTRICT,
    points bigint NOT NULL CHECK (points > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (positive_entry_id, redemption_entry_id)
);

CREATE TABLE private.referral_rewards (
    reward_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    referrer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    invitee_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    referral_id uuid NOT NULL REFERENCES private.customer_referrals (referral_id) ON DELETE RESTRICT,
    qualifying_order_id uuid NOT NULL REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    tier_level smallint NOT NULL CHECK (tier_level BETWEEN 1 AND 3),
    points integer NOT NULL CHECK (points > 0),
    earned_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL,
    status text NOT NULL DEFAULT 'EARNED'
        CHECK (status IN ('EARNED', 'EXPIRED', 'REVERSED')),
    UNIQUE (qualifying_order_id, referral_id, tier_level),
    CHECK (expires_at = earned_at + interval '30 days')
);

CREATE TABLE private.legal_contract_versions (
    terms_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    terms_version text NOT NULL CHECK (char_length(terms_version) BETWEEN 1 AND 64),
    terms_sha256 text NOT NULL CHECK (terms_sha256 ~ '^[0-9a-f]{64}$'),
    terms_text text NOT NULL CHECK (char_length(terms_text) BETWEEN 1 AND 10000),
    terms_type text NOT NULL CHECK (terms_type IN ('ORDER', 'REFUND', 'LOYALTY', 'PRIVACY')),
    is_active boolean NOT NULL DEFAULT false,
    effective_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (terms_version, terms_type)
);

CREATE UNIQUE INDEX one_active_contract_per_type_idx
    ON private.legal_contract_versions (terms_type)
    WHERE is_active;

CREATE TABLE public.legal_acceptances (
    acceptance_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    terms_id uuid NOT NULL REFERENCES private.legal_contract_versions (terms_id) ON DELETE RESTRICT,
    order_id uuid REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    accepted_at timestamptz NOT NULL DEFAULT now(),
    idempotency_key text NOT NULL UNIQUE CHECK (char_length(idempotency_key) BETWEEN 1 AND 200),
    CHECK (
        (terms_id IS NOT NULL)
    )
);

CREATE INDEX legal_acceptances_customer_idx
    ON public.legal_acceptances (customer_id, accepted_at DESC);

CREATE TRIGGER loyalty_redemption_allocations_append_only
    BEFORE UPDATE OR DELETE ON private.loyalty_redemption_allocations
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE TRIGGER referral_rewards_append_only
    BEFORE UPDATE OR DELETE ON private.referral_rewards
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE TRIGGER legal_contract_versions_append_only
    BEFORE UPDATE OR DELETE ON private.legal_contract_versions
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE TRIGGER legal_acceptances_append_only
    BEFORE UPDATE OR DELETE ON public.legal_acceptances
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

ALTER TABLE public.consumer_return_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.consumer_return_requests FORCE ROW LEVEL SECURITY;
ALTER TABLE public.legal_acceptances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.legal_acceptances FORCE ROW LEVEL SECURITY;
ALTER TABLE private.loyalty_redemption_allocations ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.loyalty_redemption_allocations FORCE ROW LEVEL SECURITY;
ALTER TABLE private.referral_rewards ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.referral_rewards FORCE ROW LEVEL SECURITY;
ALTER TABLE private.referral_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.referral_codes FORCE ROW LEVEL SECURITY;
ALTER TABLE private.referral_rpc_idempotency ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.referral_rpc_idempotency FORCE ROW LEVEL SECURITY;
ALTER TABLE private.legal_contract_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.legal_contract_versions FORCE ROW LEVEL SECURITY;

CREATE POLICY return_requests_customer_read
ON public.consumer_return_requests FOR SELECT TO authenticated
USING (customer_id = (SELECT auth.uid()));

CREATE POLICY return_requests_admin_read
ON public.consumer_return_requests FOR SELECT TO authenticated
USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY legal_acceptances_customer_read
ON public.legal_acceptances FOR SELECT TO authenticated
USING (customer_id = (SELECT auth.uid()));

CREATE POLICY legal_acceptances_admin_read
ON public.legal_acceptances FOR SELECT TO authenticated
USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

REVOKE ALL ON public.consumer_return_requests, public.legal_acceptances
    FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.consumer_return_requests, public.legal_acceptances TO authenticated;

CREATE FUNCTION public.get_loyalty_balance()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
    WITH active_balance AS (
        SELECT COALESCE(sum(
            CASE
                WHEN entry.points_delta > 0
                 AND entry.expires_at > clock_timestamp()
                THEN entry.points_delta
                WHEN entry.points_delta < 0
                THEN entry.points_delta
                ELSE 0
            END
        ), 0)::bigint AS points
        FROM private.loyalty_ledger AS entry
        WHERE entry.customer_id = auth.uid()
    )
    SELECT jsonb_build_object(
        'points', GREATEST(points, 0),
        'currency_code', 'POINTS'
    )
    FROM active_balance;
$$;

CREATE FUNCTION public.grant_loyalty_points(
    p_customer_id uuid,
    p_points integer,
    p_source_type text,
    p_source_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_entry private.loyalty_ledger%ROWTYPE;
    v_earned_at timestamptz := clock_timestamp();
BEGIN
    IF p_customer_id IS NULL OR p_points IS NULL OR p_points <= 0
       OR p_points > 1000000 OR p_source_type IS NULL
       OR p_source_type !~ '^[a-z][a-z0-9_]{0,63}$'
       OR p_source_id IS NULL OR char_length(p_source_id) NOT BETWEEN 1 AND 200
    THEN
        RAISE EXCEPTION 'invalid loyalty grant'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO private.loyalty_ledger (
        customer_id, entry_type, points_delta, source_type, source_id,
        earned_at, expires_at
    )
    VALUES (
        p_customer_id, 'EARN', p_points, p_source_type, p_source_id,
        v_earned_at, v_earned_at + interval '30 days'
    )
    ON CONFLICT (source_type, source_id, customer_id) DO NOTHING
    RETURNING * INTO v_entry;

    IF NOT FOUND THEN
        SELECT *
        INTO v_entry
        FROM private.loyalty_ledger
        WHERE customer_id = p_customer_id
          AND source_type = p_source_type
          AND source_id = p_source_id;
    END IF;

    RETURN jsonb_build_object(
        'loyalty_entry_id', v_entry.loyalty_entry_id,
        'customer_id', v_entry.customer_id,
        'points', v_entry.points_delta,
        'expires_at', v_entry.expires_at
    );
END;
$$;

CREATE FUNCTION public.redeem_loyalty_points(
    p_points integer,
    p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_customer_id uuid := auth.uid();
    v_remaining integer;
    v_entry private.loyalty_ledger%ROWTYPE;
    v_allocated bigint;
    v_take integer;
    v_redemption private.loyalty_ledger%ROWTYPE;
    v_existing private.loyalty_ledger%ROWTYPE;
BEGIN
    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'authenticated customer identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF p_points IS NULL OR p_points <= 0 OR p_points > 1000000
       OR p_idempotency_key IS NULL OR char_length(p_idempotency_key) NOT BETWEEN 1 AND 200
    THEN
        RAISE EXCEPTION 'valid points and idempotency key are required'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('loyalty.redeem:' || v_customer_id::text, 0)
    );

    SELECT *
    INTO v_existing
    FROM private.loyalty_ledger
    WHERE customer_id = v_customer_id
      AND entry_type = 'REDEEM'
      AND source_type = 'loyalty_redemption'
      AND source_id = p_idempotency_key;
    IF FOUND THEN
        IF (-1 * v_existing.points_delta) <> p_points THEN
            RAISE EXCEPTION 'idempotency key was reused with different redemption parameters'
                USING ERRCODE = '23505';
        END IF;
        RETURN jsonb_build_object(
            'loyalty_entry_id', v_existing.loyalty_entry_id,
            'points_redeemed', (-1 * v_existing.points_delta),
            'duplicate', true
        );
    END IF;

    SELECT GREATEST(COALESCE(sum(
        CASE
            WHEN entry.points_delta > 0
             AND entry.expires_at > clock_timestamp()
            THEN entry.points_delta
            WHEN entry.points_delta < 0
            THEN entry.points_delta
            ELSE 0
        END
    ), 0), 0)
    INTO v_remaining
    FROM private.loyalty_ledger AS entry
    WHERE entry.customer_id = v_customer_id;

    IF p_points > v_remaining THEN
        RAISE EXCEPTION 'insufficient loyalty balance'
            USING ERRCODE = '55000';
    END IF;

    INSERT INTO private.loyalty_ledger (
        customer_id, entry_type, points_delta, source_type, source_id
    )
    VALUES (
        v_customer_id, 'REDEEM', -p_points,
        'loyalty_redemption', p_idempotency_key
    )
    RETURNING * INTO v_redemption;

    v_remaining := p_points;
    FOR v_entry IN
        SELECT entry.*
        FROM private.loyalty_ledger AS entry
        WHERE entry.customer_id = v_customer_id
          AND entry.points_delta > 0
          AND entry.expires_at > clock_timestamp()
        ORDER BY entry.expires_at ASC, entry.earned_at ASC, entry.loyalty_entry_id ASC
    LOOP
        EXIT WHEN v_remaining = 0;
        SELECT COALESCE(sum(points), 0)
        INTO v_allocated
        FROM private.loyalty_redemption_allocations
        WHERE positive_entry_id = v_entry.loyalty_entry_id;

        v_take := LEAST(v_remaining, v_entry.points_delta - v_allocated);
        IF v_take > 0 THEN
            INSERT INTO private.loyalty_redemption_allocations (
                customer_id, positive_entry_id, redemption_entry_id, points
            )
            VALUES (
                v_customer_id, v_entry.loyalty_entry_id,
                v_redemption.loyalty_entry_id, v_take
            );
            v_remaining := v_remaining - v_take;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'loyalty_entry_id', v_redemption.loyalty_entry_id,
        'points_redeemed', p_points,
        'duplicate', false
    );
END;
$$;

CREATE FUNCTION public.expire_loyalty_points(p_customer_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_entry private.loyalty_ledger%ROWTYPE;
    v_allocated bigint;
    v_expired integer := 0;
    v_remaining integer;
    v_expiry_entry private.loyalty_ledger%ROWTYPE;
BEGIN
    PERFORM pg_advisory_xact_lock(
        hashtextextended('loyalty.expire:' || p_customer_id::text, 0)
    );

    FOR v_entry IN
        SELECT *
        FROM private.loyalty_ledger
        WHERE customer_id = p_customer_id
          AND points_delta > 0
          AND expires_at <= clock_timestamp()
        FOR UPDATE
    LOOP
        SELECT COALESCE(sum(points), 0)
        INTO v_allocated
        FROM private.loyalty_redemption_allocations
        WHERE positive_entry_id = v_entry.loyalty_entry_id;
        v_remaining := v_entry.points_delta - v_allocated::integer;
        IF v_remaining > 0 THEN
            INSERT INTO private.loyalty_ledger (
                customer_id, entry_type, points_delta, source_type, source_id, earned_at
            )
            VALUES (
                p_customer_id, 'EXPIRE', -v_remaining,
                'loyalty_expiry', v_entry.loyalty_entry_id::text, clock_timestamp()
            )
            ON CONFLICT (source_type, source_id, customer_id) DO NOTHING
            RETURNING * INTO v_expiry_entry;
            IF FOUND THEN
                v_expired := v_expired + v_remaining;
            END IF;
        END IF;
    END LOOP;
    RETURN v_expired;
END;
$$;

WITH contract_terms(terms_type, terms_version, terms_text) AS (
    VALUES
        ('ORDER', 'order-v1', 'أقر بإتمام الطلب المسبق الدفع وفق الشروط المعروضة قبل التأكيد.'),
        ('REFUND', 'refund-v1', 'أقر بفهم سياسة الإرجاع والاسترداد وشروطها الإجرائية.'),
        ('LOYALTY', 'loyalty-v1', 'أقر بفهم قواعد نقاط الولاء والمدة والاسترداد المبكر والانتهاء.'),
        ('PRIVACY', 'privacy-v1', 'أقر بفهم إشعار الخصوصية وكيفية معالجة بيانات الحساب والطلب.')
)
INSERT INTO private.legal_contract_versions (
    terms_version, terms_sha256, terms_text, terms_type, is_active
)
SELECT
    terms_version,
    encode(sha256(convert_to(terms_text, 'UTF8')), 'hex'),
    terms_text,
    terms_type,
    true
FROM contract_terms;

CREATE FUNCTION public.create_referral_code()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_referrer_id uuid := auth.uid();
    v_code text;
    v_code_hash text;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF v_referrer_id IS NULL THEN
        RAISE EXCEPTION 'authenticated identity is required'
            USING ERRCODE = '28000';
    END IF;

    v_code := encode(extensions.gen_random_bytes(16), 'hex');
    v_code_hash := encode(sha256(convert_to(v_code, 'UTF8')), 'hex');

    INSERT INTO private.referral_codes (
        referrer_id, code_hash, created_at, expires_at
    )
    VALUES (
        v_referrer_id, v_code_hash, v_now, v_now + interval '30 days'
    );

    RETURN jsonb_build_object(
        'referral_code', v_code,
        'expires_at', v_now + interval '30 days'
    );
END;
$$;

CREATE FUNCTION public.register_customer_referral(
    p_invitee_id uuid,
    p_referral_code text,
    p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_invitee_id uuid := auth.uid();
    v_referrer_id uuid;
    v_referral private.customer_referrals%ROWTYPE;
    v_existing_result jsonb;
    v_payload_hash text;
    v_code_hash text;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF v_invitee_id IS NULL THEN
        RAISE EXCEPTION 'authenticated identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF p_invitee_id IS NULL OR p_invitee_id <> v_invitee_id
       OR p_referral_code IS NULL OR char_length(p_referral_code) <> 32
       OR p_referral_code !~ '^[0-9a-fA-F]{32}$'
       OR p_idempotency_key IS NULL OR char_length(p_idempotency_key) NOT BETWEEN 1 AND 200
    THEN
        RAISE EXCEPTION 'invalid referral'
            USING ERRCODE = '22023';
    END IF;

    v_code_hash := encode(sha256(convert_to(lower(p_referral_code), 'UTF8')), 'hex');
    v_payload_hash := encode(
        sha256(convert_to(
            jsonb_build_object(
                'invitee_id', v_invitee_id,
                'referral_code', lower(p_referral_code)
            )::text,
            'UTF8'
        )),
        'hex'
    );

    IF EXISTS (
        SELECT 1
        FROM private.referral_rpc_idempotency
        WHERE operation = 'register_customer_referral'
          AND idempotency_key = p_idempotency_key
          AND (actor_id <> v_invitee_id OR payload_hash <> v_payload_hash)
    ) THEN
        RAISE EXCEPTION 'idempotency key was reused with different referral parameters'
            USING ERRCODE = '23505';
    END IF;

    SELECT result INTO v_existing_result
    FROM private.referral_rpc_idempotency
    WHERE operation = 'register_customer_referral'
      AND idempotency_key = p_idempotency_key
      AND actor_id = v_invitee_id;
    IF FOUND THEN
        IF NOT EXISTS (
            SELECT 1
            FROM private.referral_rpc_idempotency
            WHERE operation = 'register_customer_referral'
              AND idempotency_key = p_idempotency_key
              AND actor_id = v_invitee_id
              AND payload_hash = v_payload_hash
        ) THEN
            RAISE EXCEPTION 'idempotency key was reused with different referral parameters'
                USING ERRCODE = '23505';
        END IF;
        RETURN v_existing_result;
    END IF;

    SELECT referrer_id INTO v_referrer_id
    FROM private.referral_codes
    WHERE code_hash = v_code_hash
      AND revoked_at IS NULL
      AND expires_at > v_now;
    IF NOT FOUND OR v_referrer_id = v_invitee_id THEN
        RAISE EXCEPTION 'invalid or expired referral code'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('referral.register:' || v_invitee_id::text, 0)
    );

    INSERT INTO private.customer_referrals (
        referrer_id, invitee_id, referral_code, created_at, expires_at
    )
    VALUES (
        v_referrer_id, v_invitee_id, lower(p_referral_code),
        v_now, v_now + interval '30 days'
    )
    ON CONFLICT (invitee_id) DO NOTHING
    RETURNING * INTO v_referral;

    IF NOT FOUND THEN
        SELECT * INTO v_referral
        FROM private.customer_referrals
        WHERE invitee_id = v_invitee_id;
        IF v_referral.referrer_id <> v_referrer_id
           OR v_referral.referral_code <> lower(p_referral_code)
        THEN
            RAISE EXCEPTION 'invitee is already registered to another referrer'
                USING ERRCODE = '23505';
        END IF;
    END IF;

    v_existing_result := jsonb_build_object(
        'referral_id', v_referral.referral_id,
        'referrer_id', v_referral.referrer_id,
        'invitee_id', v_referral.invitee_id,
        'tier_level', v_referral.tier_level,
        'expires_at', v_referral.expires_at
    );

    INSERT INTO private.referral_rpc_idempotency (
        operation, idempotency_key, actor_id, payload_hash, result
    )
    VALUES (
        'register_customer_referral', p_idempotency_key, v_invitee_id,
        v_payload_hash, v_existing_result
    )
    ON CONFLICT (operation, idempotency_key) DO NOTHING;

    RETURN v_existing_result;
END;
$$;

CREATE FUNCTION public.record_referral_qualifying_order(
    p_order_id uuid,
    p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_order public.orders%ROWTYPE;
    v_referrer_id uuid;
    v_referral private.customer_referrals%ROWTYPE;
    v_existing_result jsonb;
    v_payload_hash text;
    v_tier smallint;
    v_points integer;
    v_reward_count integer := 0;
    v_now timestamptz := clock_timestamp();
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'authenticated identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF p_order_id IS NULL OR p_idempotency_key IS NULL
       OR char_length(p_idempotency_key) NOT BETWEEN 1 AND 200
    THEN
        RAISE EXCEPTION 'order and idempotency key are required'
            USING ERRCODE = '22023';
    END IF;

    v_payload_hash := encode(
        sha256(convert_to(
            jsonb_build_object(
                'order_id', p_order_id,
                'actor_id', v_actor_id
            )::text,
            'UTF8'
        )),
        'hex'
    );

    IF EXISTS (
        SELECT 1
        FROM private.referral_rpc_idempotency
        WHERE operation = 'record_referral_qualifying_order'
          AND idempotency_key = p_idempotency_key
          AND (actor_id <> v_actor_id OR payload_hash <> v_payload_hash)
    ) THEN
        RAISE EXCEPTION 'idempotency key was reused with different order parameters'
            USING ERRCODE = '23505';
    END IF;

    SELECT result INTO v_existing_result
    FROM private.referral_rpc_idempotency
    WHERE operation = 'record_referral_qualifying_order'
      AND idempotency_key = p_idempotency_key
      AND actor_id = v_actor_id;
    IF FOUND THEN
        IF NOT EXISTS (
            SELECT 1
            FROM private.referral_rpc_idempotency
            WHERE operation = 'record_referral_qualifying_order'
              AND idempotency_key = p_idempotency_key
              AND actor_id = v_actor_id
              AND payload_hash = v_payload_hash
        ) THEN
            RAISE EXCEPTION 'idempotency key was reused with different order parameters'
                USING ERRCODE = '23505';
        END IF;
        RETURN v_existing_result;
    END IF;

    SELECT * INTO v_order
    FROM public.orders
    WHERE order_id = p_order_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order not found'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_order.customer_id <> v_actor_id THEN
        RAISE EXCEPTION 'order customer identity does not match authenticated identity'
            USING ERRCODE = '42501';
    END IF;
    IF v_order.payment_status <> 'SUCCEEDED' THEN
        RAISE EXCEPTION 'only successfully paid orders qualify referrals'
            USING ERRCODE = '55000';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('referral.order:' || p_order_id::text, 0)
    );

    v_referrer_id := v_order.customer_id;
    FOR v_tier IN 1..3 LOOP
        SELECT * INTO v_referral
        FROM private.customer_referrals
        WHERE invitee_id = v_referrer_id
          AND expires_at > v_now
        ORDER BY created_at DESC
        LIMIT 1;
        EXIT WHEN NOT FOUND;

        v_points := CASE v_tier WHEN 1 THEN 5 WHEN 2 THEN 3 ELSE 1 END;
        INSERT INTO private.referral_rewards (
            referrer_id, invitee_id, referral_id, qualifying_order_id,
            tier_level, points, earned_at, expires_at
        )
        VALUES (
            v_referral.referrer_id, v_order.customer_id, v_referral.referral_id,
            p_order_id, v_tier, v_points, v_now, v_now + interval '30 days'
        )
        ON CONFLICT (qualifying_order_id, referral_id, tier_level) DO NOTHING;

        IF FOUND THEN
            INSERT INTO private.loyalty_ledger (
                customer_id, entry_type, points_delta, source_type, source_id,
                earned_at, expires_at
            )
            VALUES (
                v_referral.referrer_id, 'REFERRAL', v_points,
                'referral_reward', p_order_id::text || ':' || v_referral.referral_id::text || ':' || v_tier::text,
                v_now, v_now + interval '30 days'
            )
            ON CONFLICT (source_type, source_id, customer_id) DO NOTHING;
            v_reward_count := v_reward_count + 1;
        END IF;

        v_referrer_id := v_referral.referrer_id;
    END LOOP;

    UPDATE private.customer_referrals AS referral
    SET first_successful_order_id = p_order_id,
        reward_eligible_at = v_now,
        reward_points = reward_points + CASE
            WHEN referral.referrer_id = v_order.customer_id THEN 0 ELSE 5 END
    WHERE referral.invitee_id = v_order.customer_id
      AND referral.first_successful_order_id IS NULL;

    v_existing_result := jsonb_build_object(
        'order_id', p_order_id,
        'rewards_created', v_reward_count
    );

    INSERT INTO private.referral_rpc_idempotency (
        operation, idempotency_key, actor_id, payload_hash, result
    )
    VALUES (
        'record_referral_qualifying_order', p_idempotency_key, v_actor_id,
        v_payload_hash, v_existing_result
    )
    ON CONFLICT (operation, idempotency_key) DO NOTHING;

    RETURN v_existing_result;
END;
$$;

CREATE FUNCTION public.confirm_legal_acceptance(
    p_terms_type text,
    p_terms_version text,
    p_terms_sha256 text,
    p_order_id uuid,
    p_idempotency_key text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_customer_id uuid := auth.uid();
    v_terms private.legal_contract_versions%ROWTYPE;
    v_acceptance_id uuid;
BEGIN
    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'authenticated identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF p_terms_type IS NULL OR p_terms_type NOT IN ('ORDER','REFUND','LOYALTY','PRIVACY')
       OR p_terms_version IS NULL OR char_length(p_terms_version) NOT BETWEEN 1 AND 64
       OR p_terms_sha256 IS NULL OR p_terms_sha256 !~ '^[0-9a-f]{64}$'
       OR p_idempotency_key IS NULL OR char_length(p_idempotency_key) NOT BETWEEN 1 AND 200
    THEN
        RAISE EXCEPTION 'invalid legal acceptance'
            USING ERRCODE = '22023';
    END IF;
    IF p_order_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.orders
        WHERE order_id = p_order_id AND customer_id = v_customer_id
    ) THEN
        RAISE EXCEPTION 'order does not belong to the authenticated customer'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_terms
    FROM private.legal_contract_versions
    WHERE terms_type = p_terms_type
      AND terms_version = p_terms_version
      AND terms_sha256 = p_terms_sha256
      AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'terms version is not an active legal contract'
            USING ERRCODE = '55000';
    END IF;

    INSERT INTO public.legal_acceptances (
        customer_id, terms_id, order_id, idempotency_key
    )
    VALUES (
        v_customer_id, v_terms.terms_id, p_order_id, p_idempotency_key
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING acceptance_id INTO v_acceptance_id;

    IF v_acceptance_id IS NULL THEN
        SELECT acceptance_id INTO v_acceptance_id
        FROM public.legal_acceptances
        WHERE idempotency_key = p_idempotency_key
          AND customer_id = v_customer_id;
    END IF;
    RETURN v_acceptance_id;
END;
$$;

CREATE FUNCTION public.request_consumer_return(
    p_order_id uuid,
    p_refund_amount_minor bigint,
    p_reason text,
    p_contract_confirmation_id uuid,
    p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_customer_id uuid := auth.uid();
    v_order public.orders%ROWTYPE;
    v_refund_id uuid;
    v_return_id uuid;
BEGIN
    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'authenticated customer identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF p_order_id IS NULL OR p_refund_amount_minor IS NULL OR p_refund_amount_minor <= 0
       OR p_reason IS NULL OR char_length(p_reason) NOT BETWEEN 10 AND 1000
       OR p_contract_confirmation_id IS NULL
       OR p_idempotency_key IS NULL OR char_length(p_idempotency_key) NOT BETWEEN 1 AND 200
    THEN
        RAISE EXCEPTION 'invalid consumer return request'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_order
    FROM public.orders
    WHERE order_id = p_order_id
      AND customer_id = v_customer_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'order does not belong to the authenticated customer'
            USING ERRCODE = '42501';
    END IF;
    IF v_order.order_status <> 'DELIVERED'
       OR v_order.payment_status NOT IN ('SUCCEEDED', 'PARTIALLY_REFUNDED')
       OR p_refund_amount_minor > v_order.total_minor
    THEN
        RAISE EXCEPTION 'order is not eligible for a return refund'
            USING ERRCODE = '55000';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.customer_contract_confirmations
        WHERE confirmation_id = p_contract_confirmation_id
          AND customer_id = v_customer_id
          AND (order_id = p_order_id OR order_id IS NULL)
    ) THEN
        RAISE EXCEPTION 'customer contract confirmation is missing or mismatched'
            USING ERRCODE = '42501';
    END IF;

    INSERT INTO private.refund_approvals (
        order_id, amount_minor, currency_code, idempotency_key,
        requested_by, state, reason
    )
    VALUES (
        p_order_id, p_refund_amount_minor, 'EGP', p_idempotency_key,
        v_customer_id, 'REQUESTED', p_reason
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING refund_id INTO v_refund_id;

    IF v_refund_id IS NULL THEN
        SELECT refund_id INTO v_refund_id
        FROM private.refund_approvals
        WHERE idempotency_key = p_idempotency_key
          AND order_id = p_order_id
          AND requested_by = v_customer_id;
    END IF;

    INSERT INTO public.consumer_return_requests (
        customer_id, order_id, refund_amount_minor, reason,
        contract_confirmation_id, status, requested_by, refund_id, idempotency_key
    )
    VALUES (
        v_customer_id, p_order_id, p_refund_amount_minor, p_reason,
        p_contract_confirmation_id, 'REQUESTED', v_customer_id, v_refund_id,
        p_idempotency_key
    )
    ON CONFLICT (idempotency_key) DO NOTHING
    RETURNING return_request_id INTO v_return_id;

    IF v_return_id IS NULL THEN
        SELECT return_request_id INTO v_return_id
        FROM public.consumer_return_requests
        WHERE idempotency_key = p_idempotency_key;
    END IF;

    RETURN jsonb_build_object(
        'return_request_id', v_return_id,
        'refund_id', v_refund_id,
        'status', 'REQUESTED'
    );
END;
$$;

CREATE FUNCTION public.decide_consumer_return(
    p_return_request_id uuid,
    p_decision text,
    p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_request public.consumer_return_requests%ROWTYPE;
    v_decided_at timestamptz := clock_timestamp();
BEGIN
    IF v_actor_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.app_user_roles
        WHERE user_id = v_actor_id AND role IN ('ADMIN', 'SUPER_ADMIN')
    ) THEN
        RAISE EXCEPTION 'administrator identity is required'
            USING ERRCODE = '42501';
    END IF;
    IF p_return_request_id IS NULL
       OR p_decision IS NULL OR p_decision NOT IN ('APPROVED', 'REJECTED')
       OR p_idempotency_key IS NULL
    THEN
        RAISE EXCEPTION 'invalid return decision'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_request
    FROM public.consumer_return_requests
    WHERE return_request_id = p_return_request_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'return request does not exist'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_request.status <> 'REQUESTED' THEN
        RAISE EXCEPTION 'return request is not pending'
            USING ERRCODE = '55000';
    END IF;
    IF v_request.requested_by = v_actor_id THEN
        RAISE EXCEPTION 'maker-checker separation requires a different approver'
            USING ERRCODE = '42501';
    END IF;

    UPDATE public.consumer_return_requests
    SET status = p_decision,
        approved_by = v_actor_id,
        decided_at = v_decided_at
    WHERE return_request_id = p_return_request_id;

    UPDATE private.refund_approvals
    SET state = p_decision,
        approved_by = v_actor_id,
        decided_at = v_decided_at
    WHERE refund_id = v_request.refund_id;

    INSERT INTO private.transactional_outbox (
        aggregate_type, aggregate_id, event_type, payload
    )
    VALUES (
        'consumer_return',
        p_return_request_id,
        'consumer.return_decided',
        jsonb_build_object(
            'decision', p_decision,
            'sandbox_only', true,
            'idempotency_key', p_idempotency_key
        )
    );

    RETURN jsonb_build_object(
        'return_request_id', p_return_request_id,
        'status', p_decision
    );
END;
$$;

CREATE FUNCTION public.complete_sandbox_consumer_return(
    p_return_request_id uuid,
    p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_request public.consumer_return_requests%ROWTYPE;
    v_order public.orders%ROWTYPE;
    v_completed_at timestamptz := clock_timestamp();
BEGIN
    IF v_actor_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.app_user_roles
        WHERE user_id = v_actor_id AND role IN ('ADMIN', 'SUPER_ADMIN')
    ) THEN
        RAISE EXCEPTION 'administrator identity is required'
            USING ERRCODE = '42501';
    END IF;
    IF p_return_request_id IS NULL OR p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'return request and idempotency key are required'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_request
    FROM public.consumer_return_requests
    WHERE return_request_id = p_return_request_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'return request does not exist'
            USING ERRCODE = 'P0002';
    END IF;
    IF v_request.status <> 'APPROVED' THEN
        RAISE EXCEPTION 'only approved returns can be completed'
            USING ERRCODE = '55000';
    END IF;
    IF v_request.approved_by = v_actor_id THEN
        RAISE EXCEPTION 'completion requires a checker different from the approver'
            USING ERRCODE = '42501';
    END IF;

    SELECT * INTO v_order
    FROM public.orders
    WHERE order_id = v_request.order_id
    FOR UPDATE;

    UPDATE private.refund_approvals
    SET state = 'COMPLETED'
    WHERE refund_id = v_request.refund_id
      AND state = 'APPROVED';

    UPDATE public.consumer_return_requests
    SET status = 'COMPLETED',
        completed_at = v_completed_at
    WHERE return_request_id = p_return_request_id;

    UPDATE public.orders
    SET payment_status = CASE
            WHEN v_request.refund_amount_minor = total_minor THEN 'REFUNDED'::public.payment_status
            ELSE 'PARTIALLY_REFUNDED'::public.payment_status
        END,
        order_status = CASE
            WHEN v_request.refund_amount_minor = total_minor THEN 'REFUNDED'::public.order_status
            ELSE order_status
        END
    WHERE order_id = v_request.order_id;

    INSERT INTO private.transactional_outbox (
        aggregate_type, aggregate_id, event_type, payload
    )
    VALUES (
        'consumer_return',
        p_return_request_id,
        'consumer.return_completed',
        jsonb_build_object(
            'mode', 'SANDBOX',
            'refund_amount_minor', v_request.refund_amount_minor,
            'idempotency_key', p_idempotency_key
        )
    );

    RETURN jsonb_build_object(
        'return_request_id', p_return_request_id,
        'status', 'COMPLETED',
        'mode', 'SANDBOX'
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_loyalty_balance() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.grant_loyalty_points(uuid,integer,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.redeem_loyalty_points(integer,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.expire_loyalty_points(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_referral_code() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.register_customer_referral(uuid,text,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.record_referral_qualifying_order(uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.confirm_legal_acceptance(text,text,text,uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.request_consumer_return(uuid,bigint,text,uuid,text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.decide_consumer_return(uuid,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.complete_sandbox_consumer_return(uuid,text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.get_loyalty_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_loyalty_points(integer,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_referral_code() TO authenticated;
GRANT EXECUTE ON FUNCTION public.register_customer_referral(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_referral_qualifying_order(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.confirm_legal_acceptance(text,text,text,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_consumer_return(uuid,bigint,text,uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.grant_loyalty_points(uuid,integer,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION public.expire_loyalty_points(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.decide_consumer_return(uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_sandbox_consumer_return(uuid,text) TO authenticated;
