BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(23);

SELECT ok(
    (
        SELECT relrowsecurity AND relforcerowsecurity
        FROM pg_class
        WHERE oid = 'private.payment_attempts'::regclass
    )
    AND (
        SELECT relrowsecurity AND relforcerowsecurity
        FROM pg_class
        WHERE oid = 'private.payment_webhook_events'::regclass
    ),
    'payment attempt and webhook data force row-level security'
);

SELECT ok(
    NOT has_table_privilege('anon', 'private.payment_attempts', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.payment_attempts', 'SELECT')
    AND NOT has_table_privilege('service_role', 'private.payment_attempts', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.payment_webhook_events', 'INSERT'),
    'payment attempts and provider events have no direct API table access'
);

SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.create_sandbox_payment_intent(uuid,uuid)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'anon',
        'public.create_sandbox_payment_intent(uuid,uuid)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'service_role',
        'public.create_sandbox_payment_intent(uuid,uuid)',
        'EXECUTE'
    )
    AND has_function_privilege(
        'service_role',
        'public.process_payment_webhook(text,text,text,text,bigint,text)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'authenticated',
        'public.process_payment_webhook(text,text,text,text,bigint,text)',
        'EXECUTE'
    ),
    'customers can start their own sandbox intent and only the trusted worker can process webhooks'
);

SET LOCAL ROLE authenticated;
SELECT throws_ok(
    $$
    SELECT public.create_sandbox_payment_intent(
        '81000000-0000-0000-0000-000000000001',
        '82000000-0000-0000-0000-000000000001'
    )
    $$,
    '28000',
    'authenticated customer identity is required',
    'payment intent creation requires an authenticated customer'
);
RESET ROLE;
SET LOCAL ROLE postgres;

INSERT INTO auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at
)
VALUES (
    '80000000-0000-0000-0000-000000000001',
    'authenticated',
    'authenticated',
    'payment-customer@example.test',
    '',
    now(),
    now(),
    now()
);

INSERT INTO public.orders (
    order_id,
    customer_id,
    payment_method,
    subtotal_minor,
    total_minor,
    snapshot_schema_version,
    snapshot_json,
    snapshot_sha256
)
VALUES
    (
        '81000000-0000-0000-0000-000000000001',
        '80000000-0000-0000-0000-000000000001',
        'CARD',
        15000,
        15000,
        1,
        '{}'::jsonb,
        repeat('a', 64)
    ),
    (
        '81000000-0000-0000-0000-000000000002',
        '80000000-0000-0000-0000-000000000001',
        'MOBILE_WALLET',
        8400,
        8400,
        1,
        '{}'::jsonb,
        repeat('b', 64)
    );

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    '80000000-0000-0000-0000-000000000001',
    true
);
SELECT set_config(
    'test.payment_reference',
    public.create_sandbox_payment_intent(
        '81000000-0000-0000-0000-000000000001',
        '82000000-0000-0000-0000-000000000001'
    ) ->> 'payment_reference',
    true
);

SELECT is(
    public.create_sandbox_payment_intent(
        '81000000-0000-0000-0000-000000000001',
        '82000000-0000-0000-0000-000000000001'
    ) ->> 'mode',
    'SANDBOX',
    'customer payment intent is explicitly sandbox-only'
);

SELECT is(
    public.create_sandbox_payment_intent(
        '81000000-0000-0000-0000-000000000001',
        '82000000-0000-0000-0000-000000000001'
    ) ->> 'payment_reference',
    current_setting('test.payment_reference'),
    'replaying an intent request returns the same provider reference'
);

SELECT is(
    public.create_sandbox_payment_intent(
        '81000000-0000-0000-0000-000000000001',
        '82000000-0000-0000-0000-000000000003'
    ) ->> 'payment_reference',
    current_setting('test.payment_reference'),
    'a retry after losing the client key reuses the order open payment intent'
);

SELECT throws_ok(
    $$
    SELECT public.create_sandbox_payment_intent(
        '81000000-0000-0000-0000-000000000002',
        '82000000-0000-0000-0000-000000000001'
    )
    $$,
    '23505',
    'idempotency key was reused for a different payment request',
    'a payment idempotency key cannot be reused for another order'
);

SELECT set_config(
    'test.second_payment_reference',
    public.create_sandbox_payment_intent(
        '81000000-0000-0000-0000-000000000002',
        '82000000-0000-0000-0000-000000000002'
    ) ->> 'payment_reference',
    true
);
RESET ROLE;
SET LOCAL ROLE service_role;

SELECT private.record_inventory_adjustment(
    '83000000-0000-0000-0000-000000000001',
    '84000000-0000-0000-0000-000000000001',
    'RESTOCK',
    1,
    'Payment test stock'
);
SELECT private.reserve_inventory(
    '81000000-0000-0000-0000-000000000001',
    '83000000-0000-0000-0000-000000000001',
    1
);

SELECT is(
    public.process_payment_webhook(
        'sandbox',
        'sandbox-capture-1',
        'payment.succeeded',
        current_setting('test.payment_reference'),
        15000,
        'EGP'
    ) ->> 'status',
    'SUCCEEDED',
    'a verified sandbox capture is processed'
);

RESET ROLE;
SET LOCAL ROLE postgres;
SELECT ok(
    (
        SELECT order_status = 'CONFIRMED' AND payment_status = 'SUCCEEDED'
        FROM public.orders
        WHERE order_id = '81000000-0000-0000-0000-000000000001'
    ),
    'successful prepayment confirms the order atomically'
);

SELECT ok(
    (SELECT count(*) = 1
     FROM private.ledger_journals AS journal
     WHERE journal.source_type = 'payment_capture'
       AND journal.source_id = (
           SELECT payment_attempt_id::text
           FROM private.payment_attempts
           WHERE payment_reference = current_setting('test.payment_reference')
       ))
    AND (
        SELECT sum(entry.amount_minor) FILTER (WHERE entry.side = 'DEBIT')
                   = sum(entry.amount_minor) FILTER (WHERE entry.side = 'CREDIT')
        FROM private.ledger_journals AS journal
        JOIN private.ledger_entries AS entry USING (journal_id)
        WHERE journal.source_type = 'payment_capture'
          AND journal.source_id = (
              SELECT payment_attempt_id::text
              FROM private.payment_attempts
              WHERE payment_reference = current_setting('test.payment_reference')
          )
    ),
    'capture posts one balanced integer-minor-unit journal'
);

SELECT ok(
    (
          SELECT physical_quantity = 0 AND reserved_quantity = 0
          FROM private.inventory_balances
          WHERE variant_id = '83000000-0000-0000-0000-000000000001'
    )
    AND (
          SELECT status = 'CONSUMED'
          FROM private.inventory_reservations
          WHERE order_id = '81000000-0000-0000-0000-000000000001'
            AND variant_id = '83000000-0000-0000-0000-000000000001'
    ),
    'successful payment consumes its reserved inventory in the same transaction'
);

SET LOCAL ROLE service_role;
SELECT is(
    public.process_payment_webhook(
        'sandbox',
        'sandbox-capture-1',
        'payment.succeeded',
        current_setting('test.payment_reference'),
        15000,
        'EGP'
    ) ->> 'duplicate',
    'true',
    'a repeated provider event is acknowledged without repeating effects'
);

SELECT throws_ok(
    $$
    SELECT public.process_payment_webhook(
        'sandbox',
        'sandbox-capture-1',
        'payment.succeeded',
        current_setting('test.payment_reference'),
        15001,
        'EGP'
    )
    $$,
    '23505',
    'provider event id was reused with different payment data',
    'a repeated provider event id cannot change its amount'
);

SELECT is(
    public.process_payment_webhook(
        'sandbox',
        'sandbox-failure-after-capture',
        'payment.failed',
        current_setting('test.payment_reference'),
        15000,
        'EGP'
    ) ->> 'status',
    'ALREADY_SUCCEEDED',
    'a stale failure cannot overwrite a successful capture'
);

SELECT is(
    public.process_payment_webhook(
        'sandbox',
        'sandbox-second-attempt-failed',
        'payment.failed',
        current_setting('test.second_payment_reference'),
        8400,
        'EGP'
    ) ->> 'status',
    'FAILED',
    'a failed attempt remains retryable while the order is still unpaid'
);

RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config(
    'test.third_payment_reference',
    public.create_sandbox_payment_intent(
        '81000000-0000-0000-0000-000000000002',
        '82000000-0000-0000-0000-000000000004'
    ) ->> 'payment_reference',
    true
);
RESET ROLE;
SET LOCAL ROLE service_role;

SELECT is(
    public.process_payment_webhook(
        'sandbox',
        'sandbox-second-attempt-delayed-failure',
        'payment.failed',
        current_setting('test.second_payment_reference'),
        8400,
        'EGP'
    ) ->> 'status',
    'FAILED',
    'a delayed failure from an older attempt is processed without blocking a retry'
);

RESET ROLE;
SET LOCAL ROLE postgres;
SELECT is(
    (
        SELECT payment_status::text
        FROM public.orders
        WHERE order_id = '81000000-0000-0000-0000-000000000002'
    ),
    'PENDING',
    'an older failed attempt cannot overwrite the newer pending attempt'
);
SET LOCAL ROLE service_role;

SELECT is(
    public.process_payment_webhook(
        'sandbox',
        'sandbox-unknown-1',
        'payment.unknown',
        current_setting('test.third_payment_reference'),
        8400,
        'EGP'
    ) ->> 'status',
    'UNKNOWN',
    'an unresolved provider response is kept in the unknown state'
);

SELECT is(
    public.process_payment_webhook(
        'sandbox',
        'sandbox-mismatch-1',
        'payment.succeeded',
        current_setting('test.third_payment_reference'),
        8401,
        'EGP'
    ) ->> 'status',
    'MISMATCH_REVIEW_REQUIRED',
    'a capture with an unexpected amount is held for review'
);

RESET ROLE;
SET LOCAL ROLE postgres;
SELECT ok(
    (
        SELECT order_status = 'PAYMENT_PENDING' AND payment_status = 'UNKNOWN'
        FROM public.orders
        WHERE order_id = '81000000-0000-0000-0000-000000000002'
    )
    AND EXISTS (
        SELECT 1
        FROM private.transactional_outbox
        WHERE event_type = 'payment.review_required'
          AND payload ->> 'reason' = 'amount_or_currency_mismatch'
    ),
    'unknown and mismatched payments do not confirm orders and enqueue review'
);

SELECT throws_ok(
    $$
    UPDATE private.payment_webhook_events
    SET event_type = 'tampered'
    WHERE provider_event_id = 'sandbox-capture-1'
    $$,
    '55000',
    'immutable commerce records cannot be changed',
    'accepted provider event records are append-only'
);

SET LOCAL ROLE service_role;
SELECT throws_ok(
    $$
    SELECT public.process_payment_webhook(
        'sandbox',
        'sandbox-invalid-amount',
        'payment.succeeded',
        current_setting('test.payment_reference'),
        0,
        'EGP'
    )
    $$,
    '22023',
    'invalid normalized payment event',
    'zero-value webhook amounts are rejected'
);

SELECT * FROM finish();
ROLLBACK;
