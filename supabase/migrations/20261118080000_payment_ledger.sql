CREATE TABLE private.payment_attempts (
    payment_attempt_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    provider text NOT NULL CHECK (provider ~ '^[a-z][a-z0-9_]{0,63}$'),
    idempotency_key uuid NOT NULL,
    payment_reference text NOT NULL CHECK (
        char_length(payment_reference) BETWEEN 1 AND 200
    ),
    amount_minor bigint NOT NULL CHECK (amount_minor > 0),
    currency_code text NOT NULL CHECK (currency_code = 'EGP'),
    status text NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'UNKNOWN', 'SUCCEEDED', 'FAILED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider, idempotency_key),
    UNIQUE (provider, payment_reference)
);

CREATE INDEX payment_attempts_order_created_idx
    ON private.payment_attempts (order_id, created_at DESC);

CREATE UNIQUE INDEX payment_attempts_one_open_per_order_idx
    ON private.payment_attempts (order_id)
    WHERE status IN ('PENDING', 'UNKNOWN');

ALTER TABLE private.payment_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.payment_attempts FORCE ROW LEVEL SECURITY;

REVOKE ALL ON private.payment_attempts
    FROM PUBLIC, anon, authenticated, service_role;

CREATE FUNCTION public.create_sandbox_payment_intent(
    p_order_id uuid,
    p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_customer_id uuid := auth.uid();
    v_order public.orders%ROWTYPE;
    v_attempt private.payment_attempts%ROWTYPE;
BEGIN
    IF v_customer_id IS NULL THEN
        RAISE EXCEPTION 'authenticated customer identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF p_order_id IS NULL OR p_idempotency_key IS NULL THEN
        RAISE EXCEPTION 'order id and idempotency key are required'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_order
    FROM public.orders
    WHERE order_id = p_order_id
      AND customer_id = v_customer_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'order does not exist'
            USING ERRCODE = 'P0002';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('payment.sandbox:' || p_idempotency_key::text, 0)
    );

    SELECT *
    INTO v_attempt
    FROM private.payment_attempts
    WHERE provider = 'sandbox'
      AND idempotency_key = p_idempotency_key
    FOR UPDATE;

    IF FOUND THEN
        IF v_attempt.order_id <> p_order_id
            OR v_attempt.amount_minor <> v_order.total_minor
            OR v_attempt.currency_code <> v_order.currency_code
        THEN
            RAISE EXCEPTION 'idempotency key was reused for a different payment request'
                USING ERRCODE = '23505';
        END IF;
        RETURN jsonb_build_object(
            'payment_attempt_id', v_attempt.payment_attempt_id,
            'provider', v_attempt.provider,
            'payment_reference', v_attempt.payment_reference,
            'amount_minor', v_attempt.amount_minor,
            'currency_code', v_attempt.currency_code,
            'status', v_attempt.status,
            'mode', 'SANDBOX'
        );
    END IF;

    IF v_order.order_status <> 'PAYMENT_PENDING'
        OR v_order.payment_status IN ('SUCCEEDED', 'PARTIALLY_REFUNDED', 'REFUNDED')
    THEN
        RAISE EXCEPTION 'order is not eligible for a payment attempt'
            USING ERRCODE = '55000';
    END IF;

    SELECT *
    INTO v_attempt
    FROM private.payment_attempts
    WHERE order_id = p_order_id
      AND status IN ('PENDING', 'UNKNOWN')
    FOR UPDATE;

    IF FOUND THEN
        RETURN jsonb_build_object(
            'payment_attempt_id', v_attempt.payment_attempt_id,
            'provider', v_attempt.provider,
            'payment_reference', v_attempt.payment_reference,
            'amount_minor', v_attempt.amount_minor,
            'currency_code', v_attempt.currency_code,
            'status', v_attempt.status,
            'mode', 'SANDBOX'
        );
    END IF;

    IF v_order.payment_status <> 'PENDING' THEN
        UPDATE public.orders
        SET payment_status = 'PENDING'
        WHERE order_id = p_order_id;
    END IF;

    INSERT INTO private.payment_attempts (
        order_id,
        provider,
        idempotency_key,
        payment_reference,
        amount_minor,
        currency_code
    )
    VALUES (
        p_order_id,
        'sandbox',
        p_idempotency_key,
        gen_random_uuid()::text,
        v_order.total_minor,
        v_order.currency_code
    )
    RETURNING * INTO v_attempt;

    RETURN jsonb_build_object(
        'payment_attempt_id', v_attempt.payment_attempt_id,
        'provider', v_attempt.provider,
        'payment_reference', v_attempt.payment_reference,
        'amount_minor', v_attempt.amount_minor,
        'currency_code', v_attempt.currency_code,
        'status', v_attempt.status,
        'mode', 'SANDBOX'
    );
END;
$$;

CREATE FUNCTION public.process_payment_webhook(
    p_provider text,
    p_provider_event_id text,
    p_event_type text,
    p_payment_reference text,
    p_amount_minor bigint,
    p_currency_code text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
    v_attempt private.payment_attempts%ROWTYPE;
    v_order public.orders%ROWTYPE;
    v_event_id uuid;
    v_existing_event private.payment_webhook_events%ROWTYPE;
    v_event_payload jsonb;
    v_order_id uuid;
    v_clearing_account_id uuid;
    v_customer_funds_account_id uuid;
    v_journal_id uuid;
    v_reservation_id uuid;
    v_other_attempt_status text;
    v_result text;
BEGIN
    IF p_provider IS NULL
        OR p_provider !~ '^[a-z][a-z0-9_]{0,63}$'
        OR p_provider_event_id IS NULL
        OR char_length(p_provider_event_id) NOT BETWEEN 1 AND 200
        OR p_event_type IS NULL
        OR p_event_type NOT IN ('payment.succeeded', 'payment.failed', 'payment.unknown')
        OR p_payment_reference IS NULL
        OR char_length(p_payment_reference) NOT BETWEEN 1 AND 200
        OR p_amount_minor IS NULL
        OR p_amount_minor <= 0
        OR p_currency_code IS DISTINCT FROM 'EGP'
    THEN
        RAISE EXCEPTION 'invalid normalized payment event'
            USING ERRCODE = '22023';
    END IF;

    SELECT payment_attempt.order_id
    INTO v_order_id
    FROM private.payment_attempts AS payment_attempt
    WHERE payment_attempt.provider = p_provider
      AND payment_attempt.payment_reference = p_payment_reference;

    IF v_order_id IS NOT NULL THEN
        SELECT *
        INTO v_order
        FROM public.orders
        WHERE order_id = v_order_id
        FOR UPDATE;

        SELECT *
        INTO v_attempt
        FROM private.payment_attempts
        WHERE provider = p_provider
          AND payment_reference = p_payment_reference
        FOR UPDATE;
    END IF;

    v_event_payload := jsonb_build_object(
        'event_type', p_event_type,
        'payment_reference', p_payment_reference,
        'amount_minor', p_amount_minor,
        'currency_code', p_currency_code
    );

    INSERT INTO private.payment_webhook_events (
        provider,
        provider_event_id,
        order_id,
        event_type,
        event_payload,
        signature_verified,
        amount_minor,
        currency_code
    )
    VALUES (
        p_provider,
        p_provider_event_id,
        v_order_id,
        p_event_type,
        v_event_payload,
        true,
        p_amount_minor,
        p_currency_code
    )
    ON CONFLICT (provider, provider_event_id) DO NOTHING
    RETURNING event_id INTO v_event_id;

    IF v_event_id IS NULL THEN
        SELECT *
        INTO v_existing_event
        FROM private.payment_webhook_events
        WHERE provider = p_provider
          AND provider_event_id = p_provider_event_id;

        IF v_existing_event.event_type <> p_event_type
            OR v_existing_event.order_id IS DISTINCT FROM v_order_id
            OR v_existing_event.event_payload <> v_event_payload
            OR v_existing_event.amount_minor IS DISTINCT FROM p_amount_minor
            OR v_existing_event.currency_code IS DISTINCT FROM p_currency_code
        THEN
            RAISE EXCEPTION 'provider event id was reused with different payment data'
                USING ERRCODE = '23505';
        END IF;

        RETURN jsonb_build_object(
            'accepted', true,
            'duplicate', true,
            'status', 'ALREADY_PROCESSED'
        );
    END IF;

    IF v_order_id IS NULL THEN
        INSERT INTO private.transactional_outbox (
            aggregate_type,
            aggregate_id,
            event_type,
            payload
        )
        VALUES (
            'payment_event',
            v_event_id,
            'payment.review_required',
            jsonb_build_object(
                'reason', 'unmatched_payment_reference',
                'provider', p_provider,
                'provider_event_id', p_provider_event_id
            )
        );

        RETURN jsonb_build_object(
            'accepted', true,
            'duplicate', false,
            'status', 'UNMATCHED_REVIEW_REQUIRED'
        );
    END IF;

    IF p_amount_minor <> v_attempt.amount_minor
        OR p_amount_minor <> v_order.total_minor
        OR p_currency_code <> v_attempt.currency_code
        OR p_currency_code <> v_order.currency_code
    THEN
        SELECT other_attempt.status
        INTO v_other_attempt_status
        FROM private.payment_attempts AS other_attempt
        WHERE other_attempt.order_id = v_order_id
          AND other_attempt.payment_attempt_id <> v_attempt.payment_attempt_id
          AND other_attempt.status IN ('PENDING', 'UNKNOWN')
        ORDER BY other_attempt.created_at DESC
        LIMIT 1
        FOR UPDATE;

        UPDATE private.payment_attempts
        SET status = 'UNKNOWN', updated_at = clock_timestamp()
        WHERE payment_attempt_id = v_attempt.payment_attempt_id
          AND status <> 'SUCCEEDED'
          AND v_other_attempt_status IS NULL;

        UPDATE public.orders
        SET payment_status = CASE
            WHEN v_other_attempt_status = 'PENDING'
                THEN 'PENDING'::public.payment_status
            ELSE 'UNKNOWN'::public.payment_status
        END
        WHERE order_id = v_order_id
          AND payment_status NOT IN ('SUCCEEDED', 'PARTIALLY_REFUNDED', 'REFUNDED');

        INSERT INTO private.transactional_outbox (
            aggregate_type,
            aggregate_id,
            event_type,
            payload
        )
        VALUES (
            'payment_event',
            v_event_id,
            'payment.review_required',
            jsonb_build_object(
                'reason', 'amount_or_currency_mismatch',
                'order_id', v_order_id,
                'provider_event_id', p_provider_event_id
            )
        );

        RETURN jsonb_build_object(
            'accepted', true,
            'duplicate', false,
            'status', 'MISMATCH_REVIEW_REQUIRED'
        );
    END IF;

    IF p_event_type = 'payment.succeeded' THEN
        IF v_attempt.status = 'SUCCEEDED' THEN
            v_result := 'ALREADY_CAPTURED';
        ELSE
            v_clearing_account_id := private.create_ledger_account(
                'PAYMENT_CLEARING',
                'ASSET',
                v_attempt.currency_code
            );
            v_customer_funds_account_id := private.create_ledger_account(
                'CUSTOMER_PREPAYMENT',
                'LIABILITY',
                v_attempt.currency_code
            );

            v_journal_id := private.post_ledger_journal(
                'payment_capture',
                v_attempt.payment_attempt_id::text,
                v_attempt.currency_code,
                jsonb_build_array(
                    jsonb_build_object(
                        'account_id', v_clearing_account_id::text,
                        'side', 'DEBIT',
                        'amount_minor', v_attempt.amount_minor::text
                    ),
                    jsonb_build_object(
                        'account_id', v_customer_funds_account_id::text,
                        'side', 'CREDIT',
                        'amount_minor', v_attempt.amount_minor::text
                    )
                )
            );

            UPDATE private.payment_attempts
            SET status = 'SUCCEEDED', updated_at = clock_timestamp()
            WHERE payment_attempt_id = v_attempt.payment_attempt_id;

            IF v_order.order_status = 'PAYMENT_PENDING'
                AND v_order.payment_status NOT IN (
                    'SUCCEEDED', 'PARTIALLY_REFUNDED', 'REFUNDED'
                )
            THEN
                FOR v_reservation_id IN
                    SELECT reservation.reservation_id
                    FROM private.inventory_reservations AS reservation
                    WHERE reservation.order_id = v_order_id
                      AND reservation.status = 'RESERVED'
                    ORDER BY reservation.variant_id
                    FOR UPDATE
                LOOP
                    PERFORM private.consume_inventory_reservation(v_reservation_id);
                END LOOP;
            END IF;

            IF v_order.payment_status NOT IN ('SUCCEEDED', 'PARTIALLY_REFUNDED', 'REFUNDED') THEN
                UPDATE public.orders
                SET payment_status = 'SUCCEEDED',
                    order_status = CASE
                        WHEN order_status = 'PAYMENT_PENDING' THEN 'CONFIRMED'::public.order_status
                        ELSE order_status
                    END
                WHERE order_id = v_order_id;
            END IF;

            INSERT INTO private.transactional_outbox (
                aggregate_type,
                aggregate_id,
                event_type,
                payload
            )
            VALUES (
                'payment_attempt',
                v_attempt.payment_attempt_id,
                'payment.captured',
                jsonb_build_object(
                    'order_id', v_order_id,
                    'payment_reference', v_attempt.payment_reference,
                    'amount_minor', v_attempt.amount_minor,
                    'currency_code', v_attempt.currency_code,
                    'journal_id', v_journal_id
                )
            );

            IF v_order.order_status <> 'PAYMENT_PENDING'
                OR v_order.payment_status IN ('SUCCEEDED', 'PARTIALLY_REFUNDED', 'REFUNDED')
            THEN
                INSERT INTO private.transactional_outbox (
                    aggregate_type,
                    aggregate_id,
                    event_type,
                    payload
                )
                VALUES (
                    'payment_event',
                    v_event_id,
                    'payment.review_required',
                    jsonb_build_object(
                        'reason', 'late_or_additional_capture',
                        'order_id', v_order_id,
                        'payment_attempt_id', v_attempt.payment_attempt_id,
                        'journal_id', v_journal_id
                    )
                );
            END IF;

            v_result := 'SUCCEEDED';
        END IF;
    ELSIF p_event_type = 'payment.failed' THEN
        IF v_attempt.status <> 'SUCCEEDED' THEN
            UPDATE private.payment_attempts
            SET status = 'FAILED', updated_at = clock_timestamp()
            WHERE payment_attempt_id = v_attempt.payment_attempt_id;

            IF v_order.payment_status NOT IN ('SUCCEEDED', 'PARTIALLY_REFUNDED', 'REFUNDED') THEN
                SELECT other_attempt.status
                INTO v_other_attempt_status
                FROM private.payment_attempts AS other_attempt
                WHERE other_attempt.order_id = v_order_id
                  AND other_attempt.payment_attempt_id <> v_attempt.payment_attempt_id
                  AND other_attempt.status IN ('PENDING', 'UNKNOWN')
                ORDER BY other_attempt.created_at DESC
                LIMIT 1
                FOR UPDATE;

                UPDATE public.orders
                SET payment_status = CASE
                    WHEN v_other_attempt_status = 'PENDING'
                        THEN 'PENDING'::public.payment_status
                    WHEN v_other_attempt_status = 'UNKNOWN'
                        THEN 'UNKNOWN'::public.payment_status
                    ELSE 'FAILED'::public.payment_status
                END
                WHERE order_id = v_order_id;
            END IF;
            v_result := 'FAILED';
        ELSE
            v_result := 'ALREADY_SUCCEEDED';
        END IF;
    ELSE
        IF v_attempt.status <> 'SUCCEEDED' THEN
            SELECT other_attempt.status
            INTO v_other_attempt_status
            FROM private.payment_attempts AS other_attempt
            WHERE other_attempt.order_id = v_order_id
              AND other_attempt.payment_attempt_id <> v_attempt.payment_attempt_id
              AND other_attempt.status IN ('PENDING', 'UNKNOWN')
            ORDER BY other_attempt.created_at DESC
            LIMIT 1
            FOR UPDATE;

            UPDATE private.payment_attempts
            SET status = 'UNKNOWN', updated_at = clock_timestamp()
            WHERE payment_attempt_id = v_attempt.payment_attempt_id
              AND v_other_attempt_status IS NULL;

            IF v_order.payment_status NOT IN ('SUCCEEDED', 'PARTIALLY_REFUNDED', 'REFUNDED') THEN
                SELECT other_attempt.status
                INTO v_other_attempt_status
                FROM private.payment_attempts AS other_attempt
                WHERE other_attempt.order_id = v_order_id
                  AND other_attempt.payment_attempt_id <> v_attempt.payment_attempt_id
                  AND other_attempt.status IN ('PENDING', 'UNKNOWN')
                ORDER BY other_attempt.created_at DESC
                LIMIT 1
                FOR UPDATE;

                UPDATE public.orders
                SET payment_status = CASE
                    WHEN v_other_attempt_status = 'PENDING'
                        THEN 'PENDING'::public.payment_status
                    ELSE 'UNKNOWN'::public.payment_status
                END
                WHERE order_id = v_order_id;
            END IF;
            v_result := 'UNKNOWN';
        ELSE
            v_result := 'ALREADY_SUCCEEDED';
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'accepted', true,
        'duplicate', false,
        'status', v_result
    );
END;
$$;

REVOKE ALL ON FUNCTION public.create_sandbox_payment_intent(uuid, uuid)
    FROM PUBLIC, anon, service_role;
REVOKE ALL ON FUNCTION public.process_payment_webhook(text, text, text, text, bigint, text)
    FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.create_sandbox_payment_intent(uuid, uuid)
    TO authenticated;
GRANT EXECUTE ON FUNCTION public.process_payment_webhook(text, text, text, text, bigint, text)
    TO service_role;
