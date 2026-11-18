BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(20);

SELECT ok(
    (
        SELECT count(*) = 4
          AND bool_and(relrowsecurity)
          AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname IN (
              'orders',
              'order_items',
              'customer_contract_confirmations',
              'shipping_regions'
          )
          AND relation.relkind = 'r'
    ),
    'all API-facing commerce tables enable and force RLS'
);

SELECT ok(
    (
        SELECT count(*) = 9
          AND bool_and(relrowsecurity)
          AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'private'
          AND relation.relname IN (
              'payment_webhook_events',
              'idempotency_keys',
              'transactional_outbox',
              'refund_approvals',
              'loyalty_ledger',
              'customer_referrals',
              'supplier_telegram_mappings',
              'supplier_submissions',
              'inventory_snapshots'
          )
          AND relation.relkind = 'r'
    ),
    'all private commerce tables enable and force RLS'
);

SELECT ok(
    NOT has_table_privilege('anon', 'public.orders', 'SELECT')
    AND has_table_privilege('authenticated', 'public.orders', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.orders', 'INSERT')
    AND NOT has_table_privilege('service_role', 'public.orders', 'SELECT'),
    'orders are customer-readable but not directly writable or service-role-readable'
);

SELECT ok(
    has_table_privilege('authenticated', 'public.order_items', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'public.order_items', 'INSERT')
    AND has_table_privilege('authenticated', 'public.customer_contract_confirmations', 'INSERT'),
    'order items are read-only and customers can record contract acceptance'
);

SELECT ok(
    has_table_privilege('anon', 'public.shipping_regions', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.shipping_regions', 'UPDATE')
    AND has_table_privilege('authenticated', 'public.shipping_regions', 'UPDATE'),
    'shipping regions are publicly readable and writes are gated by RLS'
);

SELECT ok(
    NOT has_table_privilege('anon', 'private.payment_webhook_events', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.loyalty_ledger', 'SELECT')
    AND NOT has_table_privilege('service_role', 'private.supplier_submissions', 'SELECT'),
    'private payment, loyalty, and supplier records are not directly accessible'
);

SELECT is(
    (
        SELECT count(*)::integer
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'orders'
    ),
    2,
    'orders expose only customer and administrator read policies'
);

SELECT is(
    (
        SELECT count(*)::integer
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'shipping_regions'
    ),
    5,
    'shipping policy set separates public reads from super-admin writes'
);

SELECT throws_ok(
    $$ INSERT INTO public.orders (
           customer_id, payment_method, subtotal_minor, total_minor,
           snapshot_schema_version, snapshot_json, snapshot_sha256
       ) VALUES (
           gen_random_uuid(), 'COD', 100, 100, 1, '{}'::jsonb, repeat('0', 64)
       ) $$,
    '23514',
    NULL,
    'cash on delivery is not an allowed payment method'
);

SELECT throws_ok(
    $$ INSERT INTO public.orders (
           customer_id, payment_method, subtotal_minor, total_minor,
           snapshot_schema_version, snapshot_json, snapshot_sha256
       ) VALUES (
           gen_random_uuid(), 'CARD', 100, 100, 1, '{}'::jsonb, repeat('0', 64)
       ) $$,
    '23503',
    NULL,
    'orders require a real customer identity'
);

SELECT throws_ok(
    $$ INSERT INTO public.orders (
           customer_id, order_status, payment_status, payment_method,
           subtotal_minor, total_minor, snapshot_schema_version, snapshot_json,
           snapshot_sha256
       ) VALUES (
           gen_random_uuid(), 'CONFIRMED', 'PENDING', 'CARD',
           100, 100, 1, '{}'::jsonb, repeat('0', 64)
       ) $$,
    '23514',
    NULL,
    'an order cannot be confirmed before successful prepayment'
);

SELECT throws_ok(
    $$ INSERT INTO private.idempotency_keys (
           scope, idempotency_key, request_sha256, state, completed_at
       ) VALUES (
           'order.create', 'invalid-state', repeat('0', 64), 'SUCCEEDED', NULL
       ) $$,
    '23514',
    NULL,
    'completed idempotency records require a completion timestamp'
);

SELECT throws_ok(
    $$ INSERT INTO private.loyalty_ledger (
           customer_id, entry_type, points_delta, source_type, source_id,
           earned_at, expires_at
       ) VALUES (
           gen_random_uuid(), 'EARN', 1, 'order', 'invalid-expiry',
           now(), now() + interval '29 days'
       ) $$,
    '23514',
    NULL,
    'positive loyalty grants must expire after exactly thirty days'
);

SELECT throws_ok(
    $$ INSERT INTO private.payment_webhook_events (
           provider, provider_event_id, event_type, event_payload, signature_verified
       ) VALUES (
           'gateway', 'unsigned-event', 'payment.succeeded', '{}'::jsonb, false
       ) $$,
    '23514',
    NULL,
    'unverified payment webhook events cannot be persisted as accepted events'
);

SELECT ok(
    NOT has_function_privilege(
        'anon',
        'public.set_commerce_updated_at()',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'authenticated',
        'private.prevent_commerce_record_mutation()',
        'EXECUTE'
    ),
    'commerce trigger functions are not callable from API roles'
);

SELECT is(
    (
        SELECT count(*)::integer
        FROM pg_indexes
        WHERE schemaname = 'private'
          AND indexname = 'transactional_outbox_pending_idx'
    ),
    1,
    'the outbox has a partial index for pending delivery work'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.orders'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%sourcing_window_ends_at%'
    ),
    'orders constrain sourcing windows to the documented two-to-three-day range'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'private.loyalty_ledger'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%30 days%'
    ),
    'positive loyalty grants expire after thirty days'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.orders'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) LIKE '%snapshot_sha256%'
    ),
    'order snapshots require a SHA-256 digest'
);

SELECT ok(
    EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'private.payment_webhook_events'::regclass
          AND contype = 'u'
          AND pg_get_constraintdef(oid) LIKE '%provider%'
          AND pg_get_constraintdef(oid) LIKE '%provider_event_id%'
    ),
    'payment webhook events are unique by provider and provider event id'
);

SELECT * FROM finish();
ROLLBACK;
