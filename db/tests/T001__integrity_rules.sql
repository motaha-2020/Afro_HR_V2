-- =============================================================================
-- Afro_HR_V2 — Rule tests. Each case asserts that a rule from ERD §42/§43/§50-53
-- is actually enforced by the database, not just documented.
-- Run: ./apply.sh test    (expects the seed to have been applied)
-- =============================================================================
SET client_min_messages TO WARNING;

CREATE OR REPLACE FUNCTION pg_temp.expect_failure(p_case TEXT, p_sql TEXT, p_expect TEXT)
RETURNS TEXT LANGUAGE plpgsql AS $fn$
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        IF position(p_expect IN SQLERRM) > 0 OR position(p_expect IN SQLSTATE) > 0 THEN
            RETURN format('PASS  %s', p_case);
        END IF;
        RETURN format('FAIL  %s -- blocked, but with: %s', p_case, SQLERRM);
    END;
    RETURN format('FAIL  %s -- statement was ALLOWED but should have been rejected', p_case);
END $fn$;

DO $t$
DECLARE
    v_tenant UUID; v_company UUID; v_employment UUID; v_employee UUID;
    v_position UUID; v_dept UUID; v_asg_project UUID; v_user UUID;
    v_results TEXT[] := '{}';
BEGIN
    SELECT tenant_id INTO v_tenant FROM platform.tenants WHERE tenant_code='AFRO';
    SELECT user_id INTO v_user FROM identity.users WHERE username='system';
    CALL platform.set_context(v_tenant, v_user, true);

    SELECT company_id INTO v_company FROM platform.companies WHERE company_code='AFRO-EGY';
    SELECT employment_id, employee_id INTO v_employment, v_employee
      FROM core_hr.employments LIMIT 1;
    SELECT position_id INTO v_position FROM org.positions LIMIT 1;
    SELECT org_unit_id INTO v_dept FROM org.organization_units WHERE org_unit_code='OPS-TELECOM';
    SELECT reference_value_id INTO v_asg_project FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='ASSIGNMENT_TYPE' AND value_code='PROJECT';

    -- ERD §50: DRAFT cannot jump straight to TERMINATED.
    v_results := v_results || pg_temp.expect_failure(
        'ERD 50  illegal employment state transition',
        format('UPDATE core_hr.employments SET employment_status=''TERMINATED'',
                       termination_date=DATE ''2026-06-01''
                 WHERE employment_id=%L', v_employment),
        'ILLEGAL_STATE_TRANSITION');

    -- ERD §42 Rule 4: a second overlapping PRIMARY assignment.
    v_results := v_results || pg_temp.expect_failure(
        'ERD 42.4 second primary assignment',
        format('INSERT INTO workforce.employee_assignments
                  (tenant_id, company_id, employment_id, employee_id, position_id, org_unit_id,
                   assignment_type_id, allocation_percentage, is_primary, status, start_date)
                VALUES (%L,%L,%L,%L,%L,%L,%L,100,true,''PLANNED'',DATE ''2026-06-01'')',
               v_tenant, v_company, v_employment, v_employee, v_position, v_dept, v_asg_project),
        'ex_one_primary_assignment');

    -- ERD §42 Rule 3: project allocation pushing the total past 100%.
    -- Force the deferred cap trigger to fire per-statement so it can be caught here.
    SET CONSTRAINTS workforce.tg_assignment_allocation_cap IMMEDIATE;
    v_results := v_results || pg_temp.expect_failure(
        'ERD 42.3 project allocation over 100%',
        format('INSERT INTO workforce.employee_assignments
                  (tenant_id, company_id, employment_id, employee_id, position_id, org_unit_id,
                   assignment_type_id, allocation_percentage, is_primary, status, start_date)
                VALUES (%L,%L,%L,%L,%L,%L,%L,40,false,''PLANNED'',DATE ''2026-01-01'')',
               v_tenant, v_company, v_employment, v_employee, v_position, v_dept, v_asg_project),
        'ALLOCATION_OVER_CAP');

    SET CONSTRAINTS ALL DEFERRED;

    -- ERD §23: denormalised employee_id must match the employment.
    v_results := v_results || pg_temp.expect_failure(
        'ERD 23   assignment employee/employment mismatch',
        format('INSERT INTO workforce.employee_assignments
                  (tenant_id, company_id, employment_id, employee_id, position_id, org_unit_id,
                   assignment_type_id, allocation_percentage, is_primary, status, start_date)
                VALUES (%L,%L,%L,%L,%L,%L,%L,10,false,''PLANNED'',DATE ''2027-01-01'')',
               v_tenant, v_company, v_employment, gen_random_uuid(), v_position, v_dept, v_asg_project),
        'ASSIGNMENT_EMPLOYEE_MISMATCH');

    -- ERD §42 Rule 5 / §43: two live contracts overlapping in time.
    v_results := v_results || pg_temp.expect_failure(
        'ERD 42.5 overlapping active contracts',
        format('INSERT INTO personnel.employment_contracts
                  (tenant_id, company_id, employment_id, contract_number, contract_type_id,
                   start_date, status, signed_date)
                SELECT %L,%L,%L,''EGY-CTR-99999'', reference_value_id,
                       DATE ''2026-06-01'', ''PENDING_SIGNATURE'', DATE ''2026-05-01''
                  FROM config.reference_values
                 WHERE tenant_id=%L AND reference_type_code=''CONTRACT_TYPE''
                   AND value_code=''RENEWAL''',
               v_tenant, v_company, v_employment, v_tenant),
        'ex_no_overlapping_contract');


    RAISE NOTICE E'\n%', array_to_string(v_results, E'\n');
END $t$;
