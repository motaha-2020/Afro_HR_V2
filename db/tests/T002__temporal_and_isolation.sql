-- =============================================================================
-- Afro_HR_V2 — Temporal correctness (ERD §44/§45) and tenant isolation.
-- =============================================================================
SET client_min_messages TO WARNING;

DO $t$
DECLARE
    v_tenant UUID; v_company UUID; v_employment UUID; v_user UUID; v_pkg UUID;
    v_basic UUID; v_freq UUID; v_reason UUID; v_grade UUID;
    v_jun NUMERIC; v_sep NUMERIC;
    v_other_tenant UUID; v_visible INT;
BEGIN
    SELECT tenant_id INTO v_tenant FROM platform.tenants WHERE tenant_code='AFRO';
    SELECT user_id  INTO v_user  FROM identity.users WHERE username='system';
    CALL platform.set_context(v_tenant, v_user, true);

    SELECT company_id INTO v_company FROM platform.companies WHERE company_code='AFRO-EGY';
    SELECT employment_id INTO v_employment FROM core_hr.employments LIMIT 1;
    SELECT component_id INTO v_basic FROM compensation.salary_components WHERE component_code='BASIC';
    SELECT grade_id INTO v_grade FROM org.grades WHERE grade_code='G6';
    SELECT reference_value_id INTO v_freq FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='PAY_FREQUENCY' AND value_code='MONTHLY';
    SELECT reference_value_id INTO v_reason FROM config.reference_values
     WHERE tenant_id=v_tenant AND reference_type_code='COMPENSATION_REASON' AND value_code='ANNUAL_REVIEW';

    -- ERD §44: a raise does not UPDATE the old figure; it closes it and opens a new one.
    UPDATE compensation.employee_compensations
       SET effective_to = DATE '2026-08-01'
     WHERE employment_id = v_employment AND status='APPROVED' AND effective_to IS NULL;

    INSERT INTO compensation.employee_compensations
        (tenant_id, company_id, employment_id, currency_code, pay_frequency_id, grade_id,
         reason_id, effective_from, status, approved_by, approved_at)
    VALUES (v_tenant, v_company, v_employment, 'EGP', v_freq, v_grade, v_reason,
            DATE '2026-08-01', 'APPROVED', v_user, now())
    RETURNING employee_compensation_id INTO v_pkg;

    INSERT INTO compensation.employee_compensation_components
        (tenant_id, employee_compensation_id, component_id, calculation_type, amount,
         taxable, social_insurance_applicable, effective_from)
    VALUES (v_tenant, v_pkg, v_basic, 'FIXED', 25000, true, true, DATE '2026-08-01');

    -- ERD §45: the database must still answer "what was it in June?"
    SELECT amount INTO v_jun FROM compensation.package_as_of(v_employment, DATE '2026-06-15')
     WHERE component_code='BASIC';
    SELECT amount INTO v_sep FROM compensation.package_as_of(v_employment, DATE '2026-09-15')
     WHERE component_code='BASIC';

    IF v_jun = 20000 AND v_sep = 25000 THEN
        RAISE NOTICE 'PASS  ERD 45   point-in-time salary: Jun=% Sep=%', v_jun, v_sep;
    ELSE
        RAISE NOTICE 'FAIL  ERD 45   point-in-time salary: Jun=% Sep=% (expected 20000 / 25000)', v_jun, v_sep;
    END IF;

    -- Workforce snapshot resolves the whole chain on a date.
    PERFORM 1 FROM workforce.workforce_as_of(DATE '2026-06-15')
      WHERE employment_id = v_employment AND job_title_en = 'Project Manager';
    IF FOUND THEN
        RAISE NOTICE 'PASS  ERD 45   workforce_as_of resolves position/job/org unit';
    ELSE
        RAISE NOTICE 'FAIL  ERD 45   workforce_as_of returned no row';
    END IF;

    -- Tenant isolation: a second tenant must see none of Afro's people.
    INSERT INTO platform.tenants (tenant_code, tenant_name, default_timezone)
    VALUES ('OTHER', 'Other Group', 'Africa/Cairo')
    ON CONFLICT (tenant_code) DO UPDATE SET tenant_name = EXCLUDED.tenant_name
    RETURNING tenant_id INTO v_other_tenant;

    CALL platform.set_context(v_other_tenant, NULL, false);
    SELECT count(*) INTO v_visible FROM core_hr.employees;
    IF v_visible = 0 THEN
        RAISE NOTICE 'PASS  RLS      other tenant sees 0 employees';
    ELSE
        RAISE NOTICE 'FAIL  RLS      other tenant sees % employees', v_visible;
    END IF;

    CALL platform.set_context(v_tenant, v_user, false);
    SELECT count(*) INTO v_visible FROM core_hr.employees;
    IF v_visible > 0 THEN
        RAISE NOTICE 'PASS  RLS      own tenant sees % employees', v_visible;
    ELSE
        RAISE NOTICE 'FAIL  RLS      own tenant sees 0 employees';
    END IF;

    -- Audit trail captured the compensation change.
    CALL platform.set_context(v_tenant, v_user, true);
    SELECT count(*) INTO v_visible FROM audit.change_log
     WHERE table_name = 'employee_compensations';
    IF v_visible > 0 THEN
        RAISE NOTICE 'PASS  ERD 46   audit captured % compensation changes', v_visible;
    ELSE
        RAISE NOTICE 'FAIL  ERD 46   audit captured nothing';
    END IF;

    SELECT count(*) INTO v_visible FROM audit.event_outbox WHERE event_type='EmployeeActivated';
    IF v_visible > 0 THEN
        RAISE NOTICE 'PASS  Events   EmployeeActivated emitted to outbox';
    ELSE
        RAISE NOTICE 'FAIL  Events   no EmployeeActivated event';
    END IF;
END $t$;
