DO $$
DECLARE
    v_relation regclass;
    v_row_count bigint;
    v_has_legacy_signature boolean;
    v_external_reference boolean;
    v_table_name text;
    v_required_columns text[];
BEGIN
    FOR v_table_name, v_required_columns IN
        SELECT *
        FROM (
            VALUES
                ('categories', ARRAY['id', 'name', 'slug', 'is_active']::text[]),
                ('products', ARRAY['id', 'title', 'price', 'category_id']::text[]),
                ('profiles', ARRAY['id', 'full_name', 'role', 'is_active']::text[]),
                ('cart_items', ARRAY['id', 'user_id', 'product_id', 'quantity']::text[]),
                ('addresses', ARRAY['id', 'user_id', 'governorate', 'city']::text[])
        ) AS legacy_tables(table_name, required_columns)
    LOOP
        v_relation := to_regclass(format('public.%I', v_table_name));
        IF v_relation IS NULL THEN
            CONTINUE;
        END IF;

        EXECUTE format('LOCK TABLE public.%I IN ACCESS EXCLUSIVE MODE', v_table_name);

        SELECT coalesce(
            array_agg(attribute.attname::text ORDER BY attribute.attname::text)
                @> v_required_columns,
            false
        )
        INTO v_has_legacy_signature
        FROM pg_attribute AS attribute
        WHERE attribute.attrelid = v_relation
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped;

        IF NOT v_has_legacy_signature THEN
            RAISE EXCEPTION
                'refusing to drop public.%: its columns do not match the audited legacy table',
                v_table_name
                USING ERRCODE = '55000';
        END IF;

        EXECUTE format('SELECT count(*) FROM public.%I', v_table_name)
            INTO v_row_count;
        IF v_row_count <> 0 THEN
            RAISE EXCEPTION
                'refusing to drop public.%: it contains % rows; archive or migrate this data first',
                v_table_name,
                v_row_count
                USING ERRCODE = '55000';
        END IF;
    END LOOP;

    IF to_regtype('public.user_role') IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM pg_attribute AS attribute
        JOIN pg_class AS relation ON relation.oid = attribute.attrelid
        WHERE relation.relnamespace = 'public'::regnamespace
          AND relation.relname = 'profiles'
          AND attribute.attname = 'role'
          AND attribute.atttypid = to_regtype('public.user_role')
          AND attribute.attnum > 0
          AND NOT attribute.attisdropped
    ) THEN
        RAISE EXCEPTION
            'refusing to drop public.user_role: it is not attached to the audited legacy profiles.role column'
            USING ERRCODE = '55000';
    END IF;

    FOREACH v_table_name IN ARRAY ARRAY[
        'cart_items',
        'addresses',
        'products',
        'categories',
        'profiles'
    ]
    LOOP
        v_relation := to_regclass(format('public.%I', v_table_name));
        IF v_relation IS NULL THEN
            CONTINUE;
        END IF;

        SELECT EXISTS (
            SELECT 1
            FROM pg_constraint AS constraint_record
            WHERE constraint_record.contype = 'f'
              AND constraint_record.confrelid = v_relation
              AND constraint_record.conrelid <> v_relation
              AND NOT (
                  constraint_record.conrelid = to_regclass('public.cart_items')
                  AND v_table_name = 'products'
              )
              AND NOT (
                  constraint_record.conrelid = to_regclass('public.cart_items')
                  AND v_table_name = 'profiles'
              )
              AND NOT (
                  constraint_record.conrelid = to_regclass('public.addresses')
                  AND v_table_name = 'profiles'
              )
              AND NOT (
                  constraint_record.conrelid = to_regclass('public.products')
                  AND v_table_name = 'categories'
              )
        )
        INTO v_external_reference;

        IF v_external_reference THEN
            RAISE EXCEPTION
                'refusing to drop public.%: another table has a foreign-key dependency',
                v_table_name
                USING ERRCODE = '55000';
        END IF;
    END LOOP;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

DROP TABLE IF EXISTS public.cart_items;
DROP TABLE IF EXISTS public.addresses;
DROP TABLE IF EXISTS public.products;
DROP TABLE IF EXISTS public.categories;
DROP TABLE IF EXISTS public.profiles;

DROP FUNCTION IF EXISTS public.handle_new_user();
DROP FUNCTION IF EXISTS public.m003_set_updated_at();
DROP FUNCTION IF EXISTS public.set_products_updated_at();

DO $$
BEGIN
    IF to_regtype('public.order_status') IS NOT NULL THEN
        IF EXISTS (
            SELECT 1
            FROM pg_enum AS enum_label
            WHERE enum_label.enumtypid = 'public.order_status'::regtype
              AND enum_label.enumlabel NOT IN (
                  'pending', 'processing', 'shipped', 'delivered', 'cancelled', 'returned'
              )
        ) OR (
            SELECT count(*)
            FROM pg_enum AS enum_label
            WHERE enum_label.enumtypid = 'public.order_status'::regtype
        ) <> 6 THEN
            RAISE EXCEPTION 'refusing to drop an unrecognized public.order_status enum'
                USING ERRCODE = '55000';
        END IF;
        DROP TYPE public.order_status;
    END IF;

    IF to_regtype('public.payment_status') IS NOT NULL THEN
        IF EXISTS (
            SELECT 1
            FROM pg_enum AS enum_label
            WHERE enum_label.enumtypid = 'public.payment_status'::regtype
              AND enum_label.enumlabel NOT IN ('pending', 'paid', 'failed', 'refunded')
        ) OR (
            SELECT count(*)
            FROM pg_enum AS enum_label
            WHERE enum_label.enumtypid = 'public.payment_status'::regtype
        ) <> 4 THEN
            RAISE EXCEPTION 'refusing to drop an unrecognized public.payment_status enum'
                USING ERRCODE = '55000';
        END IF;
        DROP TYPE public.payment_status;
    END IF;

    IF to_regtype('public.user_role') IS NOT NULL THEN
        IF EXISTS (
            SELECT 1
            FROM pg_enum AS enum_label
            WHERE enum_label.enumtypid = 'public.user_role'::regtype
              AND enum_label.enumlabel NOT IN ('customer', 'support', 'admin', 'super_admin')
        ) OR (
            SELECT count(*)
            FROM pg_enum AS enum_label
            WHERE enum_label.enumtypid = 'public.user_role'::regtype
        ) <> 4 THEN
            RAISE EXCEPTION 'refusing to drop an unrecognized public.user_role enum'
                USING ERRCODE = '55000';
        END IF;
        DROP TYPE public.user_role;
    END IF;
END;
$$;
