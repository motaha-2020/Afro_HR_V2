-- =============================================================================
-- Afro_HR_V2 — V013 : Point-in-time access
-- Source: ERD v1.0 §44-§45 — "if we ran payroll for Jan 2027 and asked which
-- department the employee was in during June 2026, the database must answer."
-- =============================================================================

-- Full workforce picture as it stood on any given date.
CREATE OR REPLACE FUNCTION workforce.workforce_as_of(p_as_of DATE DEFAULT current_date)
RETURNS TABLE (
    tenant_id        UUID,
    company_id       UUID,
    employee_id      UUID,
    employee_code    TEXT,
    display_name     TEXT,
    employment_id    UUID,
    employment_status TEXT,
    hire_date        DATE,
    assignment_id    UUID,
    position_id      UUID,
    position_code    TEXT,
    job_title_en     TEXT,
    org_unit_id      UUID,
    org_unit_name    TEXT,
    project_id       UUID,
    project_name     TEXT,
    allocation_percentage NUMERIC,
    is_primary       BOOLEAN,
    grade_code       TEXT,
    manager_employee_id UUID
)
LANGUAGE sql STABLE AS $fn$
    SELECT e.tenant_id,
           em.company_id,
           e.employee_id,
           e.employee_code::text,
           e.display_name::text,
           em.employment_id,
           em.employment_status::text,
           em.hire_date,
           a.assignment_id,
           a.position_id,
           p.position_code::text,
           j.job_title_en::text,
           a.org_unit_id,
           ou.name_en::text,
           a.project_id,
           pr.project_name::text,
           a.allocation_percentage,
           a.is_primary,
           g.grade_code::text,
           a.manager_employee_id
      FROM core_hr.employments em
      JOIN core_hr.employees   e  ON e.employee_id = em.employee_id
      LEFT JOIN workforce.employee_assignments a
             ON a.employment_id = em.employment_id
            AND a.validity @> p_as_of
            AND a.status IN ('ACTIVE','SUSPENDED')
      LEFT JOIN org.positions p          ON p.position_id  = a.position_id
      LEFT JOIN org.jobs j               ON j.job_id       = p.job_id
      LEFT JOIN org.organization_units ou ON ou.org_unit_id = a.org_unit_id
      LEFT JOIN org.grades g             ON g.grade_id     = p.grade_id
      LEFT JOIN integration.project_references pr ON pr.project_id = a.project_id
     WHERE em.validity @> p_as_of
       AND em.employment_status NOT IN ('DRAFT','CLOSED');
$fn$;

-- The compensation package that was in force on a given date (payroll's entry point).
CREATE OR REPLACE FUNCTION compensation.package_as_of(
    p_employment_id UUID,
    p_as_of DATE DEFAULT current_date
) RETURNS TABLE (
    employee_compensation_id UUID,
    currency_code   TEXT,
    component_code  TEXT,
    component_type  TEXT,
    calculation_type TEXT,
    amount          NUMERIC,
    percentage      NUMERIC,
    rate            NUMERIC,
    quantity        NUMERIC,
    taxable         BOOLEAN,
    social_insurance_applicable BOOLEAN
)
LANGUAGE sql STABLE AS $fn$
    SELECT ec.employee_compensation_id,
           ec.currency_code::text,
           sc.component_code::text,
           sc.component_type::text,
           cc.calculation_type::text,
           cc.amount,
           cc.percentage,
           cc.rate,
           cc.quantity,
           cc.taxable,
           cc.social_insurance_applicable
      FROM compensation.employee_compensations ec
      JOIN compensation.employee_compensation_components cc
        ON cc.employee_compensation_id = ec.employee_compensation_id
       AND daterange(cc.effective_from, cc.effective_to, '[)') @> p_as_of
      JOIN compensation.salary_components sc ON sc.component_id = cc.component_id
     WHERE ec.employment_id = p_employment_id
       AND ec.status = 'APPROVED'
       AND ec.validity @> p_as_of
     ORDER BY sc.sort_order, sc.component_code;
$fn$;

-- Org chart walked from positions (ERD §13), resolved to the people in them.
CREATE OR REPLACE VIEW org.v_org_chart AS
WITH RECURSIVE chart AS (
    SELECT p.position_id, p.tenant_id, p.company_id, p.position_code,
           p.reports_to_position_id, 1 AS depth,
           ARRAY[p.position_code::text] AS path
      FROM org.positions p
     WHERE p.reports_to_position_id IS NULL AND p.status <> 'CLOSED'
    UNION ALL
    SELECT c2.position_id, c2.tenant_id, c2.company_id, c2.position_code,
           c2.reports_to_position_id, chart.depth + 1,
           chart.path || c2.position_code::text
      FROM org.positions c2
      JOIN chart ON c2.reports_to_position_id = chart.position_id
     WHERE c2.status <> 'CLOSED' AND chart.depth < 64
)
SELECT chart.*,
       j.job_title_en,
       ou.name_en AS org_unit_name,
       e.employee_id AS incumbent_employee_id,
       e.display_name AS incumbent_name
  FROM chart
  JOIN org.positions p ON p.position_id = chart.position_id
  JOIN org.jobs j ON j.job_id = p.job_id
  JOIN org.organization_units ou ON ou.org_unit_id = p.org_unit_id
  LEFT JOIN workforce.employee_assignments a
         ON a.position_id = chart.position_id AND a.is_primary
        AND a.status = 'ACTIVE' AND a.validity @> current_date
  LEFT JOIN core_hr.employees e ON e.employee_id = a.employee_id;
