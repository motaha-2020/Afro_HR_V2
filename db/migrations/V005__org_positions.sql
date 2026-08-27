-- =============================================================================
-- Afro_HR_V2 — V005 : org.positions + reporting lines
-- Source: ERD v1.0 §11-§14, §51 ; Org-Chart (administrative vs functional lines)
-- =============================================================================

CREATE TABLE org.positions (
    position_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id              UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id             UUID NOT NULL,
    position_code          config.entity_code NOT NULL,
    job_id                 UUID NOT NULL,
    org_unit_id            UUID NOT NULL,
    grade_id               UUID,
    reports_to_position_id UUID,
    default_location_id    UUID,
    cost_center_id         UUID,
    position_type_id       UUID,
    position_type_code     config.entity_code NOT NULL
        GENERATED ALWAYS AS ('POSITION_TYPE'::config.entity_code) STORED,
    headcount_capacity     INT NOT NULL DEFAULT 1 CHECK (headcount_capacity >= 0),
    -- ERD §12: PLANNED→APPROVED→VACANT→FILLED... current_filled is NOT stored;
    -- it is derived from active assignments (see org.v_position_headcount).
    status                 VARCHAR(30) NOT NULL DEFAULT 'PLANNED'
                           CHECK (status IN ('PLANNED','APPROVED','VACANT',
                                             'PARTIALLY_FILLED','FILLED','FROZEN','CLOSED')),
    effective_from         DATE NOT NULL,
    effective_to           DATE,
    CONSTRAINT fk_pos_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_job FOREIGN KEY (job_id, tenant_id)
        REFERENCES org.jobs(job_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_org_unit FOREIGN KEY (org_unit_id, tenant_id)
        REFERENCES org.organization_units(org_unit_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_grade FOREIGN KEY (grade_id, tenant_id)
        REFERENCES org.grades(grade_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_reports_to FOREIGN KEY (reports_to_position_id, tenant_id)
        REFERENCES org.positions(position_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_location FOREIGN KEY (default_location_id, tenant_id)
        REFERENCES org.work_locations(location_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_cost_center FOREIGN KEY (cost_center_id, tenant_id)
        REFERENCES org.cost_centers(cost_center_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_pos_type FOREIGN KEY (position_type_id, tenant_id, position_type_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT uq_position UNIQUE (company_id, position_code),     -- ERD §41
    CONSTRAINT uq_position_tenant UNIQUE (position_id, tenant_id),
    CONSTRAINT ck_pos_not_self_report CHECK (reports_to_position_id IS DISTINCT FROM position_id),
    CONSTRAINT ck_pos_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
CALL platform.apply_standard_columns('org.positions');
CALL platform.apply_tenant_rls('org.positions');
CREATE INDEX ix_positions_org_unit ON org.positions(org_unit_id, status);
CREATE INDEX ix_positions_reports_to ON org.positions(reports_to_position_id);
CREATE INDEX ix_positions_job ON org.positions(job_id);

CREATE TRIGGER tg_position_state
    BEFORE INSERT OR UPDATE OF status ON org.positions
    FOR EACH ROW EXECUTE FUNCTION config.tg_enforce_state_machine('POSITION', 'status');

COMMENT ON COLUMN org.positions.reports_to_position_id IS
    'ERD §13: the org chart is position-to-position. The person occupying the '
    'parent position becomes the manager — not employee.manager_id.';

-- Deferred FK from V004 (organization_units.manager_position_id) — circular.
ALTER TABLE org.organization_units
    ADD CONSTRAINT fk_ou_manager_position FOREIGN KEY (manager_position_id, tenant_id)
        REFERENCES org.positions(position_id, tenant_id) ON DELETE RESTRICT;

-- Position reporting cycle guard.
CREATE OR REPLACE FUNCTION org.tg_position_no_cycle() RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
DECLARE v_cursor UUID := NEW.reports_to_position_id; v_hops INT := 0;
BEGIN
    WHILE v_cursor IS NOT NULL LOOP
        IF v_cursor = NEW.position_id THEN
            RAISE EXCEPTION 'POSITION_REPORTING_CYCLE: position % reports to itself',
                NEW.position_id USING ERRCODE = '23514';
        END IF;
        v_hops := v_hops + 1;
        IF v_hops > 64 THEN
            RAISE EXCEPTION 'POSITION_REPORTING_TOO_DEEP: exceeded 64 levels' USING ERRCODE = '23514';
        END IF;
        SELECT reports_to_position_id INTO v_cursor FROM org.positions WHERE position_id = v_cursor;
    END LOOP;
    RETURN NEW;
END $fn$;

CREATE TRIGGER tg_position_no_cycle
    AFTER INSERT OR UPDATE OF reports_to_position_id ON org.positions
    FOR EACH ROW EXECUTE FUNCTION org.tg_position_no_cycle();

-- --- ERD §14 : administrative vs functional vs project reporting ------------
CREATE TABLE org.reporting_relationships (
    reporting_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id         UUID NOT NULL,
    subject_position_id UUID NOT NULL,
    manager_position_id UUID,
    manager_employee_id UUID,        -- FK added in V006; used for project/matrix lines
    reporting_type     VARCHAR(20) NOT NULL
                       CHECK (reporting_type IN ('ADMINISTRATIVE','FUNCTIONAL','PROJECT','MATRIX')),
    start_date         DATE NOT NULL,
    end_date           DATE,
    validity           DATERANGE GENERATED ALWAYS AS
                       (daterange(start_date, end_date, '[)')) STORED,
    CONSTRAINT fk_rr_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_rr_subject FOREIGN KEY (subject_position_id, tenant_id)
        REFERENCES org.positions(position_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_rr_manager_pos FOREIGN KEY (manager_position_id, tenant_id)
        REFERENCES org.positions(position_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT ck_rr_dates CHECK (end_date IS NULL OR end_date > start_date),
    CONSTRAINT ck_rr_has_manager CHECK (manager_position_id IS NOT NULL OR manager_employee_id IS NOT NULL),
    -- ERD §43: at most one ADMINISTRATIVE line per position at any point in time.
    CONSTRAINT ex_one_admin_line EXCLUDE USING gist (
        subject_position_id WITH =,
        validity WITH &&
    ) WHERE (reporting_type = 'ADMINISTRATIVE')
);
CALL platform.apply_standard_columns('org.reporting_relationships');
CALL platform.apply_tenant_rls('org.reporting_relationships');
CREATE INDEX ix_reporting_manager ON org.reporting_relationships(manager_position_id);
