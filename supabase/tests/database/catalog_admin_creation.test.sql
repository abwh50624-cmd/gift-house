BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(9);

SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.create_catalog_product_with_variants(uuid,text,text,text,text,boolean,jsonb)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'anon',
        'public.create_catalog_product_with_variants(uuid,text,text,text,text,boolean,jsonb)',
        'EXECUTE'
    )
    AND NOT (
        SELECT procedure.prosecdef
        FROM pg_proc AS procedure
        WHERE procedure.oid = 'public.create_catalog_product_with_variants(uuid,text,text,text,text,boolean,jsonb)'::regprocedure
    ),
    'product creation is authenticated and remains security-invoker'
);

INSERT INTO auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at
)
VALUES
    (
        'c2000000-0000-0000-0000-000000000001',
        'authenticated',
        'authenticated',
        'catalog-customer@example.test',
        '',
        now(),
        now(),
        now()
    ),
    (
        'c2000000-0000-0000-0000-000000000002',
        'authenticated',
        'authenticated',
        'catalog-admin@example.test',
        '',
        now(),
        now(),
        now()
    ),
    (
        'c2000000-0000-0000-0000-000000000003',
        'authenticated',
        'authenticated',
        'catalog-super-admin@example.test',
        '',
        now(),
        now(),
        now()
    );

UPDATE public.app_user_roles
SET role = 'ADMIN'
WHERE user_id = 'c2000000-0000-0000-0000-000000000002';

UPDATE public.app_user_roles
SET role = 'SUPER_ADMIN'
WHERE user_id = 'c2000000-0000-0000-0000-000000000003';

INSERT INTO public.categories (category_id, slug, name, is_active)
VALUES
    (
        'c2100000-0000-0000-0000-000000000001',
        'catalog-active-category',
        'قسم فعال',
        true
    ),
    (
        'c2100000-0000-0000-0000-000000000002',
        'catalog-inactive-category',
        'قسم غير فعال',
        false
    );

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'c2000000-0000-0000-0000-000000000001',
    true
);
SELECT throws_ok(
    $$
    SELECT public.create_catalog_product_with_variants(
        'c2100000-0000-0000-0000-000000000001',
        'customer-cannot-create',
        'منتج غير مصرح',
        NULL,
        NULL,
        false,
        '[{"variant_name":"أساسي","weight_grams":100,"price_minor":10000}]'
    )
    $$,
    '42501',
    'catalog administrator role is required',
    'customers cannot create products through the RPC'
);
SELECT throws_ok(
    $$
    INSERT INTO public.products (category_id, slug, name)
    VALUES (
        'c2100000-0000-0000-0000-000000000001',
        'customer-direct-product',
        'منتج غير مصرح'
    )
    $$,
    '42501',
    NULL,
    'customers cannot bypass the RPC and write products directly'
);

SELECT set_config(
    'request.jwt.claim.sub',
    'c2000000-0000-0000-0000-000000000002',
    true
);
SELECT ok(
    public.create_catalog_product_with_variants(
        'c2100000-0000-0000-0000-000000000001',
        'admin-created-product',
        'منتج جديد',
        'وصف',
        NULL,
        true,
        '[
            {"variant_name":"صغير","weight_grams":100,"price_minor":12500},
            {"variant_name":"كبير","weight_grams":250,"price_minor":22000}
        ]'
    ) IS NOT NULL,
    'admins can atomically create a product and its variants'
);

SELECT is(
    (
        SELECT count(*)::integer
        FROM public.product_variants AS variant
        JOIN public.products AS product ON product.product_id = variant.product_id
        WHERE product.slug = 'admin-created-product'
          AND product.status = 'PUBLISHED'
          AND variant.is_active
          AND product.created_by = 'c2000000-0000-0000-0000-000000000002'
    ),
    2,
    'publication activates all submitted variants and records the authenticated creator'
);

SELECT throws_ok(
    $$
    SELECT public.create_catalog_product_with_variants(
        'c2100000-0000-0000-0000-000000000001',
        'product-without-variants',
        'منتج بلا خيارات',
        NULL,
        NULL,
        false,
        '[]'
    )
    $$,
    '22023',
    'invalid catalog product input',
    'products require at least one variant'
);

SELECT throws_ok(
    $$
    SELECT public.create_catalog_product_with_variants(
        'c2100000-0000-0000-0000-000000000002',
        'product-in-inactive-category',
        'منتج بقسم غير نشط',
        NULL,
        NULL,
        false,
        '[{"variant_name":"أساسي","weight_grams":100,"price_minor":10000}]'
    )
    $$,
    '23514',
    'an active product category is required',
    'products cannot be created under inactive categories'
);

RESET ROLE;
SELECT set_config(
    'request.jwt.claim.sub',
    'c2000000-0000-0000-0000-000000000002',
    true
);
SET LOCAL ROLE authenticated;
SELECT throws_ok(
    $$
    INSERT INTO public.categories (slug, name, is_active)
    VALUES ('admin-cannot-create-category', 'تصنيف غير مصرح', true)
    $$,
    '42501',
    NULL,
    'admins cannot create categories through direct RLS-protected writes'
);

SELECT set_config(
    'request.jwt.claim.sub',
    'c2000000-0000-0000-0000-000000000003',
    true
);
SELECT lives_ok(
    $$
    INSERT INTO public.categories (slug, name, is_active)
    VALUES ('super-admin-created-category', 'تصنيف جديد', true)
    $$,
    'super admins can create categories through the existing RLS policy'
);

SELECT * FROM finish();
ROLLBACK;
