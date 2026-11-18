CREATE SCHEMA IF NOT EXISTS private;

REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA private TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA private
    REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA private
    REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA private
    REVOKE ALL ON FUNCTIONS FROM PUBLIC, anon, authenticated, service_role;

CREATE TABLE private.ledger_accounts (
    account_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_code text NOT NULL CHECK (account_code ~ '^[A-Z][A-Z0-9_]{0,63}$'),
    account_type text NOT NULL CHECK (
        account_type IN ('ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'EXPENSE')
    ),
    currency_code text NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (account_code, currency_code)
);

CREATE TABLE private.ledger_journals (
    journal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_type text NOT NULL CHECK (source_type ~ '^[a-z][a-z0-9_]{0,63}$'),
    source_id text NOT NULL CHECK (length(source_id) BETWEEN 1 AND 200),
    currency_code text NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
    request_entries jsonb NOT NULL CHECK (jsonb_typeof(request_entries) = 'array'),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (source_type, source_id)
);

CREATE TABLE private.ledger_entries (
    entry_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    journal_id uuid NOT NULL REFERENCES private.ledger_journals (journal_id),
    account_id uuid NOT NULL REFERENCES private.ledger_accounts (account_id),
    side text NOT NULL CHECK (side IN ('DEBIT', 'CREDIT')),
    amount_minor bigint NOT NULL CHECK (amount_minor > 0),
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ledger_entries_journal_id_idx
    ON private.ledger_entries (journal_id);

CREATE TABLE private.inventory_balances (
    variant_id uuid PRIMARY KEY,
    physical_quantity bigint NOT NULL DEFAULT 0 CHECK (physical_quantity >= 0),
    reserved_quantity bigint NOT NULL DEFAULT 0 CHECK (
        reserved_quantity >= 0 AND reserved_quantity <= physical_quantity
    ),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE private.inventory_reservations (
    reservation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id uuid NOT NULL,
    variant_id uuid NOT NULL REFERENCES private.inventory_balances (variant_id),
    quantity bigint NOT NULL CHECK (quantity > 0),
    status text NOT NULL CHECK (status IN ('RESERVED', 'RELEASED', 'CONSUMED')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (order_id, variant_id)
);

CREATE TABLE private.inventory_movements (
    movement_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    variant_id uuid NOT NULL REFERENCES private.inventory_balances (variant_id),
    reservation_id uuid REFERENCES private.inventory_reservations (reservation_id),
    operation_id uuid UNIQUE,
    movement_type text NOT NULL CHECK (
        movement_type IN ('RESTOCK', 'RETURN', 'ADJUSTMENT', 'RESERVE', 'RELEASE', 'SALE')
    ),
    physical_delta bigint NOT NULL,
    reserved_delta bigint NOT NULL,
    reason text NOT NULL CHECK (length(reason) BETWEEN 1 AND 500),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (physical_delta <> 0 OR reserved_delta <> 0),
    CHECK (
        (
            movement_type IN ('RESTOCK', 'RETURN', 'ADJUSTMENT')
            AND reservation_id IS NULL
            AND operation_id IS NOT NULL
            AND reserved_delta = 0
            AND (movement_type = 'ADJUSTMENT' OR physical_delta > 0)
        )
        OR (
            movement_type = 'RESERVE'
            AND reservation_id IS NOT NULL
            AND operation_id IS NULL
            AND physical_delta = 0
            AND reserved_delta > 0
        )
        OR (
            movement_type = 'RELEASE'
            AND reservation_id IS NOT NULL
            AND operation_id IS NULL
            AND physical_delta = 0
            AND reserved_delta < 0
        )
        OR (
            movement_type = 'SALE'
            AND reservation_id IS NOT NULL
            AND operation_id IS NULL
            AND physical_delta < 0
            AND reserved_delta = physical_delta
        )
    ),
    UNIQUE (reservation_id, movement_type)
);

CREATE FUNCTION private.prevent_ledger_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, private
AS $$
BEGIN
    RAISE EXCEPTION 'ledger records are append-only'
        USING ERRCODE = '55000';
END;
$$;

CREATE TRIGGER ledger_accounts_append_only
    BEFORE UPDATE OR DELETE ON private.ledger_accounts
    FOR EACH ROW EXECUTE FUNCTION private.prevent_ledger_mutation();

CREATE TRIGGER ledger_journals_append_only
    BEFORE UPDATE OR DELETE ON private.ledger_journals
    FOR EACH ROW EXECUTE FUNCTION private.prevent_ledger_mutation();

CREATE TRIGGER ledger_entries_append_only
    BEFORE UPDATE OR DELETE ON private.ledger_entries
    FOR EACH ROW EXECUTE FUNCTION private.prevent_ledger_mutation();

CREATE TRIGGER inventory_movements_append_only
    BEFORE UPDATE OR DELETE ON private.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION private.prevent_ledger_mutation();

CREATE FUNCTION private.assert_ledger_journal_balanced()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, private
AS $$
DECLARE
    v_journal_id uuid;
    v_entry_count bigint;
    v_debits numeric;
    v_credits numeric;
BEGIN
    v_journal_id := COALESCE(
        (to_jsonb(NEW) ->> 'journal_id')::uuid,
        (to_jsonb(NEW) ->> 'id')::uuid
    );

    SELECT
        count(*),
        COALESCE(sum(amount_minor) FILTER (WHERE side = 'DEBIT'), 0),
        COALESCE(sum(amount_minor) FILTER (WHERE side = 'CREDIT'), 0)
    INTO v_entry_count, v_debits, v_credits
    FROM private.ledger_entries
    WHERE journal_id = v_journal_id;

    IF v_entry_count < 2 OR v_debits <= 0 OR v_debits <> v_credits THEN
        RAISE EXCEPTION 'journal % must contain at least two balanced entries', v_journal_id
            USING ERRCODE = '23514';
    END IF;

    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER ledger_journal_must_balance
    AFTER INSERT ON private.ledger_journals
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION private.assert_ledger_journal_balanced();

CREATE CONSTRAINT TRIGGER ledger_entries_must_balance
    AFTER INSERT ON private.ledger_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION private.assert_ledger_journal_balanced();

CREATE FUNCTION private.create_ledger_account(
    p_account_code text,
    p_account_type text,
    p_currency_code text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, private
AS $$
DECLARE
    v_account_id uuid;
    v_existing_type text;
BEGIN
    IF p_account_code IS NULL
        OR p_account_code !~ '^[A-Z][A-Z0-9_]{0,63}$'
        OR p_account_type NOT IN ('ASSET', 'LIABILITY', 'EQUITY', 'REVENUE', 'EXPENSE')
        OR p_currency_code !~ '^[A-Z]{3}$'
    THEN
        RAISE EXCEPTION 'invalid ledger account attributes'
            USING ERRCODE = '22023';
    END IF;

    INSERT INTO private.ledger_accounts (account_code, account_type, currency_code)
    VALUES (p_account_code, p_account_type, p_currency_code)
    ON CONFLICT (account_code, currency_code) DO NOTHING
    RETURNING account_id INTO v_account_id;

    IF v_account_id IS NOT NULL THEN
        RETURN v_account_id;
    END IF;

    SELECT account_id, account_type
    INTO v_account_id, v_existing_type
    FROM private.ledger_accounts
    WHERE account_code = p_account_code
      AND currency_code = p_currency_code;

    IF v_existing_type <> p_account_type THEN
        RAISE EXCEPTION 'idempotency conflict for ledger account %', p_account_code
            USING ERRCODE = '23505';
    END IF;

    RETURN v_account_id;
END;
$$;

CREATE FUNCTION private.post_ledger_journal(
    p_source_type text,
    p_source_id text,
    p_currency_code text,
    p_entries jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, private
AS $$
DECLARE
    v_journal_id uuid;
    v_existing_currency text;
    v_existing_entries jsonb;
    v_entry_count bigint;
    v_valid_accounts bigint;
    v_debits numeric;
    v_credits numeric;
BEGIN
    IF p_source_type IS NULL
        OR p_source_type !~ '^[a-z][a-z0-9_]{0,63}$'
        OR p_source_id IS NULL
        OR length(p_source_id) NOT BETWEEN 1 AND 200
        OR p_currency_code IS NULL
        OR p_currency_code !~ '^[A-Z]{3}$'
        OR p_entries IS NULL
        OR jsonb_typeof(p_entries) <> 'array'
    THEN
        RAISE EXCEPTION 'invalid journal request'
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*)
    INTO v_entry_count
    FROM jsonb_array_elements(p_entries);

    IF v_entry_count < 2 OR v_entry_count > 1000 THEN
        RAISE EXCEPTION 'journal must contain between 2 and 1000 entries'
            USING ERRCODE = '22023';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(p_entries) AS item(value)
        WHERE jsonb_typeof(item.value) <> 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(item.value)) <> 3
           OR NOT (item.value ?& ARRAY['account_id', 'side', 'amount_minor'])
           OR jsonb_typeof(item.value -> 'account_id') <> 'string'
           OR (item.value ->> 'account_id') !~
                '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
           OR jsonb_typeof(item.value -> 'side') <> 'string'
           OR item.value ->> 'side' NOT IN ('DEBIT', 'CREDIT')
           OR jsonb_typeof(item.value -> 'amount_minor') <> 'string'
           OR (item.value ->> 'amount_minor') !~ '^[1-9][0-9]{0,18}$'
    ) THEN
        RAISE EXCEPTION 'journal entries have invalid shape or values'
            USING ERRCODE = '22023';
    END IF;

    SELECT
        count(account.account_id),
        COALESCE(sum(entry.amount_minor::numeric)
            FILTER (WHERE entry.side = 'DEBIT'), 0),
        COALESCE(sum(entry.amount_minor::numeric)
            FILTER (WHERE entry.side = 'CREDIT'), 0)
    INTO v_valid_accounts, v_debits, v_credits
    FROM jsonb_to_recordset(p_entries) AS entry(
        account_id uuid,
        side text,
        amount_minor text
    )
    LEFT JOIN private.ledger_accounts AS account
        ON account.account_id = entry.account_id
       AND account.currency_code = p_currency_code;

    IF v_valid_accounts <> v_entry_count THEN
        RAISE EXCEPTION 'journal references an unknown account or currency'
            USING ERRCODE = '23503';
    END IF;

    IF v_debits <= 0 OR v_debits <> v_credits THEN
        RAISE EXCEPTION 'journal debits and credits must balance'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO private.ledger_journals (
        source_type,
        source_id,
        currency_code,
        request_entries
    )
    VALUES (p_source_type, p_source_id, p_currency_code, p_entries)
    ON CONFLICT (source_type, source_id) DO NOTHING
    RETURNING journal_id INTO v_journal_id;

    IF v_journal_id IS NULL THEN
        SELECT journal_id, currency_code, request_entries
        INTO v_journal_id, v_existing_currency, v_existing_entries
        FROM private.ledger_journals
        WHERE source_type = p_source_type
          AND source_id = p_source_id
        FOR UPDATE;

        IF v_existing_currency <> p_currency_code OR v_existing_entries <> p_entries THEN
            RAISE EXCEPTION 'idempotency conflict for source %.%', p_source_type, p_source_id
                USING ERRCODE = '23505';
        END IF;

        RETURN v_journal_id;
    END IF;

    INSERT INTO private.ledger_entries (journal_id, account_id, side, amount_minor)
    SELECT
        v_journal_id,
        entry.account_id,
        entry.side,
        entry.amount_minor::bigint
    FROM jsonb_to_recordset(p_entries) AS entry(
        account_id uuid,
        side text,
        amount_minor text
    );

    RETURN v_journal_id;
END;
$$;

CREATE FUNCTION private.record_inventory_adjustment(
    p_variant_id uuid,
    p_operation_id uuid,
    p_movement_type text,
    p_quantity_delta bigint,
    p_reason text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, private
AS $$
DECLARE
    v_movement_id uuid;
    v_existing private.inventory_movements%ROWTYPE;
    v_physical bigint;
    v_reserved bigint;
    v_new_physical numeric;
BEGIN
    IF p_variant_id IS NULL
        OR p_operation_id IS NULL
        OR p_movement_type NOT IN ('RESTOCK', 'RETURN', 'ADJUSTMENT')
        OR p_quantity_delta = 0
        OR p_reason IS NULL
        OR length(p_reason) NOT BETWEEN 1 AND 500
        OR (p_movement_type IN ('RESTOCK', 'RETURN') AND p_quantity_delta < 0)
    THEN
        RAISE EXCEPTION 'invalid inventory adjustment'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended('inventory-operation:' || p_operation_id::text, 0)
    );

    SELECT *
    INTO v_existing
    FROM private.inventory_movements
    WHERE operation_id = p_operation_id;

    IF FOUND THEN
        IF v_existing.variant_id <> p_variant_id
            OR v_existing.movement_type <> p_movement_type
            OR v_existing.physical_delta <> p_quantity_delta
            OR v_existing.reason <> p_reason
        THEN
            RAISE EXCEPTION 'idempotency conflict for inventory operation %', p_operation_id
                USING ERRCODE = '23505';
        END IF;
        RETURN v_existing.movement_id;
    END IF;

    INSERT INTO private.inventory_balances (variant_id)
    VALUES (p_variant_id)
    ON CONFLICT (variant_id) DO NOTHING;

    SELECT physical_quantity, reserved_quantity
    INTO v_physical, v_reserved
    FROM private.inventory_balances
    WHERE variant_id = p_variant_id
    FOR UPDATE;

    v_new_physical := v_physical::numeric + p_quantity_delta::numeric;
    IF v_new_physical < v_reserved OR v_new_physical < 0
        OR v_new_physical > 9223372036854775807::numeric
    THEN
        RAISE EXCEPTION 'inventory adjustment would violate stock invariants'
            USING ERRCODE = '23514';
    END IF;

    UPDATE private.inventory_balances
    SET physical_quantity = v_new_physical::bigint,
        updated_at = now()
    WHERE variant_id = p_variant_id;

    INSERT INTO private.inventory_movements (
        variant_id,
        operation_id,
        movement_type,
        physical_delta,
        reserved_delta,
        reason
    )
    VALUES (
        p_variant_id,
        p_operation_id,
        p_movement_type,
        p_quantity_delta,
        0,
        p_reason
    )
    RETURNING movement_id INTO v_movement_id;

    RETURN v_movement_id;
END;
$$;

CREATE FUNCTION private.reserve_inventory(
    p_order_id uuid,
    p_variant_id uuid,
    p_quantity bigint
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, private
AS $$
DECLARE
    v_reservation private.inventory_reservations%ROWTYPE;
    v_physical bigint;
    v_reserved bigint;
BEGIN
    IF p_order_id IS NULL OR p_variant_id IS NULL OR p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'invalid inventory reservation'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(p_order_id::text || ':' || p_variant_id::text, 0)
    );

    SELECT *
    INTO v_reservation
    FROM private.inventory_reservations
    WHERE order_id = p_order_id
      AND variant_id = p_variant_id
    FOR UPDATE;

    IF FOUND THEN
        IF v_reservation.quantity <> p_quantity
            OR v_reservation.status <> 'RESERVED'
        THEN
            RAISE EXCEPTION 'idempotency conflict for order inventory reservation'
                USING ERRCODE = '23505';
        END IF;
        RETURN v_reservation.reservation_id;
    END IF;

    SELECT physical_quantity, reserved_quantity
    INTO v_physical, v_reserved
    FROM private.inventory_balances
    WHERE variant_id = p_variant_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'inventory item does not exist'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_physical - v_reserved < p_quantity THEN
        RAISE EXCEPTION 'insufficient available inventory'
            USING ERRCODE = '23514';
    END IF;

    INSERT INTO private.inventory_reservations (
        order_id, variant_id, quantity, status
    )
    VALUES (p_order_id, p_variant_id, p_quantity, 'RESERVED')
    RETURNING * INTO v_reservation;

    UPDATE private.inventory_balances
    SET reserved_quantity = reserved_quantity + p_quantity,
        updated_at = now()
    WHERE variant_id = p_variant_id;

    INSERT INTO private.inventory_movements (
        variant_id,
        reservation_id,
        movement_type,
        physical_delta,
        reserved_delta,
        reason
    )
    VALUES (
        p_variant_id,
        v_reservation.reservation_id,
        'RESERVE',
        0,
        p_quantity,
        'Order inventory reservation'
    );

    RETURN v_reservation.reservation_id;
END;
$$;

CREATE FUNCTION private.release_inventory_reservation(p_reservation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, private
AS $$
DECLARE
    v_reservation private.inventory_reservations%ROWTYPE;
BEGIN
    IF p_reservation_id IS NULL THEN
        RAISE EXCEPTION 'reservation id is required'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_reservation
    FROM private.inventory_reservations
    WHERE reservation_id = p_reservation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'inventory reservation does not exist'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_reservation.status = 'RELEASED' THEN
        RETURN true;
    ELSIF v_reservation.status = 'CONSUMED' THEN
        RAISE EXCEPTION 'consumed inventory cannot be released'
            USING ERRCODE = '23514';
    END IF;

    PERFORM 1
    FROM private.inventory_balances
    WHERE variant_id = v_reservation.variant_id
    FOR UPDATE;

    UPDATE private.inventory_balances
    SET reserved_quantity = reserved_quantity - v_reservation.quantity,
        updated_at = now()
    WHERE variant_id = v_reservation.variant_id
      AND reserved_quantity >= v_reservation.quantity;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'inventory reservation balance is inconsistent'
            USING ERRCODE = '23514';
    END IF;

    UPDATE private.inventory_reservations
    SET status = 'RELEASED', updated_at = now()
    WHERE reservation_id = p_reservation_id;

    INSERT INTO private.inventory_movements (
        variant_id,
        reservation_id,
        movement_type,
        physical_delta,
        reserved_delta,
        reason
    )
    VALUES (
        v_reservation.variant_id,
        p_reservation_id,
        'RELEASE',
        0,
        -v_reservation.quantity,
        'Order inventory reservation released'
    );

    RETURN true;
END;
$$;

CREATE FUNCTION private.consume_inventory_reservation(p_reservation_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, private
AS $$
DECLARE
    v_reservation private.inventory_reservations%ROWTYPE;
BEGIN
    IF p_reservation_id IS NULL THEN
        RAISE EXCEPTION 'reservation id is required'
            USING ERRCODE = '22023';
    END IF;

    SELECT *
    INTO v_reservation
    FROM private.inventory_reservations
    WHERE reservation_id = p_reservation_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'inventory reservation does not exist'
            USING ERRCODE = 'P0002';
    END IF;

    IF v_reservation.status = 'CONSUMED' THEN
        RETURN true;
    ELSIF v_reservation.status = 'RELEASED' THEN
        RAISE EXCEPTION 'released inventory cannot be consumed'
            USING ERRCODE = '23514';
    END IF;

    UPDATE private.inventory_balances
    SET physical_quantity = physical_quantity - v_reservation.quantity,
        reserved_quantity = reserved_quantity - v_reservation.quantity,
        updated_at = now()
    WHERE variant_id = v_reservation.variant_id
      AND physical_quantity >= v_reservation.quantity
      AND reserved_quantity >= v_reservation.quantity;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'inventory reservation balance is inconsistent'
            USING ERRCODE = '23514';
    END IF;

    UPDATE private.inventory_reservations
    SET status = 'CONSUMED', updated_at = now()
    WHERE reservation_id = p_reservation_id;

    INSERT INTO private.inventory_movements (
        variant_id,
        reservation_id,
        movement_type,
        physical_delta,
        reserved_delta,
        reason
    )
    VALUES (
        v_reservation.variant_id,
        p_reservation_id,
        'SALE',
        -v_reservation.quantity,
        -v_reservation.quantity,
        'Reserved inventory consumed by order'
    );

    RETURN true;
END;
$$;

ALTER TABLE private.ledger_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.ledger_accounts FORCE ROW LEVEL SECURITY;
ALTER TABLE private.ledger_journals ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.ledger_journals FORCE ROW LEVEL SECURITY;
ALTER TABLE private.ledger_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.ledger_entries FORCE ROW LEVEL SECURITY;
ALTER TABLE private.inventory_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.inventory_balances FORCE ROW LEVEL SECURITY;
ALTER TABLE private.inventory_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.inventory_reservations FORCE ROW LEVEL SECURITY;
ALTER TABLE private.inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.inventory_movements FORCE ROW LEVEL SECURITY;

REVOKE ALL ON ALL TABLES IN SCHEMA private
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA private
    FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private
    FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION private.create_ledger_account(text, text, text)
    TO service_role;
GRANT EXECUTE ON FUNCTION private.post_ledger_journal(text, text, text, jsonb)
    TO service_role;
GRANT EXECUTE ON FUNCTION private.record_inventory_adjustment(uuid, uuid, text, bigint, text)
    TO service_role;
GRANT EXECUTE ON FUNCTION private.reserve_inventory(uuid, uuid, bigint)
    TO service_role;
GRANT EXECUTE ON FUNCTION private.release_inventory_reservation(uuid)
    TO service_role;
GRANT EXECUTE ON FUNCTION private.consume_inventory_reservation(uuid)
    TO service_role;
