-- =============================================================================
-- Afro_HR_V2 — V009 : Domain 08 — Personnel & Contracts
-- Source: ERD v1.0 §28-§32, §42 Rule 5, §43, §52
-- Employment 1:N Contract (original, renewal, amendment) — never Employee 1:1.
-- A signed contract is never edited; it is superseded by a new version.
-- =============================================================================

CREATE TABLE personnel.employment_contracts (
    contract_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id       UUID NOT NULL,
    employment_id    UUID NOT NULL,
    contract_number  config.entity_code NOT NULL,
    contract_type_id UUID NOT NULL,
    contract_type_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('CONTRACT_TYPE'::config.entity_code) STORED,
    supersedes_contract_id UUID,          -- ERD §31: versioning by chaining
    version_number   INT NOT NULL DEFAULT 1 CHECK (version_number >= 1),
    start_date       DATE NOT NULL,
    end_date         DATE,
    validity         DATERANGE GENERATED ALWAYS AS (daterange(start_date, end_date, '[)')) STORED,
    probation_days   INT CHECK (probation_days IS NULL OR probation_days >= 0),
    notice_period_days INT CHECK (notice_period_days IS NULL OR notice_period_days >= 0),
    working_hours_rule_id UUID,
    -- ERD §32: a legal snapshot of the stated amount may live on the contract,
    -- but the system of record for payroll maths is compensation.*
    stated_gross_amount NUMERIC(18,4),
    stated_currency  config.currency_code,
    status           VARCHAR(30) NOT NULL DEFAULT 'DRAFT'
        CHECK (status IN ('DRAFT','PENDING_SIGNATURE','ACTIVE','EXPIRING',
                          'EXPIRED','TERMINATED','SUPERSEDED')),
    signed_date      DATE,
    document_ref     VARCHAR(500),        -- object-storage key (MinIO/S3), not a BLOB
    CONSTRAINT fk_ctr_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ctr_employment FOREIGN KEY (employment_id, tenant_id, company_id)
        REFERENCES core_hr.employments(employment_id, tenant_id, company_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ctr_type FOREIGN KEY (contract_type_id, tenant_id, contract_type_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT fk_ctr_supersedes FOREIGN KEY (supersedes_contract_id, tenant_id)
        REFERENCES personnel.employment_contracts(contract_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_contract_number UNIQUE (company_id, contract_number),
    CONSTRAINT uq_contract_tenant UNIQUE (contract_id, tenant_id),
    CONSTRAINT ck_ctr_dates CHECK (end_date IS NULL OR end_date > start_date),
    CONSTRAINT ck_ctr_signed CHECK (
        status NOT IN ('ACTIVE','EXPIRING','EXPIRED') OR signed_date IS NOT NULL),
    CONSTRAINT ck_ctr_not_self_supersede CHECK (supersedes_contract_id IS DISTINCT FROM contract_id),
    -- ERD §42 Rule 5 / §43: no two live contracts overlapping in time.
    CONSTRAINT ex_no_overlapping_contract EXCLUDE USING gist (
        employment_id WITH =, validity WITH &&
    ) WHERE (status IN ('PENDING_SIGNATURE','ACTIVE','EXPIRING'))
);
CALL platform.apply_standard_columns('personnel.employment_contracts');
CALL platform.apply_tenant_rls('personnel.employment_contracts');
CREATE INDEX ix_contracts_employment ON personnel.employment_contracts(employment_id, status);
CREATE INDEX ix_contracts_expiry ON personnel.employment_contracts(tenant_id, end_date)
    WHERE status IN ('ACTIVE','EXPIRING');

CREATE TRIGGER tg_contract_state
    BEFORE INSERT OR UPDATE OF status ON personnel.employment_contracts
    FOR EACH ROW EXECUTE FUNCTION config.tg_enforce_state_machine('CONTRACT', 'status');

-- A signed contract is immutable except for its status and supersede chain.
CREATE OR REPLACE FUNCTION personnel.tg_contract_immutable_when_signed() RETURNS TRIGGER
LANGUAGE plpgsql AS $fn$
BEGIN
    IF OLD.status IN ('ACTIVE','EXPIRING','EXPIRED','TERMINATED','SUPERSEDED') THEN
        IF (NEW.start_date, NEW.end_date, NEW.contract_type_id, NEW.stated_gross_amount,
            NEW.probation_days, NEW.notice_period_days, NEW.contract_number)
           IS DISTINCT FROM
           (OLD.start_date, OLD.end_date, OLD.contract_type_id, OLD.stated_gross_amount,
            OLD.probation_days, OLD.notice_period_days, OLD.contract_number) THEN
            RAISE EXCEPTION
                'CONTRACT_IMMUTABLE: contract % is % — issue an amendment instead of editing it',
                OLD.contract_number, OLD.status USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END $fn$;

CREATE TRIGGER tg_contract_immutable
    BEFORE UPDATE ON personnel.employment_contracts
    FOR EACH ROW EXECUTE FUNCTION personnel.tg_contract_immutable_when_signed();
