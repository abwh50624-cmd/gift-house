CREATE TYPE public.support_thread_status AS ENUM (
    'OPEN',
    'NEEDS_ADMIN',
    'WAITING_CUSTOMER',
    'RESOLVED',
    'CLOSED'
);

CREATE TYPE public.support_message_sender AS ENUM (
    'CUSTOMER',
    'ADMIN',
    'AI'
);

CREATE TABLE public.support_threads (
    thread_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    order_id uuid REFERENCES public.orders (order_id) ON DELETE RESTRICT,
    subject text NOT NULL CHECK (char_length(subject) BETWEEN 1 AND 160),
    status public.support_thread_status NOT NULL DEFAULT 'OPEN',
    priority smallint NOT NULL DEFAULT 0 CHECK (priority BETWEEN 0 AND 3),
    complaint_kind text
        CHECK (complaint_kind IS NULL OR complaint_kind IN (
            'GENERAL',
            'DAMAGED',
            'MANUFACTURING_DEFECT',
            'WRONG_SPECIFICATION',
            'LATE_DELIVERY',
            'RETURN'
        )),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX support_threads_customer_updated_idx
    ON public.support_threads (customer_id, updated_at DESC);
CREATE INDEX support_threads_admin_queue_idx
    ON public.support_threads (status, priority DESC, updated_at DESC);

CREATE TABLE public.support_messages (
    message_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id uuid NOT NULL REFERENCES public.support_threads (thread_id) ON DELETE RESTRICT,
    sender_id uuid NOT NULL REFERENCES auth.users (id) ON DELETE RESTRICT,
    sender_type public.support_message_sender NOT NULL,
    body text NOT NULL
        CHECK (char_length(body) BETWEEN 1 AND 4000),
    ai_sandbox boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (
        (sender_type = 'AI' AND ai_sandbox)
        OR (sender_type <> 'AI' AND NOT ai_sandbox)
    )
);

CREATE INDEX support_messages_thread_created_idx
    ON public.support_messages (thread_id, created_at, message_id);

CREATE TABLE private.ai_concierge_requests (
    request_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id uuid NOT NULL REFERENCES public.support_threads (thread_id) ON DELETE RESTRICT,
    scope text NOT NULL CHECK (scope IN ('CUSTOMER', 'ADMIN')),
    request_payload jsonb NOT NULL
        CHECK (
            jsonb_typeof(request_payload) = 'object'
            AND octet_length(request_payload::text) <= 16384
        ),
    sandbox_only boolean NOT NULL DEFAULT true CHECK (sandbox_only),
    created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.support_threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_threads FORCE ROW LEVEL SECURITY;
ALTER TABLE public.support_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.support_messages FORCE ROW LEVEL SECURITY;
ALTER TABLE private.ai_concierge_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.ai_concierge_requests FORCE ROW LEVEL SECURITY;

CREATE POLICY support_threads_select_customer
ON public.support_threads
FOR SELECT TO authenticated
USING (customer_id = (SELECT auth.uid()));

CREATE POLICY support_threads_select_admin
ON public.support_threads
FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1
    FROM public.app_user_roles AS role
    WHERE role.user_id = (SELECT auth.uid())
      AND role.role IN ('ADMIN', 'SUPER_ADMIN')
));

CREATE POLICY support_messages_select_customer
ON public.support_messages
FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1
    FROM public.support_threads AS thread
    WHERE thread.thread_id = support_messages.thread_id
      AND thread.customer_id = (SELECT auth.uid())
));

CREATE POLICY support_messages_select_admin
ON public.support_messages
FOR SELECT TO authenticated
USING (EXISTS (
    SELECT 1
    FROM public.app_user_roles AS role
    WHERE role.user_id = (SELECT auth.uid())
      AND role.role IN ('ADMIN', 'SUPER_ADMIN')
));

REVOKE ALL ON public.support_threads, public.support_messages
    FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON public.support_threads, public.support_messages TO authenticated;

REVOKE ALL ON private.ai_concierge_requests
    FROM PUBLIC, anon, authenticated, service_role;

CREATE TRIGGER support_messages_append_only
    BEFORE UPDATE OR DELETE ON public.support_messages
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE TRIGGER ai_concierge_requests_append_only
    BEFORE UPDATE OR DELETE ON private.ai_concierge_requests
    FOR EACH ROW EXECUTE FUNCTION private.prevent_commerce_record_mutation();

CREATE FUNCTION public.open_support_thread(
    p_subject text,
    p_initial_message text,
    p_order_id uuid,
    p_complaint_kind text,
    p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_request_hash text;
    v_existing_hash text;
    v_existing_state text;
    v_existing_response jsonb;
    v_thread public.support_threads%ROWTYPE;
    v_scope text;
    v_priority smallint := 0;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'authenticated customer identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF p_subject IS NULL
       OR p_initial_message IS NULL
       OR p_idempotency_key IS NULL
       OR char_length(p_subject) NOT BETWEEN 1 AND 160
       OR char_length(p_initial_message) NOT BETWEEN 1 AND 4000
    THEN
        RAISE EXCEPTION 'valid subject, message, and UUID idempotency key are required'
            USING ERRCODE = '22023';
    END IF;
    IF p_complaint_kind IS NOT NULL
       AND p_complaint_kind NOT IN (
           'GENERAL', 'DAMAGED', 'MANUFACTURING_DEFECT',
           'WRONG_SPECIFICATION', 'LATE_DELIVERY', 'RETURN'
       )
    THEN
        RAISE EXCEPTION 'invalid complaint kind'
            USING ERRCODE = '22023';
    END IF;
    IF p_order_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM public.orders AS order_record
        WHERE order_record.order_id = p_order_id
          AND order_record.customer_id = v_actor_id
    ) THEN
        RAISE EXCEPTION 'order does not belong to the authenticated customer'
            USING ERRCODE = '42501';
    END IF;

    IF p_complaint_kind IN ('DAMAGED', 'MANUFACTURING_DEFECT', 'RETURN') THEN
        v_priority := 2;
    ELSIF p_complaint_kind = 'LATE_DELIVERY' THEN
        v_priority := 1;
    END IF;

    v_scope := 'support.thread.open.' || v_actor_id::text;
    v_request_hash := encode(
        sha256(convert_to(jsonb_build_object(
            'subject', p_subject,
            'initial_message', p_initial_message,
            'order_id', p_order_id,
            'complaint_kind', p_complaint_kind
        )::text, 'UTF8')),
        'hex'
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_scope || ':' || p_idempotency_key::text, 0)
    );

    SELECT request_sha256, state, response_json
    INTO v_existing_hash, v_existing_state, v_existing_response
    FROM private.idempotency_keys
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key::text
    FOR UPDATE;
    IF FOUND THEN
        IF v_existing_hash <> v_request_hash THEN
            RAISE EXCEPTION 'support idempotency key was reused for a different thread'
                USING ERRCODE = '23505';
        END IF;
        IF v_existing_state = 'SUCCEEDED' THEN
            RETURN v_existing_response;
        END IF;
        RAISE EXCEPTION 'support request is not replayable'
            USING ERRCODE = '55000';
    END IF;

    INSERT INTO private.idempotency_keys (
        scope, idempotency_key, request_sha256, state
    )
    VALUES (v_scope, p_idempotency_key::text, v_request_hash, 'PROCESSING');

    INSERT INTO public.support_threads (
        customer_id, order_id, subject, status, priority, complaint_kind
    )
    VALUES (
        v_actor_id, p_order_id, p_subject, 'OPEN', v_priority, p_complaint_kind
    )
    RETURNING * INTO v_thread;

    INSERT INTO public.support_messages (
        thread_id, sender_id, sender_type, body
    )
    VALUES (
        v_thread.thread_id, v_actor_id, 'CUSTOMER', p_initial_message
    );

    INSERT INTO private.ai_concierge_requests (
        thread_id, scope, request_payload
    )
    VALUES (
        v_thread.thread_id,
        'CUSTOMER',
        jsonb_build_object(
            'subject', p_subject,
            'initial_message', p_initial_message,
            'complaint_kind', p_complaint_kind,
            'order_id', p_order_id
        )
    );

    INSERT INTO private.transactional_outbox (
        aggregate_type, aggregate_id, event_type, payload
    )
    VALUES (
        'support_thread',
        v_thread.thread_id,
        'support.thread.opened',
        jsonb_build_object(
            'thread_id', v_thread.thread_id,
            'customer_id', v_actor_id,
            'priority', v_priority
        )
    );

    v_existing_response := jsonb_build_object(
        'thread_id', v_thread.thread_id,
        'status', v_thread.status
    );
    UPDATE private.idempotency_keys
    SET state = 'SUCCEEDED',
        response_json = v_existing_response,
        completed_at = clock_timestamp()
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key::text;
    RETURN v_existing_response;
END;
$$;

CREATE FUNCTION public.send_support_message(
    p_thread_id uuid,
    p_message text,
    p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_actor_id uuid := auth.uid();
    v_thread public.support_threads%ROWTYPE;
    v_sender public.support_message_sender;
    v_scope text;
    v_request_hash text;
    v_existing_hash text;
    v_existing_state text;
    v_existing_response jsonb;
BEGIN
    IF v_actor_id IS NULL THEN
        RAISE EXCEPTION 'authenticated identity is required'
            USING ERRCODE = '28000';
    END IF;
    IF p_thread_id IS NULL
       OR p_message IS NULL
       OR p_idempotency_key IS NULL
       OR char_length(p_message) NOT BETWEEN 1 AND 4000
    THEN
        RAISE EXCEPTION 'valid thread, message, and UUID idempotency key are required'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_thread
    FROM public.support_threads
    WHERE thread_id = p_thread_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'support thread does not exist'
            USING ERRCODE = '22023';
    END IF;

    IF v_thread.customer_id = v_actor_id THEN
        v_sender := 'CUSTOMER';
    ELSIF EXISTS (
        SELECT 1
        FROM public.app_user_roles AS role
        WHERE role.user_id = v_actor_id
          AND role.role IN ('ADMIN', 'SUPER_ADMIN')
    ) THEN
        v_sender := 'ADMIN';
    ELSE
        RAISE EXCEPTION 'support thread access is denied'
            USING ERRCODE = '42501';
    END IF;

    v_scope := 'support.message.' || v_actor_id::text;
    v_request_hash := encode(
        sha256(convert_to(jsonb_build_object(
            'thread_id', p_thread_id,
            'message', p_message
        )::text, 'UTF8')),
        'hex'
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_scope || ':' || p_idempotency_key::text, 0)
    );

    SELECT request_sha256, state, response_json
    INTO v_existing_hash, v_existing_state, v_existing_response
    FROM private.idempotency_keys
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key::text
    FOR UPDATE;
    IF FOUND THEN
        IF v_existing_hash <> v_request_hash THEN
            RAISE EXCEPTION 'support idempotency key was reused for a different message'
                USING ERRCODE = '23505';
        END IF;
        IF v_existing_state = 'SUCCEEDED' THEN
            RETURN v_existing_response;
        END IF;
        RAISE EXCEPTION 'support request is not replayable'
            USING ERRCODE = '55000';
    END IF;

    INSERT INTO private.idempotency_keys (
        scope, idempotency_key, request_sha256, state
    )
    VALUES (v_scope, p_idempotency_key::text, v_request_hash, 'PROCESSING');

    INSERT INTO public.support_messages (
        thread_id, sender_id, sender_type, body
    )
    VALUES (
        p_thread_id, v_actor_id, v_sender, p_message
    );

    UPDATE public.support_threads
    SET status = CASE
            WHEN v_sender = 'ADMIN' THEN 'WAITING_CUSTOMER'
            ELSE 'OPEN'
        END,
        updated_at = clock_timestamp()
    WHERE thread_id = p_thread_id;

    v_existing_response := jsonb_build_object(
        'thread_id', p_thread_id,
        'sender_type', v_sender
    );
    UPDATE private.idempotency_keys
    SET state = 'SUCCEEDED',
        response_json = v_existing_response,
        completed_at = clock_timestamp()
    WHERE scope = v_scope
      AND idempotency_key = p_idempotency_key::text;
    RETURN v_existing_response;
END;
$$;

CREATE FUNCTION public.ingest_sandbox_ai_reply(
    p_thread_id uuid,
    p_message text,
    p_idempotency_key uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, private, auth
AS $$
DECLARE
    v_thread public.support_threads%ROWTYPE;
    v_scope text := 'support.ai.sandbox';
    v_request_hash text;
BEGIN
    IF p_thread_id IS NULL
       OR p_message IS NULL
       OR p_idempotency_key IS NULL
       OR char_length(p_message) NOT BETWEEN 1 AND 4000
    THEN
        RAISE EXCEPTION 'valid AI reply, thread, and UUID idempotency key are required'
            USING ERRCODE = '22023';
    END IF;
    IF current_user NOT IN ('postgres', 'service_role') THEN
        RAISE EXCEPTION 'only the sandbox AI worker may ingest replies'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
    INTO v_thread
    FROM public.support_threads
    WHERE thread_id = p_thread_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'support thread does not exist'
            USING ERRCODE = '22023';
    END IF;

    v_request_hash := encode(
        sha256(convert_to(jsonb_build_object(
            'thread_id', p_thread_id,
            'message', p_message
        )::text, 'UTF8')),
        'hex'
    );
    PERFORM pg_advisory_xact_lock(
        hashtextextended(v_scope || ':' || p_idempotency_key::text, 0)
    );

    INSERT INTO private.idempotency_keys (
        scope, idempotency_key, request_sha256, state, completed_at
    )
    VALUES (
        v_scope,
        p_idempotency_key::text,
        v_request_hash,
        'SUCCEEDED',
        clock_timestamp()
    )
    ON CONFLICT (scope, idempotency_key) DO NOTHING;

    IF EXISTS (
        SELECT 1
        FROM private.idempotency_keys
        WHERE scope = v_scope
          AND idempotency_key = p_idempotency_key::text
          AND request_sha256 <> v_request_hash
    ) THEN
        RAISE EXCEPTION 'sandbox AI idempotency key was reused for a different reply'
            USING ERRCODE = '23505';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM public.support_messages
        WHERE thread_id = p_thread_id
          AND sender_type = 'AI'
          AND ai_sandbox
          AND body = p_message
    ) THEN
        INSERT INTO public.support_messages (
            thread_id, sender_id, sender_type, body, ai_sandbox
        )
        VALUES (
            p_thread_id, v_thread.customer_id, 'AI', p_message, true
        );
    END IF;

    UPDATE public.support_threads
    SET status = 'WAITING_CUSTOMER',
        updated_at = clock_timestamp()
    WHERE thread_id = p_thread_id;
    RETURN jsonb_build_object(
        'thread_id', p_thread_id,
        'sender_type', 'AI',
        'sandbox', true
    );
END;
$$;

CREATE FUNCTION public.get_my_support_threads()
RETURNS TABLE (
    thread_id uuid,
    subject text,
    status public.support_thread_status,
    priority smallint,
    complaint_kind text,
    updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
    SELECT
        thread.thread_id,
        thread.subject,
        thread.status,
        thread.priority,
        thread.complaint_kind,
        thread.updated_at
    FROM public.support_threads AS thread
    WHERE thread.customer_id = auth.uid()
    ORDER BY thread.updated_at DESC;
$$;

CREATE FUNCTION public.get_support_thread_messages(p_thread_id uuid)
RETURNS TABLE (
    message_id uuid,
    sender_type public.support_message_sender,
    body text,
    ai_sandbox boolean,
    created_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
    SELECT
        message.message_id,
        message.sender_type,
        message.body,
        message.ai_sandbox,
        message.created_at
    FROM public.support_messages AS message
    JOIN public.support_threads AS thread
      ON thread.thread_id = message.thread_id
    WHERE message.thread_id = p_thread_id
      AND (
          thread.customer_id = auth.uid()
          OR EXISTS (
              SELECT 1
              FROM public.app_user_roles AS role
              WHERE role.user_id = auth.uid()
                AND role.role IN ('ADMIN', 'SUPER_ADMIN')
          )
      )
    ORDER BY message.created_at, message.message_id;
$$;

REVOKE ALL ON FUNCTION public.open_support_thread(text,text,uuid,text,uuid)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.open_support_thread(text,text,uuid,text,uuid)
    TO authenticated;
REVOKE ALL ON FUNCTION public.send_support_message(uuid,text,uuid)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_support_message(uuid,text,uuid)
    TO authenticated;
REVOKE ALL ON FUNCTION public.get_my_support_threads()
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_support_threads()
    TO authenticated;
REVOKE ALL ON FUNCTION public.get_support_thread_messages(uuid)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_support_thread_messages(uuid)
    TO authenticated;
REVOKE ALL ON FUNCTION public.ingest_sandbox_ai_reply(uuid,text,uuid)
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ingest_sandbox_ai_reply(uuid,text,uuid)
    TO service_role;
