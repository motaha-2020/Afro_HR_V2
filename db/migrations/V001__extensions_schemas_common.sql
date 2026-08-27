-- =============================================================================
-- Afro_HR_V2 — V001 : Extensions, Schemas, Common Functions & Domains
-- Source: "Logical Database Schema + Core ERD v1.0" §2, §43, §46, §47
--         "Enterprise Data Model & Database Domain Map" §2
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS btree_gist; -- EXCLUDE (uuid WITH =, daterange WITH &&)
CREATE EXTENSION IF NOT EXISTS citext;     -- case-insensitive email

-- ---------------------------------------------------------------------------
-- Schemas (one schema per data domain — ERD §2, Domain Map §2)
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS platform;     -- Domain 01 Tenant & Platform
CREATE SCHEMA IF NOT EXISTS identity;     -- Domain 02 Identity & Access
CREATE SCHEMA IF NOT EXISTS org;          -- Domain 03 Organization & Job Architecture
CREATE SCHEMA IF NOT EXISTS core_hr;      -- Domain 04 Core Employee
CREATE SCHEMA IF NOT EXISTS workforce;    -- Domain 05 Workforce Assignment
CREATE SCHEMA IF NOT EXISTS personnel;    -- Domain 08 Personnel & Compliance
CREATE SCHEMA IF NOT EXISTS compensation; -- Domain 11 Compensation & Payroll
CREATE SCHEMA IF NOT EXISTS config;       -- Shared Configuration
CREATE SCHEMA IF NOT EXISTS integration;  -- Integration Data
CREATE SCHEMA IF NOT EXISTS audit;        -- Audit & Event Store

COMMENT ON SCHEMA platform     IS 'Domain 01 — Tenant, Company, number sequences. Owner: Platform.';
COMMENT ON SCHEMA identity     IS 'Domain 02 — Users, roles, permissions. Does NOT own Employee.';
COMMENT ON SCHEMA org          IS 'Domain 03 — Org units, jobs, positions, grades, locations.';
COMMENT ON SCHEMA core_hr      IS 'Domain 04 — Employee (person) + Employment (relationship).';
COMMENT ON SCHEMA workforce    IS 'Domain 05 — Assignments: the link between employment and work.';
COMMENT ON SCHEMA personnel    IS 'Domain 08 — Contracts, documents, employment compliance.';
COMMENT ON SCHEMA compensation IS 'Domain 11 — System of record for pay structure.';
COMMENT ON SCHEMA audit        IS 'Append-only change log + domain event outbox.';

-- ---------------------------------------------------------------------------
-- Reusable domains
-- ---------------------------------------------------------------------------
CREATE DOMAIN config.entity_code   AS VARCHAR(50)
    CHECK (VALUE ~ '^[A-Z0-9][A-Z0-9._-]{0,49}$');
CREATE DOMAIN config.country_code  AS CHAR(3)  CHECK (VALUE ~ '^[A-Z]{3}$'); -- ISO 3166-1 alpha-3
CREATE DOMAIN config.currency_code AS CHAR(3)  CHECK (VALUE ~ '^[A-Z]{3}$'); -- ISO 4217
CREATE DOMAIN config.lang_code     AS VARCHAR(10) CHECK (VALUE IN ('ar','en','fr'));
CREATE DOMAIN config.percentage    AS NUMERIC(5,2) CHECK (VALUE >= 0 AND VALUE <= 100);

-- ---------------------------------------------------------------------------
-- Session context (drives RLS + audit "who")
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.current_tenant_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('afro.tenant_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION platform.current_user_id() RETURNS UUID
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('afro.user_id', true), '')::uuid
$$;

-- Platform Super Admin bypasses tenant isolation (03.txt — two admin levels)
CREATE OR REPLACE FUNCTION platform.is_platform_admin() RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(current_setting('afro.platform_admin', true), ''), 'false')::boolean
$$;

CREATE OR REPLACE PROCEDURE platform.set_context(
    p_tenant_id UUID,
    p_user_id   UUID DEFAULT NULL,
    p_platform_admin BOOLEAN DEFAULT false
) LANGUAGE plpgsql AS $$
BEGIN
    PERFORM set_config('afro.tenant_id',      COALESCE(p_tenant_id::text, ''), false);
    PERFORM set_config('afro.user_id',        COALESCE(p_user_id::text, ''),   false);
    PERFORM set_config('afro.platform_admin', p_platform_admin::text,          false);
END $$;

-- ---------------------------------------------------------------------------
-- ERD §46/§47 — audit metadata + optimistic locking, applied by trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION platform.tg_touch_row() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at := now();
        NEW.updated_at := now();
        NEW.created_by := COALESCE(NEW.created_by, platform.current_user_id());
        NEW.updated_by := NEW.created_by;
        NEW.version    := 1;
    ELSE
        -- Optimistic locking: caller must echo back the version it read (ERD §47)
        IF NEW.version IS DISTINCT FROM OLD.version THEN
            RAISE EXCEPTION
                'OPTIMISTIC_LOCK_CONFLICT on %.%: row version is %, caller sent %',
                TG_TABLE_SCHEMA, TG_TABLE_NAME, OLD.version, NEW.version
                USING ERRCODE = '40001';
        END IF;
        NEW.created_at := OLD.created_at;
        NEW.created_by := OLD.created_by;
        NEW.updated_at := now();
        NEW.updated_by := COALESCE(platform.current_user_id(), OLD.updated_by);
        NEW.version    := OLD.version + 1;
    END IF;
    RETURN NEW;
END $$;

-- Attaches the standard audit columns + touch trigger + RLS to a table.
CREATE OR REPLACE PROCEDURE platform.apply_standard_columns(p_table REGCLASS)
LANGUAGE plpgsql AS $$
DECLARE
    v_name TEXT := replace(p_table::text, '.', '_');
BEGIN
    EXECUTE format($f$
        ALTER TABLE %s
            ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            ADD COLUMN IF NOT EXISTS created_by UUID,
            ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
            ADD COLUMN IF NOT EXISTS updated_by UUID,
            ADD COLUMN IF NOT EXISTS version    INT NOT NULL DEFAULT 1
    $f$, p_table);

    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', 'tg_touch_' || v_name, p_table);
    EXECUTE format(
        'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON %s
             FOR EACH ROW EXECUTE FUNCTION platform.tg_touch_row()',
        'tg_touch_' || v_name, p_table);
END $$;

-- Enables tenant-scoped RLS on any table carrying tenant_id (02.txt — PG RLS as
-- a second line of defence behind application permissions).
CREATE OR REPLACE PROCEDURE platform.apply_tenant_rls(p_table REGCLASS)
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', p_table);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY', p_table);
    EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %s', p_table);
    EXECUTE format($f$
        CREATE POLICY tenant_isolation ON %s
            USING      (platform.is_platform_admin() OR tenant_id = platform.current_tenant_id())
            WITH CHECK (platform.is_platform_admin() OR tenant_id = platform.current_tenant_id())
    $f$, p_table);
END $$;
