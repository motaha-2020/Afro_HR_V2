-- =============================================================================
-- Afro_HR_V2 — V002 : Domain 01 — Tenant & Platform
-- Source: ERD v1.0 §3 (tenants), §4-§5 (companies), §54-§55 (number sequences)
-- Rule: Tenant = SaaS customer.  Company = legal entity (own payroll, labor
--       rules, currency).  They are never merged.
-- =============================================================================

CREATE TABLE platform.tenants (
    tenant_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_code      config.entity_code NOT NULL UNIQUE,
    tenant_name      VARCHAR(200) NOT NULL,
    status           VARCHAR(30)  NOT NULL DEFAULT 'ACTIVE'
                     CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    default_language config.lang_code NOT NULL DEFAULT 'en',
    default_timezone VARCHAR(50)  NOT NULL DEFAULT 'Africa/Cairo'
);
CALL platform.apply_standard_columns('platform.tenants');
-- No RLS on tenants itself: it is the isolation root, reachable only by
-- Platform Super Admin through the application layer.

CREATE TABLE platform.companies (
    company_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_code        config.entity_code NOT NULL,
    legal_name          VARCHAR(250) NOT NULL,
    display_name        VARCHAR(200) NOT NULL,
    country_code        config.country_code NOT NULL,
    registration_number VARCHAR(100),
    tax_number          VARCHAR(100),
    base_currency       config.currency_code NOT NULL,
    default_timezone    VARCHAR(50),
    status              VARCHAR(30) NOT NULL DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','SUSPENDED','CLOSED')),
    effective_from      DATE NOT NULL,
    effective_to        DATE,
    CONSTRAINT uq_company_code_per_tenant UNIQUE (tenant_id, company_code),   -- ERD §41
    CONSTRAINT ck_company_effective_range CHECK (effective_to IS NULL OR effective_to >= effective_from),
    -- Composite target so children can enforce "company belongs to my tenant" (ERD §42 Rule 1)
    CONSTRAINT uq_company_tenant UNIQUE (company_id, tenant_id)
);
CALL platform.apply_standard_columns('platform.companies');
CALL platform.apply_tenant_rls('platform.companies');
CREATE INDEX ix_companies_tenant ON platform.companies(tenant_id) WHERE status = 'ACTIVE';

COMMENT ON CONSTRAINT uq_company_tenant ON platform.companies IS
    'Not a business key. Exists so child tables can FK (company_id, tenant_id) and make '
    'cross-tenant references structurally impossible — ERD §42 Rule 1.';

-- ---------------------------------------------------------------------------
-- ERD §54/§55 — human-readable codes come from configured sequences, never
-- from random backend logic.  e.g. AFR-EGY-EMP-000001
-- ---------------------------------------------------------------------------
CREATE TABLE platform.number_sequences (
    sequence_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    company_id      UUID,
    sequence_code   config.entity_code NOT NULL,  -- EMPLOYEE_CODE, POSITION_CODE, CONTRACT_NO ...
    prefix          VARCHAR(40) NOT NULL DEFAULT '',
    suffix          VARCHAR(40) NOT NULL DEFAULT '',
    padding         SMALLINT    NOT NULL DEFAULT 6 CHECK (padding BETWEEN 1 AND 18),
    next_number     BIGINT      NOT NULL DEFAULT 1 CHECK (next_number >= 1),
    increment_by    INT         NOT NULL DEFAULT 1 CHECK (increment_by >= 1),
    reset_policy    VARCHAR(20) NOT NULL DEFAULT 'NEVER'
                    CHECK (reset_policy IN ('NEVER','YEARLY','MONTHLY')),
    last_reset_key  VARCHAR(10),
    CONSTRAINT fk_seq_company FOREIGN KEY (company_id, tenant_id)
        REFERENCES platform.companies(company_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_sequence_scope UNIQUE NULLS NOT DISTINCT (tenant_id, company_id, sequence_code)
);
CALL platform.apply_standard_columns('platform.number_sequences');
CALL platform.apply_tenant_rls('platform.number_sequences');

CREATE OR REPLACE FUNCTION platform.next_code(
    p_tenant_id     UUID,
    p_sequence_code TEXT,
    p_company_id    UUID DEFAULT NULL
) RETURNS TEXT
LANGUAGE plpgsql AS $$
DECLARE
    r           platform.number_sequences%ROWTYPE;
    v_reset_key TEXT;
    v_value     BIGINT;
BEGIN
    -- Row lock serialises concurrent code allocation; no gaps on commit.
    SELECT * INTO r FROM platform.number_sequences
     WHERE tenant_id = p_tenant_id
       AND sequence_code = p_sequence_code
       AND company_id IS NOT DISTINCT FROM p_company_id
     FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'SEQUENCE_NOT_CONFIGURED: % (tenant=%, company=%)',
            p_sequence_code, p_tenant_id, p_company_id USING ERRCODE = '23503';
    END IF;

    v_reset_key := CASE r.reset_policy
                       WHEN 'YEARLY'  THEN to_char(current_date, 'YYYY')
                       WHEN 'MONTHLY' THEN to_char(current_date, 'YYYY-MM')
                       ELSE NULL
                   END;

    IF r.reset_policy <> 'NEVER' AND r.last_reset_key IS DISTINCT FROM v_reset_key THEN
        r.next_number := 1;
    END IF;

    v_value := r.next_number;

    UPDATE platform.number_sequences
       SET next_number    = v_value + r.increment_by,
           last_reset_key = v_reset_key,
           version        = version   -- satisfies the optimistic-lock trigger
     WHERE sequence_id = r.sequence_id;

    RETURN r.prefix || lpad(v_value::text, r.padding, '0') || r.suffix;
END $$;
