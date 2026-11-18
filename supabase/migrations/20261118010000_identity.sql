CREATE TYPE public.app_role AS ENUM ('CUSTOMER', 'ADMIN', 'SUPER_ADMIN');

CREATE TABLE public.customer_profiles (
    user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    display_name text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 100),
    phone_e164 text CHECK (
        phone_e164 IS NULL
        OR phone_e164 ~ '^\+[1-9][0-9]{7,14}$'
    ),
    phone_verified_at timestamptz,
    preferred_locale text NOT NULL DEFAULT 'ar'
        CHECK (preferred_locale IN ('ar', 'en')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT customer_phone_verification_consistent
        CHECK ((phone_e164 IS NULL AND phone_verified_at IS NULL)
            OR (phone_e164 IS NOT NULL AND phone_verified_at IS NOT NULL))
);

CREATE TABLE public.app_user_roles (
    user_id uuid PRIMARY KEY REFERENCES auth.users (id) ON DELETE CASCADE,
    role public.app_role NOT NULL DEFAULT 'CUSTOMER',
    granted_at timestamptz NOT NULL DEFAULT now(),
    granted_by uuid REFERENCES auth.users (id)
);

ALTER TABLE public.customer_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_profiles FORCE ROW LEVEL SECURITY;
ALTER TABLE public.app_user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_user_roles FORCE ROW LEVEL SECURITY;

CREATE POLICY customer_profiles_select_own
ON public.customer_profiles
FOR SELECT
TO authenticated
USING (user_id = (SELECT auth.uid()));

CREATE POLICY customer_profiles_update_own
ON public.customer_profiles
FOR UPDATE
TO authenticated
USING (user_id = (SELECT auth.uid()))
WITH CHECK (user_id = (SELECT auth.uid()));

CREATE POLICY app_user_roles_select_own
ON public.app_user_roles
FOR SELECT
TO authenticated
USING (user_id = (SELECT auth.uid()));

REVOKE ALL ON public.customer_profiles FROM anon, authenticated;
REVOKE ALL ON public.app_user_roles FROM anon, authenticated;
GRANT SELECT, UPDATE ON public.customer_profiles TO authenticated;
GRANT SELECT ON public.app_user_roles TO authenticated;

CREATE OR REPLACE FUNCTION public.set_customer_profile_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
    NEW.updated_at := now();
    NEW.user_id := OLD.user_id;
    NEW.phone_verified_at := OLD.phone_verified_at;
    RETURN NEW;
END;
$$;

CREATE TRIGGER customer_profiles_set_updated_at
BEFORE UPDATE ON public.customer_profiles
FOR EACH ROW EXECUTE FUNCTION public.set_customer_profile_updated_at();

REVOKE ALL ON FUNCTION public.set_customer_profile_updated_at() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.create_customer_identity()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    v_display_name text;
BEGIN
    v_display_name := NULLIF(
        BTRIM(COALESCE(NEW.raw_user_meta_data ->> 'full_name', '')),
        ''
    );
    IF v_display_name IS NULL THEN
        v_display_name := 'عميل بيت الهدايا';
    END IF;
    IF char_length(v_display_name) > 100 THEN
        v_display_name := substr(v_display_name, 1, 100);
    END IF;

    INSERT INTO public.customer_profiles (user_id, display_name)
    VALUES (NEW.id, v_display_name)
    ON CONFLICT (user_id) DO NOTHING;

    INSERT INTO public.app_user_roles (user_id, role)
    VALUES (NEW.id, 'CUSTOMER')
    ON CONFLICT (user_id) DO NOTHING;
    RETURN NEW;
END;
$$;

CREATE TRIGGER auth_user_create_customer_identity
AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.create_customer_identity();

REVOKE ALL ON FUNCTION public.create_customer_identity() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.get_my_role()
RETURNS public.app_role
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
    SELECT role
    FROM public.app_user_roles
    WHERE user_id = auth.uid()
$$;

REVOKE ALL ON FUNCTION public.get_my_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_role() TO authenticated;
