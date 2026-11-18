BEGIN;

CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET LOCAL search_path = extensions, pg_catalog, public;

SELECT plan(30);

SELECT ok(
    (
        SELECT count(*) = 6
           AND bool_and(relrowsecurity)
           AND bool_and(relforcerowsecurity)
        FROM pg_class AS relation
        JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
        WHERE namespace.nspname = 'private'
          AND relation.relname IN (
              'ledger_accounts',
              'ledger_journals',
              'ledger_entries',
              'inventory_balances',
              'inventory_reservations',
              'inventory_movements'
          )
          AND relation.relkind = 'r'
    ),
    'every private foundation table has enabled and forced RLS'
);

SELECT ok(
    NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'private'),
    'the private foundation has no permissive API policies'
);

SELECT ok(
    NOT has_schema_privilege('anon', 'private', 'USAGE'),
    'anon cannot access the private schema'
);

SELECT ok(
    NOT has_schema_privilege('authenticated', 'private', 'USAGE'),
    'authenticated cannot access the private schema'
);

SELECT ok(
    has_schema_privilege('service_role', 'private', 'USAGE'),
    'service_role has schema usage for the restricted functions'
);

SELECT ok(
    NOT has_table_privilege('anon', 'private.ledger_entries', 'SELECT')
    AND NOT has_table_privilege('authenticated', 'private.ledger_entries', 'SELECT')
    AND NOT has_table_privilege('service_role', 'private.ledger_entries', 'SELECT'),
    'no API role can read ledger entries directly'
);

SELECT ok(
    NOT has_table_privilege('anon', 'private.inventory_balances', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'private.inventory_balances', 'UPDATE')
    AND NOT has_table_privilege('service_role', 'private.inventory_balances', 'UPDATE'),
    'no API role can update inventory balances directly'
);

SELECT ok(
    NOT has_function_privilege(
        'anon',
        'private.post_ledger_journal(text,text,text,jsonb)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'authenticated',
        'private.post_ledger_journal(text,text,text,jsonb)',
        'EXECUTE'
    ),
    'client API roles cannot post ledger journals'
);

SELECT ok(
    has_function_privilege(
        'service_role',
        'private.post_ledger_journal(text,text,text,jsonb)',
        'EXECUTE'
    ),
    'service_role can execute the ledger transaction function'
);

SELECT ok(
    has_function_privilege(
        'service_role',
        'private.reserve_inventory(uuid,uuid,bigint)',
        'EXECUTE'
    )
    AND has_function_privilege(
        'service_role',
        'private.release_inventory_reservation(uuid)',
        'EXECUTE'
    )
    AND has_function_privilege(
        'service_role',
        'private.consume_inventory_reservation(uuid)',
        'EXECUTE'
    ),
    'service_role can execute only the inventory transaction functions'
);

SELECT ok(
    NOT has_function_privilege(
        'anon',
        'private.reserve_inventory(uuid,uuid,bigint)',
        'EXECUTE'
    )
    AND NOT has_function_privilege(
        'authenticated',
        'private.reserve_inventory(uuid,uuid,bigint)',
        'EXECUTE'
    ),
    'client API roles cannot reserve inventory'
);

SELECT ok(
    NOT has_sequence_privilege(
        'service_role',
        'private.ledger_entries_entry_id_seq',
        'USAGE'
    ),
    'service_role cannot directly consume the ledger identity sequence'
);

SELECT lives_ok(
    $$ SELECT private.create_ledger_account('TEST_CASH', 'ASSET', 'EGP') $$,
    'ledger account creation is available to the trusted database role'
);

SELECT lives_ok(
    $$ SELECT private.create_ledger_account('TEST_REVENUE', 'REVENUE', 'EGP') $$,
    'a balanced journal can use a second account'
);

SELECT lives_ok(
    $$
    SELECT private.post_ledger_journal(
        'test_payment',
        'payment-1',
        'EGP',
        jsonb_build_array(
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_CASH'
                      AND currency_code = 'EGP'
                ),
                'side', 'DEBIT',
                'amount_minor', '100'
            ),
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_REVENUE'
                      AND currency_code = 'EGP'
                ),
                'side', 'CREDIT',
                'amount_minor', '100'
            )
        )
    )
    $$,
    'a balanced journal posts atomically'
);

SELECT is(
    private.post_ledger_journal(
        'test_payment',
        'payment-1',
        'EGP',
        jsonb_build_array(
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_CASH'
                      AND currency_code = 'EGP'
                ),
                'side', 'DEBIT',
                'amount_minor', '100'
            ),
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_REVENUE'
                      AND currency_code = 'EGP'
                ),
                'side', 'CREDIT',
                'amount_minor', '100'
            )
        )
    ),
    private.post_ledger_journal(
        'test_payment',
        'payment-1',
        'EGP',
        jsonb_build_array(
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_CASH'
                      AND currency_code = 'EGP'
                ),
                'side', 'DEBIT',
                'amount_minor', '100'
            ),
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_REVENUE'
                      AND currency_code = 'EGP'
                ),
                'side', 'CREDIT',
                'amount_minor', '100'
            )
        )
    ),
    'replaying the same journal request returns the same journal id'
);

SELECT ok(
    (SELECT count(*) = 1 FROM private.ledger_journals WHERE source_id = 'payment-1')
    AND (
        SELECT count(*) = 2
        FROM private.ledger_entries AS entry
        JOIN private.ledger_journals AS journal USING (journal_id)
        WHERE journal.source_id = 'payment-1'
    ),
    'a replay does not duplicate journal entries'
);

SELECT throws_ok(
    $$
    SELECT private.post_ledger_journal(
        'test_payment',
        'payment-unbalanced',
        'EGP',
        jsonb_build_array(
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_CASH'
                      AND currency_code = 'EGP'
                ),
                'side', 'DEBIT',
                'amount_minor', '100'
            ),
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_REVENUE'
                      AND currency_code = 'EGP'
                ),
                'side', 'CREDIT',
                'amount_minor', '99'
            )
        )
    )
    $$,
    '23514',
    'journal debits and credits must balance',
    'an unbalanced journal is rejected'
);

SELECT throws_ok(
    $$
    SELECT private.post_ledger_journal(
        'test_payment',
        'payment-1',
        'EGP',
        jsonb_build_array(
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_CASH'
                      AND currency_code = 'EGP'
                ),
                'side', 'DEBIT',
                'amount_minor', '101'
            ),
            jsonb_build_object(
                'account_id', (
                    SELECT account_id::text
                    FROM private.ledger_accounts
                    WHERE account_code = 'TEST_REVENUE'
                      AND currency_code = 'EGP'
                ),
                'side', 'CREDIT',
                'amount_minor', '101'
            )
        )
    )
    $$,
    '23505',
    'idempotency conflict for source test_payment.payment-1',
    'an idempotency key cannot be reused with a different journal'
);

SELECT throws_ok(
    $$
    UPDATE private.ledger_entries
    SET amount_minor = 101
    WHERE journal_id = (
        SELECT journal_id
        FROM private.ledger_journals
        WHERE source_id = 'payment-1'
    )
    $$,
    '55000',
    'ledger records are append-only',
    'posted ledger entries cannot be modified'
);

SELECT lives_ok(
    $$
    SELECT private.record_inventory_adjustment(
        '10000000-0000-0000-0000-000000000001',
        '20000000-0000-0000-0000-000000000001',
        'RESTOCK',
        5,
        'Foundation test stock'
    )
    $$,
    'initial stock is recorded through an idempotent movement'
);

SELECT is(
    private.reserve_inventory(
        '30000000-0000-0000-0000-000000000001',
        '10000000-0000-0000-0000-000000000001',
        3
    ),
    private.reserve_inventory(
        '30000000-0000-0000-0000-000000000001',
        '10000000-0000-0000-0000-000000000001',
        3
    ),
    'replaying a reservation returns the same reservation id'
);

SELECT ok(
    (
        SELECT physical_quantity = 5 AND reserved_quantity = 3
        FROM private.inventory_balances
        WHERE variant_id = '10000000-0000-0000-0000-000000000001'
    ),
    'reservation atomically increments reserved quantity'
);

SELECT throws_ok(
    $$
    SELECT private.reserve_inventory(
        '30000000-0000-0000-0000-000000000002',
        '10000000-0000-0000-0000-000000000001',
        3
    )
    $$,
    '23514',
    'insufficient available inventory',
    'reservation cannot oversell available stock'
);

SELECT lives_ok(
    $$
    SELECT private.release_inventory_reservation(
        private.reserve_inventory(
            '30000000-0000-0000-0000-000000000001',
            '10000000-0000-0000-0000-000000000001',
            3
        )
    )
    $$,
    'a reservation can be released'
);

SELECT ok(
    private.release_inventory_reservation(
        (
            SELECT reservation_id
            FROM private.inventory_reservations
            WHERE order_id = '30000000-0000-0000-0000-000000000001'
              AND variant_id = '10000000-0000-0000-0000-000000000001'
        )
    ),
    'releasing a reservation is idempotent'
);

SELECT lives_ok(
    $$
    SELECT private.reserve_inventory(
        '30000000-0000-0000-0000-000000000003',
        '10000000-0000-0000-0000-000000000001',
        3
    )
    $$,
    'released stock can be reserved by a new order'
);

SELECT lives_ok(
    $$
    SELECT private.consume_inventory_reservation(
        (
            SELECT reservation_id
            FROM private.inventory_reservations
            WHERE order_id = '30000000-0000-0000-0000-000000000003'
              AND variant_id = '10000000-0000-0000-0000-000000000001'
        )
    )
    $$,
    'a reserved quantity can be consumed'
);

SELECT ok(
    private.consume_inventory_reservation(
        (
            SELECT reservation_id
            FROM private.inventory_reservations
            WHERE order_id = '30000000-0000-0000-0000-000000000003'
              AND variant_id = '10000000-0000-0000-0000-000000000001'
        )
    ),
    'consuming a reservation is idempotent'
);

SELECT ok(
    (
        SELECT physical_quantity = 2 AND reserved_quantity = 0
        FROM private.inventory_balances
        WHERE variant_id = '10000000-0000-0000-0000-000000000001'
    ),
    'consuming a reservation decrements physical and reserved stock once'
);

SELECT * FROM finish();

ROLLBACK;
