BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(14);

SELECT ok(
    (
        SELECT count(*) = 3
           AND bool_and(relrowsecurity)
           AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname IN ('public', 'private')
          AND (
              (namespace.nspname = 'public' AND relation.relname IN ('support_threads', 'support_messages'))
              OR (namespace.nspname = 'private' AND relation.relname = 'ai_concierge_requests')
          )
          AND relation.relkind = 'r'
    ),
    'support and AI records force row-level security'
);

SELECT ok(
    NOT has_table_privilege('anon', 'public.support_threads', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.support_messages', 'SELECT')
    AND NOT has_table_privilege('service_role', 'public.support_threads', 'SELECT')
    AND NOT has_table_privilege('service_role', 'public.support_messages', 'SELECT'),
    'support tables have no anonymous or direct service table access'
);

SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.open_support_thread(text,text,uuid,text,uuid)',
        'EXECUTE'
    ),
    'customers can open support threads'
);

SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.send_support_message(uuid,text,uuid)',
        'EXECUTE'
    ),
    'customers can send support messages'
);

SELECT ok(
    has_function_privilege(
        'authenticated',
        'public.get_support_thread_messages(uuid)',
        'EXECUTE'
    ),
    'customers can read support thread messages'
);

SELECT ok(
    has_function_privilege(
        'service_role',
        'public.ingest_sandbox_ai_reply(uuid,text,uuid)',
        'EXECUTE'
    ),
    'the service role can ingest sandbox AI replies'
);

SELECT ok(
    NOT has_function_privilege(
        'authenticated',
        'public.ingest_sandbox_ai_reply(uuid,text,uuid)',
        'EXECUTE'
    ),
    'customers cannot directly ingest AI replies'
);

INSERT INTO auth.users (
    id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at
)
VALUES
    (
        'b1000000-0000-0000-0000-000000000001',
        'authenticated',
        'authenticated',
        'ai-customer@example.test',
        '',
        now(),
        now(),
        now()
    ),
    (
        'b1000000-0000-0000-0000-000000000002',
        'authenticated',
        'authenticated',
        'ai-admin@example.test',
        '',
        now(),
        now(),
        now()
    );

UPDATE public.app_user_roles
SET role = 'ADMIN'
WHERE user_id = 'b1000000-0000-0000-0000-000000000002';

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'b1000000-0000-0000-0000-000000000001',
    true
);
SELECT set_config(
    'test.support_thread',
    public.open_support_thread(
        'تلف في المنتج',
        'وصلني المنتج مكسورا',
        NULL,
        'DAMAGED',
        'b2000000-0000-0000-0000-000000000001'
    )::text,
    true
);
SELECT is(
    (SELECT count(*)::integer
     FROM public.support_messages
     WHERE thread_id = (current_setting('test.support_thread')::jsonb ->> 'thread_id')::uuid),
    1,
    'opening a support thread records the initial customer message'
);
SELECT is(
    (
        SELECT status::text
        FROM public.support_threads
        WHERE thread_id = (current_setting('test.support_thread')::jsonb ->> 'thread_id')::uuid
    ),
    'OPEN',
    'a new support thread starts open'
);
SELECT is(
    (
        SELECT priority::integer
        FROM public.support_threads
        WHERE thread_id = (current_setting('test.support_thread')::jsonb ->> 'thread_id')::uuid
    ),
    2,
    'damaged complaints receive elevated priority'
);
SELECT is(
    public.open_support_thread(
        'تلف في المنتج',
        'وصلني المنتج مكسورا',
        NULL,
        'DAMAGED',
        'b2000000-0000-0000-0000-000000000001'
    )::text,
    current_setting('test.support_thread'),
    'replaying support thread creation returns the original result'
);
SELECT throws_ok(
    $$
    SELECT public.open_support_thread(
        'طلب آخر',
        'رسالة أخرى',
        NULL,
        'GENERAL',
        'b2000000-0000-0000-0000-000000000001'
    )
    $$,
    '23505',
    'support idempotency key was reused for a different thread',
    'support idempotency keys reject mismatched replay requests'
);
RESET ROLE;

SET LOCAL ROLE authenticated;
SELECT set_config(
    'request.jwt.claim.sub',
    'b1000000-0000-0000-0000-000000000002',
    true
);
SELECT is(
    (
        SELECT count(*)::integer
        FROM public.support_threads
    ),
    1,
    'an admin can read the support queue'
);
RESET ROLE;

SET LOCAL ROLE service_role;
SELECT set_config(
    'request.jwt.claim.sub',
    '',
    true
);
SELECT set_config(
    'test.ai_reply',
    public.ingest_sandbox_ai_reply(
        (current_setting('test.support_thread')::jsonb ->> 'thread_id')::uuid,
        'تم تسجيل طلبك للمراجعة',
        'b2000000-0000-0000-0000-000000000002'
    )::text,
    true
);
SELECT is(
    current_setting('test.ai_reply')::jsonb ->> 'sender_type',
    'AI',
    'the sandbox AI worker can ingest a sandbox-only reply'
);
RESET ROLE;

SELECT * FROM finish();
ROLLBACK;
