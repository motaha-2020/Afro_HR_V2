-- =============================================================================
-- Afro_HR_V2 — V012 : Audit trail + domain event outbox
-- Source: ERD v1.0 §46 ; Master Blueprint (Shared Engines: Audit, Events)
-- The System Master Map defines each module by the events it produces and
-- consumes; this outbox is where those events are actually emitted from.
-- =============================================================================

CREATE TABLE audit.change_log (
    change_id    BIGSERIAL,
    tenant_id    UUID,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_user_id UUID,
    schema_name  TEXT NOT NULL,
    table_name   TEXT NOT NULL,
    record_id    TEXT NOT NULL,
    operation    CHAR(1) NOT NULL CHECK (operation IN ('I','U','D')),
    changed_fields TEXT[],
    old_row      JSONB,
    new_row      JSONB,
    -- A partitioned table's PK must contain the partition key.
    PRIMARY KEY (change_id, occurred_at)
) PARTITION BY RANGE (occurred_at);

-- Start with 2026-2027; a scheduled job rolls partitions forward.
CREATE TABLE audit.change_log_2026 PARTITION OF audit.change_log
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');
CREATE TABLE audit.change_log_2027 PARTITION OF audit.change_log
    FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');
CREATE TABLE audit.change_log_default PARTITION OF audit.change_log DEFAULT;

CREATE INDEX ix_change_log_record ON audit.change_log(schema_name, table_name, record_id);
CREATE INDEX ix_change_log_tenant ON audit.change_log(tenant_id, occurred_at DESC);

REVOKE UPDATE, DELETE ON audit.change_log FROM PUBLIC;

CREATE OR REPLACE FUNCTION audit.tg_capture_change() RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_old JSONB; v_new JSONB; v_changed TEXT[]; v_pk TEXT; v_tenant UUID;
BEGIN
    IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW); END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(key) INTO v_changed
          FROM jsonb_each(v_new)
         WHERE v_old -> key IS DISTINCT FROM value
           AND key NOT IN ('updated_at','updated_by','version');
        IF v_changed IS NULL THEN RETURN NULL; END IF;   -- nothing meaningful changed
    END IF;

    v_pk     := COALESCE(v_new, v_old) ->> TG_ARGV[0];
    v_tenant := NULLIF(COALESCE(v_new, v_old) ->> 'tenant_id', '')::uuid;

    INSERT INTO audit.change_log (tenant_id, actor_user_id, schema_name, table_name,
                                  record_id, operation, changed_fields, old_row, new_row)
    VALUES (v_tenant, platform.current_user_id(), TG_TABLE_SCHEMA, TG_TABLE_NAME,
            v_pk, left(TG_OP, 1), v_changed, v_old, v_new);
    RETURN NULL;
END $fn$;

CREATE OR REPLACE PROCEDURE audit.enable_audit(p_table REGCLASS, p_pk_column TEXT)
LANGUAGE plpgsql AS $p$
DECLARE v_name TEXT := replace(p_table::text, '.', '_');
BEGIN
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', 'tg_audit_' || v_name, p_table);
    EXECUTE format(
        'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %s
             FOR EACH ROW EXECUTE FUNCTION audit.tg_capture_change(%L)',
        'tg_audit_' || v_name, p_table, p_pk_column);
END $p$;

-- Attach the audit trail to every table the Master Map treats as governed data.
CALL audit.enable_audit('platform.companies',                          'company_id');
CALL audit.enable_audit('org.organization_units',                      'org_unit_id');
CALL audit.enable_audit('org.jobs',                                    'job_id');
CALL audit.enable_audit('org.positions',                               'position_id');
CALL audit.enable_audit('org.grades',                                  'grade_id');
CALL audit.enable_audit('org.reporting_relationships',                 'reporting_id');
CALL audit.enable_audit('core_hr.employees',                           'employee_id');
CALL audit.enable_audit('core_hr.employments',                         'employment_id');
CALL audit.enable_audit('core_hr.employee_identifiers',                'identifier_id');
CALL audit.enable_audit('core_hr.employee_bank_accounts',              'bank_account_id');
CALL audit.enable_audit('workforce.employee_assignments',              'assignment_id');
CALL audit.enable_audit('personnel.employment_contracts',              'contract_id');
CALL audit.enable_audit('compensation.employee_compensations',         'employee_compensation_id');
CALL audit.enable_audit('compensation.employee_compensation_components','component_record_id');
CALL audit.enable_audit('identity.users',                              'user_id');
CALL audit.enable_audit('identity.user_roles',                         'user_role_id');

-- ---------------------------------------------------------------------------
-- Domain event outbox — the "Events Produced / Events Consumed" columns of the
-- System Master Map. Written in the same transaction as the business change,
-- then relayed to the message bus by a background worker (Hangfire).
-- ---------------------------------------------------------------------------
CREATE TABLE audit.event_outbox (
    event_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      UUID NOT NULL,
    company_id     UUID,
    event_type     VARCHAR(100) NOT NULL,   -- EmployeeActivated, AssignmentEnded, ...
    source_module  VARCHAR(10)  NOT NULL,   -- M01..M20
    aggregate_type VARCHAR(50)  NOT NULL,
    aggregate_id   UUID         NOT NULL,
    payload        JSONB        NOT NULL,
    occurred_at    TIMESTAMPTZ  NOT NULL DEFAULT now(),
    published_at   TIMESTAMPTZ,
    attempt_count  INT NOT NULL DEFAULT 0,
    last_error     TEXT
);
CREATE INDEX ix_outbox_unpublished ON audit.event_outbox(occurred_at)
    WHERE published_at IS NULL;
CREATE INDEX ix_outbox_aggregate ON audit.event_outbox(aggregate_type, aggregate_id);

CREATE OR REPLACE FUNCTION audit.emit_event(
    p_tenant_id      UUID,
    p_event_type     TEXT,
    p_source_module  TEXT,
    p_aggregate_type TEXT,
    p_aggregate_id   UUID,
    p_payload        JSONB DEFAULT '{}'::jsonb,
    p_company_id     UUID  DEFAULT NULL
) RETURNS UUID
LANGUAGE sql AS $fn$
    INSERT INTO audit.event_outbox
        (tenant_id, company_id, event_type, source_module, aggregate_type, aggregate_id, payload)
    VALUES (p_tenant_id, p_company_id, p_event_type, p_source_module,
            p_aggregate_type, p_aggregate_id, p_payload)
    RETURNING event_id;
$fn$;

-- Employment lifecycle emits the events the Master Map says downstream modules
-- (Payroll, Onboarding, Offboarding, Analytics) consume.
CREATE OR REPLACE FUNCTION core_hr.tg_emit_employment_events() RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
DECLARE v_type TEXT;
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.employment_status IS NOT DISTINCT FROM NEW.employment_status THEN
        RETURN NULL;
    END IF;

    v_type := CASE NEW.employment_status
                  WHEN 'ACTIVE'        THEN 'EmployeeActivated'
                  WHEN 'ON_LEAVE'      THEN 'EmploymentOnLeave'
                  WHEN 'SUSPENDED'     THEN 'EmploymentSuspended'
                  WHEN 'NOTICE_PERIOD' THEN 'EmploymentNoticeStarted'
                  WHEN 'TERMINATED'    THEN 'EmploymentTerminated'
                  WHEN 'CLOSED'        THEN 'EmploymentClosed'
                  ELSE NULL
              END;
    IF v_type IS NULL THEN RETURN NULL; END IF;

    PERFORM audit.emit_event(
        NEW.tenant_id, v_type, 'M04', 'Employment', NEW.employment_id,
        jsonb_build_object(
            'employee_id',   NEW.employee_id,
            'company_id',    NEW.company_id,
            'status',        NEW.employment_status,
            'hire_date',     NEW.hire_date,
            'termination_date', NEW.termination_date),
        NEW.company_id);
    RETURN NULL;
END $fn$;

CREATE TRIGGER tg_employment_events
    AFTER INSERT OR UPDATE OF employment_status ON core_hr.employments
    FOR EACH ROW EXECUTE FUNCTION core_hr.tg_emit_employment_events();
