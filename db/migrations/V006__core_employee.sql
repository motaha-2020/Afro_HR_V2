-- =============================================================================
-- Afro_HR_V2 — V006 : Domain 04 — Core Employee
-- Source: ERD v1.0 §15-§21, §49, §50 ; Domain Map §11 (employees is not a wide table)
-- Core rule: EMPLOYEE is the person. EMPLOYMENT is "this person works for this
--            company from this date". Employee 1:N Employment.
-- =============================================================================

CREATE TABLE core_hr.employees (
    employee_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    employee_code    config.entity_code NOT NULL,   -- from platform.next_code(), ERD §54
    first_name_en    VARCHAR(100) NOT NULL,
    middle_name_en   VARCHAR(100),
    last_name_en     VARCHAR(100) NOT NULL,
    first_name_ar    VARCHAR(100),
    middle_name_ar   VARCHAR(100),
    last_name_ar     VARCHAR(100),
    display_name     VARCHAR(250) NOT NULL,
    date_of_birth    DATE,
    gender           VARCHAR(20) CHECK (gender IN ('MALE','FEMALE','UNDISCLOSED')),
    marital_status   VARCHAR(20) CHECK (marital_status IN ('SINGLE','MARRIED','DIVORCED','WIDOWED')),
    nationality_code config.country_code,
    primary_mobile   VARCHAR(30),
    primary_email    CITEXT,
    -- ERD §49: person status is NOT employment status.
    employee_status  VARCHAR(20) NOT NULL DEFAULT 'ACTIVE'
                     CHECK (employee_status IN ('ACTIVE','INACTIVE','DECEASED','BLACKLISTED')),
    user_id          UUID,   -- optional; not every employee is a system user
    CONSTRAINT uq_employee_code UNIQUE (tenant_id, employee_code),
    CONSTRAINT uq_employee_tenant UNIQUE (employee_id, tenant_id),
    CONSTRAINT ck_employee_dob CHECK (date_of_birth IS NULL OR date_of_birth < current_date)
);
CALL platform.apply_standard_columns('core_hr.employees');
CALL platform.apply_tenant_rls('core_hr.employees');
CREATE INDEX ix_employees_name ON core_hr.employees(tenant_id, last_name_en, first_name_en);

COMMENT ON TABLE core_hr.employees IS
    'Domain Map §11: deliberately narrow. Contacts, addresses, identifiers, dependents and bank accounts live in child tables.';

-- --- ERD §17 : identifiers as rows, not fixed columns ------------------------
CREATE TABLE core_hr.employee_identifiers (
    identifier_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id           UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    employee_id         UUID NOT NULL,
    identifier_type_id  UUID NOT NULL,
    identifier_type_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('IDENTIFIER_TYPE'::config.entity_code) STORED,
    identifier_number   VARCHAR(100) NOT NULL,
    country_code        config.country_code,
    issue_date          DATE,
    expiry_date         DATE,
    issuing_authority   VARCHAR(150),
    is_primary          BOOLEAN NOT NULL DEFAULT false,
    verification_status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (verification_status IN ('PENDING','VERIFIED','REJECTED','EXPIRED')),
    verified_at         TIMESTAMPTZ,
    verified_by         UUID,
    CONSTRAINT fk_ident_employee FOREIGN KEY (employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ident_type FOREIGN KEY (identifier_type_id, tenant_id, identifier_type_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT ck_ident_dates CHECK (expiry_date IS NULL OR issue_date IS NULL OR expiry_date > issue_date),
    CONSTRAINT uq_ident_per_type UNIQUE (employee_id, identifier_type_id, identifier_number)
);
CALL platform.apply_standard_columns('core_hr.employee_identifiers');
CALL platform.apply_tenant_rls('core_hr.employee_identifiers');
CREATE UNIQUE INDEX uq_ident_one_primary
    ON core_hr.employee_identifiers(employee_id, identifier_type_id) WHERE is_primary;
CREATE INDEX ix_ident_expiry ON core_hr.employee_identifiers(tenant_id, expiry_date)
    WHERE expiry_date IS NOT NULL;

CREATE TABLE core_hr.employee_contacts (
    contact_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    employee_id     UUID NOT NULL,
    contact_type_id UUID NOT NULL,
    contact_type_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('CONTACT_TYPE'::config.entity_code) STORED,
    contact_value   VARCHAR(200) NOT NULL,
    is_primary      BOOLEAN NOT NULL DEFAULT false,
    CONSTRAINT fk_contact_employee FOREIGN KEY (employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE CASCADE,
    CONSTRAINT fk_contact_type FOREIGN KEY (contact_type_id, tenant_id, contact_type_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code)
);
CALL platform.apply_standard_columns('core_hr.employee_contacts');
CALL platform.apply_tenant_rls('core_hr.employee_contacts');

CREATE TABLE core_hr.employee_addresses (
    address_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    employee_id     UUID NOT NULL,
    address_type_id UUID NOT NULL,
    address_type_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('ADDRESS_TYPE'::config.entity_code) STORED,
    address_line_1  VARCHAR(250) NOT NULL,
    address_line_2  VARCHAR(250),
    city            VARCHAR(100),
    governorate     VARCHAR(100),
    postal_code     VARCHAR(20),
    country_code    config.country_code,
    effective_from  DATE NOT NULL DEFAULT current_date,
    effective_to    DATE,
    CONSTRAINT fk_addr_employee FOREIGN KEY (employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE CASCADE,
    CONSTRAINT fk_addr_type FOREIGN KEY (address_type_id, tenant_id, address_type_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code),
    CONSTRAINT ck_addr_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
CALL platform.apply_standard_columns('core_hr.employee_addresses');
CALL platform.apply_tenant_rls('core_hr.employee_addresses');

CREATE TABLE core_hr.employee_dependents (
    dependent_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    employee_id     UUID NOT NULL,
    full_name       VARCHAR(250) NOT NULL,
    relationship_type_id UUID NOT NULL,
    relationship_type_code config.entity_code NOT NULL
        GENERATED ALWAYS AS ('RELATIONSHIP_TYPE'::config.entity_code) STORED,
    date_of_birth   DATE,
    gender          VARCHAR(20) CHECK (gender IN ('MALE','FEMALE','UNDISCLOSED')),
    national_id     VARCHAR(50),
    -- Feeds the Benefits Eligibility Engine (Master Blueprint, Capability 01).
    is_benefit_eligible  BOOLEAN NOT NULL DEFAULT true,
    is_emergency_contact BOOLEAN NOT NULL DEFAULT false,
    contact_number  VARCHAR(30),
    CONSTRAINT fk_dep_employee FOREIGN KEY (employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE CASCADE,
    CONSTRAINT fk_dep_relationship FOREIGN KEY (relationship_type_id, tenant_id, relationship_type_code)
        REFERENCES config.reference_values(reference_value_id, tenant_id, reference_type_code)
);
CALL platform.apply_standard_columns('core_hr.employee_dependents');
CALL platform.apply_tenant_rls('core_hr.employee_dependents');

CREATE TABLE core_hr.employee_bank_accounts (
    bank_account_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    employee_id     UUID NOT NULL,
    bank_name       VARCHAR(150) NOT NULL,
    branch_name     VARCHAR(150),
    account_number  VARCHAR(64) NOT NULL,
    iban            VARCHAR(34),
    swift_code      VARCHAR(11),
    currency_code   config.currency_code NOT NULL,
    is_primary      BOOLEAN NOT NULL DEFAULT false,
    -- Payroll must never pay into an unverified account.
    verification_status VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (verification_status IN ('PENDING','VERIFIED','REJECTED')),
    effective_from  DATE NOT NULL DEFAULT current_date,
    effective_to    DATE,
    CONSTRAINT fk_bank_employee FOREIGN KEY (employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT ck_bank_effective CHECK (effective_to IS NULL OR effective_to >= effective_from)
);
CALL platform.apply_standard_columns('core_hr.employee_bank_accounts');
CALL platform.apply_tenant_rls('core_hr.employee_bank_accounts');
CREATE UNIQUE INDEX uq_bank_one_primary
    ON core_hr.employee_bank_accounts(employee_id) WHERE is_primary AND effective_to IS NULL;
