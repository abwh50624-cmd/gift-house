BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(10);

SELECT ok(
    (
        SELECT count(*) = 2
          AND bool_and(relrowsecurity)
          AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'public'
          AND relation.relname IN ('customer_profiles', 'app_user_roles')
          AND relation.relkind = 'r'
    ),
    'customer identity tables have enabled and forced RLS'
);

SELECT ok(
    NOT has_table_privilege('anon', 'public.customer_profiles', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.customer_profiles', 'UPDATE'),
    'anonymous users cannot read or update customer profiles'
);

SELECT ok(
    has_table_privilege('authenticated', 'public.customer_profiles', 'SELECT')
    AND has_table_privilege('authenticated', 'public.customer_profiles', 'UPDATE'),
    'authenticated users can use only profile self-service operations'
);

SELECT ok(
    NOT has_table_privilege('authenticated', 'public.app_user_roles', 'INSERT')
    AND NOT has_table_privilege('authenticated', 'public.app_user_roles', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.app_user_roles', 'DELETE'),
    'customers cannot mutate application role assignments'
);

SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.get_my_role()',
        'EXECUTE'
    ),
    'authenticated users can resolve their own role'
);

SELECT ok(
    NOT has_function_privilege(
        'anon',
        'public.get_my_role()',
        'EXECUTE'
    ),
    'anonymous users cannot resolve roles'
);

SELECT throws_ok(
    $$ INSERT INTO public.customer_profiles (
           user_id, display_name, phone_e164
       ) VALUES (
           gen_random_uuid(), 'عميل تجريبي', '01234567890'
       ) $$,
    '23514',
    NULL,
    'phone numbers must use valid E.164 format'
);

SELECT throws_ok(
    $$ INSERT INTO public.customer_profiles (
           user_id, display_name, phone_e164, phone_verified_at
       ) VALUES (
           gen_random_uuid(), 'عميل تجريبي', '+201012345678', NULL
       ) $$,
    '23514',
    NULL,
    'a stored phone number cannot be presented as verified'
);

SELECT throws_ok(
    $$ INSERT INTO public.app_user_roles (user_id, role)
       VALUES (gen_random_uuid(), 'NOT_A_ROLE') $$,
    '22P02',
    NULL,
    'application roles are constrained to the enum'
);

SELECT ok(
    (
        SELECT count(*) = 2
        FROM pg_policies
        WHERE schemaname = 'public'
          AND tablename = 'customer_profiles'
    ),
    'customer profile policies allow only own-row read and update'
);

SELECT * FROM finish();
ROLLBACK;
