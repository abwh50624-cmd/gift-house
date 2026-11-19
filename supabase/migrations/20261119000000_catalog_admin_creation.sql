CREATE OR REPLACE FUNCTION public.create_catalog_product_with_variants(
    p_category_id uuid,
    p_slug text,
    p_name text,
    p_description text,
    p_image_object_key text,
    p_publish boolean,
    p_variants jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_product_id uuid;
    v_role text;
BEGIN
    v_role := public.get_my_role()::text;
    IF auth.uid() IS NULL OR v_role IS NULL OR v_role NOT IN ('ADMIN', 'SUPER_ADMIN') THEN
        RAISE EXCEPTION 'catalog administrator role is required'
            USING ERRCODE = '42501';
    END IF;

    IF p_publish IS NULL
        OR p_category_id IS NULL
        OR NULLIF(BTRIM(p_name), '') IS NULL
        OR NULLIF(BTRIM(p_slug), '') IS NULL
        OR p_variants IS NULL
        OR jsonb_typeof(p_variants) IS DISTINCT FROM 'array'
    THEN
        RAISE EXCEPTION 'invalid catalog product input'
            USING ERRCODE = '22023';
    END IF;

    IF jsonb_array_length(p_variants) NOT BETWEEN 1 AND 50 THEN
        RAISE EXCEPTION 'invalid catalog product input'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_variants) AS variant(value)
        WHERE jsonb_typeof(value) IS DISTINCT FROM 'object'
           OR NOT (value ?& ARRAY['variant_name', 'weight_grams', 'price_minor'])
           OR (value - ARRAY['variant_name', 'weight_grams', 'price_minor']::text[])
                IS DISTINCT FROM '{}'::jsonb
           OR jsonb_typeof(value -> 'variant_name') IS DISTINCT FROM 'string'
           OR jsonb_typeof(value -> 'weight_grams') IS DISTINCT FROM 'number'
           OR jsonb_typeof(value -> 'price_minor') IS DISTINCT FROM 'number'
           OR COALESCE(value ->> 'weight_grams', '') !~ '^[1-9][0-9]*$'
           OR COALESCE(value ->> 'price_minor', '') !~ '^[1-9][0-9]*$'
    ) THEN
        RAISE EXCEPTION 'invalid product variant input'
            USING ERRCODE = '22023';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.categories AS category
        WHERE category.category_id = p_category_id
          AND category.is_active
    ) THEN
        RAISE EXCEPTION 'an active product category is required'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO public.products (
        category_id,
        slug,
        name,
        description,
        image_object_key,
        status,
        created_by
    )
    VALUES (
        p_category_id,
        BTRIM(p_slug),
        BTRIM(p_name),
        NULLIF(BTRIM(p_description), ''),
        NULLIF(BTRIM(p_image_object_key), ''),
        CASE WHEN p_publish
            THEN 'PUBLISHED'::public.product_status
            ELSE 'DRAFT'::public.product_status
        END,
        auth.uid()
    )
    RETURNING product_id INTO v_product_id;

    INSERT INTO public.product_variants (
        product_id,
        variant_name,
        weight_grams,
        price_minor,
        is_active,
        display_order
    )
    SELECT
        v_product_id,
        BTRIM(variant.variant_name),
        variant.weight_grams,
        variant.price_minor,
        p_publish,
        item.position - 1
    FROM jsonb_array_elements(p_variants) WITH ORDINALITY AS item(value, position)
    CROSS JOIN LATERAL jsonb_to_record(item.value) AS variant(
        variant_name text,
        weight_grams integer,
        price_minor bigint
    );

    RETURN v_product_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_catalog_product_with_variants(
    uuid, text, text, text, text, boolean, jsonb
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_catalog_product_with_variants(
    uuid, text, text, text, text, boolean, jsonb
) TO authenticated;
