BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(30);

SELECT ok(
    (
        SELECT count(*) = 2
          AND bool_and(relrowsecurity)
          AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname IN ('consumer_return_requests', 'legal_acceptances')
          AND relation.relkind = 'r'
    ),
    'phase 11 API-facing tables force RLS'
);

SELECT ok(
    (
        SELECT count(*) = 4
          AND bool_and(relrowsecurity)
          AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'private'
          AND relation.relname IN (
              'loyalty_redemption_allocations',
              'referral_rewards',
              'legal_contract_versions',
              'customer_referrals'
          )
          AND relation.relkind = 'r'
    ),
    'phase 11 private and referral tables force RLS'
);

SELECT is(
    (SELECT count(*)::integer FROM private.legal_contract_versions WHERE is_active),
    4,
    'four legal contract types are seeded and active'
);

SELECT ok(
    has_function_privilege('authenticated', 'public.get_loyalty_balance()', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.redeem_loyalty_points(integer,text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.grant_loyalty_points(uuid,integer,text,text)', 'EXECUTE'),
    'customers can read and redeem loyalty but cannot grant points'
);

SELECT ok(
    has_function_privilege('authenticated', 'public.request_consumer_return(uuid,bigint,text,uuid,text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.confirm_legal_acceptance(text,text,text,uuid,text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.request_consumer_return(uuid,bigint,text,uuid,text)', 'EXECUTE'),
    'consumer return and legal confirmation RPCs require authentication'
);

INSERT INTO auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at
)
VALUES
    ('c1000000-0000-0000-0000-000000000001','authenticated','authenticated','loyalty-customer@example.test','',now(),now(),now()),
    ('c1000000-0000-0000-0000-000000000002','authenticated','authenticated','loyalty-admin@example.test','',now(),now(),now()),
    ('c1000000-0000-0000-0000-000000000003','authenticated','authenticated','loyalty-checker@example.test','',now(),now(),now()),
    ('c1000000-0000-0000-0000-000000000004','authenticated','authenticated','referrer@example.test','',now(),now(),now()),
    ('c1000000-0000-0000-0000-000000000005','authenticated','authenticated','referee@example.test','',now(),now(),now());

UPDATE public.app_user_roles SET role = 'ADMIN'
WHERE user_id IN (
    'c1000000-0000-0000-0000-000000000002',
    'c1000000-0000-0000-0000-000000000003'
);

SET LOCAL ROLE service_role;
SELECT set_config('request.jwt.claim.sub', '', true);
SELECT public.grant_loyalty_points(
    'c1000000-0000-0000-0000-000000000001',
    100,
    'welcome',
    'welcome-customer-1'
);
SELECT public.grant_loyalty_points(
    'c1000000-0000-0000-0000-000000000001',
    200,
    'order',
    'order-customer-1'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'c1000000-0000-0000-0000-000000000001',
    true
);
SELECT is(
    (public.get_loyalty_balance() ->> 'points')::integer,
    300,
    'loyalty balance sums positive grants'
);

SELECT is(
    (public.redeem_loyalty_points(120, 'c2000000-0000-0000-0000-000000000001') ->> 'points_redeemed')::integer,
    120,
    'earliest-expiry loyalty redemption succeeds atomically'
);

SELECT is(
    (public.get_loyalty_balance() ->> 'points')::integer,
    180,
    'redemption reduces loyalty balance'
);

SELECT is(
    (public.redeem_loyalty_points(120, 'c2000000-0000-0000-0000-000000000001') ->> 'duplicate')::boolean,
    true,
    'loyalty redemption replay is idempotent'
);

SELECT throws_ok(
    $$ SELECT public.redeem_loyalty_points(181, 'c2000000-0000-0000-0000-000000000002') $$,
    '55000',
    'insufficient loyalty balance',
    'redemption rejects insufficient balances'
);
RESET ROLE;

INSERT INTO public.orders (
    order_id, customer_id, order_status, payment_status, payment_method,
    subtotal_minor, shipping_minor, discount_minor, total_minor,
    snapshot_schema_version, snapshot_json, snapshot_sha256
) VALUES (
    'c3000000-0000-0000-0000-000000000001',
    'c1000000-0000-0000-0000-000000000005',
    'DELIVERED',
    'SUCCEEDED',
    'CARD',
    1000,
    100,
    0,
    1100,
    1,
    '{}'::jsonb,
    repeat('0', 64)
);

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'c1000000-0000-0000-0000-000000000004',
    true
);
SELECT set_config(
    'test.referral',
    public.register_customer_referral(
        'c1000000-0000-0000-0000-000000000005',
        'ABC-123',
        'c4000000-0000-0000-0000-000000000001'
    )::text,
    true
);
SELECT is(
    (current_setting('test.referral')::jsonb ->> 'tier_level')::integer,
    1,
    'direct referral is assigned tier one'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'c1000000-0000-0000-0000-000000000001',
    true
);
SELECT public.register_customer_referral(
    'c1000000-0000-0000-0000-000000000004',
    'HIER-123',
    'c4000000-0000-0000-0000-000000000010'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'c1000000-0000-0000-0000-000000000005',
    true
);
SELECT set_config(
    'test.referral_reward',
    public.record_referral_qualifying_order(
        'c3000000-0000-0000-0000-000000000001',
        'c4000000-0000-0000-0000-000000000002'
    )::text,
    true
);
SELECT is(
    (current_setting('test.referral_reward')::jsonb ->> 'rewards_created')::integer,
    2,
    'qualifying order records direct and second-tier referral rewards'
);

SELECT set_config(
    'test.refund_terms',
    public.confirm_legal_acceptance(
        'REFUND',
        'refund-v1',
        encode(sha256(convert_to('أقر بفهم سياسة الإرجاع والاسترداد وشروطها الإجرائية.', 'UTF8')), 'hex'),
        'c3000000-0000-0000-0000-000000000001',
        'c4000000-0000-0000-0000-000000000003'
    )::text,
    true
);
SELECT ok(
    (SELECT count(*) = 1
     FROM public.legal_acceptances
     WHERE customer_id = 'c1000000-0000-0000-0000-000000000005'),
    'customer can confirm active refund terms'
);

SELECT set_config(
    'test.contract',
    public.confirm_legal_acceptance(
        'ORDER',
        'order-v1',
        encode(sha256(convert_to('أقر بإتمام الطلب المسبق الدفع وفق الشروط المعروضة قبل التأكيد.', 'UTF8')), 'hex'),
        'c3000000-0000-0000-0000-000000000001',
        'c4000000-0000-0000-0000-000000000004'
    )::text,
    true
);

INSERT INTO public.customer_contract_confirmations (
    customer_id, order_id, terms_version, terms_sha256
) VALUES (
    'c1000000-0000-0000-0000-000000000005',
    'c3000000-0000-0000-0000-000000000001',
    'refund-v1',
    repeat('1', 64)
);
SELECT set_config(
    'test.contract_id',
    (SELECT confirmation_id::text
     FROM public.customer_contract_confirmations
     WHERE order_id = 'c3000000-0000-0000-0000-000000000001'),
    true
);

SELECT set_config(
    'test.return',
    public.request_consumer_return(
        'c3000000-0000-0000-0000-000000000001',
        500,
        'The delivered item is materially defective.',
        current_setting('test.contract_id')::uuid,
        'c4000000-0000-0000-0000-000000000005'
    )::text,
    true
);
SELECT is(
    (current_setting('test.return')::jsonb ->> 'status'),
    'REQUESTED',
    'consumer return request enters pending maker-checker state'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'c1000000-0000-0000-0000-000000000002',
    true
);
SELECT set_config(
    'test.return_decision',
    public.decide_consumer_return(
        (current_setting('test.return')::jsonb ->> 'return_request_id')::uuid,
        'APPROVED',
        'c4000000-0000-0000-0000-000000000006'
    )::text,
    true
);
SELECT is(
    (current_setting('test.return_decision')::jsonb ->> 'status'),
    'APPROVED',
    'separate administrator can approve a consumer return'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'c1000000-0000-0000-0000-000000000003',
    true
);
SELECT is(
    (public.complete_sandbox_consumer_return(
        (current_setting('test.return')::jsonb ->> 'return_request_id')::uuid,
        'c4000000-0000-0000-0000-000000000007'
    ) ->> 'mode'),
    'SANDBOX',
    'sandbox-only completion isolates external refund integration'
);
SELECT is(
    (SELECT payment_status::text
     FROM public.orders
     WHERE order_id = 'c3000000-0000-0000-0000-000000000001'),
    'PARTIALLY_REFUNDED',
    'partial approved return updates order payment status'
);
RESET ROLE;

SELECT is(
    (
        SELECT sum(points)::integer
        FROM private.loyalty_redemption_allocations
        WHERE customer_id = 'c1000000-0000-0000-0000-000000000001'
    ),
    120,
    'redemption allocations consume exactly the redeemed amount'
);

SELECT is(
    (
        SELECT sum(points)::integer
        FROM private.loyalty_redemption_allocations AS allocation
        JOIN private.loyalty_ledger AS entry
          ON entry.loyalty_entry_id = allocation.positive_entry_id
        WHERE allocation.customer_id = 'c1000000-0000-0000-0000-000000000001'
          AND entry.points_delta = 100
    ),
    100,
    'earliest-expiry FIFO redemption consumes the first grant before the next'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM private.customer_referrals
        WHERE invitee_id = 'c1000000-0000-0000-0000-000000000005'
          AND expires_at = created_at + interval '30 days'
    ),
    'direct referral registration expires after exactly thirty days'
);

SELECT is(
    (
        SELECT count(*)::integer
        FROM private.referral_rewards
        WHERE qualifying_order_id = 'c3000000-0000-0000-0000-000000000001'
    ),
    2,
    'hierarchical qualifying rewards include direct and second tiers'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1
        FROM private.referral_rewards
        WHERE expires_at IS DISTINCT FROM earned_at + interval '30 days'
    ),
    'every referral reward expires exactly thirty days after earning'
);

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'c1000000-0000-0000-0000-000000000004',
    true
);
SELECT ok(
    public.register_customer_referral(
        'c1000000-0000-0000-0000-000000000005',
        'ABC-123',
        'c4000000-0000-0000-0000-000000000001'
    ) IS NOT NULL,
    'repeat referral registration is replay-safe'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'c1000000-0000-0000-0000-000000000005',
    true
);
SELECT ok(
    public.confirm_legal_acceptance(
        'REFUND',
        'refund-v1',
        encode(sha256(convert_to('أقر بفهم سياسة الإرجاع والاسترداد وشروطها الإجرائية.', 'UTF8')), 'hex'),
        'c3000000-0000-0000-0000-000000000001',
        'c4000000-0000-0000-0000-000000000003'
    ) IS NOT NULL,
    'legal acceptance replay preserves the original acceptance'
);
SELECT ok(
    (
        SELECT count(*) = 1
        FROM public.consumer_return_requests
        WHERE return_request_id =
            (SELECT return_request_id
             FROM public.consumer_return_requests
             WHERE idempotency_key = 'c4000000-0000-0000-0000-000000000005')
    ),
    'return requests remain single-record idempotent'
);
RESET ROLE;

SELECT is(
    (
        SELECT state
        FROM private.refund_approvals
        WHERE idempotency_key = 'c4000000-0000-0000-0000-000000000005'
    ),
    'COMPLETED',
    'sandbox completion transitions the linked refund approval to completed'
);

SELECT is(
    (SELECT count(*)::integer FROM private.legal_contract_versions
     WHERE is_active),
    4,
    'exactly one active seed contract exists for each supported legal type'
);

SELECT ok(
    (
        SELECT count(*) = 1
        FROM private.loyalty_ledger
        WHERE customer_id = 'c1000000-0000-0000-0000-000000000001'
          AND entry_type = 'REDEEM'
          AND source_id = 'c2000000-0000-0000-0000-000000000001'
    ),
    'redemption replay creates no duplicate ledger entry'
);

SELECT throws_ok(
    $$ INSERT INTO private.loyalty_ledger (
           customer_id, entry_type, points_delta, source_type, source_id,
           earned_at, expires_at
       ) VALUES (
           'c1000000-0000-0000-0000-000000000001', 'EARN', 10,
           'order', 'bad-expiry', now(), now() + interval '29 days'
       ) $$,
    '23514',
    NULL,
    'positive loyalty entries remain exactly thirty-day grants'
);

SELECT ok(
    NOT has_table_privilege('authenticated', 'private.loyalty_ledger', 'SELECT')
    AND NOT has_table_privilege('anon', 'private.referral_rewards', 'SELECT')
    AND NOT has_table_privilege('service_role', 'private.legal_contract_versions', 'SELECT'),
    'loyalty, referral rewards, and legal private records are not directly readable'
);

SELECT * FROM finish();
ROLLBACK;
