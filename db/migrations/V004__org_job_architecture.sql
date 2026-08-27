-- =============================================================================
-- Afro_HR_V2 — V004 : Domain 03 — Organization & Job Architecture
-- Source: ERD v1.0 §6-§14 ; Domain Map §7-§9
-- Core rule: JOB is the definition ("Project Manager").
--            POSITION is the seat ("Project Manager - Huawei, Cairo, Grade G6").
--            They are never merged.  Reporting lives on POSITION, not employee.
-- =============================================================================

-- --- Supporting master data -------------------------------------------------
CREATE TABLE org.cost_centers (
    cost_center_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id       UUID NOT NULL,
    cost_center_code config.entity_code NOT NULL,
    name_en          VARCHAR(150) NOT NULL,
    name_ar          VARCHAR(150),
    status           VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    CONSTRAINT fk_cc_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_cost_center UNIQUE (company_id, cost_center_code),
    CONSTRAINT uq_cost_center_tenant UNIQUE (cost_center_id, tenant_id)
);
CALL platform.apply_standard_columns('org.cost_centers');
CALL platform.apply_tenant_rls('org.cost_centers');

CREATE TABLE org.work_locations (
    location_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id    UUID NOT NULL,
    location_code config.entity_code NOT NULL,
    name_en       VARCHAR(150) NOT NULL,
    name_ar       VARCHAR(150),
    location_type VARCHAR(30) NOT NULL DEFAULT 'OFFICE'
                  CHECK (location_type IN ('OFFICE','WAREHOUSE','SITE','CLIENT_PREMISES','REMOTE')),
    country_code  config.country_code NOT NULL,
    city          VARCHAR(100),
    timezone      VARCHAR(50),
    geo_lat       NUMERIC(9,6),
    geo_lng       NUMERIC(9,6),
    status        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    CONSTRAINT fk_loc_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_work_location UNIQUE (company_id, location_code),
    CONSTRAINT uq_work_location_tenant UNIQUE (location_id, tenant_id)
);
CALL platform.apply_standard_columns('org.work_locations');
CALL platform.apply_tenant_rls('org.work_locations');

CREATE TABLE org.job_families (
    job_family_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    family_code   config.entity_code NOT NULL,
    name_en       VARCHAR(150) NOT NULL,
    name_ar       VARCHAR(150),
    parent_family_id UUID REFERENCES org.job_families(job_family_id) ON DELETE RESTRICT,
    status        VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    CONSTRAINT uq_job_family UNIQUE (tenant_id, family_code),
    CONSTRAINT uq_job_family_tenant UNIQUE (job_family_id, tenant_id)
);
CALL platform.apply_standard_columns('org.job_families');
CALL platform.apply_tenant_rls('org.job_families');

CREATE TABLE org.career_levels (
    career_level_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    level_code      config.entity_code NOT NULL,
    name_en         VARCHAR(100) NOT NULL,
    level_order     INT NOT NULL,
    CONSTRAINT uq_career_level UNIQUE (tenant_id, level_code),
    CONSTRAINT uq_career_level_tenant UNIQUE (career_level_id, tenant_id)
);
CALL platform.apply_standard_columns('org.career_levels');
CALL platform.apply_tenant_rls('org.career_levels');

-- ERD §38 — Grade drives ranges/eligibility/authority, never the actual salary.
CREATE TABLE org.grades (
    grade_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    grade_code   config.entity_code NOT NULL,
    name_en      VARCHAR(100) NOT NULL,
    name_ar      VARCHAR(100),
    grade_order  INT NOT NULL,
    career_level_id UUID,
    min_salary   NUMERIC(18,4),
    mid_salary   NUMERIC(18,4),
    max_salary   NUMERIC(18,4),
    currency_code config.currency_code,
    status       VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    CONSTRAINT fk_grade_level FOREIGN KEY (career_level_id, tenant_id)
        REFERENCES org.career_levels(career_level_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_grade UNIQUE (tenant_id, grade_code),
    CONSTRAINT uq_grade_tenant UNIQUE (grade_id, tenant_id),
    CONSTRAINT ck_grade_range CHECK (
        min_salary IS NULL OR max_salary IS NULL OR max_salary >= min_salary)
);
CALL platform.apply_standard_columns('org.grades');
CALL platform.apply_tenant_rls('org.grades');

-- --- ERD §6-§8 : one recursive table for Sector/Dept/Section/Unit/Team --------
CREATE TABLE org.organization_units (
    org_unit_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id         UUID NOT NULL,
    org_unit_code      config.entity_code NOT NULL,
    name_en            VARCHAR(200) NOT NULL,
    name_ar            VARCHAR(200),
    name_fr            VARCHAR(200),
    org_unit_type_id   UUID NOT NULL,
    org_unit_type_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('ORG_UNIT_TYPE'::config.entity_code) STORED,
    parent_org_unit_id UUID,
    manager_position_id UUID,          -- FK added in V005 (circular with positions)
    cost_center_id     UUID,
    status             VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    effective_from     DATE NOT NULL,
    effective_to       DATE,
    CONSTRAINT fk_ou_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ou_type FOREIGN KEY (org_unit_type_id, tenant_id, org_unit_type_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT fk_ou_parent FOREIGN KEY (parent_org_unit_id, tenant_id)
        REFERENCES org.organization_units(org_unit_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ou_cost_center FOREIGN KEY (cost_center_id, tenant_id)
        REFERENCES org.cost_centers(cost_center_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_org_unit UNIQUE (company_id, org_unit_code),
    CONSTRAINT uq_org_unit_tenant UNIQUE (org_unit_id, tenant_id),
    CONSTRAINT ck_ou_not_self_parent CHECK (parent_org_unit_id IS DISTINCT FROM org_unit_id),
    CONSTRAINT ck_ou_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
CALL platform.apply_standard_columns('org.organization_units');
CALL platform.apply_tenant_rls('org.organization_units');
CREATE INDEX ix_org_units_parent ON org.organization_units(parent_org_unit_id);
CREATE INDEX ix_org_units_company ON org.organization_units(company_id, status);

-- Cycle guard for the recursive hierarchy.
CREATE OR REPLACE FUNCTION org.tg_org_unit_no_cycle() RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
DECLARE v_cursor UUID := NEW.parent_org_unit_id; v_hops INT := 0;
BEGIN
    WHILE v_cursor IS NOT NULL LOOP
        IF v_cursor = NEW.org_unit_id THEN
            RAISE EXCEPTION 'ORG_HIERARCHY_CYCLE: org unit % cannot descend from itself',
                NEW.org_unit_id USING ERRCODE = '23514';
        END IF;
        v_hops := v_hops + 1;
        IF v_hops > 64 THEN
            RAISE EXCEPTION 'ORG_HIERARCHY_TOO_DEEP: exceeded 64 levels' USING ERRCODE = '23514';
        END IF;
        SELECT parent_org_unit_id INTO v_cursor
          FROM org.organization_units WHERE org_unit_id = v_cursor;
    END LOOP;
    RETURN NEW;
END $fn$;

CREATE TRIGGER tg_org_unit_no_cycle
    AFTER INSERT OR UPDATE OF parent_org_unit_id ON org.organization_units
    FOR EACH ROW EXECUTE FUNCTION org.tg_org_unit_no_cycle();

-- --- ERD §9-§10 : JOB = the definition --------------------------------------
CREATE TABLE org.jobs (
    job_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    job_code        config.entity_code NOT NULL,
    job_title_en    VARCHAR(200) NOT NULL,
    job_title_ar    VARCHAR(200),
    job_title_fr    VARCHAR(200),
    job_family_id   UUID,
    career_level_id UUID,
    default_grade_id UUID,
    job_purpose     TEXT,
    job_description TEXT,
    status          VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    effective_from  DATE NOT NULL,
    effective_to    DATE,
    CONSTRAINT fk_job_family FOREIGN KEY (job_family_id, tenant_id)
        REFERENCES org.job_families(job_family_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_job_level FOREIGN KEY (career_level_id, tenant_id)
        REFERENCES org.career_levels(career_level_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_job_grade FOREIGN KEY (default_grade_id, tenant_id)
        REFERENCES org.grades(grade_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_job UNIQUE (tenant_id, job_code),                -- ERD §41
    CONSTRAINT uq_job_tenant UNIQUE (job_id, tenant_id),
    CONSTRAINT ck_job_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
CALL platform.apply_standard_columns('org.jobs');
CALL platform.apply_tenant_rls('org.jobs');

COMMENT ON TABLE org.jobs IS
    'ERD §10: one JOB (Project Manager) fans out to many POSITIONs '
    '(PM-Huawei, PM-Nokia, PM-Ericsson). Never collapse the two.';
