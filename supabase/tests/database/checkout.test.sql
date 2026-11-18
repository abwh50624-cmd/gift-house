BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(15);

SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.create_checkout_order(jsonb,text,text,uuid,text,text)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'anon',
        'public.create_checkout_order(jsonb,text,text,uuid,text,text)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'service_role',
        'public.create_checkout_order(jsonb,text,text,uuid,text,text)',
        'EXECUTE'
    ),
    'checkout RPC is callable only by authenticated customers'
);

SELECT ok(
    NOT has_function_privilege(
        'authenticated',
        'private.expire_pending_checkout_orders(integer)',
        'EXECUTE'
    )
    AND has_function_privilege(
        'service_role',
        'private.expire_pending_checkout_orders(integer)',
        'EXECUTE'
    ),
    'pending reservation expiry is restricted to the trusted worker'
);

SELECT ok(
    NOT has_column_privilege(
        'authenticated',
        'private.inventory_reservations',
        'expires_at',
        'UPDATE'
    ),
    'customers cannot change checkout reservation expiry'
);

SELECT is(
    public.get_checkout_terms() ->> 'version',
    'prepaid-order-v1',
    'checkout serves the current versioned prepaid terms'
);

SELECT is(
    public.get_checkout_terms() ->> 'sha256',
    encode(
        sha256(convert_to(public.get_checkout_terms() ->> 'text', 'UTF8')),
        'hex'
    ),
    'checkout terms digest matches the exact text shown to customers'
);

SELECT throws_ok(
    $$
    SELECT public.create_checkout_order(
        '[]'::jsonb,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        'CARD',
        gen_random_uuid(),
        'prepaid-order-v1',
        public.get_checkout_terms() ->> 'sha256'
    )
    $$,
    '28000',
    'authenticated customer identity is required',
    'guests cannot create checkout orders'
);

INSERT INTO auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at
)
VALUES (
    '51000000-0000-0000-0000-000000000001',
    'authenticated',
    'authenticated',
    'checkout-customer@example.test',
    '',
    now(),
    now(),
    now()
);

INSERT INTO public.categories (category_id, slug, name, is_active)
VALUES (
    '52000000-0000-0000-0000-000000000001',
    'checkout-category',
    'قسم الطلب',
    true
);

INSERT INTO public.products (product_id, category_id, slug, name, status)
VALUES (
    '53000000-0000-0000-0000-000000000001',
    '52000000-0000-0000-0000-000000000001',
    'checkout-product',
    'منتج الطلب',
    'PUBLISHED'
);

INSERT INTO public.product_variants (
    variant_id, product_id, variant_name, weight_grams, price_minor, is_active
)
VALUES (
    '54000000-0000-0000-0000-000000000001',
    '53000000-0000-0000-0000-000000000001',
    'وزن الطلب',
    250,
    12500,
    true
);

INSERT INTO private.inventory_balances (variant_id, physical_quantity)
VALUES ('54000000-0000-0000-0000-000000000001', 5);

INSERT INTO public.shipping_regions (
    region_id, provider, provider_region_code, name, shipping_minor, is_active
)
VALUES (
    '55000000-0000-0000-0000-000000000001',
    'BOSTA',
    'checkout-test-region',
    'منطقة التوصيل',
    3000,
    true
);

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    '51000000-0000-0000-0000-000000000001',
    true
);

SELECT throws_ok(
    $$
    SELECT public.create_checkout_order(
        '[{"variant_id":"54000000-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01',
        'COD',
        '55000000-0000-0000-0000-000000000001',
        'prepaid-order-v1',
        public.get_checkout_terms() ->> 'sha256'
    )
    $$,
    '22023',
    'unsupported prepaid payment method',
    'cash on delivery is rejected by the server'
);

SELECT throws_ok(
    $$
    SELECT public.create_checkout_order(
        '[{"variant_id":"54000000-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa04',
        'CARD',
        '55000000-0000-0000-0000-000000000001',
        'outdated-terms',
        public.get_checkout_terms() ->> 'sha256'
    )
    $$,
    '22023',
    'checkout terms have changed; review and accept the current terms',
    'stale checkout terms cannot be accepted by the server'
);

SELECT is(
    public.create_checkout_order(
        '[{"variant_id":"54000000-0000-0000-0000-000000000001","quantity":2}]'::jsonb,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02',
        'CARD',
        '55000000-0000-0000-0000-000000000001',
        public.get_checkout_terms() ->> 'version',
        public.get_checkout_terms() ->> 'sha256'
    ) ->> 'total_minor',
    '28000',
    'order total is recalculated from database price and shipping data'
);

SELECT is(
    public.create_checkout_order(
        '[{"variant_id":"54000000-0000-0000-0000-000000000001","quantity":2}]'::jsonb,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02',
        'CARD',
        '55000000-0000-0000-0000-000000000001',
        public.get_checkout_terms() ->> 'version',
        public.get_checkout_terms() ->> 'sha256'
    ) ->> 'order_id',
    (
        SELECT order_id::text
        FROM public.orders
    ),
    'retry with the same idempotency key returns the original order'
);

SELECT throws_ok(
    $$
    SELECT public.create_checkout_order(
        '[{"variant_id":"54000000-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa02',
        'CARD',
        '55000000-0000-0000-0000-000000000001',
        public.get_checkout_terms() ->> 'version',
        public.get_checkout_terms() ->> 'sha256'
    )
    $$,
    '23505',
    'idempotency key was reused with a different checkout request',
    'idempotency key cannot be reused for a different cart'
);

SELECT throws_ok(
    $$
    SELECT public.create_checkout_order(
        '[{"variant_id":"54000000-0000-0000-0000-000000000001","quantity":4}]'::jsonb,
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa03',
        'CARD',
        '55000000-0000-0000-0000-000000000001',
        public.get_checkout_terms() ->> 'version',
        public.get_checkout_terms() ->> 'sha256'
    )
    $$,
    '23514',
    'insufficient available inventory',
    'stock shortage rejects the whole checkout transaction'
);

RESET ROLE;
SET LOCAL ROLE postgres;

SELECT ok(
    (
        SELECT count(*) = 1
          AND bool_and(order_status = 'PAYMENT_PENDING')
          AND bool_and(payment_status = 'PENDING')
          AND bool_and(payment_method = 'CARD')
        FROM public.orders
    )
    AND (
        SELECT count(*) = 1
          AND bool_and(quantity = 2)
          AND bool_and(unit_price_minor = 12500)
        FROM public.order_items
    )
    AND (
        SELECT reserved_quantity = 2
        FROM private.inventory_balances
        WHERE variant_id = '54000000-0000-0000-0000-000000000001'
    ),
    'order, immutable items, and stock reservation commit atomically as pending payment'
);

SELECT ok(
    (
        SELECT snapshot_sha256 = encode(
            sha256(convert_to(snapshot_json::text, 'UTF8')),
            'hex'
        )
        FROM public.orders
    )
    AND (
        SELECT count(*) = 1
        FROM public.customer_contract_confirmations
    )
    AND (
        SELECT count(*) = 1
        FROM private.transactional_outbox
        WHERE event_type = 'checkout.payment_requested'
    ),
    'order snapshot, accepted terms, and payment outbox event are persisted'
);

SELECT throws_ok(
    $$
    UPDATE public.orders
    SET snapshot_json = snapshot_json || '{"tampered":true}'::jsonb
    $$,
    '55000',
    'immutable commerce records cannot be changed',
    'persisted order snapshots cannot be modified'
);

SELECT * FROM finish();
ROLLBACK;
