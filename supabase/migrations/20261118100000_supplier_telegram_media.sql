CREATE FUNCTION public.ingest_supplier_telegram_photo(
    p_update_id bigint,
    p_chat_id bigint,
    p_user_id bigint,
    p_message_id bigint,
    p_supplier_item_code text,
    p_image_object_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private
AS $$
DECLARE
    v_supplier_id uuid;
    v_variant_id uuid;
    v_product_id uuid;
BEGIN
    IF p_update_id IS NULL OR p_update_id <= 0 OR p_update_id > 9007199254740991
        OR p_chat_id IS NULL OR p_chat_id = 0
        OR p_user_id IS NULL OR p_user_id <= 0
        OR p_message_id IS NULL OR p_message_id <= 0
        OR p_supplier_item_code IS NULL
        OR p_supplier_item_code !~ '^[A-Z0-9_-]{1,64}$'
        OR p_image_object_key IS NULL
        OR char_length(p_image_object_key) NOT BETWEEN 1 AND 512
        OR p_image_object_key ~ '(^/|(^|/)\.\.?(/|$))'
    THEN
        RAISE EXCEPTION 'invalid supplier Telegram photo'
            USING ERRCODE = '22023';
    END IF;

    SELECT supplier.supplier_id
    INTO v_supplier_id
    FROM private.supplier_telegram_mappings AS supplier
    WHERE supplier.telegram_chat_id = p_chat_id
      AND supplier.is_active
      AND p_user_id = ANY (supplier.authorized_telegram_user_ids);

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'UNAUTHORIZED');
    END IF;

    SELECT mapping.variant_id
    INTO v_variant_id
    FROM private.supplier_variant_mappings AS mapping
    WHERE mapping.supplier_id = v_supplier_id
      AND mapping.supplier_item_code = upper(p_supplier_item_code)
      AND mapping.is_active;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('status', 'UNMAPPED_ITEM');
    END IF;

    SELECT variant.product_id
    INTO v_product_id
    FROM public.product_variants AS variant
    WHERE variant.variant_id = v_variant_id;

    UPDATE public.products
    SET image_object_key = p_image_object_key,
        updated_at = clock_timestamp()
    WHERE product_id = v_product_id;

    RETURN jsonb_build_object(
        'status', 'RECORDED',
        'product_id', v_product_id,
        'image_object_key', p_image_object_key
    );
END;
$$;

REVOKE ALL ON FUNCTION public.ingest_supplier_telegram_photo(
    bigint, bigint, bigint, bigint, text, text
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_supplier_telegram_photo(
    bigint, bigint, bigint, bigint, text, text
) TO service_role;
