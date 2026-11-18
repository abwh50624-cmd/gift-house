BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(24);

SELECT ok(
    (
        SELECT count(*) = 9
          AND bool_and(relrowsecurity)
          AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'private'
          AND relation.relname IN (
              'supplier_variant_mappings',
              'supplier_mapping_events',
              'supplier_telegram_mapping_events',
              'supplier_telegram_updates',
              'supplier_availability_reports',
              'sourcing_batches',
              'sourcing_allocations',
              'sourcing_gaps',
              'sourcing_batch_events'
          )
          AND relation.relkind = 'r'
    ),
    'supplier sourcing tables all force row-level security'
);

SELECT ok(
    NOT has_table_privilege('anon', 'private.supplier_availability_reports', 'SELECT')
    AND NOT has_table_privilege(
        'authenticated',
        'private.supplier_availability_reports',
        'SELECT'
    )
    AND NOT has_table_privilege('service_role', 'private.sourcing_allocations', 'SELECT'),
    'supplier availability and allocations have no direct API table access'
);

SELECT ok(
    has_function_privilege(
        'service_role',
        'public.ingest_supplier_telegram_update(bigint,bigint,bigint,bigint,text)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'authenticated',
        'public.ingest_supplier_telegram_update(bigint,bigint,bigint,bigint,text)',
        'EXECUTE'
    )
    AND has_function_privilege(
        'authenticated',
        'public.configure_supplier_telegram_mapping(text,text,bigint,bigint[])',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'service_role',
        'public.configure_supplier_telegram_mapping(text,text,bigint,bigint[])',
        'EXECUTE'
    )
    AND has_function_privilege(
        'authenticated',
        'public.create_sourcing_batch(timestamp with time zone,timestamp with time zone)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'service_role',
        'public.approve_sourcing_batch(uuid)',
        'EXECUTE'
    ),
    'only the worker ingests Telegram and sourcing actions use customer-authenticated RPCs'
);

INSERT INTO auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at
)
VALUES
    (
        '91000000-0000-0000-0000-000000000001',
        'authenticated',
        'authenticated',
        'sourcing-maker@example.test',
        '',
        now(),
        now(),
        now()
    ),
    (
        '91000000-0000-0000-0000-000000000002',
        'authenticated',
        'authenticated',
        'sourcing-checker@example.test',
        '',
        now(),
        now(),
        now()
    ),
    (
        '91000000-0000-0000-0000-000000000003',
        'authenticated',
        'authenticated',
        'sourcing-admin@example.test',
        '',
        now(),
        now(),
        now()
    );

UPDATE public.app_user_roles
SET role = 'SUPER_ADMIN'
WHERE user_id IN (
    '91000000-0000-0000-0000-000000000001',
    '91000000-0000-0000-0000-000000000002'
);
UPDATE public.app_user_roles
SET role = 'ADMIN'
WHERE user_id = '91000000-0000-0000-0000-000000000003';

INSERT INTO public.categories (category_id, slug, name, is_active)
VALUES (
    '92000000-0000-0000-0000-000000000001',
    'sourcing-test-category',
    'قسم التوريد',
    true
);
INSERT INTO public.products (product_id, category_id, slug, name, status)
VALUES (
    '93000000-0000-0000-0000-000000000001',
    '92000000-0000-0000-0000-000000000001',
    'sourcing-test-product',
    'منتج التوريد',
    'PUBLISHED'
);
INSERT INTO public.product_variants (
    variant_id, product_id, variant_name, weight_grams, price_minor, is_active
)
VALUES (
    '94000000-0000-0000-0000-000000000001',
    '93000000-0000-0000-0000-000000000001',
    'وزن التوريد',
    250,
    20000,
    true
);
SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    '91000000-0000-0000-0000-000000000003',
    true
);
SELECT throws_ok(
    $$
    SELECT public.configure_supplier_variant_mapping(
        '95000000-0000-0000-0000-000000000001',
        '94000000-0000-0000-0000-000000000001',
        'ITEM-A'
    )
    $$,
    '42501',
    'super administrator role is required',
    'ordinary admins cannot map supplier items to official catalog variants'
);
SELECT throws_ok(
    $$
    SELECT public.configure_supplier_telegram_mapping(
        'SUPPLIER_117',
        'مورد تجريبي',
        -10012345,
        ARRAY[77001]::bigint[]
    )
    $$,
    '42501',
    'super administrator role is required',
    'ordinary admins cannot register supplier Telegram identities'
);

SELECT set_config(
    'request.jwt.claim.sub',
    '91000000-0000-0000-0000-000000000001',
    true
);
SELECT set_config(
    'test.supplier_id',
    public.configure_supplier_telegram_mapping(
        'SUPPLIER_117',
        'مورد تجريبي',
        -10012345,
        ARRAY[77001]::bigint[]
    )::text,
    true
);
SELECT ok(
    public.configure_supplier_variant_mapping(
        current_setting('test.supplier_id')::uuid,
        '94000000-0000-0000-0000-000000000001',
        'ITEM-A'
    ) IS NOT NULL,
    'super admins can configure the audited supplier item mapping'
);
RESET ROLE;
SET LOCAL ROLE postgres;
SELECT ok(
    (
        SELECT count(*) = 1
           AND bool_and(new_chat_id = -10012345)
           AND bool_and(new_authorized_user_ids = ARRAY[77001]::bigint[])
        FROM private.supplier_telegram_mapping_events
    ),
    'supplier channel and authorized-team changes are audited'
);

SET LOCAL ROLE service_role;
SELECT is(
    public.ingest_supplier_telegram_update(
        9900000001,
        -10012345,
        77002,
        1,
        '/available ITEM-A 5 4000'
    ) ->> 'status',
    'UNAUTHORIZED',
    'supplier messages from a user outside the authorized id list are ignored'
);

SELECT is(
    public.ingest_supplier_telegram_update(
        9900000002,
        -10012345,
        77001,
        2,
        '/available ITEM-A 5 4000'
    ) ->> 'status',
    'RECORDED',
    'authorized supplier stock reports are recorded'
);

SELECT is(
    public.ingest_supplier_telegram_update(
        9900000002,
        -10012345,
        77001,
        2,
        '/available ITEM-A 999 1'
    ) ->> 'duplicate',
    'true',
    'replaying a Telegram update cannot replace its original report'
);

RESET ROLE;
SET LOCAL ROLE postgres;
SELECT is(
    (
        SELECT count(*)::integer
        FROM private.supplier_availability_reports
        WHERE available_quantity = 5
          AND supplier_cost_minor = 4000
          AND expires_at = reported_at + interval '48 hours'
    ),
    1,
    'availability reports expire exactly 48 hours after receipt'
);

SET LOCAL ROLE service_role;
SELECT is(
    public.ingest_supplier_telegram_update(
        9900000003,
        -10012345,
        77001,
        3,
        '/available UNKNOWN-ITEM 2 100'
    ) ->> 'status',
    'UNMAPPED_ITEM',
    'unmapped supplier item codes are never accepted as catalog identities'
);

RESET ROLE;
SET LOCAL ROLE postgres;
SELECT ok(
    EXISTS (
        SELECT 1
        FROM private.transactional_outbox
        WHERE event_type = 'supplier.mapping_required'
    ),
    'unmapped product codes create administrative outbox events'
);

INSERT INTO public.orders (
    order_id,
    customer_id,
    order_status,
    payment_status,
    sourcing_status,
    payment_method,
    subtotal_minor,
    total_minor,
    sourcing_window_ends_at,
    snapshot_schema_version,
    snapshot_json,
    snapshot_sha256,
    created_at
)
VALUES
    (
        '96000000-0000-0000-0000-000000000001',
        '91000000-0000-0000-0000-000000000001',
        'CONFIRMED',
        'SUCCEEDED',
        'PENDING',
        'CARD',
        100000,
        100000,
        now() + interval '48 hours',
        1,
        '{}'::jsonb,
        repeat('a', 64),
        now() - interval '10 minutes'
    ),
    (
        '96000000-0000-0000-0000-000000000002',
        '91000000-0000-0000-0000-000000000001',
        'PAYMENT_PENDING',
        'PENDING',
        'PENDING',
        'CARD',
        20000,
        20000,
        now() + interval '48 hours',
        1,
        '{}'::jsonb,
        repeat('b', 64),
        now() - interval '10 minutes'
    );
INSERT INTO public.order_items (
    order_item_id,
    order_id,
    variant_id,
    quantity,
    unit_price_minor,
    line_total_minor,
    item_snapshot
)
VALUES
    (
        '97000000-0000-0000-0000-000000000001',
        '96000000-0000-0000-0000-000000000001',
        '94000000-0000-0000-0000-000000000001',
        5,
        20000,
        100000,
        '{}'::jsonb
    ),
    (
        '97000000-0000-0000-0000-000000000002',
        '96000000-0000-0000-0000-000000000002',
        '94000000-0000-0000-0000-000000000001',
        1,
        20000,
        20000,
        '{}'::jsonb
    );

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    '91000000-0000-0000-0000-000000000003',
    true
);
SELECT throws_ok(
    $$
    SELECT public.create_sourcing_batch(now() - interval '2 days', now() - interval '1 minute')
    $$,
    '42501',
    'super administrator role is required',
    'ordinary admins cannot create sourcing plans'
);
SELECT set_config(
    'request.jwt.claim.sub',
    '91000000-0000-0000-0000-000000000001',
    true
);
SELECT set_config(
    'test.first_batch_result',
    public.create_sourcing_batch(
        now() - interval '2 days',
        now() - interval '1 minute'
    )::text,
    true
);
SELECT is(
    current_setting('test.first_batch_result')::jsonb ->> 'status',
    'PROPOSED',
    'a fully coverable two-day paid-order batch receives a proposed plan'
);
SELECT throws_ok(
    $$
    SELECT public.approve_sourcing_batch(
        (current_setting('test.first_batch_result')::jsonb ->> 'batch_id')::uuid
    )
    $$,
    '42501',
    'sourcing plan creator cannot approve the same plan',
    'sourcing plan creation and approval require distinct super admins'
);
SELECT set_config(
    'request.jwt.claim.sub',
    '91000000-0000-0000-0000-000000000002',
    true
);
SELECT is(
    public.approve_sourcing_batch(
        (current_setting('test.first_batch_result')::jsonb ->> 'batch_id')::uuid
    ) ->> 'status',
    'APPROVED',
    'a second super admin can approve a complete sourcing plan'
);

RESET ROLE;
SET LOCAL ROLE postgres;
SELECT ok(
    (
        SELECT sourcing_status = 'SOURCING'
        FROM public.orders
        WHERE order_id = '96000000-0000-0000-0000-000000000001'
    )
    AND (
        SELECT sum(quantity) = 5
        FROM private.sourcing_allocations
        WHERE batch_id = (current_setting('test.first_batch_result')::jsonb ->> 'batch_id')::uuid
    )
    AND EXISTS (
        SELECT 1
        FROM private.transactional_outbox
        WHERE aggregate_id = (current_setting('test.first_batch_result')::jsonb ->> 'batch_id')::uuid
          AND event_type = 'sourcing.orders_prepared'
    ),
    'approval advances sourcing state and atomically queues supplier instructions'
);

RESET ROLE;
SET LOCAL ROLE postgres;
SELECT throws_ok(
    $$
    UPDATE private.supplier_availability_reports
    SET available_quantity = 999
    WHERE telegram_update_id = 9900000002
    $$,
    '55000',
    'immutable commerce records cannot be changed',
    'supplier availability reports are append-only'
);

SET LOCAL ROLE service_role;
SELECT is(
    public.ingest_supplier_telegram_update(
        9900000004,
        -10012345,
        77001,
        4,
        '/available ITEM-A 0 0'
    ) ->> 'status',
    'RECORDED',
    'zero availability is recorded without fabricating a supplier cost'
);
RESET ROLE;
SET LOCAL ROLE postgres;
SELECT ok(
    EXISTS (
        SELECT 1
        FROM private.transactional_outbox
        WHERE event_type = 'supplier.availability_gap'
    ),
    'supplier stock shortages create an administrative outbox event'
);

UPDATE public.orders
SET order_status = 'CONFIRMED',
    payment_status = 'SUCCEEDED'
WHERE order_id = '96000000-0000-0000-0000-000000000002';

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    '91000000-0000-0000-0000-000000000001',
    true
);
SELECT set_config(
    'test.gap_batch_result',
    public.create_sourcing_batch(
        now() - interval '2 days',
        now() - interval '1 minute'
    )::text,
    true
);
SELECT is(
    current_setting('test.gap_batch_result')::jsonb ->> 'status',
    'NEEDS_REVIEW',
    'expired or zero supplier availability leaves a batch pending review'
);
SELECT throws_ok(
    $$
    SELECT public.approve_sourcing_batch(
        (current_setting('test.gap_batch_result')::jsonb ->> 'batch_id')::uuid
    )
    $$,
    '55000',
    'only a complete proposed sourcing batch can be approved',
    'a sourcing batch with unresolved gaps cannot be approved'
);
SELECT is(
    public.cancel_sourcing_batch(
        (current_setting('test.gap_batch_result')::jsonb ->> 'batch_id')::uuid
    ) ->> 'status',
    'CANCELLED',
    'an unapproved sourcing plan can be cancelled without changing orders'
);

SELECT * FROM finish();
ROLLBACK;
