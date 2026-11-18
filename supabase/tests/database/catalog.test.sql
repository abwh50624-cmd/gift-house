BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(13);

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
    'catalog tables have enabled and forced RLS'
);

SELECT ok(
    has_table_privilege('anon', 'public.categories', 'SELECT')
    AND has_table_privilege('anon', 'public.products', 'SELECT')
    AND has_table_privilege('anon', 'public.product_variants', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.products', 'INSERT'),
    'guests can read but cannot change catalog data'
);

SELECT ok(
    has_table_privilege('authenticated', 'public.categories', 'UPDATE')
    AND has_table_privilege('authenticated', 'public.products', 'UPDATE')
    AND has_table_privilege('authenticated', 'public.product_variants', 'UPDATE'),
    'authenticated catalog writes are additionally gated by RLS'
);

SELECT is(
    (
        SELECT count(*)::integer
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'categories'
    ),
    5,
    'categories expose active reads and super-admin write policies'
);

SELECT is(
    (
        SELECT count(*)::integer
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'products'
    ),
    5,
    'products expose published reads and admin write policies'
);

SELECT is(
    (
        SELECT count(*)::integer
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'product_variants'
    ),
    5,
    'variants expose active published reads and admin write policies'
);

SELECT throws_ok(
    $$ INSERT INTO public.products (category_id, slug, name, status)
       VALUES (gen_random_uuid(), 'draft-test', 'مسودة', 'NOT_A_STATUS') $$,
    '22P02',
    NULL,
    'product lifecycle values are constrained'
);

SELECT throws_ok(
    $$ INSERT INTO public.product_variants (
           product_id, variant_name, weight_grams, price_minor
       ) VALUES (
           gen_random_uuid(), 'وزن غير صالح', 0, 100
       ) $$,
    '23514',
    NULL,
    'variant weight must be a positive number of grams'
);

SELECT throws_ok(
    $$ INSERT INTO public.product_variants (
           product_id, variant_name, weight_grams, price_minor
       ) VALUES (
           gen_random_uuid(), 'سعر غير صالح', 100, 0
       ) $$,
    '23514',
    NULL,
    'variant price must be positive integer minor units'
);

SELECT throws_ok(
    $$ INSERT INTO public.categories (
           parent_category_id, slug, name
       ) VALUES (
           gen_random_uuid(), 'broken-parent', 'تصنيف غير صالح'
       ) $$,
    '23503',
    NULL,
    'category parents must exist'
);

INSERT INTO public.categories (category_id, slug, name, is_active)
VALUES
    ('41000000-0000-0000-0000-000000000001', 'public-category', 'قسم منشور', true),
    ('41000000-0000-0000-0000-000000000002', 'hidden-category', 'قسم مخفي', false);

INSERT INTO public.categories (
    category_id, parent_category_id, slug, name, is_active
)
VALUES (
    '41000000-0000-0000-0000-000000000003',
    '41000000-0000-0000-0000-000000000001',
    'public-child-category',
    'قسم فرعي منشور',
    true
);

SELECT throws_ok(
    $$
    UPDATE public.categories
    SET parent_category_id = '41000000-0000-0000-0000-000000000003'
    WHERE category_id = '41000000-0000-0000-0000-000000000001'
    $$,
    '23514',
    'category hierarchy cannot contain a cycle',
    'category hierarchy updates cannot introduce cycles'
);

INSERT INTO public.products (product_id, category_id, slug, name, status)
VALUES
    (
        '42000000-0000-0000-0000-000000000001',
        '41000000-0000-0000-0000-000000000001',
        'public-product',
        'منتج منشور',
        'PUBLISHED'
    ),
    (
        '42000000-0000-0000-0000-000000000002',
        '41000000-0000-0000-0000-000000000002',
        'hidden-product',
        'منتج مخفي',
        'PUBLISHED'
    );

INSERT INTO public.product_variants (
    variant_id, product_id, variant_name, weight_grams, price_minor, is_active
)
VALUES
    (
        '43000000-0000-0000-0000-000000000001',
        '42000000-0000-0000-0000-000000000001',
        'الأساسي',
        100,
        25000,
        true
    ),
    (
        '43000000-0000-0000-0000-000000000002',
        '42000000-0000-0000-0000-000000000001',
        'غير متاح',
        200,
        45000,
        false
    );

SET LOCAL ROLE anon;
SELECT ok(
    (SELECT count(*) = 2 FROM public.categories)
    AND (SELECT count(*) = 1 FROM public.products)
    AND (SELECT count(*) = 1 FROM public.product_variants),
    'guest RLS returns only active categories, published products, and active variants'
);
RESET ROLE;

SELECT ok(
    NOT has_function_privilege(
        'authenticated',
        'public.set_catalog_updated_at()',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'anon',
        'public.prevent_category_cycle()',
        'EXECUTE'
    ),
    'catalog trigger functions are not callable from the API'
);

SELECT * FROM finish();
ROLLBACK;
