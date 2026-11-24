-- =====================================================================
-- DocpreneurFin Pro — useful SQL queries (for DBeaver / Supabase SQL Editor)
--
-- How to use
--   * Run ONE query at a time: put the cursor inside it and press Ctrl+Enter.
--   * Replace  'XXXX-XXXX-XXXX-XXXX'  with a real Application Code
--     (e.g. '6TRY-PVW4-8G9H-DPDY'). Codes are stored in upper case with dashes.
--   * Sections 1–8 only READ data. Section 9 CHANGES / DELETES data — there is
--     no undo, so read the comment above each query first.
-- =====================================================================


-- =====================================================================
-- 1. APPLICATIONS — overview
-- =====================================================================

-- 1.1 All applications, newest first
select application_code, application_id, facility_name, facility_type, service,
       status, current_step, project_cost, created_at, updated_at
  from dpr_applications
 order by updated_at desc;

-- 1.2 How many applications per status (draft / generated / downloaded)
select status, count(*) as applications
  from dpr_applications
 group by status
 order by applications desc;

-- 1.3 Applications created per day (last 30 days)
select created_at::date as day, count(*) as applications
  from dpr_applications
 where created_at > now() - interval '30 days'
 group by 1
 order by 1 desc;

-- 1.4 One application — master record
select application_code, application_id, user_id, facility_name, facility_type, service,
       status, current_step, completed_steps, project_cost, created_at, updated_at
  from dpr_applications
 where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 1.5 Find an application by facility name, contact name, phone or email
select application_code, facility_name,
       form_data->>'contact' as contact, form_data->>'phone' as phone, form_data->>'email' as email,
       status, updated_at
  from dpr_applications
 where facility_name ilike '%hospital%'
    or form_data->>'contact' ilike '%hospital%'
    or form_data->>'phone'   like  '%9004%'
    or form_data->>'email'   ilike '%@gmail.com%'
 order by updated_at desc;


-- =====================================================================
-- 2. FORM FIELDS — every answer of one application
-- =====================================================================

-- 2.1 All answers of one application, in step order (Step 1 … Step 8)
select section_no as step, section_name, subtask, field_label, field_value
  from dpr_application_forms
 where application_code = 'XXXX-XXXX-XXXX-XXXX'
 order by section_no, sort_order;

-- 2.2 Only the answers that were filled in
select section_no as step, field_label, field_value
  from dpr_application_forms
 where application_code = 'XXXX-XXXX-XXXX-XXXX'
   and field_value is not null
 order by section_no, sort_order;

-- 2.3 Answers of one step only (change the step number)
select field_label, field_value
  from dpr_application_forms
 where application_code = 'XXXX-XXXX-XXXX-XXXX'
   and section_no = 7
 order by sort_order;

-- 2.4 One field across ALL applications (e.g. CIBIL score)
select application_code, field_value as cibil_score
  from dpr_application_forms
 where field_key = 'cibil'
 order by application_code;

-- 2.5 Which fields belong to which step (field dictionary)
select section_no as step, section_name, subtask, field_key, field_label, optional
  from dpr_field_map
 order by section_no, sort_order;

-- 2.6 Required fields still empty in one application
select m.section_no as step, m.field_label
  from dpr_field_map m
  left join dpr_application_forms f
         on f.field_key = m.field_key and f.application_code = 'XXXX-XXXX-XXXX-XXXX'
 where not m.optional
   and f.field_value is null
 order by m.section_no, m.sort_order;


-- =====================================================================
-- 3. STEP TABLES — answers in their own columns
-- =====================================================================

-- 3.1 Facility & applicant (Step 1)
select * from dpr_step01_basic_info       where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.2 Promoters / doctors (Step 2) — one row per person
select * from dpr_step02_members          where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.3 Services & capacity (Step 3)
select * from dpr_step03_medical_services where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.4 Equipment list + vendor (Step 5)
select * from dpr_step04_equipment        where application_code = 'XXXX-XXXX-XXXX-XXXX';
select * from dpr_step04_equipment_vendor where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.5 Market & SWOT (Step 4)
select * from dpr_step05_market           where application_code = 'XXXX-XXXX-XXXX-XXXX';
select * from dpr_step10_swot             where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.6 Staff (Step 5) — one row per category
select * from dpr_step06_staff            where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.7 Premises & project cost / means of finance (Step 6)
select * from dpr_step07_cost_finance     where application_code = 'XXXX-XXXX-XXXX-XXXX';
select * from dpr_step09_infrastructure   where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.8 5-year projections (Step 7) — one row per year
select year_no, bed_occupancy_pct, opd_growth_pct, total_revenue, operating_expenses,
       ebitda, interest, depreciation, net_profit, dscr
  from dpr_step08_projections
 where application_code = 'XXXX-XXXX-XXXX-XXXX'
 order by year_no;

-- 3.9 Credit standing (Step 7)
select * from dpr_step12_credit           where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.10 Licences, community impact, declaration (Step 8)
select * from dpr_step13_licences         where application_code = 'XXXX-XXXX-XXXX-XXXX';
select * from dpr_step11_community_impact where application_code = 'XXXX-XXXX-XXXX-XXXX';
select * from dpr_step14_declaration      where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.11 Photos (Step 8) — storage paths of uploaded photos
select * from dpr_step13_images           where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 3.12 Which step table holds how many field columns
select * from dpr_form_tables;


-- =====================================================================
-- 4. PDF DOCUMENTS
-- =====================================================================

-- 4.1 All PDFs of one application
select file_name, document_type, page_count,
       round(size_bytes / 1024.0, 1) as size_kb, uploaded_at, storage_path
  from dpr_application_documents
 where application_code = 'XXXX-XXXX-XXXX-XXXX'
 order by uploaded_at desc;

-- 4.2 All PDFs, all applications
select application_code, file_name, document_type, page_count,
       round(size_bytes / 1024.0, 1) as size_kb, uploaded_at
  from dpr_application_documents
 order by uploaded_at desc;

-- 4.3 PDF count and total size per application
select application_code, count(*) as pdfs, round(sum(size_bytes) / 1048576.0, 2) as total_mb
  from dpr_application_documents
 group by application_code
 order by pdfs desc;

-- 4.4 PDFs per document type
select coalesce(document_type, '(not selected)') as document_type, count(*) as pdfs
  from dpr_application_documents
 group by 1
 order by pdfs desc;

-- 4.5 Check: every PDF record has its file in storage, with the same size
select d.application_code, d.file_name,
       (o.name is not null)                                  as file_in_storage,
       ((o.metadata->>'size')::bigint = d.size_bytes)        as size_matches
  from dpr_application_documents d
  left join storage.objects o on o.bucket_id = 'dpr-documents' and o.name = d.storage_path
 order by d.application_code, d.file_name;

-- 4.6 Check: files in storage WITHOUT a database record (orphans)
select o.name, o.created_at, (o.metadata->>'size')::bigint as size_bytes
  from storage.objects o
 where o.bucket_id = 'dpr-documents'
   and not exists (select 1 from dpr_application_documents d where d.storage_path = o.name);


-- =====================================================================
-- 5. USERS & "MY APPLICATIONS"
-- =====================================================================

-- 5.1 All signed-in users
select user_id, email, full_name, phone, created_at, last_seen_at
  from dpr_users
 order by created_at desc;

-- 5.2 Users and their Application Codes
select * from dpr_user_applications;

-- 5.3 Number of applications per user
select u.email, count(a.application_id) as applications
  from dpr_users u
  left join dpr_applications a on a.user_id = u.user_id
 group by u.email
 order by applications desc;

-- 5.4 Applications not linked to any user (filled without signing in)
select application_code, facility_name, updated_at
  from dpr_applications
 where user_id is null
 order by updated_at desc;


-- =====================================================================
-- 6. REPORTS / BUSINESS NUMBERS
-- =====================================================================

-- 6.1 Project cost, loan and CIBIL per application
select a.application_code, a.facility_name,
       c.total_project_cost, c.bank_loan_final, c.promoter_contribution_final, c.funding_gap,
       cr.cibil_score
  from dpr_applications a
  left join dpr_step07_cost_finance c  on c.application_code  = a.application_code
  left join dpr_step12_credit       cr on cr.application_code = a.application_code
 order by c.total_project_cost desc nulls last;

-- 6.2 Applications by state and facility type
select form_data->>'state' as state, facility_type, count(*) as applications
  from dpr_applications
 group by 1, 2
 order by applications desc;

-- 6.3 Applications by DPR service (Bank Loan / Subsidy / Investor)
select service, count(*) as applications
  from dpr_applications
 group by service;

-- 6.4 Report downloads
select a.application_code, a.facility_name, d.status, d.email_verified, d.phone_verified,
       d.download_count, d.generated_at, d.last_downloaded_at
  from dpr_applications a
  join dpr_step14_declaration d on d.application_code = a.application_code
 order by d.last_downloaded_at desc nulls last;

-- 6.5 Website enquiries
select * from inquiries order by 1 desc;


-- =====================================================================
-- 7. HEALTH CHECKS — is everything saved and linked?
-- =====================================================================

-- 7.1 Row count of every DPR table
select t.table_name,
       (xpath('/row/c/text()', query_to_xml(format('select count(*) c from public.%I', t.table_name), false, true, '')))[1]::text::int as rows
  from information_schema.tables t
 where t.table_schema = 'public' and t.table_type = 'BASE TABLE' and t.table_name like 'dpr%'
 order by t.table_name;

-- 7.2 Every saved answer is in dpr_application_forms with the same value
--     (mismatched should be 'none' for every application)
with k as (
  select a.application_code, e.key, e.value
    from dpr_applications a, jsonb_each(a.form_data) e
   where left(e.key, 1) <> '_' and e.key not in ('done', 'verified', 'lang'))
select k.application_code,
       count(*)                                          as answers_saved,
       count(*) filter (where f.value_json = k.value)    as values_match,
       coalesce(string_agg(case when f.value_json is distinct from k.value then k.key end, ', '), 'none') as mismatched
  from k
  left join dpr_application_forms f on f.application_code = k.application_code and f.field_key = k.key
 group by k.application_code;

-- 7.3 Every application has a row in each main step table
select a.application_code,
       exists (select 1 from dpr_step01_basic_info   s where s.application_code = a.application_code) as step1,
       exists (select 1 from dpr_step07_cost_finance s where s.application_code = a.application_code) as cost,
       exists (select 1 from dpr_step12_credit       s where s.application_code = a.application_code) as credit,
       exists (select 1 from dpr_step14_declaration  s where s.application_code = a.application_code) as declaration
  from dpr_applications a;

-- 7.4 Fields saved by the website that have no step label yet (should return nothing)
select distinct field_key
  from dpr_application_forms
 where section_no = 0;

-- 7.5 Storage areas and file counts
select b.id as bucket, b.public, b.file_size_limit / 1048576 as max_mb, b.allowed_mime_types,
       (select count(*) from storage.objects o where o.bucket_id = b.id) as files
  from storage.buckets b
 order by b.id;


-- =====================================================================
-- 8. DATABASE STRUCTURE
-- =====================================================================

-- 8.1 Columns of one table (change the table name)
select column_name, data_type, is_nullable
  from information_schema.columns
 where table_schema = 'public' and table_name = 'dpr_applications'
 order by ordinal_position;

-- 8.2 Foreign keys (how tables are linked)
select conrelid::regclass as from_table, confrelid::regclass as to_table, conname as link_name
  from pg_constraint
 where contype = 'f' and connamespace = 'public'::regnamespace
 order by 1::text, 2::text;

-- 8.3 Functions the website may call
select p.proname as function_name, pg_get_function_identity_arguments(p.oid) as arguments
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace
   and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
 order by 1;


-- =====================================================================
-- 9. CHANGES & DELETES — careful, there is NO undo
-- =====================================================================

-- 9.1 Delete ONE application and all its form data (step tables, forms, PDF records).
--     PDF / photo FILES stay in storage — remove them in Supabase → Storage → dpr-documents /
--     dpr-images (folder = the application_id), or delete from the website instead.
-- delete from dpr_applications where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 9.2 Change an application's status (draft / generated / downloaded)
-- update dpr_applications set status = 'draft' where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 9.3 Link an application to a user (by the user's email)
-- update dpr_applications
--    set user_id = (select user_id from dpr_users where email = 'name@example.com')
--  where application_code = 'XXXX-XXXX-XXXX-XXXX';

-- 9.4 Delete applications not changed for 90 days that were never completed
-- delete from dpr_applications where status = 'draft' and updated_at < now() - interval '90 days';

-- 9.5 Delete ALL DPR data (all applications, answers, PDF records, users) — files stay in storage
-- begin;
-- delete from dpr_application_documents;
-- delete from dpr_application_forms;
-- delete from dpr_applications;
-- delete from dpr_deleted;
-- delete from dpr_delete_grants;
-- delete from dpr_users;
-- commit;
