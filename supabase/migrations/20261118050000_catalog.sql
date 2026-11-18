CREATE TYPE public.product_status AS ENUM ('DRAFT', 'PUBLISHED', 'ARCHIVED');

CREATE TABLE public.categories (
    category_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_category_id uuid REFERENCES public.categories (category_id) ON DELETE RESTRICT,
    slug text NOT NULL CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 100),
    description text CHECK (description IS NULL OR char_length(description) <= 500),
    display_order integer NOT NULL DEFAULT 0,
    is_active boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (parent_category_id IS NULL OR parent_category_id <> category_id)
);

CREATE UNIQUE INDEX categories_root_slug_unique
    ON public.categories (slug)
    WHERE parent_category_id IS NULL;

CREATE UNIQUE INDEX categories_child_slug_unique
    ON public.categories (parent_category_id, slug)
    WHERE parent_category_id IS NOT NULL;

CREATE INDEX categories_parent_order_idx
    ON public.categories (parent_category_id, display_order, category_id);

CREATE TABLE public.products (
    product_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id uuid NOT NULL REFERENCES public.categories (category_id) ON DELETE RESTRICT,
    slug text NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 160),
    description text CHECK (description IS NULL OR char_length(description) <= 2000),
    image_object_key text CHECK (
        image_object_key IS NULL
        OR (
            char_length(image_object_key) BETWEEN 1 AND 512
            AND image_object_key !~ '(^/|(^|/)\.\.?(/|$))'
        )
    ),
    status public.product_status NOT NULL DEFAULT 'DRAFT',
    created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX products_category_status_idx
    ON public.products (category_id, status, created_at DESC);

CREATE TABLE public.product_variants (
    variant_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    product_id uuid NOT NULL REFERENCES public.products (product_id) ON DELETE RESTRICT,
    variant_name text NOT NULL CHECK (char_length(variant_name) BETWEEN 1 AND 100),
    weight_grams integer NOT NULL CHECK (weight_grams > 0),
    price_minor bigint NOT NULL CHECK (price_minor > 0),
    currency_code text NOT NULL DEFAULT 'EGP' CHECK (currency_code = 'EGP'),
    is_active boolean NOT NULL DEFAULT false,
    display_order integer NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (product_id, variant_name, weight_grams)
);

CREATE INDEX product_variants_product_active_idx
    ON public.product_variants (product_id, is_active, display_order, variant_id);

CREATE FUNCTION public.set_catalog_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER categories_set_updated_at
BEFORE UPDATE ON public.categories
FOR EACH ROW EXECUTE FUNCTION public.set_catalog_updated_at();

CREATE TRIGGER products_set_updated_at
BEFORE UPDATE ON public.products
FOR EACH ROW EXECUTE FUNCTION public.set_catalog_updated_at();

CREATE TRIGGER product_variants_set_updated_at
BEFORE UPDATE ON public.product_variants
FOR EACH ROW EXECUTE FUNCTION public.set_catalog_updated_at();

REVOKE ALL ON FUNCTION public.set_catalog_updated_at() FROM PUBLIC, anon, authenticated;

CREATE FUNCTION public.prevent_category_cycle()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('category-hierarchy', 0));

    IF NEW.parent_category_id IS NOT NULL AND EXISTS (
        WITH RECURSIVE ancestors(category_id, parent_category_id) AS (
            SELECT category_id, parent_category_id
            FROM public.categories
            WHERE category_id = NEW.parent_category_id
            UNION ALL
            SELECT category.category_id, category.parent_category_id
            FROM public.categories AS category
            JOIN ancestors ON category.category_id = ancestors.parent_category_id
        )
        SELECT 1
        FROM ancestors
        WHERE category_id = NEW.category_id
    ) THEN
        RAISE EXCEPTION 'category hierarchy cannot contain a cycle'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER categories_prevent_cycle
BEFORE INSERT OR UPDATE OF parent_category_id ON public.categories
FOR EACH ROW EXECUTE FUNCTION public.prevent_category_cycle();

REVOKE ALL ON FUNCTION public.prevent_category_cycle() FROM PUBLIC, anon, authenticated;

ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories FORCE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products FORCE ROW LEVEL SECURITY;
ALTER TABLE public.product_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_variants FORCE ROW LEVEL SECURITY;

CREATE POLICY categories_public_read
ON public.categories
FOR SELECT
TO anon, authenticated
USING (is_active);

CREATE POLICY categories_admin_read
ON public.categories
FOR SELECT
TO authenticated
USING (public.get_my_role() = 'SUPER_ADMIN');

CREATE POLICY categories_super_admin_insert
ON public.categories
FOR INSERT
TO authenticated
WITH CHECK (public.get_my_role() = 'SUPER_ADMIN');

CREATE POLICY categories_super_admin_update
ON public.categories
FOR UPDATE
TO authenticated
USING (public.get_my_role() = 'SUPER_ADMIN')
WITH CHECK (public.get_my_role() = 'SUPER_ADMIN');

CREATE POLICY categories_super_admin_delete
ON public.categories
FOR DELETE
TO authenticated
USING (public.get_my_role() = 'SUPER_ADMIN');

CREATE POLICY products_public_read
ON public.products
FOR SELECT
TO anon, authenticated
USING (
    status = 'PUBLISHED'
    AND EXISTS (
        SELECT 1
        FROM public.categories AS category
        WHERE category.category_id = products.category_id
          AND category.is_active
    )
);

CREATE POLICY products_admin_read
ON public.products
FOR SELECT
TO authenticated
USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY products_admin_insert
ON public.products
FOR INSERT
TO authenticated
WITH CHECK (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY products_admin_update
ON public.products
FOR UPDATE
TO authenticated
USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'))
WITH CHECK (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY products_admin_delete
ON public.products
FOR DELETE
TO authenticated
USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY product_variants_public_read
ON public.product_variants
FOR SELECT
TO anon, authenticated
USING (
    is_active
    AND EXISTS (
        SELECT 1
        FROM public.products AS product
        JOIN public.categories AS category
          ON category.category_id = product.category_id
        WHERE product.product_id = product_variants.product_id
          AND product.status = 'PUBLISHED'
          AND category.is_active
    )
);

CREATE POLICY product_variants_admin_read
ON public.product_variants
FOR SELECT
TO authenticated
USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY product_variants_admin_insert
ON public.product_variants
FOR INSERT
TO authenticated
WITH CHECK (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY product_variants_admin_update
ON public.product_variants
FOR UPDATE
TO authenticated
USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'))
WITH CHECK (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

CREATE POLICY product_variants_admin_delete
ON public.product_variants
FOR DELETE
TO authenticated
USING (public.get_my_role() IN ('ADMIN', 'SUPER_ADMIN'));

REVOKE ALL ON public.categories, public.products, public.product_variants
    FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.categories, public.products, public.product_variants
    TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.categories TO authenticated;
GRANT INSERT, UPDATE, DELETE ON public.products, public.product_variants
    TO authenticated;
