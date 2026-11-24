-- =====================================================================
-- DocpreneurFin Pro — Users, Application Forms and Application Documents
--
-- Run in Supabase → SQL Editor AFTER migrate_application_master.sql.
-- Safe to re-run. Everything runs in ONE transaction. No data is dropped.
--
-- Database structure after this migration
--   dpr_users                  one row per signed-in user (Supabase Auth)
--      └─< dpr_applications    application_id (PK) + application_code (unique) + user_id
--             ├─< dpr_application_forms      every form field + value, with its step & subtask
--             ├─< dpr_application_documents  uploaded PDFs + metadata (PDF only)
--             └─< dpr_stepNN_*               existing per-step tables (unchanged)
--
--   * One user → many applications. Every application has its own
--     application_id and application_code; nothing is shared between them.
--   * Deleting an application deletes its forms and documents rows (cascade).
--   * The website never reads tables directly. It uses the functions below:
--       anon or signed in : add_dpr_document, list_dpr_documents
--       signed in only    : dpr_touch_user, claim_dpr, my_applications, open_my_application
-- =====================================================================
begin;

-- ---------- 1. users ----------
create table if not exists public.dpr_users (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  email         text,
  full_name     text,
  phone         text,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);
create unique index if not exists dpr_users_email_idx on public.dpr_users (lower(email));
alter table public.dpr_users enable row level security;   -- no policies: read through functions only

-- create the dpr_users row as soon as someone signs up with Supabase Auth
create or replace function public.dpr_on_auth_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.dpr_users(user_id, email) values (new.id, lower(new.email))
  on conflict (user_id) do update set email = excluded.email;
  return new;
end;
$$;
drop trigger if exists dpr_on_auth_user_trg on auth.users;
create trigger dpr_on_auth_user_trg after insert or update of email on auth.users
  for each row execute function public.dpr_on_auth_user();

-- users who signed up before this migration
insert into public.dpr_users(user_id, email)
select id, lower(email) from auth.users
on conflict (user_id) do nothing;

-- ---------- 2. application: code + owner ----------
alter table public.dpr_applications
  add column if not exists user_id uuid references public.dpr_users(user_id) on delete set null;
create index if not exists dpr_applications_user_idx on public.dpr_applications (user_id, updated_at desc);

-- the Application Code shown to users, e.g. NATG-RXPW-MZR2-HT81 (always derived from the edit token)
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='dpr_applications' and column_name='application_code') then
    alter table public.dpr_applications add column application_code text
      generated always as (regexp_replace(public.dpr_norm_code(edit_token), '^(.{4})(.{4})(.{4})(.{4})$', '\1-\2-\3-\4')) stored;
  end if;
end $$;
create unique index if not exists dpr_applications_application_code_key on public.dpr_applications (application_code);

-- a new application saved by a signed-in user belongs to that user
create or replace function public.dpr_set_owner() returns trigger
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if new.user_id is null and uid is not null then
    insert into dpr_users(user_id, email) values (uid, lower(auth.jwt()->>'email'))
    on conflict (user_id) do update set last_seen_at = now();
    new.user_id := uid;
  end if;
  return new;
end;
$$;
drop trigger if exists dpr_set_owner_trg on public.dpr_applications;
create trigger dpr_set_owner_trg before insert on public.dpr_applications
  for each row execute function public.dpr_set_owner();

-- ---------- 3. application forms: every field, labelled with its step & subtask ----------
create table if not exists public.dpr_field_map (
  field_key     text primary key,
  section_no    int  not null,          -- step number in the website (1 … 7)
  section_name  text not null,          -- e.g. 'Declaration & Final Report'
  subtask       text,                   -- e.g. '5-Year Projections & Credit Standing'
  field_label   text not null,
  optional      boolean not null default false,
  sort_order    int  not null
);
alter table public.dpr_field_map enable row level security;

-- labels come from the website's form definition (regenerate when the form changes)
insert into public.dpr_field_map (field_key, section_no, section_name, subtask, field_label, optional, sort_order) values
('sector',1,'Facility & Applicant Details','Facility Type & Speciality Selection','1. Healthcare Segment',false,1),
('activity',1,'Facility & Applicant Details','Facility Type & Speciality Selection','2. Facility / Sub-Speciality',false,2),
('customActivity',1,'Facility & Applicant Details','Facility Type & Speciality Selection','Specify Custom Activity',false,3),
('classif',1,'Facility & Applicant Details','Facility Type & Speciality Selection','3. Project Classification',false,4),
('facility',1,'Facility & Applicant Details','Facility, Location & Contact','Facility / Hospital Name',false,5),
('entity',1,'Facility & Applicant Details','Facility, Location & Contact','Entity Type',false,6),
('town',1,'Facility & Applicant Details','Facility, Location & Contact','Village / Town / City',false,7),
('district',1,'Facility & Applicant Details','Facility, Location & Contact','District',false,8),
('state',1,'Facility & Applicant Details','Facility, Location & Contact','State',false,9),
('contact',1,'Facility & Applicant Details','Facility, Location & Contact','Contact Person Name',false,10),
('phone',1,'Facility & Applicant Details','Facility, Location & Contact','Contact Number',false,11),
('email',1,'Facility & Applicant Details','Facility, Location & Contact','Email Address',false,12),
('group',1,'Facility & Applicant Details','Organisation, Registrations & Bank','Group / Trust / Organisation Name',true,13),
('pin',1,'Facility & Applicant Details','Organisation, Registrations & Bank','PIN Code',true,14),
('overview',1,'Facility & Applicant Details','Organisation, Registrations & Bank','Project Overview',true,15),
('cea',1,'Facility & Applicant Details','Organisation, Registrations & Bank','Clinical Establishment Reg. No.',true,16),
('pan',1,'Facility & Applicant Details','Organisation, Registrations & Bank','PAN No.',true,17),
('gst',1,'Facility & Applicant Details','Organisation, Registrations & Bank','GST No.',true,18),
('udyam',1,'Facility & Applicant Details','Organisation, Registrations & Bank','MSME / Udyam No.',true,19),
('nabh',1,'Facility & Applicant Details','Organisation, Registrations & Bank','NABH / NABL Status',true,20),
('bankName',1,'Facility & Applicant Details','Organisation, Registrations & Bank','Existing Bank Name',true,21),
('branch',1,'Facility & Applicant Details','Organisation, Registrations & Bank','Bank Branch',true,22),
('ifsc',1,'Facility & Applicant Details','Organisation, Registrations & Bank','IFSC Code',true,23),
('members',2,'Promoter Doctors & Team','Promoter & Medical Team','Promoter & Medical Team',false,24),
('affil',2,'Promoter Doctors & Team','Clinical Experience & Hospital Affiliations','Past / Current Hospital Affiliations',true,25),
('depts',3,'Medical Services & Capacity','Departments, Beds & OPD','Departments / Specialities',false,26),
('beds',3,'Medical Services & Capacity','Departments, Beds & OPD','Total Beds (0 for OPD-only)',false,27),
('icu',3,'Medical Services & Capacity','Departments, Beds & OPD','ICU / HDU Beds',false,28),
('ots',3,'Medical Services & Capacity','Departments, Beds & OPD','Operation Theatres',false,29),
('opd',3,'Medical Services & Capacity','Departments, Beds & OPD','OPD Patients per Day (Year 1)',false,30),
('arpob',3,'Medical Services & Capacity','Tariff & Payer Mix','Avg Revenue per Occupied Bed per Day – ARPOB (₹)',false,31),
('opdRev',3,'Medical Services & Capacity','Tariff & Payer Mix','Avg OPD + Diagnostics Revenue per Patient (₹)',false,32),
('payer',3,'Medical Services & Capacity','Tariff & Payer Mix','Payer Mix',false,33),
('services',3,'Medical Services & Capacity','Procedures, USP & Revenue Assumptions','Key Procedures / Packages',true,34),
('usp',3,'Medical Services & Capacity','Procedures, USP & Revenue Assumptions','Unique Selling Proposition (USP)',true,35),
('opdDays',3,'Medical Services & Capacity','Procedures, USP & Revenue Assumptions','OPD Working Days per Year',true,36),
('growth',3,'Medical Services & Capacity','Procedures, USP & Revenue Assumptions','Annual Tariff / Volume Growth (%)',true,37),
('consum',3,'Medical Services & Capacity','Procedures, USP & Revenue Assumptions','Medicines & Consumables (% of Revenue)',true,38),
('catchPop',4,'Market, Catchment & SWOT','Catchment & Competition','Catchment Population (approx.)',false,39),
('catchKm',4,'Market, Catchment & SWOT','Catchment & Competition','Catchment Radius (km)',false,40),
('competitors',4,'Market, Catchment & SWOT','Catchment & Competition','Main Competing Facilities',false,41),
('segments',4,'Market, Catchment & SWOT','Patient Segments, Referrals & SWOT','Target Patient Segments',true,42),
('referral',4,'Market, Catchment & SWOT','Patient Segments, Referrals & SWOT','Referral Sources & Outreach',true,43),
('tpa',4,'Market, Catchment & SWOT','Patient Segments, Referrals & SWOT','Insurance / TPA / PM-JAY Empanelment Plan',true,44),
('sw_s',4,'Market, Catchment & SWOT','Patient Segments, Referrals & SWOT','Strengths',true,45),
('sw_w',4,'Market, Catchment & SWOT','Patient Segments, Referrals & SWOT','Weaknesses',true,46),
('sw_o',4,'Market, Catchment & SWOT','Patient Segments, Referrals & SWOT','Opportunities',true,47),
('sw_t',4,'Market, Catchment & SWOT','Patient Segments, Referrals & SWOT','Threats',true,48),
('equip',5,'Medical Equipment & Staffing','Medical Equipment Schedule','Medical Equipment Schedule',false,49),
('staff',5,'Medical Equipment & Staffing','Staffing & Monthly Payroll','Staffing & Monthly Payroll',false,50),
('vendor',5,'Medical Equipment & Staffing','Vendor, AMC & Consultant Fees','Primary Supplier Name',true,51),
('vendorLoc',5,'Medical Equipment & Staffing','Vendor, AMC & Consultant Fees','Supplier Location',true,52),
('aerb',5,'Medical Equipment & Staffing','Vendor, AMC & Consultant Fees','Radiation Equipment requiring AERB licence?',true,53),
('amc',5,'Medical Equipment & Staffing','Vendor, AMC & Consultant Fees','Annual Maintenance (AMC) % of Equipment Cost',true,54),
('visiting',5,'Medical Equipment & Staffing','Vendor, AMC & Consultant Fees','Visiting Consultant Fee Share (% of IPD revenue)',true,55),
('premises',6,'Premises, Project Cost & Finance','Premises & Timeline','Premises Status',false,56),
('area',6,'Premises, Project Cost & Finance','Premises & Timeline','Built-up Area (sq.ft.)',false,57),
('months',6,'Premises, Project Cost & Finance','Premises & Timeline','Time to Start Operations (months)',false,58),
('rent',6,'Premises, Project Cost & Finance','Premises & Timeline','Monthly Rent (₹)',false,59),
('land',6,'Premises, Project Cost & Finance','Total Project Cost (CAPEX)','Land Cost (₹)',false,60),
('building',6,'Premises, Project Cost & Finance','Total Project Cost (CAPEX)','Building & Civil Works (OT, ICU, Wards) (₹)',false,61),
('equipTotal',6,'Premises, Project Cost & Finance','Total Project Cost (CAPEX)','Medical Equipment Total (₹)',false,62),
('furniture',6,'Premises, Project Cost & Finance','Total Project Cost (CAPEX)','Furniture, Beds, IT & HIS Software (₹)',false,63),
('gases',6,'Premises, Project Cost & Finance','Total Project Cost (CAPEX)','Medical Gas Pipeline, Oxygen & DG Set (₹)',false,64),
('prelim',6,'Premises, Project Cost & Finance','Total Project Cost (CAPEX)','Pre-operative, Licensing & Preliminary (₹)',false,65),
('wc',6,'Premises, Project Cost & Finance','Total Project Cost (CAPEX)','Working Capital Margin (₹)',false,66),
('pcTotal',6,'Premises, Project Cost & Finance','Total Project Cost (CAPEX)','TOTAL PROJECT COST (₹)',false,67),
('loan',6,'Premises, Project Cost & Finance','Means of Finance','Bank Loan Required (₹)',false,68),
('promoter',6,'Premises, Project Cost & Finance','Means of Finance','Promoter Contribution (₹)',false,69),
('subsidy',6,'Premises, Project Cost & Finance','Means of Finance','Subsidy / Grant (₹)',false,70),
('mofCheck',6,'Premises, Project Cost & Finance','Means of Finance','Funding Balance Check',false,71),
('bank',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Primary Lending Bank',true,72),
('scheme',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Bank Loan Scheme',true,73),
('collateral',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Collateral Offered',true,74),
('morat',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Repayment Moratorium (Months)',true,75),
('tenure',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Repayment Tenure (Years)',true,76),
('rate',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Interest Rate % (p.a.)',true,77),
('schemeName',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Target Scheme',true,78),
('category',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Applicant Category',true,79),
('locType',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Project Location Type',true,80),
('raise',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Equity Raise Sought (₹)',true,81),
('dilution',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Equity Dilution Offered (%)',true,82),
('investorType',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Target Investor Type',true,83),
('useFunds',6,'Premises, Project Cost & Finance','DPR Service Specific Questions','Use of Funds',true,84),
('floors',6,'Premises, Project Cost & Finance','Building & Utilities','No. of Floors',true,85),
('lift',6,'Premises, Project Cost & Finance','Building & Utilities','Bed Lift Available?',true,86),
('power',6,'Premises, Project Cost & Finance','Building & Utilities','Power Required (KVA)',true,87),
('dg',6,'Premises, Project Cost & Finance','Building & Utilities','DG Backup (KVA)',true,88),
('o2',6,'Premises, Project Cost & Finance','Building & Utilities','Oxygen Source',true,89),
('water',6,'Premises, Project Cost & Finance','Building & Utilities','Water Required (L/day)',true,90),
('utilPct',6,'Premises, Project Cost & Finance','Building & Utilities','Utilities, Admin, Marketing & Insurance (% of Revenue)',true,91),
('declName',7,'Declaration & Final Report','Authorised Signatory Declaration','Declarant Name',false,92),
('declDesig',7,'Declaration & Final Report','Authorised Signatory Declaration','Designation',false,93),
('declPlace',7,'Declaration & Final Report','Authorised Signatory Declaration','Place',false,94),
('declOk',7,'Declaration & Final Report','Authorised Signatory Declaration','I confirm the information provided is true to the best of my knowledge',false,95),
('occ',7,'Declaration & Final Report','5-Year Projections & Credit Standing','Bed occupancy by year (%)',true,96),
('opdG',7,'Declaration & Final Report','5-Year Projections & Credit Standing','OPD growth by year (%)',true,97),
('cibil',7,'Declaration & Final Report','5-Year Projections & Credit Standing','CIBIL Score',true,98),
('existEmi',7,'Declaration & Final Report','5-Year Projections & Credit Standing','Existing Monthly EMI (₹)',true,99),
('prevLoan',7,'Declaration & Final Report','5-Year Projections & Credit Standing','Taken Loan Before?',true,100),
('default',7,'Declaration & Final Report','5-Year Projections & Credit Standing','Default History?',true,101),
('existLoan',7,'Declaration & Final Report','5-Year Projections & Credit Standing','Existing Loan Amount (₹)',true,102),
('outstanding',7,'Declaration & Final Report','5-Year Projections & Credit Standing','Outstanding Amount (₹)',true,103),
('lic',7,'Declaration & Final Report','Statutory Licences & Approvals','Approvals Obtained',true,104),
('images',7,'Declaration & Final Report','Upload Facility & Team Photos','Facility & team photos (storage paths)',true,105),
('empLocal',7,'Declaration & Final Report','Social & Community Health Impact','Local Employment (Persons)',true,106),
('empWomen',7,'Declaration & Final Report','Social & Community Health Impact','Women Employment (Persons)',true,107),
('empYouth',7,'Declaration & Final Report','Social & Community Health Impact','Youth Employment (Persons)',true,108),
('camps',7,'Declaration & Final Report','Social & Community Health Impact','Free Health Camps per Year',true,109),
('pmjay',7,'Declaration & Final Report','Social & Community Health Impact','PM-JAY / State Scheme Empanelment?',true,110),
('training',7,'Declaration & Final Report','Social & Community Health Impact','Nursing / Paramedical Skill Training Provided?',true,111),
('bmw',7,'Declaration & Final Report','Social & Community Health Impact','Bio-Medical Waste Management Plan',true,112),
('eco',7,'Declaration & Final Report','Social & Community Health Impact','Green Initiatives Description',true,113),
('service',1,'Facility & Applicant Details','Report settings','DPR service',false,114),
('depth',1,'Facility & Applicant Details','Report settings','Report depth',false,115),
('plan',1,'Facility & Applicant Details','Report settings','Plan',false,116)
on conflict (field_key) do update set
  section_no = excluded.section_no, section_name = excluded.section_name, subtask = excluded.subtask,
  field_label = excluded.field_label, optional = excluded.optional, sort_order = excluded.sort_order;

create table if not exists public.dpr_application_forms (
  application_id    uuid not null references public.dpr_applications(application_id) on update cascade on delete cascade,
  application_code  text not null,
  section_no        int,
  section_name      text,
  subtask           text,
  field_key         text not null,
  field_label       text,
  field_value       text,     -- plain value (text / number / yes-no); lists & tables as JSON text
  value_json        jsonb,    -- the same value as stored by the website
  sort_order        int,
  updated_at        timestamptz not null default now(),
  primary key (application_id, field_key)
);
create index if not exists dpr_application_forms_code_idx on public.dpr_application_forms (application_code);
alter table public.dpr_application_forms enable row level security;

-- keep dpr_application_forms in step with dpr_applications.form_data on every save
create or replace function public.dpr_sync_forms() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from dpr_application_forms where application_id = new.application_id;
  insert into dpr_application_forms (application_id, application_code, section_no, section_name, subtask,
                                     field_key, field_label, field_value, value_json, sort_order)
  select new.application_id, new.application_code,
         coalesce(m.section_no, 0), coalesce(m.section_name, 'Other'), m.subtask,
         e.key, coalesce(m.field_label, e.key),
         case jsonb_typeof(e.value) when 'null' then null
                                    when 'string' then nullif(e.value #>> '{}', '')
                                    when 'number' then e.value #>> '{}'
                                    when 'boolean' then e.value #>> '{}'
                                    else e.value::text end,
         e.value, coalesce(m.sort_order, 9999)
    from jsonb_each(coalesce(new.form_data, '{}'::jsonb)) e
    left join dpr_field_map m on m.field_key = e.key
   where left(e.key, 1) <> '_' and e.key not in ('done', 'verified', 'lang');
  return new;
end;
$$;
drop trigger if exists dpr_sync_forms_trg on public.dpr_applications;
create trigger dpr_sync_forms_trg after insert or update of form_data, edit_token on public.dpr_applications
  for each row execute function public.dpr_sync_forms();

-- fill it for applications saved before this migration
update public.dpr_applications set form_data = form_data;

-- ---------- 4. application documents: PDFs only ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dpr-documents', 'dpr-documents', false, 10485760, array['application/pdf'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.dpr_application_documents (
  document_id        uuid primary key default gen_random_uuid(),
  application_id     uuid not null references public.dpr_applications(application_id) on update cascade on delete cascade,
  application_code   text not null,
  user_id            uuid references public.dpr_users(user_id) on delete set null,
  file_name          text not null,
  storage_bucket     text not null default 'dpr-documents',
  storage_path       text not null unique,
  mime_type          text not null default 'application/pdf' check (mime_type = 'application/pdf'),
  size_bytes         bigint not null check (size_bytes > 0 and size_bytes <= 10485760),
  page_count         int,
  document_type      text,          -- e.g. GST certificate, bank statement (detected by auto-fill)
  sha256             text,
  autofilled_fields  int not null default 0,
  uploaded_at        timestamptz not null default now()
);
create index if not exists dpr_application_documents_app_idx  on public.dpr_application_documents (application_id, uploaded_at desc);
create index if not exists dpr_application_documents_code_idx on public.dpr_application_documents (application_code);
alter table public.dpr_application_documents enable row level security;

create or replace function public.dpr_app_exists(p_folder text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from dpr_applications a where a.application_id::text = p_folder)
$$;
grant execute on function public.dpr_app_exists(text) to anon, authenticated;

-- the website may only UPLOAD PDFs into the folder of an existing application
drop policy if exists "website can upload dpr documents" on storage.objects;
create policy "website can upload dpr documents" on storage.objects
  for insert to anon, authenticated
  with check (
    bucket_id = 'dpr-documents'
    and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9]{10,16}-[A-Za-z0-9._-]{1,80}\.pdf$'
    and public.dpr_app_exists(split_part(name, '/', 1))
  );
-- …and remove them only while the application's delete window is open (same rule as photos)
drop policy if exists "website can list documents being deleted" on storage.objects;
create policy "website can list documents being deleted" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'dpr-documents' and public.dpr_can_delete_folder(split_part(name, '/', 1)));
drop policy if exists "website can delete documents being deleted" on storage.objects;
create policy "website can delete documents being deleted" on storage.objects
  for delete to anon, authenticated
  using (bucket_id = 'dpr-documents' and public.dpr_can_delete_folder(split_part(name, '/', 1)));

-- record an uploaded PDF (checks the application code and that the file really is in storage)
create or replace function public.add_dpr_document(
  p_id uuid, p_code text, p_path text, p_name text, p_size bigint,
  p_pages int default null, p_type text default null, p_sha text default null, p_fields int default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a record;
  d record;
begin
  select application_id, application_code, edit_token, user_id into a from dpr_applications where application_id = p_id;
  if not found or public.dpr_norm_code(a.edit_token) <> public.dpr_norm_code(p_code) then
    perform pg_sleep(0.4);
    raise exception 'not allowed';
  end if;
  if p_path is null or split_part(p_path, '/', 1) <> p_id::text or right(lower(p_path), 4) <> '.pdf' then
    raise exception 'invalid path';
  end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'dpr-documents' and o.name = p_path) then
    raise exception 'file not found in storage';
  end if;
  if (select count(*) from dpr_application_documents where application_id = p_id) >= 30 then
    raise exception 'too many documents';
  end if;
  insert into dpr_application_documents (application_id, application_code, user_id, file_name, storage_path,
                                         size_bytes, page_count, document_type, sha256, autofilled_fields)
  values (p_id, a.application_code, a.user_id, left(coalesce(nullif(trim(p_name), ''), 'document.pdf'), 160), p_path,
          p_size, p_pages, left(p_type, 80), left(p_sha, 64), greatest(coalesce(p_fields, 0), 0))
  on conflict (storage_path) do update set autofilled_fields = excluded.autofilled_fields
  returning document_id, file_name, size_bytes, page_count, document_type, uploaded_at into d;
  return to_jsonb(d);
end;
$$;
revoke all on function public.add_dpr_document(uuid, text, text, text, bigint, int, text, text, int) from public;
grant execute on function public.add_dpr_document(uuid, text, text, text, bigint, int, text, text, int) to anon, authenticated;

create or replace function public.list_dpr_documents(p_id uuid, p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from dpr_applications where application_id = p_id
                    and public.dpr_norm_code(edit_token) = public.dpr_norm_code(p_code)) then
    return '[]'::jsonb;
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
            'document_id', document_id, 'file_name', file_name, 'size_bytes', size_bytes,
            'page_count', page_count, 'document_type', document_type, 'uploaded_at', uploaded_at)
          order by uploaded_at desc)
     from dpr_application_documents where application_id = p_id), '[]'::jsonb);
end;
$$;
revoke all on function public.list_dpr_documents(uuid, text) from public;
grant execute on function public.list_dpr_documents(uuid, text) to anon, authenticated;

-- ---------- 5. signed-in users: dashboard functions ----------
create or replace function public.dpr_touch_user(p_name text default null, p_phone text default null) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'sign in required'; end if;
  insert into dpr_users(user_id, email, full_name, phone)
  values (uid, lower(auth.jwt()->>'email'), nullif(trim(p_name), ''), nullif(trim(p_phone), ''))
  on conflict (user_id) do update set
    last_seen_at = now(),
    full_name = coalesce(nullif(trim(p_name), ''), dpr_users.full_name),
    phone     = coalesce(nullif(trim(p_phone), ''), dpr_users.phone);
end;
$$;
revoke all on function public.dpr_touch_user(text, text) from public, anon;
grant execute on function public.dpr_touch_user(text, text) to authenticated;

-- link an application (proved by its code) to the signed-in user
create or replace function public.claim_dpr(p_id uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); a record;
begin
  if uid is null then raise exception 'sign in required'; end if;
  select application_id, edit_token, user_id into a from dpr_applications where application_id = p_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if public.dpr_norm_code(a.edit_token) <> public.dpr_norm_code(p_code) then
    perform pg_sleep(0.4);
    return jsonb_build_object('ok', false, 'reason', 'wrong_code');
  end if;
  if a.user_id is not null and a.user_id <> uid then
    return jsonb_build_object('ok', false, 'reason', 'other_account');
  end if;
  perform public.dpr_touch_user();
  update dpr_applications set user_id = uid where application_id = p_id and user_id is null;
  update dpr_application_documents set user_id = uid where application_id = p_id and user_id is null;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function public.claim_dpr(uuid, text) from public, anon;
grant execute on function public.claim_dpr(uuid, text) to authenticated;

-- every application of the signed-in user (newest first)
create or replace function public.my_applications() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'application_id', a.application_id, 'application_code', a.application_code,
           'facility_name', a.facility_name, 'facility_type', a.facility_type, 'service', a.service,
           'status', a.status, 'current_step', a.current_step, 'completed_steps', a.completed_steps,
           'project_cost', a.project_cost, 'documents', (select count(*) from dpr_application_documents d where d.application_id = a.application_id),
           'created_at', a.created_at, 'updated_at', a.updated_at)
         order by a.updated_at desc), '[]'::jsonb)
    from dpr_applications a
   where auth.uid() is not null and a.user_id = auth.uid()
$$;
revoke all on function public.my_applications() from public, anon;
grant execute on function public.my_applications() to authenticated;

-- open one of the signed-in user's applications (same shape as load_dpr)
create or replace function public.open_my_application(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  select application_id, edit_token, form_data, status, current_step, updated_at into r
    from dpr_applications where application_id = p_id and user_id = auth.uid();
  if not found then return null; end if;
  return jsonb_build_object('application_id', r.application_id, 'id', r.application_id, 'token', r.edit_token,
    'form_data', coalesce(r.form_data, '{}'::jsonb) - '_calc', 'status', r.status,
    'current_step', r.current_step, 'updated_at', r.updated_at);
end;
$$;
revoke all on function public.open_my_application(uuid) from public, anon;
grant execute on function public.open_my_application(uuid) to authenticated;

-- ---------- 6. admin view: users → applications ----------
create or replace view public.dpr_user_applications with (security_invoker = true) as
select u.user_id, u.email, u.full_name, a.application_id, a.application_code, a.facility_name, a.status,
       a.current_step, a.created_at, a.updated_at,
       (select count(*) from public.dpr_application_documents d where d.application_id = a.application_id) as documents
  from public.dpr_applications a
  left join public.dpr_users u on u.user_id = a.user_id
 order by a.updated_at desc;

commit;
