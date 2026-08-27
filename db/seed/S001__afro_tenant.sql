-- =============================================================================
-- Afro_HR_V2 — Seed : Afro Group tenant, Afro Egypt company, reference data
-- Derived from the People & Culture Org-Chart and Operations Manual.
-- =============================================================================
SET client_min_messages TO WARNING;

DO $seed$
DECLARE
    v_tenant  UUID;
    v_company UUID;
BEGIN
    INSERT INTO platform.tenants (tenant_code, tenant_name, default_language, default_timezone)
    VALUES ('AFRO', 'Afro Group', 'en', 'Africa/Cairo')
    RETURNING tenant_id INTO v_tenant;

    CALL platform.set_context(v_tenant, NULL, true);

    INSERT INTO platform.companies
        (tenant_id, company_code, legal_name, display_name, country_code,
         base_currency, effective_from)
    VALUES (v_tenant, 'AFRO-EGY', 'Afro Telecom Contracting S.A.E.', 'Afro Egypt',
            'EGY', 'EGP', DATE '2020-01-01')
    RETURNING company_id INTO v_company;

    INSERT INTO platform.number_sequences
        (tenant_id, company_id, sequence_code, prefix, padding, next_number)
    VALUES
        (v_tenant, v_company, 'EMPLOYEE_CODE', 'AFR-EGY-EMP-', 6, 1),
        (v_tenant, v_company, 'POSITION_CODE', 'EGY-POS-',     4, 1),
        (v_tenant, v_company, 'CONTRACT_NO',   'EGY-CTR-',     5, 1),
        (v_tenant, v_company, 'EMPLOYMENT_NO', 'EGY-EMPL-',    5, 1);

    -- Reference values -------------------------------------------------------
    INSERT INTO config.reference_values (tenant_id, reference_type_code, value_code, name_en, name_ar, sort_order, is_system)
    VALUES
      (v_tenant,'ORG_UNIT_TYPE','SECTOR','Sector','قطاع',10,true),
      (v_tenant,'ORG_UNIT_TYPE','DEPARTMENT','Department','إدارة',20,true),
      (v_tenant,'ORG_UNIT_TYPE','SECTION','Section','قسم',30,true),
      (v_tenant,'ORG_UNIT_TYPE','TEAM','Team','فريق',40,true),
      (v_tenant,'ORG_UNIT_TYPE','PROJECT_OFFICE','Project Office','مكتب مشروع',50,true),

      (v_tenant,'EMPLOYMENT_TYPE','PERMANENT','Permanent','دائم',10,true),
      (v_tenant,'EMPLOYMENT_TYPE','FIXED_TERM','Fixed Term','محدد المدة',20,true),
      (v_tenant,'EMPLOYMENT_TYPE','PROJECT_BASED','Project Based','على المشروع',30,true),
      (v_tenant,'EMPLOYMENT_TYPE','DAILY_WORKER','Daily Worker','عامل يومية',40,true),
      (v_tenant,'EMPLOYMENT_TYPE','OUTSOURCED','Outsourced','إسناد خارجي',50,true),
      (v_tenant,'EMPLOYMENT_TYPE','INTERN','Intern','متدرب',60,true),
      (v_tenant,'EMPLOYMENT_TYPE','CONSULTANT','Consultant','استشاري',70,true),

      (v_tenant,'WORKER_CATEGORY','WHITE_COLLAR','White Collar','إداري',10,true),
      (v_tenant,'WORKER_CATEGORY','BLUE_COLLAR','Blue Collar','عمالة فنية',20,true),

      (v_tenant,'ASSIGNMENT_TYPE','PRIMARY','Primary','أساسي',10,true),
      (v_tenant,'ASSIGNMENT_TYPE','PROJECT','Project','مشروع',20,true),
      (v_tenant,'ASSIGNMENT_TYPE','SITE','Site','موقع',30,true),
      (v_tenant,'ASSIGNMENT_TYPE','ACTING','Acting','بالإنابة',40,true),
      (v_tenant,'ASSIGNMENT_TYPE','SECONDMENT','Secondment','إعارة',50,true),

      (v_tenant,'IDENTIFIER_TYPE','NATIONAL_ID','National ID','الرقم القومي',10,true),
      (v_tenant,'IDENTIFIER_TYPE','PASSPORT','Passport','جواز سفر',20,true),
      (v_tenant,'IDENTIFIER_TYPE','SOCIAL_INSURANCE','Social Insurance No.','رقم التأمين',30,true),
      (v_tenant,'IDENTIFIER_TYPE','WORK_PERMIT','Work Permit','تصريح عمل',40,true),
      (v_tenant,'IDENTIFIER_TYPE','ENGINEERS_SYNDICATE','Engineers Syndicate','نقابة المهندسين',50,true),
      (v_tenant,'IDENTIFIER_TYPE','TECHNICIAN_LICENSE','Technician License','رخصة فني',60,true),

      (v_tenant,'CONTRACT_TYPE','ORIGINAL','Original Contract','عقد أصلي',10,true),
      (v_tenant,'CONTRACT_TYPE','RENEWAL','Renewal','تجديد',20,true),
      (v_tenant,'CONTRACT_TYPE','AMENDMENT','Amendment','ملحق',30,true),

      (v_tenant,'TERMINATION_REASON','RESIGNATION','Resignation','استقالة',10,true),
      (v_tenant,'TERMINATION_REASON','END_OF_CONTRACT','End of Contract','انتهاء العقد',20,true),
      (v_tenant,'TERMINATION_REASON','DISMISSAL','Dismissal','فصل',30,true),
      (v_tenant,'TERMINATION_REASON','RETIREMENT','Retirement','تقاعد',40,true),

      (v_tenant,'PAY_FREQUENCY','MONTHLY','Monthly','شهري',10,true),
      (v_tenant,'PAY_FREQUENCY','DAILY','Daily','يومي',20,true),

      (v_tenant,'COMPENSATION_REASON','HIRING','Hiring','تعيين',10,true),
      (v_tenant,'COMPENSATION_REASON','ANNUAL_REVIEW','Annual Review','مراجعة سنوية',20,true),
      (v_tenant,'COMPENSATION_REASON','PROMOTION','Promotion','ترقية',30,true),

      (v_tenant,'POSITION_TYPE','PERMANENT_HC','Permanent Headcount','عمالة دائمة',10,true),
      (v_tenant,'POSITION_TYPE','PROJECT_HC','Project Headcount','عمالة مشروع',20,true),

      (v_tenant,'CONTACT_TYPE','MOBILE','Mobile','موبايل',10,true),
      (v_tenant,'CONTACT_TYPE','WORK_EMAIL','Work Email','بريد العمل',20,true),
      (v_tenant,'ADDRESS_TYPE','PERMANENT','Permanent','دائم',10,true),
      (v_tenant,'ADDRESS_TYPE','CURRENT','Current','حالي',20,true),
      (v_tenant,'RELATIONSHIP_TYPE','SPOUSE','Spouse','زوج/زوجة',10,true),
      (v_tenant,'RELATIONSHIP_TYPE','SON','Son','ابن',20,true),
      (v_tenant,'RELATIONSHIP_TYPE','DAUGHTER','Daughter','ابنة',30,true);

    RAISE NOTICE 'Seeded tenant % / company %', v_tenant, v_company;
END $seed$;

-- System user used as the actor for seeded/automated changes.
INSERT INTO identity.users (tenant_id, username, email, display_name, user_type, status)
VALUES (NULL, 'system', 'system@afro.local', 'System', 'SYSTEM', 'ACTIVE')
ON CONFLICT DO NOTHING;
