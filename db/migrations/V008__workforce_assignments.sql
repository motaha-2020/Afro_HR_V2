-- =============================================================================
-- Afro_HR_V2 — V008 : Domain 05 — Workforce Assignment
-- Source: ERD v1.0 §22-§27, §42 Rules 2/3/4, §53
-- This is the table that makes Afro a contracting-workforce platform and not a
-- generic HRIS: one employee, one employment, many concurrent project/site
-- allocations that sum to <= 100%.
-- =============================================================================

-- ERD §27: Project is owned by ERP/PM system, mirrored here as a reference.
CREATE TABLE integration.project_references (
    project_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id       UUID NOT NULL,
    project_code     config.entity_code NOT NULL,
    project_name     VARCHAR(250) NOT NULL,
    customer_name    VARCHAR(200),
    external_project_id VARCHAR(100),
    source_system    VARCHAR(50) NOT NULL DEFAULT 'MANUAL',
    status           VARCHAR(30) NOT NULL DEFAULT 'ACTIVE'
        CHECK (status IN ('PLANNED','ACTIVE','ON_HOLD','CLOSED','CANCELLED')),
    start_date       DATE,
    end_date         DATE,
    last_synced_at   TIMESTAMPTZ,
    CONSTRAINT fk_proj_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_project_code UNIQUE (company_id, project_code),
    CONSTRAINT uq_project_tenant UNIQUE (project_id, tenant_id)
);
CALL platform.apply_standard_columns('integration.project_references');
CALL platform.apply_tenant_rls('integration.project_references');

CREATE TABLE workforce.sites (
    site_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id  UUID NOT NULL,
    project_id  UUID,
    site_code   config.entity_code NOT NULL,
    site_name   VARCHAR(200) NOT NULL,
    location_id UUID,
    geo_lat     NUMERIC(9,6),
    geo_lng     NUMERIC(9,6),
    status      VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    CONSTRAINT fk_site_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_site_project FOREIGN KEY (project_id, tenant_id)
        REFERENCES integration.project_references(project_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_site_location FOREIGN KEY (location_id, tenant_id)
        REFERENCES org.work_locations(location_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_site_code UNIQUE (company_id, site_code),
    CONSTRAINT uq_site_tenant UNIQUE (site_id, tenant_id)
);
CALL platform.apply_standard_columns('workforce.sites');
CALL platform.apply_tenant_rls('workforce.sites');

CREATE TABLE workforce.employee_assignments (
    assignment_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id       UUID NOT NULL,
    employment_id    UUID NOT NULL,
    -- ERD §23: employee_id is denormalised for analytics; the composite FK below
    -- makes it impossible for it to drift away from employment_id.
    employee_id      UUID NOT NULL,
    position_id      UUID NOT NULL,
    org_unit_id      UUID NOT NULL,
    project_id       UUID,
    site_id          UUID,
    location_id      UUID,
    manager_employee_id UUID,
    assignment_type_id  UUID NOT NULL,
    assignment_type_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('ASSIGNMENT_TYPE'::config.entity_code) STORED,
    allocation_percentage config.percentage NOT NULL DEFAULT 100,
    is_primary       BOOLEAN NOT NULL DEFAULT false,
    status           VARCHAR(20) NOT NULL DEFAULT 'PLANNED'
        CHECK (status IN ('PLANNED','APPROVED','ACTIVE','SUSPENDED','ENDED')),
    start_date       DATE NOT NULL,
    end_date         DATE,
    validity         DATERANGE GENERATED ALWAYS AS (daterange(start_date, end_date, '[)')) STORED,
    CONSTRAINT fk_asg_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    -- ERD §42 Rule 2: assignment cannot point at a position in another company
    -- unless it is an authorised secondment (enforced in tg_assignment_rules).
    CONSTRAINT fk_asg_employment FOREIGN KEY (employment_id, tenant_id, company_id)
        REFERENCES core_hr.employments(employment_id, tenant_id, company_id) ON DELETE RESTRICT,
    CONSTRAINT fk_asg_employee FOREIGN KEY (employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_asg_position FOREIGN KEY (position_id, tenant_id)
        REFERENCES org.positions(position_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_asg_org_unit FOREIGN KEY (org_unit_id, tenant_id)
        REFERENCES org.organization_units(org_unit_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_asg_project FOREIGN KEY (project_id, tenant_id)
        REFERENCES integration.project_references(project_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_asg_site FOREIGN KEY (site_id, tenant_id)
        REFERENCES workforce.sites(site_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_asg_location FOREIGN KEY (location_id, tenant_id)
        REFERENCES org.work_locations(location_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_asg_manager FOREIGN KEY (manager_employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_asg_type FOREIGN KEY (assignment_type_id, tenant_id, assignment_type_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT ck_asg_dates CHECK (end_date IS NULL OR end_date > start_date),
    CONSTRAINT ck_asg_not_own_manager CHECK (manager_employee_id IS DISTINCT FROM employee_id),
    -- ERD §42 Rule 4: exactly one PRIMARY assignment live at any moment.
    CONSTRAINT ex_one_primary_assignment EXCLUDE USING gist (
        employment_id WITH =, validity WITH &&
    ) WHERE (is_primary AND status <> 'ENDED')
);
CALL platform.apply_standard_columns('workforce.employee_assignments');
CALL platform.apply_tenant_rls('workforce.employee_assignments');
CREATE INDEX ix_asg_employee ON workforce.employee_assignments(employee_id, status);
CREATE INDEX ix_asg_position ON workforce.employee_assignments(position_id, status);
CREATE INDEX ix_asg_project ON workforce.employee_assignments(project_id, status)
    WHERE project_id IS NOT NULL;
CREATE INDEX ix_asg_validity ON workforce.employee_assignments USING gist (validity);

CREATE TRIGGER tg_assignment_state
    BEFORE INSERT OR UPDATE OF status ON workforce.employee_assignments
    FOR EACH ROW EXECUTE FUNCTION config.tg_enforce_state_machine('ASSIGNMENT', 'status');

-- ---------------------------------------------------------------------------
-- ERD §42 Rule 3: total allocation for an employment must not exceed 100% on
-- any single day, unless tenant configuration allows over-allocation.
-- Cannot be an EXCLUDE constraint (it is a SUM over overlapping ranges), so it
-- is a constraint trigger deferred to end of transaction — that way a
-- "move 20% from Huawei to Nokia" pair of statements is not rejected midway.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION workforce.tg_check_allocation_cap() RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
DECLARE
    v_row RECORD;
    v_cap NUMERIC;
BEGIN
    -- The primary seat is capped at one row by ex_one_primary_assignment; this
    -- check governs the PROJECT/SITE allocations layered on top of it.
    IF NEW.is_primary THEN
        RETURN NULL;
    END IF;

    SELECT COALESCE(MAX((attributes->>'max_allocation_percentage')::numeric), 100)
      INTO v_cap
      FROM config.reference_values
     WHERE tenant_id = NEW.tenant_id
       AND reference_type_code = 'ASSIGNMENT_TYPE'
       AND value_code = 'PROJECT';

    -- Sum what is live on each boundary day this assignment touches.
    FOR v_row IN
        SELECT d.day, SUM(a.allocation_percentage) AS total
          FROM (SELECT DISTINCT lower(validity) AS day
                  FROM workforce.employee_assignments
                 WHERE employment_id = NEW.employment_id
                   AND NOT is_primary
                   AND status <> 'ENDED'
                   AND validity && NEW.validity) d
          JOIN workforce.employee_assignments a
            ON a.employment_id = NEW.employment_id
           AND NOT a.is_primary
           AND a.status <> 'ENDED'
           AND a.validity @> d.day
         GROUP BY d.day
        HAVING SUM(a.allocation_percentage) > v_cap
    LOOP
        RAISE EXCEPTION
            'ALLOCATION_OVER_CAP: employment % is allocated %% on %, cap is %%',
            NEW.employment_id, v_row.total, v_row.day, v_cap
            USING ERRCODE = '23514';
    END LOOP;

    RETURN NULL;
END $fn$;

CREATE CONSTRAINT TRIGGER tg_assignment_allocation_cap
    AFTER INSERT OR UPDATE OF allocation_percentage, start_date, end_date, status
    ON workforce.employee_assignments
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION workforce.tg_check_allocation_cap();

-- ERD §23: keep the denormalised employee_id honest.
CREATE OR REPLACE FUNCTION workforce.tg_assignment_employee_matches() RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
DECLARE v_employee UUID;
BEGIN
    SELECT employee_id INTO v_employee
      FROM core_hr.employments WHERE employment_id = NEW.employment_id;
    IF v_employee IS DISTINCT FROM NEW.employee_id THEN
        RAISE EXCEPTION
            'ASSIGNMENT_EMPLOYEE_MISMATCH: employment % belongs to employee %, not %',
            NEW.employment_id, v_employee, NEW.employee_id USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $fn$;

CREATE TRIGGER tg_assignment_employee_matches
    BEFORE INSERT OR UPDATE OF employee_id, employment_id ON workforce.employee_assignments
    FOR EACH ROW EXECUTE FUNCTION workforce.tg_assignment_employee_matches();

-- ERD §12: current_filled is derived, never stored.
CREATE VIEW org.v_position_headcount AS
SELECT p.position_id,
       p.tenant_id,
       p.company_id,
       p.position_code,
       p.headcount_capacity,
       COUNT(a.assignment_id) FILTER (
           WHERE a.status = 'ACTIVE' AND a.validity @> current_date
       ) AS current_filled,
       p.headcount_capacity - COUNT(a.assignment_id) FILTER (
           WHERE a.status = 'ACTIVE' AND a.validity @> current_date
       ) AS vacancies
  FROM org.positions p
  LEFT JOIN workforce.employee_assignments a
         ON a.position_id = p.position_id AND a.is_primary
 GROUP BY p.position_id, p.tenant_id, p.company_id, p.position_code, p.headcount_capacity;
