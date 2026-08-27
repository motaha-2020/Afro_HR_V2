-- =============================================================================
-- Afro_HR_V2 — V007 : core_hr.employments
-- Source: ERD v1.0 §18-§21, §41, §42 Rule 1, §50
-- Employee 1:N Employment. "Mohamed Taha" is the employee;
-- "works for Afro Egypt from 2026-01-01 as Permanent" is the employment.
-- =============================================================================

CREATE TABLE core_hr.employments (
    employment_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id        UUID NOT NULL,
    employee_id       UUID NOT NULL,
    employment_number config.entity_code,
    -- ERD §20/§21: type and worker category are two different things.
    employment_type_id UUID NOT NULL,
    employment_type_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('EMPLOYMENT_TYPE'::config.entity_code) STORED,
    worker_category_id UUID,
    worker_category_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('WORKER_CATEGORY'::config.entity_code) STORED,
    -- ERD §50 state machine
    employment_status VARCHAR(30) NOT NULL DEFAULT 'DRAFT'
        CHECK (employment_status IN ('DRAFT','PRE_EMPLOYMENT','ACTIVE','ON_LEAVE',
                                     'SUSPENDED','NOTICE_PERIOD','TERMINATED','CLOSED')),
    hire_date         DATE NOT NULL,
    seniority_date    DATE,
    probation_start_date DATE,
    probation_end_date   DATE,
    notice_start_date    DATE,
    termination_date  DATE,
    termination_reason_id UUID,
    termination_reason_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('TERMINATION_REASON'::config.entity_code) STORED,
    effective_from    DATE NOT NULL,
    effective_to      DATE,
    validity          DATERANGE GENERATED ALWAYS AS
                      (daterange(effective_from, effective_to, '[)')) STORED,
    CONSTRAINT fk_emp_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    -- ERD §42 Rule 1: employment company and employee must share a tenant.
    -- The composite FKs below make a cross-tenant employment structurally impossible.
    CONSTRAINT fk_emp_employee FOREIGN KEY (employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_emp_type FOREIGN KEY (employment_type_id, tenant_id, employment_type_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT fk_emp_worker_cat FOREIGN KEY (worker_category_id, tenant_id, worker_category_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT fk_emp_term_reason FOREIGN KEY (termination_reason_id, tenant_id, termination_reason_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT uq_employment_number UNIQUE (company_id, employment_number),
    CONSTRAINT uq_employment_tenant UNIQUE (employment_id, tenant_id),
    CONSTRAINT uq_employment_company UNIQUE (employment_id, tenant_id, company_id),
    CONSTRAINT ck_emp_effective CHECK (effective_to IS NULL OR effective_to >= effective_from),
    CONSTRAINT ck_emp_probation CHECK (
        probation_end_date IS NULL OR probation_start_date IS NULL
        OR probation_end_date >= probation_start_date),
    CONSTRAINT ck_emp_termination CHECK (termination_date IS NULL OR termination_date >= hire_date),
    CONSTRAINT ck_emp_terminated_needs_date CHECK (
        employment_status NOT IN ('TERMINATED','CLOSED') OR termination_date IS NOT NULL),
    -- No two overlapping employments for the same person at the same company.
    CONSTRAINT ex_no_overlapping_employment EXCLUDE USING gist (
        employee_id WITH =, company_id WITH =, validity WITH &&
    ) WHERE (employment_status <> 'CLOSED')
);
CALL platform.apply_standard_columns('core_hr.employments');
CALL platform.apply_tenant_rls('core_hr.employments');
CREATE INDEX ix_employments_employee ON core_hr.employments(employee_id, employment_status);
CREATE INDEX ix_employments_company ON core_hr.employments(company_id, employment_status);
CREATE INDEX ix_employments_hire_date ON core_hr.employments(tenant_id, hire_date);

CREATE TRIGGER tg_employment_state
    BEFORE INSERT OR UPDATE OF employment_status ON core_hr.employments
    FOR EACH ROW EXECUTE FUNCTION config.tg_enforce_state_machine('EMPLOYMENT', 'employment_status');

-- Deferred FKs that needed employees/employments to exist first.
ALTER TABLE org.reporting_relationships
    ADD CONSTRAINT fk_rr_manager_employee FOREIGN KEY (manager_employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE RESTRICT;
