-- =============================================================================
-- Afro_HR_V2 — V011 : Domain 02 — Identity & Access
-- Source: Domain Map §6 ; 03.txt (Platform Super Admin vs Company Super Admin)
-- This domain does NOT own Employee. Not every employee is a user, and not
-- every user is an employee (auditors, contractors, integration accounts).
-- =============================================================================

CREATE TABLE identity.users (
    user_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     UUID REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    username      CITEXT NOT NULL,
    email         CITEXT NOT NULL,
    display_name  VARCHAR(200) NOT NULL,
    user_type     VARCHAR(30) NOT NULL DEFAULT 'EMPLOYEE'
        CHECK (user_type IN ('PLATFORM_ADMIN','EMPLOYEE','CONTRACTOR','EXTERNAL','AUDITOR','SYSTEM')),
    status        VARCHAR(20) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','ACTIVE','LOCKED','DISABLED')),
    employee_id   UUID,
    mfa_enabled   BOOLEAN NOT NULL DEFAULT false,
    last_login_at TIMESTAMPTZ,
    failed_login_count INT NOT NULL DEFAULT 0,
    preferred_language config.lang_code NOT NULL DEFAULT 'en',
    CONSTRAINT fk_user_employee FOREIGN KEY (employee_id, tenant_id)
        REFERENCES core_hr.employees(employee_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_user_username UNIQUE NULLS NOT DISTINCT (tenant_id, username),
    CONSTRAINT uq_user_email UNIQUE NULLS NOT DISTINCT (tenant_id, email),
    CONSTRAINT uq_user_tenant UNIQUE NULLS NOT DISTINCT (user_id, tenant_id),
    -- Platform admins sit above every tenant; everyone else must belong to one.
    CONSTRAINT ck_user_tenant_scope CHECK (
        (user_type = 'PLATFORM_ADMIN' AND tenant_id IS NULL) OR
        (user_type <> 'PLATFORM_ADMIN' AND tenant_id IS NOT NULL)),
    CONSTRAINT ck_user_employee_link CHECK (
        employee_id IS NULL OR user_type IN ('EMPLOYEE','CONTRACTOR'))
);
CALL platform.apply_standard_columns('identity.users');
CREATE UNIQUE INDEX uq_user_per_employee ON identity.users(employee_id)
    WHERE employee_id IS NOT NULL;

-- Back-link from employee (declared in V006).
ALTER TABLE core_hr.employees
    ADD CONSTRAINT fk_employee_user FOREIGN KEY (user_id, tenant_id)
        REFERENCES identity.users(user_id, tenant_id) ON DELETE SET NULL;

CREATE TABLE identity.permissions (
    permission_code config.entity_code PRIMARY KEY,
    module_code     VARCHAR(10) NOT NULL,   -- M01..M20
    description     TEXT NOT NULL
);

CREATE TABLE identity.roles (
    role_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID REFERENCES platform.tenants(tenant_id) ON DELETE RESTRICT,
    role_code   config.entity_code NOT NULL,
    role_name   VARCHAR(150) NOT NULL,
    is_system   BOOLEAN NOT NULL DEFAULT false,
    status      VARCHAR(20) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','INACTIVE')),
    CONSTRAINT uq_role UNIQUE NULLS NOT DISTINCT (tenant_id, role_code),
    CONSTRAINT uq_role_tenant UNIQUE NULLS NOT DISTINCT (role_id, tenant_id)
);
CALL platform.apply_standard_columns('identity.roles');

CREATE TABLE identity.role_permissions (
    role_id         UUID NOT NULL REFERENCES identity.roles(role_id) ON DELETE CASCADE,
    permission_code config.entity_code NOT NULL
        REFERENCES identity.permissions(permission_code) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_code)
);

-- Scope matters as much as the permission: "HR Manager, but only for Egypt".
CREATE TABLE identity.user_roles (
    user_role_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID,
    user_id      UUID NOT NULL,
    role_id      UUID NOT NULL,
    scope_type   VARCHAR(20) NOT NULL DEFAULT 'TENANT'
        CHECK (scope_type IN ('PLATFORM','TENANT','COMPANY','ORG_UNIT','PROJECT','SELF')),
    scope_id     UUID,
    valid_from   DATE NOT NULL DEFAULT current_date,
    valid_to     DATE,
    CONSTRAINT fk_ur_user FOREIGN KEY (user_id, tenant_id)
        REFERENCES identity.users(user_id, tenant_id) ON DELETE CASCADE,
    CONSTRAINT fk_ur_role FOREIGN KEY (role_id, tenant_id)
        REFERENCES identity.roles(role_id, tenant_id) ON DELETE RESTRICT,
    CONSTRAINT uq_user_role_scope UNIQUE NULLS NOT DISTINCT (user_id, role_id, scope_type, scope_id),
    CONSTRAINT ck_ur_dates CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT ck_ur_scope_id CHECK (
        (scope_type IN ('PLATFORM','TENANT','SELF') AND scope_id IS NULL) OR
        (scope_type IN ('COMPANY','ORG_UNIT','PROJECT') AND scope_id IS NOT NULL))
);
CALL platform.apply_standard_columns('identity.user_roles');
CREATE INDEX ix_user_roles_user ON identity.user_roles(user_id) WHERE valid_to IS NULL;
