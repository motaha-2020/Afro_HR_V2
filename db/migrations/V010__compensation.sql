-- =============================================================================
-- Afro_HR_V2 — V010 : Domain 11 — Compensation (system of record for pay)
-- Source: ERD v1.0 §33-§38, §42 Rule 6, §43, §44
-- Employment 1:N Compensation package, effective-dated. We never UPDATE a
-- salary from 20K to 25K — we close one record and open the next (§44), so
-- payroll can still answer "what was the package in June 2026?" (§45).
-- =============================================================================

CREATE TABLE compensation.salary_components (
    component_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    component_code    config.entity_code NOT NULL,
    component_name_en VARCHAR(150) NOT NULL,
    component_name_ar VARCHAR(150),
    component_type    VARCHAR(30) NOT NULL
        CHECK (component_type IN ('EARNING','ALLOWANCE','BONUS','DEDUCTION','EMPLOYER_CONTRIBUTION')),
    calculation_method VARCHAR(30) NOT NULL DEFAULT 'FIXED'
        CHECK (calculation_method IN ('FIXED','PERCENTAGE','RATE_X_QUANTITY','RULE_BASED','VARIABLE')),
    percentage_base_component_id UUID,
    taxable_default   BOOLEAN NOT NULL DEFAULT true,
    insurance_default BOOLEAN NOT NULL DEFAULT true,
    is_recurring      BOOLEAN NOT NULL DEFAULT true,
    sort_order        INT NOT NULL DEFAULT 100,
    status            VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    CONSTRAINT fk_comp_base FOREIGN KEY (percentage_base_component_id, tenant_id)
        REFERENCES compensation.salary_components(component_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_salary_component UNIQUE (tenant_id, component_code),
    CONSTRAINT uq_salary_component_tenant UNIQUE (component_id, tenant_id)
);
CALL platform.apply_standard_columns('compensation.salary_components');
CALL platform.apply_tenant_rls('compensation.salary_components');

CREATE TABLE compensation.employee_compensations (
    employee_compensation_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id      UUID NOT NULL,
    employment_id   UUID NOT NULL,
    currency_code   config.currency_code NOT NULL,
    pay_frequency_id UUID NOT NULL,
    pay_frequency_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('PAY_FREQUENCY'::config.entity_code) STORED,
    grade_id        UUID,
    reason_id       UUID,
    reason_code     config.entity_code NOT NULL
        GENERATED ALWAYS AS ('COMPENSATION_REASON'::config.entity_code) STORED,
    effective_from  DATE NOT NULL,
    effective_to    DATE,
    validity        DATERANGE GENERATED ALWAYS AS
                    (daterange(effective_from, effective_to, '[)')) STORED,
    status          VARCHAR(20) NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT','PENDING_APPROVAL','APPROVED','SUPERSEDED','CANCELLED')),
    approved_by     UUID,
    approved_at     TIMESTAMPTZ,
    CONSTRAINT fk_ecomp_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ecomp_employment FOREIGN KEY (employment_id, tenant_id, company_id)
        REFERENCES core_hr.employments(employment_id, tenant_id, company_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ecomp_grade FOREIGN KEY (grade_id, tenant_id)
        REFERENCES org.grades(grade_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ecomp_frequency FOREIGN KEY (pay_frequency_id, tenant_id, pay_frequency_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT fk_ecomp_reason FOREIGN KEY (reason_id, tenant_id, reason_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT uq_ecomp_tenant UNIQUE (employee_compensation_id, tenant_id),
    CONSTRAINT ck_ecomp_effective CHECK (effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT ck_ecomp_approved CHECK (
        status <> 'APPROVED' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
    -- ERD §42 Rule 6 / §43: no temporal overlap between live packages.
    CONSTRAINT ex_no_overlapping_compensation EXCLUDE USING gist (
        employment_id WITH =, validity WITH &&
    ) WHERE (status IN ('PENDING_APPROVAL','APPROVED'))
);
CALL platform.apply_standard_columns('compensation.employee_compensations');
CALL platform.apply_tenant_rls('compensation.employee_compensations');
CREATE INDEX ix_ecomp_employment ON compensation.employee_compensations(employment_id, status);
CREATE INDEX ix_ecomp_validity ON compensation.employee_compensations USING gist (validity);

-- ERD §35: components are rows, not columns. Adding "Field Allowance" must
-- never require a schema migration.
CREATE TABLE compensation.employee_compensation_components (
    component_record_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    employee_compensation_id UUID NOT NULL,
    component_id    UUID NOT NULL,
    calculation_type VARCHAR(30) NOT NULL DEFAULT 'FIXED'
        CHECK (calculation_type IN ('FIXED','PERCENTAGE','RATE_X_QUANTITY','RULE_BASED','VARIABLE')),
    amount          NUMERIC(18,4),
    percentage      NUMERIC(7,4),
    quantity        NUMERIC(12,4),
    rate            NUMERIC(18,4),
    taxable         BOOLEAN NOT NULL DEFAULT true,
    social_insurance_applicable BOOLEAN NOT NULL DEFAULT true,
    effective_from  DATE NOT NULL,
    effective_to    DATE,
    CONSTRAINT fk_ecc_header FOREIGN KEY (employee_compensation_id, tenant_id)
        REFERENCES compensation.employee_compensations(employee_compensation_id, tenant_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_ecc_component FOREIGN KEY (component_id, tenant_id)
        REFERENCES compensation.salary_components(component_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_ecc_component UNIQUE (employee_compensation_id, component_id, effective_from),
    CONSTRAINT ck_ecc_effective CHECK (effective_to IS NULL OR effective_to > effective_from),
    -- Each calculation type must carry the inputs it actually needs.
    CONSTRAINT ck_ecc_inputs CHECK (
        (calculation_type = 'FIXED'           AND amount IS NOT NULL)
     OR (calculation_type = 'PERCENTAGE'      AND percentage IS NOT NULL)
     OR (calculation_type = 'RATE_X_QUANTITY' AND rate IS NOT NULL AND quantity IS NOT NULL)
     OR (calculation_type IN ('RULE_BASED','VARIABLE'))
    )
);
CALL platform.apply_standard_columns('compensation.employee_compensation_components');
CALL platform.apply_tenant_rls('compensation.employee_compensation_components');
CREATE INDEX ix_ecc_header ON compensation.employee_compensation_components(employee_compensation_id);

-- ERD §38: grade defines the band; it never defines the actual pay. This guard
-- warns loudly when an approved package falls outside its grade's range.
CREATE OR REPLACE FUNCTION compensation.tg_check_grade_range() RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
DECLARE
    v_min NUMERIC; v_max NUMERIC; v_total NUMERIC;
BEGIN
    IF NEW.status <> 'APPROVED' OR NEW.grade_id IS NULL THEN RETURN NEW; END IF;

    SELECT min_salary, max_salary INTO v_min, v_max
      FROM org.grades WHERE grade_id = NEW.grade_id;
    IF v_min IS NULL AND v_max IS NULL THEN RETURN NEW; END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_total
      FROM compensation.employee_compensation_components
     WHERE employee_compensation_id = NEW.employee_compensation_id
       AND calculation_type = 'FIXED';

    IF (v_min IS NOT NULL AND v_total < v_min) OR (v_max IS NOT NULL AND v_total > v_max) THEN
        RAISE WARNING
            'COMPENSATION_OUTSIDE_GRADE_RANGE: package % totals % but grade range is % .. %',
            NEW.employee_compensation_id, v_total, v_min, v_max;
    END IF;
    RETURN NEW;
END $fn$;

CREATE CONSTRAINT TRIGGER tg_compensation_grade_range
    AFTER INSERT OR UPDATE OF status ON compensation.employee_compensations
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION compensation.tg_check_grade_range();
