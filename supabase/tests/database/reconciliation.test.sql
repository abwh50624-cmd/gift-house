BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(6);

SELECT ok(
    to_regclass('public.categories') IS NOT NULL
    AND to_regclass('public.products') IS NOT NULL
    AND to_regclass('public.product_variants') IS NOT NULL,
    'the reconciled catalog tables exist'
);

SELECT ok(
    to_regclass('public.profiles') IS NULL
    AND to_regclass('public.cart_items') IS NULL
    AND to_regclass('public.addresses') IS NULL,
    'empty legacy profile, cart, and address tables are removed'
);

SELECT ok(
    to_regtype('public.order_status') IS NOT NULL
    AND to_regtype('public.payment_status') IS NOT NULL
    AND to_regtype('public.sourcing_status') IS NOT NULL
    AND to_regtype('public.user_role') IS NULL,
    'commerce enums replace the legacy status and role types'
);

SELECT ok(
    NOT EXISTS (
        SELECT 1
        FROM pg_trigger AS trigger_record
        WHERE trigger_record.tgrelid = 'auth.users'::regclass
          AND NOT trigger_record.tgisinternal
          AND trigger_record.tgname = 'on_auth_user_created'
    )
    AND EXISTS (
        SELECT 1
        FROM pg_trigger AS trigger_record
        WHERE trigger_record.tgrelid = 'auth.users'::regclass
          AND NOT trigger_record.tgisinternal
          AND trigger_record.tgname = 'auth_user_create_customer_identity'
    ),
    'only the current customer identity trigger remains on auth.users'
);

SELECT ok(
    to_regprocedure('public.handle_new_user()') IS NULL
    AND to_regprocedure('public.m003_set_updated_at()') IS NULL
    AND to_regprocedure('public.set_products_updated_at()') IS NULL,
    'legacy identity and timestamp routines are removed'
);

SELECT ok(
    (
        SELECT count(*) = 3
          AND bool_and(relrowsecurity)
          AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname IN ('categories', 'products', 'product_variants')
          AND relation.relkind = 'r'
    ),
    'reconciled catalog tables retain forced RLS'
);

SELECT * FROM finish();
ROLLBACK;
