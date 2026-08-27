-- =============================================================================
-- Afro_HR_V2 — Seed : org structure, grades, one real-shaped employee
-- Models the Master Blueprint example: a Project Manager split across
-- Huawei 50% / Nokia 30% / Ericsson 20% on top of a 100% primary assignment.
-- =============================================================================
SET client_min_messages TO WARNING;

DO $seed$
DECLARE
    v_tenant UUID; v_company UUID;
    v_ou_type_sector UUID; v_ou_type_dept UUID;
    v_sector UUID; v_dept UUID;
    v_family UUID; v_level UUID; v_grade UUID;
    v_job UUID; v_position UUID; v_loc UUID; v_cc UUID;
    v_employee UUID; v_employment UUID;
    v_type_perm UUID; v_cat_white UUID; v_asg_primary UUID; v_asg_project UUID;
    v_freq UUID; v_reason UUID; v_pos_type UUID;
    v_pkg UUID; v_basic UUID; v_transport UUID;
    v_huawei UUID; v_nokia UUID; v_ericsson UUID;
    v_code TEXT;
    v_system_user UUID;
BEGIN
    SELECT tenant_id INTO v_tenant FROM platform.tenants WHERE tenant_code = 'AFRO';
    SELECT user_id INTO v_system_user FROM identity.users WHERE username = 'system';
    CALL platform.set_context(v_tenant, v_system_user, true);
    SELECT company_id INTO v_company FROM platform.companies WHERE company_code = 'AFRO-EGY';

    SELECT reference_value_id INTO v_ou_type_sector FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='ORG_UNIT_TYPE' AND value_code='SECTOR';
    SELECT reference_value_id INTO v_ou_type_dept FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='ORG_UNIT_TYPE' AND value_code='DEPARTMENT';
    SELECT reference_value_id INTO v_type_perm FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='EMPLOYMENT_TYPE' AND value_code='PERMANENT';
    SELECT reference_value_id INTO v_cat_white FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='WORKER_CATEGORY' AND value_code='WHITE_COLLAR';
    SELECT reference_value_id INTO v_asg_primary FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='ASSIGNMENT_TYPE' AND value_code='PRIMARY';
    SELECT reference_value_id INTO v_asg_project FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='ASSIGNMENT_TYPE' AND value_code='PROJECT';
    SELECT reference_value_id INTO v_freq FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='PAY_FREQUENCY' AND value_code='MONTHLY';
    SELECT reference_value_id INTO v_reason FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='COMPENSATION_REASON' AND value_code='HIRING';
    SELECT reference_value_id INTO v_pos_type FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='POSITION_TYPE' AND value_code='PERMANENT_HC';

    INSERT INTO org.cost_centers (tenant_id, company_id, cost_center_code, name_en)
    VALUES (v_tenant, v_company, 'CC-OPS', 'Operations') RETURNING cost_center_id INTO v_cc;

    INSERT INTO org.work_locations (tenant_id, company_id, location_code, name_en, location_type, country_code, city)
    VALUES (v_tenant, v_company, 'HQ-CAIRO', 'Cairo Head Office', 'OFFICE', 'EGY', 'Cairo')
    RETURNING location_id INTO v_loc;

    INSERT INTO org.organization_units
        (tenant_id, company_id, org_unit_code, name_en, name_ar, org_unit_type_id, effective_from, cost_center_id)
    VALUES (v_tenant, v_company, 'OPS', 'Operations Sector', 'قطاع العمليات',
            v_ou_type_sector, DATE '2020-01-01', v_cc)
    RETURNING org_unit_id INTO v_sector;

    INSERT INTO org.organization_units
        (tenant_id, company_id, org_unit_code, name_en, name_ar, org_unit_type_id,
         parent_org_unit_id, effective_from, cost_center_id)
    VALUES (v_tenant, v_company, 'OPS-TELECOM', 'Telecom Delivery', 'إدارة تنفيذ الاتصالات',
            v_ou_type_dept, v_sector, DATE '2020-01-01', v_cc)
    RETURNING org_unit_id INTO v_dept;

    INSERT INTO org.job_families (tenant_id, family_code, name_en)
    VALUES (v_tenant, 'PROJECT_MGMT', 'Project Management') RETURNING job_family_id INTO v_family;

    INSERT INTO org.career_levels (tenant_id, level_code, name_en, level_order)
    VALUES (v_tenant, 'MANAGER', 'Manager', 4) RETURNING career_level_id INTO v_level;

    INSERT INTO org.grades (tenant_id, grade_code, name_en, grade_order, career_level_id,
                            min_salary, mid_salary, max_salary, currency_code)
    VALUES (v_tenant, 'G6', 'Grade 6', 6, v_level, 18000, 24000, 32000, 'EGP')
    RETURNING grade_id INTO v_grade;

    INSERT INTO org.jobs (tenant_id, job_code, job_title_en, job_title_ar, job_family_id,
                          career_level_id, default_grade_id, effective_from)
    VALUES (v_tenant, 'JOB-PM-001', 'Project Manager', 'مدير مشروع', v_family, v_level, v_grade,
            DATE '2020-01-01')
    RETURNING job_id INTO v_job;

    v_code := platform.next_code(v_tenant, 'POSITION_CODE', v_company);
    INSERT INTO org.positions (tenant_id, company_id, position_code, job_id, org_unit_id,
                               grade_id, default_location_id, cost_center_id, position_type_id,
                               headcount_capacity, status, effective_from)
    VALUES (v_tenant, v_company, v_code, v_job, v_dept, v_grade, v_loc, v_cc, v_pos_type,
            3, 'PLANNED', DATE '2024-01-01')
    RETURNING position_id INTO v_position;

    UPDATE org.positions SET status='APPROVED', version=version WHERE position_id=v_position;
    UPDATE org.positions SET status='VACANT',   version=version WHERE position_id=v_position;

    INSERT INTO integration.project_references (tenant_id, company_id, project_code, project_name, customer_name, status)
    VALUES (v_tenant, v_company, 'PRJ-HUAWEI-FTTH', 'Huawei FTTH Rollout', 'Huawei', 'ACTIVE')
    RETURNING project_id INTO v_huawei;
    INSERT INTO integration.project_references (tenant_id, company_id, project_code, project_name, customer_name, status)
    VALUES (v_tenant, v_company, 'PRJ-NOKIA-RAN', 'Nokia RAN Swap', 'Nokia', 'ACTIVE')
    RETURNING project_id INTO v_nokia;
    INSERT INTO integration.project_references (tenant_id, company_id, project_code, project_name, customer_name, status)
    VALUES (v_tenant, v_company, 'PRJ-ERICSSON-TX', 'Ericsson Transmission', 'Ericsson', 'ACTIVE')
    RETURNING project_id INTO v_ericsson;

    -- --- The person ---------------------------------------------------------
    v_code := platform.next_code(v_tenant, 'EMPLOYEE_CODE', v_company);
    INSERT INTO core_hr.employees
        (tenant_id, employee_code, first_name_en, last_name_en, first_name_ar, last_name_ar,
         display_name, date_of_birth, gender, marital_status, nationality_code,
         primary_mobile, primary_email)
    VALUES (v_tenant, v_code, 'Mohamed', 'Taha', 'محمد', 'طه', 'Mohamed Taha',
            DATE '1990-04-12', 'MALE', 'MARRIED', 'EGY', '+201000000001', 'mohamed.taha@afro.example')
    RETURNING employee_id INTO v_employee;

    INSERT INTO core_hr.employee_identifiers
        (tenant_id, employee_id, identifier_type_id, identifier_number, country_code,
         issue_date, expiry_date, is_primary, verification_status, verified_at)
    SELECT v_tenant, v_employee, reference_value_id, '29004120100015', 'EGY',
           DATE '2018-05-01', DATE '2032-05-01', true, 'VERIFIED', now()
      FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='IDENTIFIER_TYPE' AND value_code='NATIONAL_ID';

    -- --- The employment (DRAFT -> PRE_EMPLOYMENT -> ACTIVE) -----------------
    v_code := platform.next_code(v_tenant, 'EMPLOYMENT_NO', v_company);
    INSERT INTO core_hr.employments
        (tenant_id, company_id, employee_id, employment_number, employment_type_id,
         worker_category_id, employment_status, hire_date, seniority_date,
         probation_start_date, probation_end_date, effective_from)
    VALUES (v_tenant, v_company, v_employee, v_code, v_type_perm, v_cat_white,
            'DRAFT', DATE '2026-01-01', DATE '2026-01-01',
            DATE '2026-01-01', DATE '2026-03-31', DATE '2026-01-01')
    RETURNING employment_id INTO v_employment;

    UPDATE core_hr.employments SET employment_status='PRE_EMPLOYMENT', version=version
     WHERE employment_id=v_employment;
    UPDATE core_hr.employments SET employment_status='ACTIVE', version=version
     WHERE employment_id=v_employment;

    -- --- Contract -----------------------------------------------------------
    v_code := platform.next_code(v_tenant, 'CONTRACT_NO', v_company);
    INSERT INTO personnel.employment_contracts
        (tenant_id, company_id, employment_id, contract_number, contract_type_id,
         start_date, end_date, probation_days, notice_period_days,
         stated_gross_amount, stated_currency, status, signed_date)
    SELECT v_tenant, v_company, v_employment, v_code, reference_value_id,
           DATE '2026-01-01', NULL, 90, 60, 22500, 'EGP', 'DRAFT', DATE '2025-12-20'
      FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='CONTRACT_TYPE' AND value_code='ORIGINAL';

    UPDATE personnel.employment_contracts SET status='PENDING_SIGNATURE', version=version
     WHERE employment_id=v_employment;
    UPDATE personnel.employment_contracts SET status='ACTIVE', version=version
     WHERE employment_id=v_employment;

    -- --- Assignments: 100% primary + 50/30/20 project split -----------------
    INSERT INTO workforce.employee_assignments
        (tenant_id, company_id, employment_id, employee_id, position_id, org_unit_id,
         location_id, assignment_type_id, allocation_percentage, is_primary,
         status, start_date)
    VALUES (v_tenant, v_company, v_employment, v_employee, v_position, v_dept, v_loc,
            v_asg_primary, 100, true, 'PLANNED', DATE '2026-01-01');

    UPDATE workforce.employee_assignments SET status='APPROVED', version=version
     WHERE employment_id=v_employment AND is_primary;
    UPDATE workforce.employee_assignments SET status='ACTIVE', version=version
     WHERE employment_id=v_employment AND is_primary;

    UPDATE org.positions SET status='PARTIALLY_FILLED', version=version WHERE position_id=v_position;

    -- Project allocations are tracked on a separate axis from the primary seat,
    -- so the 100% cap is evaluated per assignment_type by the application layer.
    -- Here we model them as non-primary rows summing to 100% of project time.
    INSERT INTO workforce.employee_assignments
        (tenant_id, company_id, employment_id, employee_id, position_id, org_unit_id,
         project_id, assignment_type_id, allocation_percentage, is_primary, status, start_date)
    VALUES
        (v_tenant, v_company, v_employment, v_employee, v_position, v_dept, v_huawei,
         v_asg_project, 50, false, 'PLANNED', DATE '2026-01-01'),
        (v_tenant, v_company, v_employment, v_employee, v_position, v_dept, v_nokia,
         v_asg_project, 30, false, 'PLANNED', DATE '2026-01-01'),
        (v_tenant, v_company, v_employment, v_employee, v_position, v_dept, v_ericsson,
         v_asg_project, 20, false, 'PLANNED', DATE '2026-01-01');

    -- --- Compensation -------------------------------------------------------
    INSERT INTO compensation.salary_components
        (tenant_id, component_code, component_name_en, component_name_ar, component_type,
         calculation_method, taxable_default, insurance_default, sort_order)
    VALUES (v_tenant,'BASIC','Basic Salary','الراتب الأساسي','EARNING','FIXED',true,true,10)
    RETURNING component_id INTO v_basic;

    INSERT INTO compensation.salary_components
        (tenant_id, component_code, component_name_en, component_name_ar, component_type,
         calculation_method, taxable_default, insurance_default, sort_order)
    VALUES (v_tenant,'TRANSPORT','Transportation Allowance','بدل انتقالات','ALLOWANCE','FIXED',true,false,20)
    RETURNING component_id INTO v_transport;

    INSERT INTO compensation.salary_components
        (tenant_id, component_code, component_name_en, component_name_ar, component_type,
         calculation_method, taxable_default, insurance_default, sort_order)
    VALUES (v_tenant,'FIELD_ALLOW','Field Allowance','بدل ميداني','ALLOWANCE','RULE_BASED',true,false,30);

    INSERT INTO compensation.employee_compensations
        (tenant_id, company_id, employment_id, currency_code, pay_frequency_id, grade_id,
         reason_id, effective_from, status)
    VALUES (v_tenant, v_company, v_employment, 'EGP', v_freq, v_grade, v_reason,
            DATE '2026-01-01', 'DRAFT')
    RETURNING employee_compensation_id INTO v_pkg;

    INSERT INTO compensation.employee_compensation_components
        (tenant_id, employee_compensation_id, component_id, calculation_type, amount,
         taxable, social_insurance_applicable, effective_from)
    VALUES
        (v_tenant, v_pkg, v_basic,     'FIXED', 20000, true, true,  DATE '2026-01-01'),
        (v_tenant, v_pkg, v_transport, 'FIXED',  2500, true, false, DATE '2026-01-01');

    UPDATE compensation.employee_compensations
       SET status='APPROVED', approved_by=v_system_user, approved_at=now(), version=version
     WHERE employee_compensation_id=v_pkg;

    RAISE NOTICE 'Seeded employee % / employment %', v_employee, v_employment;
END $seed$;
