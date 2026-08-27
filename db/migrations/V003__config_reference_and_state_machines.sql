-- =============================================================================
-- Afro_HR_V2 — V003 : Shared Configuration
--   (a) Reference data  — ERD §8, §20, §24: types are configurable per tenant,
--       so they live in data, not in PostgreSQL ENUMs.
--   (b) State machines  — ERD §50-§53: "no arbitrary transition is allowed".
-- Note: lifecycle STATUS values stay as CHECK constraints (they are contracts
--       the code depends on); TYPE values are tenant-configurable rows.
-- =============================================================================

CREATE TABLE config.reference_types (
    reference_type_code config.entity_code PRIMARY KEY,
    description         TEXT NOT NULL,
    is_tenant_extensible BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE config.reference_values (
    reference_value_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    reference_type_code config.entity_code NOT NULL
        REFERENCES config.reference_types(reference_type_code) ON DELETE RESTRICT,
    value_code          config.entity_code NOT NULL,
    name_en             VARCHAR(150) NOT NULL,
    name_ar             VARCHAR(150),
    name_fr             VARCHAR(150),
    sort_order          INT NOT NULL DEFAULT 100,
    is_system           BOOLEAN NOT NULL DEFAULT false,  -- shipped default, cannot be deleted
    status              VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','INACTIVE')),
    attributes          JSONB NOT NULL DEFAULT '{}'::jsonb,
    CONSTRAINT uq_reference_value UNIQUE (tenant_id, reference_type_code, value_code),
    -- Composite target: referencing tables FK on (id, tenant_id, type) so a
    -- column typed "employment type" can never hold a "leave reason" row.
    CONSTRAINT uq_reference_value_typed UNIQUE (reference_value_id, tenant_id, reference_type_code)
);
CALL platform.apply_standard_columns('config.reference_values');
CALL platform.apply_tenant_rls('config.reference_values');
CREATE INDEX ix_reference_values_lookup
    ON config.reference_values(tenant_id, reference_type_code, status);

INSERT INTO config.reference_types (reference_type_code, description) VALUES
    ('ORG_UNIT_TYPE',    'Sector / Directorate / Department / Section / Unit / Team — ERD §8'),
    ('EMPLOYMENT_TYPE',  'Permanent, Fixed Term, Project Based, Daily Worker... — ERD §20'),
    ('WORKER_CATEGORY',  'White Collar / Blue Collar — kept separate from type, ERD §21'),
    ('ASSIGNMENT_TYPE',  'Primary, Project, Site, Acting, Secondment... — ERD §24'),
    ('IDENTIFIER_TYPE',  'National ID, Passport, Social Insurance, Work Permit — ERD §17'),
    ('CONTRACT_TYPE',    'Original, Renewal, Fixed Term, Amendment — ERD §28'),
    ('TERMINATION_REASON','Resignation, Dismissal, End of Contract, Retirement'),
    ('PAY_FREQUENCY',    'Monthly, Bi-Weekly, Weekly, Daily'),
    ('COMPENSATION_REASON','Hiring, Annual Review, Promotion, Market Adjustment'),
    ('POSITION_TYPE',    'Permanent headcount, Project headcount, Temporary'),
    ('CONTACT_TYPE',     'Mobile, Home phone, Personal email, Work email'),
    ('ADDRESS_TYPE',     'Permanent, Current, Mailing'),
    ('RELATIONSHIP_TYPE','Spouse, Son, Daughter, Father, Mother');

-- ---------------------------------------------------------------------------
-- (b) State machines — ERD §50 Employment, §51 Position, §52 Contract, §53 Assignment
-- ---------------------------------------------------------------------------
CREATE TABLE config.state_machines (
    machine_code  config.entity_code PRIMARY KEY,
    entity_label  TEXT NOT NULL,
    initial_state VARCHAR(40) NOT NULL
);

CREATE TABLE config.state_transitions (
    machine_code config.entity_code NOT NULL
        REFERENCES config.state_machines(machine_code) ON DELETE CASCADE,
    from_state   VARCHAR(40) NOT NULL,
    to_state     VARCHAR(40) NOT NULL,
    PRIMARY KEY (machine_code, from_state, to_state)
);

INSERT INTO config.state_machines VALUES
    ('EMPLOYMENT', 'core_hr.employments.employment_status',        'DRAFT'),
    ('POSITION',   'org.positions.status',                          'PLANNED'),
    ('CONTRACT',   'personnel.employment_contracts.status',         'DRAFT'),
    ('ASSIGNMENT', 'workforce.employee_assignments.status',         'PLANNED');

INSERT INTO config.state_transitions (machine_code, from_state, to_state) VALUES
    -- ERD §50
    ('EMPLOYMENT','DRAFT','PRE_EMPLOYMENT'),      ('EMPLOYMENT','DRAFT','CLOSED'),
    ('EMPLOYMENT','PRE_EMPLOYMENT','ACTIVE'),     ('EMPLOYMENT','PRE_EMPLOYMENT','CLOSED'),
    ('EMPLOYMENT','ACTIVE','ON_LEAVE'),           ('EMPLOYMENT','ACTIVE','SUSPENDED'),
    ('EMPLOYMENT','ACTIVE','NOTICE_PERIOD'),      ('EMPLOYMENT','ACTIVE','TERMINATED'),
    ('EMPLOYMENT','ON_LEAVE','ACTIVE'),           ('EMPLOYMENT','ON_LEAVE','NOTICE_PERIOD'),
    ('EMPLOYMENT','ON_LEAVE','TERMINATED'),
    ('EMPLOYMENT','SUSPENDED','ACTIVE'),          ('EMPLOYMENT','SUSPENDED','TERMINATED'),
    ('EMPLOYMENT','NOTICE_PERIOD','TERMINATED'),  ('EMPLOYMENT','NOTICE_PERIOD','ACTIVE'),
    ('EMPLOYMENT','TERMINATED','CLOSED'),
    -- ERD §51
    ('POSITION','PLANNED','APPROVED'),            ('POSITION','PLANNED','CLOSED'),
    ('POSITION','APPROVED','VACANT'),             ('POSITION','APPROVED','FROZEN'),
    ('POSITION','APPROVED','CLOSED'),
    ('POSITION','VACANT','PARTIALLY_FILLED'),     ('POSITION','VACANT','FILLED'),
    ('POSITION','VACANT','FROZEN'),               ('POSITION','VACANT','CLOSED'),
    ('POSITION','PARTIALLY_FILLED','FILLED'),     ('POSITION','PARTIALLY_FILLED','VACANT'),
    ('POSITION','FILLED','PARTIALLY_FILLED'),     ('POSITION','FILLED','VACANT'),
    ('POSITION','FROZEN','APPROVED'),             ('POSITION','FROZEN','CLOSED'),
    -- ERD §52
    ('CONTRACT','DRAFT','PENDING_SIGNATURE'),     ('CONTRACT','DRAFT','TERMINATED'),
    ('CONTRACT','PENDING_SIGNATURE','ACTIVE'),    ('CONTRACT','PENDING_SIGNATURE','TERMINATED'),
    ('CONTRACT','ACTIVE','EXPIRING'),             ('CONTRACT','ACTIVE','TERMINATED'),
    ('CONTRACT','ACTIVE','SUPERSEDED'),
    ('CONTRACT','EXPIRING','EXPIRED'),            ('CONTRACT','EXPIRING','SUPERSEDED'),
    ('CONTRACT','EXPIRING','TERMINATED'),
    ('CONTRACT','EXPIRED','SUPERSEDED'),
    -- ERD §53
    ('ASSIGNMENT','PLANNED','APPROVED'),          ('ASSIGNMENT','PLANNED','ENDED'),
    ('ASSIGNMENT','APPROVED','ACTIVE'),           ('ASSIGNMENT','APPROVED','ENDED'),
    ('ASSIGNMENT','ACTIVE','SUSPENDED'),          ('ASSIGNMENT','ACTIVE','ENDED'),
    ('ASSIGNMENT','SUSPENDED','ACTIVE'),          ('ASSIGNMENT','SUSPENDED','ENDED');

-- Generic guard. Attach per table with:
--   CREATE TRIGGER tg_state BEFORE INSERT OR UPDATE ON <table>
--     FOR EACH ROW EXECUTE FUNCTION config.tg_enforce_state_machine('MACHINE','status_col');
CREATE OR REPLACE FUNCTION config.tg_enforce_state_machine() RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
DECLARE
    v_machine TEXT := TG_ARGV[0];
    v_column  TEXT := TG_ARGV[1];
    v_old     TEXT;
    v_new     TEXT;
BEGIN
    EXECUTE format('SELECT ($1).%I::text', v_column) INTO v_new USING NEW;

    IF TG_OP = 'INSERT' THEN
        IF NOT EXISTS (SELECT 1 FROM config.state_machines
                        WHERE machine_code = v_machine AND initial_state = v_new)
           AND NOT EXISTS (SELECT 1 FROM config.state_transitions
                        WHERE machine_code = v_machine AND to_state = v_new) THEN
            RAISE EXCEPTION 'INVALID_INITIAL_STATE: % is not reachable in machine %',
                v_new, v_machine USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;

    EXECUTE format('SELECT ($1).%I::text', v_column) INTO v_old USING OLD;
    IF v_old IS NOT DISTINCT FROM v_new THEN
        RETURN NEW;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM config.state_transitions
                    WHERE machine_code = v_machine
                      AND from_state = v_old AND to_state = v_new) THEN
        RAISE EXCEPTION 'ILLEGAL_STATE_TRANSITION: % to % is not allowed for %',
            v_old, v_new, v_machine USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $fn$;
