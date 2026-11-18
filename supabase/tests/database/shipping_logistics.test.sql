BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(32);

SELECT ok(
    (
        SELECT count(*) = 3
           AND bool_and(relrowsecurity)
           AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'private'
          AND relation.relname IN (
              'sourcing_completion_events',
              'shipping_shipments',
              'shipping_events'
          )
          AND relation.relkind = 'r'
    ),
    'sourcing completion and shipping records force row-level security'
);

SELECT ok(
    NOT has_table_privilege('anon', 'private.shipping_shipments', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.shipping_shipments', 'SELECT')
    AND NOT has_table_privilege('service_role', 'private.shipping_events', 'SELECT'),
    'shipping records have no direct API table access'
);

SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.confirm_order_sourced(uuid,uuid)',
        'EXECUTE'
    )
    AND has_function_privilege(
        'authenticated',
        'public.create_sandbox_shipment(uuid,uuid)',
        'EXECUTE'
    )
    AND has_function_privilege(
        'authenticated',
        'public.get_my_shipping_status(uuid)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'service_role',
        'public.create_sandbox_shipment(uuid,uuid)',
        'EXECUTE'
    )
    AND has_function_privilege(
        'service_role',
        'public.ingest_sandbox_shipping_event(uuid,text,text,text)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'authenticated',
        'public.ingest_sandbox_shipping_event(uuid,text,text,text)',
        'EXECUTE'
    ),
    'admin RPCs and the sandbox event-ingestion RPC have separate grants'
);

INSERT INTO auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at
)
VALUES
    (
        'a3000000-0000-0000-0000-000000000001',
        'authenticated',
        'authenticated',
        'shipping-customer@example.test',
        '',
        now(),
        now(),
        now()
    ),
    (
        'a3000000-0000-0000-0000-000000000002',
        'authenticated',
        'authenticated',
        'shipping-admin@example.test',
        '',
        now(),
        now(),
        now()
    ),
    (
        'a3000000-0000-0000-0000-000000000003',
        'authenticated',
        'authenticated',
        'other-shipping-customer@example.test',
        '',
        now(),
        now(),
        now()
    );

UPDATE public.app_user_roles
SET role = 'ADMIN'
WHERE user_id = 'a3000000-0000-0000-0000-000000000002';

INSERT INTO public.shipping_regions (
    region_id, provider, provider_region_code, name, shipping_minor, is_active
)
VALUES (
    'a4000000-0000-0000-0000-000000000001',
    'BOSTA',
    'CAIRO-1',
    'القاهرة',
    1250,
    true
);

INSERT INTO public.orders (
    order_id,
    customer_id,
    order_status,
    payment_status,
    sourcing_status,
    payment_method,
    subtotal_minor,
    shipping_minor,
    total_minor,
    snapshot_schema_version,
    snapshot_json,
    snapshot_sha256
)
VALUES
    (
        'a5000000-0000-0000-0000-000000000001',
        'a3000000-0000-0000-0000-000000000001',
        'CONFIRMED',
        'SUCCEEDED',
        'SOURCING',
        'CARD',
        10000,
        1250,
        11250,
        1,
        jsonb_build_object(
            'shipping_region',
            jsonb_build_object(
                'region_id', 'a4000000-0000-0000-0000-000000000001',
                'name', 'القاهرة'
            )
        ),
        repeat('a', 64)
    ),
    (
        'a5000000-0000-0000-0000-000000000002',
        'a3000000-0000-0000-0000-000000000001',
        'CONFIRMED',
        'SUCCEEDED',
        'SOURCED',
        'CARD',
        10000,
        1250,
        11250,
        1,
        jsonb_build_object(
            'shipping_region',
            jsonb_build_object(
                'region_id', 'a4000000-0000-0000-0000-000000000001',
                'name', 'القاهرة'
            )
        ),
        repeat('b', 64)
    ),
    (
        'a5000000-0000-0000-0000-000000000003',
        'a3000000-0000-0000-0000-000000000001',
        'PAYMENT_PENDING',
        'PENDING',
        'PENDING',
        'CARD',
        10000,
        1250,
        11250,
        1,
        jsonb_build_object(
            'shipping_region',
            jsonb_build_object(
                'region_id', 'a4000000-0000-0000-0000-000000000001',
                'name', 'القاهرة'
            )
        ),
        repeat('c', 64)
    );

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'a3000000-0000-0000-0000-000000000001',
    true
);
SELECT throws_ok(
    $$
    SELECT public.confirm_order_sourced(
        'a5000000-0000-0000-0000-000000000001',
        'a6000000-0000-0000-0000-000000000001'
    )
    $$,
    '42501',
    'administrator role is required',
    'customers cannot confirm supplier fulfillment'
);
SELECT throws_ok(
    $$
    SELECT public.create_sandbox_shipment(
        'a5000000-0000-0000-0000-000000000001',
        'a6000000-0000-0000-0000-000000000001'
    )
    $$,
    '42501',
    'administrator role is required',
    'customers cannot create shipments'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'a3000000-0000-0000-0000-000000000002',
    true
);
SELECT set_config(
    'test.sourcing_result',
    public.confirm_order_sourced(
        'a5000000-0000-0000-0000-000000000001',
        'a6000000-0000-0000-0000-000000000001'
    )::text,
    true
);
SELECT is(
    current_setting('test.sourcing_result')::jsonb ->> 'status',
    'SOURCED',
    'an admin can confirm paid orders after supplier fulfillment'
);
SELECT is(
    public.confirm_order_sourced(
        'a5000000-0000-0000-0000-000000000001',
        'a6000000-0000-0000-0000-000000000001'
    )::jsonb ->> 'order_id',
    'a5000000-0000-0000-0000-000000000001',
    'replaying the sourcing confirmation returns its original result'
);
SELECT throws_ok(
    $$
    SELECT public.confirm_order_sourced(
        'a5000000-0000-0000-0000-000000000002',
        'a6000000-0000-0000-0000-000000000001'
    )
    $$,
    '23505',
    'sourcing idempotency key was reused for a different order',
    'a sourcing idempotency key cannot be reused for another order'
);
SELECT set_config(
    'test.shipment_result',
    public.create_sandbox_shipment(
        'a5000000-0000-0000-0000-000000000001',
        'a6000000-0000-0000-0000-000000000002'
    )::text,
    true
);
SELECT is(
    current_setting('test.shipment_result')::jsonb ->> 'status',
    'REQUESTED',
    'admin shipment requests start in the sandbox requested state'
);
SELECT ok(
    current_setting('test.shipment_result')::jsonb ->> 'provider_shipment_id'
        ~ '^SANDBOX-[0-9A-F]{24}$'
    AND (current_setting('test.shipment_result')::jsonb ->> 'sandbox_only')::boolean,
    'sandbox shipment references are visibly non-production'
);
SELECT is(
    current_setting('test.shipment_result')::jsonb ->> 'provider_shipment_id',
    'SANDBOX-' || upper(substr(
        encode(
            sha256(convert_to(
                'BOSTA:a5000000-0000-0000-0000-000000000001:a6000000-0000-0000-0000-000000000002',
                'UTF8'
            )),
            'hex'
        ),
        1,
        24
    )),
    'database and adapter use the same deterministic sandbox reference'
);
SELECT is(
    public.create_sandbox_shipment(
        'a5000000-0000-0000-0000-000000000001',
        'a6000000-0000-0000-0000-000000000002'
    )::jsonb ->> 'provider_shipment_id',
    current_setting('test.shipment_result')::jsonb ->> 'provider_shipment_id',
    'replaying shipment creation returns the same provider reference'
);
SELECT is(
    public.create_sandbox_shipment(
        'a5000000-0000-0000-0000-000000000001',
        'a6000000-0000-0000-0000-000000000003'
    )::jsonb ->> 'shipment_id',
    current_setting('test.shipment_result')::jsonb ->> 'shipment_id',
    'a second request cannot create another shipment for an order'
);
SELECT throws_ok(
    $$
    SELECT public.create_sandbox_shipment(
        'a5000000-0000-0000-0000-000000000002',
        'a6000000-0000-0000-0000-000000000002'
    )
    $$,
    '23505',
    'shipping idempotency key was reused for a different order',
    'a shipping idempotency key cannot be reused for another order'
);
RESET ROLE;

SELECT is(
    (
        SELECT count(*)::integer
        FROM private.shipping_shipments
        WHERE order_id = 'a5000000-0000-0000-0000-000000000001'
    ),
    1,
    'only one shipment row exists per order'
);
SELECT ok(
    EXISTS (
        SELECT 1
        FROM private.transactional_outbox
        WHERE aggregate_type = 'shipping_shipment'
          AND event_type = 'shipping.shipment_requested'
          AND (payload ->> 'sandbox_only')::boolean
    ),
    'shipment requests are queued transactionally without customer address data'
);

SET LOCAL ROLE service_role;
SELECT set_config(
    'test.shipping_event_result',
    public.ingest_sandbox_shipping_event(
        (current_setting('test.shipment_result')::jsonb ->> 'shipment_id')::uuid,
        'event-001',
        'LABEL_CREATED',
        'TEST123'
    )::text,
    true
);
SELECT is(
    current_setting('test.shipping_event_result')::jsonb ->> 'status',
    'LABEL_CREATED',
    'sandbox label events advance shipment status'
);
SELECT is(
    public.ingest_sandbox_shipping_event(
        (current_setting('test.shipment_result')::jsonb ->> 'shipment_id')::uuid,
        'event-001',
        'LABEL_CREATED',
        'TEST123'
    )::jsonb ->> 'duplicate',
    'true',
    'replaying a provider event does not repeat its transition'
);
SELECT throws_ok(
    $$
    SELECT public.ingest_sandbox_shipping_event(
        (current_setting('test.shipment_result')::jsonb ->> 'shipment_id')::uuid,
        'event-001',
        'IN_TRANSIT',
        'TEST123'
    )
    $$,
    '23505',
    'shipping event id was reused with different contents',
    'a provider event id cannot be reused with different contents'
);
SELECT is(
    public.ingest_sandbox_shipping_event(
        (current_setting('test.shipment_result')::jsonb ->> 'shipment_id')::uuid,
        'event-002',
        'IN_TRANSIT',
        NULL
    )::jsonb ->> 'status',
    'IN_TRANSIT',
    'in-transit events advance from label-created'
);
SELECT is(
    public.ingest_sandbox_shipping_event(
        (current_setting('test.shipment_result')::jsonb ->> 'shipment_id')::uuid,
        'event-003',
        'DELIVERED',
        NULL
    )::jsonb ->> 'status',
    'DELIVERED',
    'delivery events advance from in-transit'
);
SELECT throws_ok(
    $$
    SELECT public.ingest_sandbox_shipping_event(
        (current_setting('test.shipment_result')::jsonb ->> 'shipment_id')::uuid,
        'event-late',
        'IN_TRANSIT',
        NULL
    )
    $$,
    '55000',
    'shipping status transition is not allowed',
    'out-of-order state regressions are rejected'
);
RESET ROLE;

SELECT is(
    (
        SELECT shipping_status::text
        FROM public.orders
        WHERE order_id = 'a5000000-0000-0000-0000-000000000001'
    ),
    'DELIVERED',
    'shipping events update order tracking state atomically'
);
SELECT is(
    (
        SELECT order_status::text
        FROM public.orders
        WHERE order_id = 'a5000000-0000-0000-0000-000000000001'
    ),
    'DELIVERED',
    'delivery advances the customer order status'
);
SELECT ok(
    (
        SELECT count(*) = 1
        FROM private.sourcing_completion_events
        WHERE order_id = 'a5000000-0000-0000-0000-000000000001'
    )
    AND EXISTS (
        SELECT 1
        FROM private.transactional_outbox
        WHERE aggregate_id = 'a5000000-0000-0000-0000-000000000001'
          AND event_type = 'sourcing.goods_received'
    )
    AND EXISTS (
        SELECT 1
        FROM private.transactional_outbox
        WHERE aggregate_type = 'shipping_event'
          AND event_type = 'shipping.status_changed'
    ),
    'sourcing and shipping lifecycle transitions are audited and queued'
);

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'a3000000-0000-0000-0000-000000000001',
    true
);
SELECT is(
    public.get_my_shipping_status(
        'a5000000-0000-0000-0000-000000000001'
    )::jsonb ->> 'tracking_number',
    'TEST123',
    'customers can read their own sandbox tracking status'
);
RESET ROLE;
SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'a3000000-0000-0000-0000-000000000003',
    true
);
SELECT throws_ok(
    $$
    SELECT public.get_my_shipping_status(
        'a5000000-0000-0000-0000-000000000001'
    )
    $$,
    '42501',
    'shipment is unavailable',
    'customers cannot read another customer shipping status'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'a3000000-0000-0000-0000-000000000002',
    true
);
SELECT throws_ok(
    $$
    SELECT public.create_sandbox_shipment(
        'a5000000-0000-0000-0000-000000000003',
        'a6000000-0000-0000-0000-000000000005'
    )
    $$,
    '55000',
    'only paid, sourced, non-cancelled orders can be shipped',
    'unpaid orders cannot enter the shipping flow'
);
RESET ROLE;
SET LOCAL ROLE postgres;
SELECT throws_ok(
    $$
    UPDATE public.shipping_regions
    SET provider_region_code = 'CAIRO-2'
    WHERE region_id = 'a4000000-0000-0000-0000-000000000001'
    $$,
    '55000',
    'shipping region identity is fixed after checkout',
    'provider and region code cannot change after an order snapshots the region'
);
SELECT throws_ok(
    $$
    DELETE FROM public.shipping_regions
    WHERE region_id = 'a4000000-0000-0000-0000-000000000001'
    $$,
    '55000',
    'shipping region identity is fixed after checkout',
    'a shipping region cannot be deleted while historical orders reference it'
);
SELECT throws_ok(
    $$
    UPDATE private.shipping_events
    SET tracking_number = 'ALTERED'
    WHERE provider_event_id = 'event-001'
    $$,
    '55000',
    'immutable commerce records cannot be changed',
    'shipping events are append-only'
);
UPDATE public.shipping_regions
SET shipping_minor = 1500
WHERE region_id = 'a4000000-0000-0000-0000-000000000001';
SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'a3000000-0000-0000-0000-000000000002',
    true
);
SELECT throws_ok(
    $$
    SELECT public.create_sandbox_shipment(
        'a5000000-0000-0000-0000-000000000002',
        'a6000000-0000-0000-0000-000000000004'
    )
    $$,
    '55000',
    'shipping region or its price changed after checkout',
    'a changed shipping rate cannot alter a historical checkout'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
