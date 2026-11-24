-- =====================================================================
-- DocpreneurFin Pro — MIGRATION: Application Master Table (application_id)
--
-- Run in Supabase → SQL Editor. Safe to re-run (it skips work already done).
-- Works on an existing database (migrates it) and on an empty one (full install).
-- Everything runs in ONE transaction: if any statement fails, nothing changes.
--
-- What it does (no data is dropped — tables and columns are only renamed):
--   1. dpr_submissions  → dpr_applications   (master table)
--      id               → application_id      (primary key, uuid)
--   2. every dpr_stepNN_* sub-table: submission_id → application_id,
--      foreign key → dpr_applications(application_id)
--      ON UPDATE CASCADE ON DELETE CASCADE
--   3. dpr_deleted.id / dpr_delete_grants.submission_id → application_id
--   4. re-creates the website functions (save_dpr, load_dpr, delete_dpr),
--      the step-sync trigger and the views with the new names
--   5. adds admin functions get_application(id) and delete_application(id)
-- The website keeps working unchanged (same function names and parameters).
-- =====================================================================
begin;

-- ---------- 1. rename master table + key ----------
do $$
begin
  if to_regclass('public.dpr_submissions') is not null and to_regclass('public.dpr_applications') is null then
    -- views depend on the old names; they are re-created further below
    drop view if exists public.dpr_overview;
    drop view if exists public.dpr_full_view;
    alter table public.dpr_submissions rename to dpr_applications;
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='dpr_applications' and column_name='id') then
    alter table public.dpr_applications rename column id to application_id;
  end if;
end $$;

-- ---------- 2. sub-tables: rename column, rebuild foreign keys with cascade ----------
do $$
declare r record;
begin
  if to_regclass('public.dpr_applications') is null then return; end if;   -- fresh install: tables are created below
  -- rename submission_id → application_id wherever it exists
  for r in select table_name from information_schema.columns
            where table_schema='public' and column_name='submission_id'
  loop
    execute format('alter table public.%I rename column submission_id to application_id', r.table_name);
  end loop;

  -- dpr_deleted.id → application_id
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='dpr_deleted' and column_name='id') then
    alter table public.dpr_deleted rename column id to application_id;
  end if;

  -- drop every foreign key that points at the master table …
  for r in select c.conname, c.conrelid::regclass::text as tbl
             from pg_constraint c
            where c.contype='f' and c.confrelid = 'public.dpr_applications'::regclass
  loop
    execute format('alter table %s drop constraint %I', r.tbl, r.conname);
  end loop;
  -- … and add one consistent foreign key per sub-table
  for r in select table_name from information_schema.columns
            where table_schema='public' and column_name='application_id'
              and table_name like 'dpr\_step%' escape '\'
  loop
    execute format('alter table public.%I alter column application_id set not null', r.table_name);
    execute format('alter table public.%I add constraint %I foreign key (application_id)
                    references public.dpr_applications(application_id) on update cascade on delete cascade',
                   r.table_name, r.table_name || '_application_fk');
  end loop;
end $$;

-- ---------- 3. tidy index / constraint names ----------
do $$
declare r record;
begin
  for r in select indexname from pg_indexes
            where schemaname='public' and (indexname like 'dpr\_submissions%' escape '\' or indexname like '%\_sub\_idx' escape '\')
  loop
    execute format('alter index public.%I rename to %I', r.indexname,
      replace(replace(r.indexname, 'dpr_submissions', 'dpr_applications'), '_sub_idx', '_app_idx'));
  end loop;
  for r in select conname, conrelid::regclass::text as tbl from pg_constraint
            where connamespace='public'::regnamespace and conname like '%submission\_id%' escape '\'
  loop
    execute format('alter table %s rename constraint %I to %I', r.tbl, r.conname, replace(r.conname, 'submission_id', 'application_id'));
  end loop;
end $$;

-- index to fetch every sub-table quickly by application_id (1:1 tables use it as primary key)
do $$
declare r record;
begin
  if to_regclass('public.dpr_applications') is null then return; end if;
  for r in select c.table_name from information_schema.columns c
            where c.table_schema='public' and c.column_name='application_id' and c.table_name like 'dpr\_step%' escape '\'
              and not exists (select 1 from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum=i.indkey[0]
                               where i.indrelid=('public.'||c.table_name)::regclass and a.attname='application_id')
  loop
    execute format('create index %I on public.%I (application_id)', r.table_name || '_app_idx', r.table_name);
  end loop;
end $$;

-- the old trigger on the master table points at the old function body; drop it (re-created below)
drop trigger if exists dpr_sync_steps_trg on public.dpr_applications;
drop trigger if exists dpr_block_deleted_trg on public.dpr_applications;
drop view if exists public.dpr_overview;
drop view if exists public.dpr_full_view;

-- =====================================================================
-- 4. re-create functions, trigger and views with the new names
--    (same content as schema.sql, storage.sql, step_tables.sql, resume.sql, delete.sql)
-- =====================================================================

-- >>>>> from schema.sql
-- =====================================================================
-- DocpreneurFin Pro — Supabase schema
-- Run once in Supabase → SQL Editor → New query → paste → Run.
--
-- Security model
--   * The website uses only the public "anon" key.
--   * dpr_applications: NO direct table access for anon. The page writes
--     through save_dpr(), which only lets a browser update the row it
--     created (checked with a random per-browser edit token).
--   * inquiries: anon may INSERT only (no SELECT/UPDATE/DELETE).
--   * Nobody can read data with the anon key. Read it in the Supabase
--     dashboard (Table Editor) or with the service_role key on a server.
-- =====================================================================

-- ---------- 1. Application master (one row per application) ----------
create table if not exists public.dpr_applications (
  application_id      uuid primary key,   -- one id for the whole application lifecycle
  edit_token          text not null,
  status              text not null default 'draft'
                      check (status in ('draft','generated','downloaded')),

  -- quick-view columns (copied from the form for easy filtering)
  facility_name       text,
  healthcare_segment  text,
  facility_type       text,
  service             text,          -- loan / scheme / investor
  depth               text,          -- summary / standard / detailed
  language            text,          -- EN / HI / MR
  contact_name        text,
  email               text,
  phone               text,
  city                text,
  district            text,
  state               text,
  project_cost        numeric,       -- ₹
  bank_loan           numeric,       -- ₹
  avg_dscr            numeric,
  email_verified      boolean not null default false,
  phone_verified      boolean not null default false,
  current_step        int,
  completed_steps     int[],
  download_count      int not null default 0,

  -- every answer of all 14 steps
  form_data           jsonb not null default '{}'::jsonb,

  user_agent          text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  generated_at        timestamptz,
  last_downloaded_at  timestamptz
);

create index if not exists dpr_applications_updated_idx on public.dpr_applications (updated_at desc);
create index if not exists dpr_applications_status_idx  on public.dpr_applications (status);
create index if not exists dpr_applications_email_idx   on public.dpr_applications (lower(email));

alter table public.dpr_applications enable row level security;
-- (intentionally no policies for anon/authenticated → no direct access)

create or replace function public.save_dpr(
  p_id uuid, p_token text, p_status text, p_summary jsonb, p_data jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token  text;
  v_status text;
  rank_new int := case p_status when 'draft' then 1 when 'generated' then 2 when 'downloaded' then 3 else 0 end;
begin
  if rank_new = 0 then raise exception 'invalid status'; end if;
  if p_token is null or length(p_token) < 16 then raise exception 'invalid token'; end if;
  if pg_column_size(p_data) > 400000 then raise exception 'payload too large'; end if;

  select edit_token, status into v_token, v_status from dpr_applications where application_id = p_id;

  if v_token is null then
    insert into dpr_applications (
      application_id, edit_token, status, form_data,
      facility_name, healthcare_segment, facility_type, service, depth, language,
      contact_name, email, phone, city, district, state,
      project_cost, bank_loan, avg_dscr, email_verified, phone_verified,
      current_step, completed_steps, download_count, user_agent,
      generated_at, last_downloaded_at)
    values (
      p_id, p_token, p_status, coalesce(p_data, '{}'::jsonb),
      p_summary->>'facility_name', p_summary->>'healthcare_segment', p_summary->>'facility_type',
      p_summary->>'service', p_summary->>'depth', p_summary->>'language',
      p_summary->>'contact_name', p_summary->>'email', p_summary->>'phone',
      p_summary->>'city', p_summary->>'district', p_summary->>'state',
      nullif(p_summary->>'project_cost','')::numeric, nullif(p_summary->>'bank_loan','')::numeric,
      nullif(p_summary->>'avg_dscr','')::numeric,
      coalesce((p_summary->>'email_verified')::boolean, false),
      coalesce((p_summary->>'phone_verified')::boolean, false),
      nullif(p_summary->>'current_step','')::int,
      coalesce(array(select jsonb_array_elements_text(coalesce(p_summary->'completed_steps','[]'::jsonb))::int), '{}'),
      case when p_status = 'downloaded' then 1 else 0 end,
      left(p_summary->>'user_agent', 200),
      case when p_status in ('generated','downloaded') then now() end,
      case when p_status = 'downloaded' then now() end);

  elsif v_token = p_token then
    update dpr_applications set
      form_data          = coalesce(p_data, form_data),
      status             = case when rank_new > (case status when 'draft' then 1 when 'generated' then 2 else 3 end)
                                then p_status else status end,
      facility_name      = p_summary->>'facility_name',
      healthcare_segment = p_summary->>'healthcare_segment',
      facility_type      = p_summary->>'facility_type',
      service            = p_summary->>'service',
      depth              = p_summary->>'depth',
      language           = p_summary->>'language',
      contact_name       = p_summary->>'contact_name',
      email              = p_summary->>'email',
      phone              = p_summary->>'phone',
      city               = p_summary->>'city',
      district           = p_summary->>'district',
      state              = p_summary->>'state',
      project_cost       = nullif(p_summary->>'project_cost','')::numeric,
      bank_loan          = nullif(p_summary->>'bank_loan','')::numeric,
      avg_dscr           = nullif(p_summary->>'avg_dscr','')::numeric,
      email_verified     = email_verified or coalesce((p_summary->>'email_verified')::boolean, false),
      phone_verified     = phone_verified or coalesce((p_summary->>'phone_verified')::boolean, false),
      current_step       = nullif(p_summary->>'current_step','')::int,
      completed_steps    = coalesce(array(select jsonb_array_elements_text(coalesce(p_summary->'completed_steps','[]'::jsonb))::int), completed_steps),
      download_count     = download_count + case when p_status = 'downloaded' then 1 else 0 end,
      generated_at       = case when p_status in ('generated','downloaded') then coalesce(generated_at, now()) else generated_at end,
      last_downloaded_at = case when p_status = 'downloaded' then now() else last_downloaded_at end,
      user_agent         = left(p_summary->>'user_agent', 200),
      updated_at         = now()
    where application_id = p_id;

  else
    raise exception 'not allowed';
  end if;
end;
$$;

revoke all on function public.save_dpr(uuid, text, text, jsonb, jsonb) from public;
grant execute on function public.save_dpr(uuid, text, text, jsonb, jsonb) to anon, authenticated;


-- ---------- 2. Contact-form inquiries (home page) ----------
create table if not exists public.inquiries (
  id            bigint generated always as identity primary key,
  full_name     text not null,
  organisation  text,
  email         text not null,
  phone         text not null,
  city          text,
  speciality    text,
  purpose       text,
  page          text default 'home',
  created_at    timestamptz not null default now()
);

alter table public.inquiries enable row level security;

drop policy if exists "website can add inquiries" on public.inquiries;
create policy "website can add inquiries" on public.inquiries
  for insert to anon, authenticated
  with check (
    char_length(full_name) between 2 and 120
    and email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'
    and phone ~ '^[6-9][0-9]{9}$'
    and coalesce(char_length(organisation),0) <= 200
    and coalesce(char_length(city),0) <= 120
  );
-- no select/update/delete policies → the website cannot read inquiries


-- ---------- 3. Handy views for the team (dashboard only) ----------
create or replace view public.dpr_overview with (security_invoker = true) as
select application_id, status, facility_name, facility_type, contact_name, email, phone, city, state,
       round(project_cost/100000.0, 2) as project_cost_lakh,
       round(bank_loan/100000.0, 2)    as bank_loan_lakh,
       avg_dscr, email_verified, phone_verified, current_step, download_count,
       created_at, updated_at
from public.dpr_applications
order by updated_at desc;

-- >>>>> from storage.sql
-- =====================================================================
-- DocpreneurFin Pro — photo storage (Step 13: logo, building, equipment, team)
-- Run once in Supabase → SQL Editor (after schema.sql).
--
--   * Private bucket "dpr-images": max 2 MB per file, JPG/PNG/WEBP only.
--   * The website (anon key) may UPLOAD only — no list, read, overwrite or delete.
--   * Files are stored as <submission-id>/<slot>-<timestamp>.jpg and the path is
--     saved in dpr_applications.form_data -> 'images'.
--   * View photos in Supabase → Storage → dpr-images → <submission id> folder.
-- =====================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dpr-images', 'dpr-images', false, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "website can upload dpr images" on storage.objects;
create policy "website can upload dpr images" on storage.objects
  for insert to anon, authenticated
  with check (
    bucket_id = 'dpr-images'
    and (storage.foldername(name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and name ~ '^[0-9a-f-]{36}/(logo|front|equipImg|team)-[0-9]{10,16}\.(jpg|jpeg|png|webp)$'
  );
-- no select/update/delete policies for anon → files stay private

-- photo count in the team overview
create or replace view public.dpr_overview with (security_invoker = true) as
select application_id, status, facility_name, facility_type, contact_name, email, phone, city, state,
       round(project_cost/100000.0, 2) as project_cost_lakh,
       round(bank_loan/100000.0, 2)    as bank_loan_lakh,
       avg_dscr, email_verified, phone_verified, current_step, download_count,
       created_at, updated_at,
       coalesce((select count(*) from jsonb_object_keys(coalesce(form_data->'images','{}'::jsonb))), 0) as photos
from public.dpr_applications
order by updated_at desc;

-- >>>>> from step_tables.sql
-- =====================================================================
-- DocpreneurFin Pro — one table per DPR page (Step 1 … Step 14)
-- Run in Supabase → SQL Editor AFTER schema.sql (and storage.sql).
--
-- How it works
--   The website keeps saving through save_dpr() into dpr_applications.form_data.
--   A trigger copies every save into the step tables below, with typed columns.
--   Child tables hold repeating rows (doctors, equipment, staff, 5-year
--   projections, licences, photos). All tables are private (RLS on, no
--   policies) — view them in the Supabase Table Editor.
--   Every table has application_id → dpr_applications(id) ON DELETE CASCADE,
--   so deleting a submission removes all its step data.
-- =====================================================================

-- ---------- safe-cast helpers ----------
create or replace function public.dpr_num(t text) returns numeric
language sql immutable as $$
  select case when t ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$' then trim(t)::numeric end
$$;
create or replace function public.dpr_int(t text) returns int
language sql immutable as $$ select round(public.dpr_num(t))::int $$;
create or replace function public.dpr_yes(t text) returns boolean
language sql immutable as $$
  select case lower(trim(coalesce(t,''))) when 'yes' then true when 'no' then false end
$$;
create or replace function public.dpr_txt(t text) returns text
language sql immutable as $$ select nullif(trim(coalesce(t,'')), '') $$;

-- ---------- Step 1: Basic Information ----------
create table if not exists public.dpr_step01_basic_info (
  application_id        uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  healthcare_segment   text,
  facility_type        text,
  custom_activity      text,
  project_classification text,
  facility_name        text,
  group_name           text,
  project_overview     text,
  entity_type          text,
  clinical_establishment_reg_no text,
  medical_council_reg_no text,
  pan_no               text,
  gst_no               text,
  udyam_no             text,
  cin_llpin            text,
  nabh_status          text,
  town_city            text,
  district             text,
  state                text,
  pin_code             text,
  contact_person       text,
  contact_number       text,
  email                text,
  existing_bank_name   text,
  bank_branch          text,
  ifsc_code            text,
  dpr_service          text,          -- loan / scheme / investor
  report_depth         text,          -- summary / standard / detailed
  -- service specific
  lending_bank         text,
  loan_scheme          text,
  collateral           text,
  moratorium_months    int,
  tenure_years         numeric,
  interest_rate_pct    numeric,
  target_scheme        text,
  applicant_category   text,
  location_type        text,
  equity_raise         numeric,
  equity_dilution_pct  numeric,
  investor_type        text,
  use_of_funds         text,
  updated_at           timestamptz not null default now()
);

-- ---------- Step 2: Doctors & Management ----------
create table if not exists public.dpr_step02_team_profile (
  application_id              uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  hospital_affiliations      text,
  existing_monthly_patients  int,
  promoter_annual_income     numeric,
  updated_at                 timestamptz not null default now()
);
create table if not exists public.dpr_step02_members (
  id               bigint generated always as identity primary key,
  application_id    uuid not null references public.dpr_applications(application_id) on update cascade on delete cascade,
  sort_order       int not null,
  name             text,
  designation      text,
  gender           text,
  age              int,
  qualification    text,
  council_reg_no   text,
  experience_years numeric
);
create index if not exists dpr_step02_members_app_idx on public.dpr_step02_members (application_id);

-- ---------- Step 3: Medical Services ----------
create table if not exists public.dpr_step03_medical_services (
  application_id            uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  departments              text[],
  key_procedures           text,
  total_beds               int,
  icu_beds                 int,
  operation_theatres       int,
  opd_patients_per_day     int,
  opd_days_per_year        int,
  avg_length_of_stay_days  numeric,
  arpob                    numeric,
  opd_revenue_per_patient  numeric,
  annual_growth_pct        numeric,
  consumables_pct          numeric,
  payer_mix                text,
  usp                      text,
  updated_at               timestamptz not null default now()
);

-- ---------- Step 4: Medical Equipment ----------
create table if not exists public.dpr_step04_equipment_vendor (
  application_id      uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  supplier_name      text,
  supplier_location  text,
  aerb_required      boolean,
  amc_pct            numeric,
  equipment_total    numeric,
  updated_at         timestamptz not null default now()
);
create table if not exists public.dpr_step04_equipment (
  id             bigint generated always as identity primary key,
  application_id  uuid not null references public.dpr_applications(application_id) on update cascade on delete cascade,
  sort_order     int not null,
  item_name      text,
  quantity       numeric,
  unit_price     numeric,
  total_price    numeric generated always as (coalesce(quantity,0) * coalesce(unit_price,0)) stored
);
create index if not exists dpr_step04_equipment_app_idx on public.dpr_step04_equipment (application_id);

-- ---------- Step 5: Market Strategy ----------
create table if not exists public.dpr_step05_market (
  application_id          uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  catchment_population   bigint,
  catchment_radius_km    numeric,
  target_segments        text,
  referral_sources       text,
  insurance_tpa_plan     text,
  competitors            text,
  updated_at             timestamptz not null default now()
);

-- ---------- Step 6: Staffing Plan ----------
create table if not exists public.dpr_step06_staffing_plan (
  application_id            uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  visiting_consultant_pct  numeric,
  total_staff              int,
  monthly_payroll          numeric,
  updated_at               timestamptz not null default now()
);
create table if not exists public.dpr_step06_staff (
  id              bigint generated always as identity primary key,
  application_id   uuid not null references public.dpr_applications(application_id) on update cascade on delete cascade,
  sort_order      int not null,
  category        text,
  persons         int,
  monthly_salary  numeric,
  monthly_cost    numeric generated always as (coalesce(persons,0) * coalesce(monthly_salary,0)) stored
);
create index if not exists dpr_step06_staff_app_idx on public.dpr_step06_staff (application_id);

-- ---------- Step 7: Cost & Financing ----------
create table if not exists public.dpr_step07_cost_finance (
  application_id           uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  land_cost               numeric,
  building_civil_cost     numeric,
  medical_equipment_cost  numeric,
  furniture_it_his_cost   numeric,
  medical_gas_dg_cost     numeric,
  preliminary_cost        numeric,
  working_capital_margin  numeric,
  total_project_cost      numeric,
  promoter_contribution   numeric,   -- as entered (0 = auto)
  bank_loan_entered       numeric,   -- as entered (0 = 75% auto)
  subsidy_grant           numeric,
  promoter_contribution_final numeric,  -- after auto-balance
  bank_loan_final         numeric,
  funding_gap             numeric,
  updated_at              timestamptz not null default now()
);

-- ---------- Step 8: Financial Projections (one row per year) ----------
create table if not exists public.dpr_step08_projections (
  id                  bigint generated always as identity primary key,
  application_id       uuid not null references public.dpr_applications(application_id) on update cascade on delete cascade,
  year_no             int not null,
  bed_occupancy_pct   numeric,
  opd_growth_pct      numeric,
  ipd_revenue         numeric,
  opd_revenue         numeric,
  total_revenue       numeric,
  operating_expenses  numeric,
  ebitda              numeric,
  interest            numeric,
  depreciation        numeric,
  net_profit          numeric,
  principal_repaid    numeric,
  dscr                numeric,
  unique (application_id, year_no)
);
create table if not exists public.dpr_step08_viability (
  application_id       uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  avg_dscr            numeric,
  breakeven_pct       numeric,
  payback_year        int,
  updated_at          timestamptz not null default now()
);

-- ---------- Step 9: Infrastructure ----------
create table if not exists public.dpr_step09_infrastructure (
  application_id         uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  premises_status       text,
  built_up_area_sqft    numeric,
  floors                int,
  bed_lift              boolean,
  power_kva             numeric,
  dg_backup_kva         numeric,
  oxygen_source         text,
  water_litres_per_day  numeric,
  monthly_rent          numeric,
  utilities_admin_pct   numeric,
  months_to_start       int,
  updated_at            timestamptz not null default now()
);

-- ---------- Step 10: SWOT ----------
create table if not exists public.dpr_step10_swot (
  application_id  uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  strengths      text,
  weaknesses     text,
  opportunities  text,
  threats        text,
  updated_at     timestamptz not null default now()
);

-- ---------- Step 11: Community Health Impact ----------
create table if not exists public.dpr_step11_community_impact (
  application_id         uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  local_employment      int,
  women_employment      int,
  youth_employment      int,
  free_camps_per_year   int,
  pmjay_empanelled      boolean,
  bmw_management_plan   text,
  skill_training        boolean,
  green_initiatives     text,
  updated_at            timestamptz not null default now()
);

-- ---------- Step 12: Credit Standing ----------
create table if not exists public.dpr_step12_credit (
  application_id         uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  cibil_score           int,
  previous_loan         boolean,
  existing_loan_amount  numeric,
  outstanding_amount    numeric,
  existing_monthly_emi  numeric,
  default_history       boolean,
  updated_at            timestamptz not null default now()
);

-- ---------- Step 13: Licences & Site Images ----------
create table if not exists public.dpr_step13_licences (
  id             bigint generated always as identity primary key,
  application_id  uuid not null references public.dpr_applications(application_id) on update cascade on delete cascade,
  licence_name   text not null,
  obtained       boolean not null default true,
  unique (application_id, licence_name)
);
create table if not exists public.dpr_step13_images (
  id             bigint generated always as identity primary key,
  application_id  uuid not null references public.dpr_applications(application_id) on update cascade on delete cascade,
  slot           text not null,            -- logo / front / equipImg / team
  storage_bucket text,
  storage_path   text,
  original_name  text,
  bytes          int,
  width          int,
  height         int,
  uploaded_at    timestamptz,
  unique (application_id, slot)
);

-- ---------- Step 14: Declaration & Report ----------
create table if not exists public.dpr_step14_declaration (
  application_id     uuid primary key references public.dpr_applications(application_id) on update cascade on delete cascade,
  declarant_name    text,
  designation       text,
  place             text,
  declaration_agreed boolean,
  report_depth      text,
  status            text,
  email_verified    boolean,
  phone_verified    boolean,
  download_count    int,
  generated_at      timestamptz,
  last_downloaded_at timestamptz,
  updated_at        timestamptz not null default now()
);

-- ---------- privacy: RLS on, no policies ----------
do $$
declare t text;
begin
  foreach t in array array[
    'dpr_step01_basic_info','dpr_step02_team_profile','dpr_step02_members','dpr_step03_medical_services',
    'dpr_step04_equipment_vendor','dpr_step04_equipment','dpr_step05_market','dpr_step06_staffing_plan',
    'dpr_step06_staff','dpr_step07_cost_finance','dpr_step08_projections','dpr_step08_viability',
    'dpr_step09_infrastructure','dpr_step10_swot','dpr_step11_community_impact','dpr_step12_credit',
    'dpr_step13_licences','dpr_step13_images','dpr_step14_declaration']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---------- trigger: copy form_data into the step tables ----------
create or replace function public.dpr_sync_steps() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  d   jsonb := coalesce(new.form_data, '{}'::jsonb);
  c   jsonb := coalesce(new.form_data->'_calc', '{}'::jsonb);
  sid uuid  := new.application_id;
begin
  -- Step 1
  delete from dpr_step01_basic_info where application_id = sid;
  insert into dpr_step01_basic_info values (
    sid, dpr_txt(d->>'sector'), dpr_txt(d->>'activity'), dpr_txt(d->>'customActivity'), dpr_txt(d->>'classif'),
    dpr_txt(d->>'facility'), dpr_txt(d->>'group'), dpr_txt(d->>'overview'), dpr_txt(d->>'entity'),
    dpr_txt(d->>'cea'), dpr_txt(d->>'mcReg'), dpr_txt(d->>'pan'), dpr_txt(d->>'gst'), dpr_txt(d->>'udyam'),
    dpr_txt(d->>'cin'), dpr_txt(d->>'nabh'), dpr_txt(d->>'town'), dpr_txt(d->>'district'), dpr_txt(d->>'state'),
    dpr_txt(d->>'pin'), dpr_txt(d->>'contact'), dpr_txt(d->>'phone'), dpr_txt(d->>'email'),
    dpr_txt(d->>'bankName'), dpr_txt(d->>'branch'), dpr_txt(d->>'ifsc'), dpr_txt(d->>'service'), dpr_txt(d->>'depth'),
    dpr_txt(d->>'bank'), dpr_txt(d->>'scheme'), dpr_txt(d->>'collateral'), dpr_int(d->>'morat'),
    dpr_num(d->>'tenure'), dpr_num(d->>'rate'), dpr_txt(d->>'schemeName'), dpr_txt(d->>'category'),
    dpr_txt(d->>'locType'), dpr_num(d->>'raise'), dpr_num(d->>'dilution'), dpr_txt(d->>'investorType'),
    dpr_txt(d->>'useFunds'), now());

  -- Step 2
  delete from dpr_step02_team_profile where application_id = sid;
  insert into dpr_step02_team_profile values (sid, dpr_txt(d->>'affil'), dpr_int(d->>'pastPatients'), dpr_num(d->>'existingIncome'), now());
  delete from dpr_step02_members where application_id = sid;
  insert into dpr_step02_members (application_id, sort_order, name, designation, gender, age, qualification, council_reg_no, experience_years)
  select sid, o::int, dpr_txt(m->>'name'), dpr_txt(m->>'desig'), dpr_txt(m->>'gender'), dpr_int(m->>'age'),
         dpr_txt(m->>'qual'), dpr_txt(m->>'reg'), dpr_num(m->>'exp')
  from jsonb_array_elements(case when jsonb_typeof(d->'members')='array' then d->'members' else '[]' end) with ordinality as x(m, o)
  where coalesce(dpr_txt(m->>'name'), dpr_txt(m->>'qual'), dpr_txt(m->>'reg')) is not null;

  -- Step 3
  delete from dpr_step03_medical_services where application_id = sid;
  insert into dpr_step03_medical_services values (
    sid,
    array(select jsonb_array_elements_text(case when jsonb_typeof(d->'depts')='array' then d->'depts' else '[]' end)),
    dpr_txt(d->>'services'), dpr_int(d->>'beds'), dpr_int(d->>'icu'), dpr_int(d->>'ots'), dpr_int(d->>'opd'),
    dpr_int(d->>'opdDays'), dpr_num(d->>'alos'), dpr_num(d->>'arpob'), dpr_num(d->>'opdRev'), dpr_num(d->>'growth'),
    dpr_num(d->>'consum'), dpr_txt(d->>'payer'), dpr_txt(d->>'usp'), now());

  -- Step 4
  delete from dpr_step04_equipment where application_id = sid;
  insert into dpr_step04_equipment (application_id, sort_order, item_name, quantity, unit_price)
  select sid, o::int, dpr_txt(e->>'item'), dpr_num(e->>'qty'), dpr_num(e->>'price')
  from jsonb_array_elements(case when jsonb_typeof(d->'equip')='array' then d->'equip' else '[]' end) with ordinality as x(e, o)
  where coalesce(dpr_txt(e->>'item'), e->>'qty', e->>'price') is not null;
  delete from dpr_step04_equipment_vendor where application_id = sid;
  insert into dpr_step04_equipment_vendor values (sid, dpr_txt(d->>'vendor'), dpr_txt(d->>'vendorLoc'), dpr_yes(d->>'aerb'),
    dpr_num(d->>'amc'), (select sum(total_price) from dpr_step04_equipment where application_id = sid), now());

  -- Step 5
  delete from dpr_step05_market where application_id = sid;
  insert into dpr_step05_market values (sid, dpr_num(d->>'catchPop')::bigint, dpr_num(d->>'catchKm'), dpr_txt(d->>'segments'),
    dpr_txt(d->>'referral'), dpr_txt(d->>'tpa'), dpr_txt(d->>'competitors'), now());

  -- Step 6
  delete from dpr_step06_staff where application_id = sid;
  insert into dpr_step06_staff (application_id, sort_order, category, persons, monthly_salary)
  select sid, o::int, dpr_txt(s->>'cat'), dpr_int(s->>'n'), dpr_num(s->>'sal')
  from jsonb_array_elements(case when jsonb_typeof(d->'staff')='array' then d->'staff' else '[]' end) with ordinality as x(s, o);
  delete from dpr_step06_staffing_plan where application_id = sid;
  insert into dpr_step06_staffing_plan values (sid, dpr_num(d->>'visiting'),
    (select sum(persons) from dpr_step06_staff where application_id = sid),
    (select sum(monthly_cost) from dpr_step06_staff where application_id = sid), now());

  -- Step 7
  delete from dpr_step07_cost_finance where application_id = sid;
  insert into dpr_step07_cost_finance values (sid, dpr_num(d->>'land'), dpr_num(d->>'building'),
    (select sum(total_price) from dpr_step04_equipment where application_id = sid),
    dpr_num(d->>'furniture'), dpr_num(d->>'gases'), dpr_num(d->>'prelim'), dpr_num(d->>'wc'),
    dpr_num(c#>>'{totals,project_cost}'), dpr_num(d->>'promoter'), dpr_num(d->>'loan'), dpr_num(d->>'subsidy'),
    dpr_num(c#>>'{totals,promoter}'), dpr_num(c#>>'{totals,bank_loan}'), dpr_num(c#>>'{totals,gap}'), now());

  -- Step 8
  delete from dpr_step08_projections where application_id = sid;
  insert into dpr_step08_projections (application_id, year_no, bed_occupancy_pct, opd_growth_pct, ipd_revenue, opd_revenue,
    total_revenue, operating_expenses, ebitda, interest, depreciation, net_profit, principal_repaid, dscr)
  select sid, coalesce(dpr_int(p->>'year'), o::int), dpr_num(p->>'occupancy'), dpr_num(p->>'opd_growth'), dpr_num(p->>'ipd'),
         dpr_num(p->>'opd'), dpr_num(p->>'revenue'), dpr_num(p->>'opex'), dpr_num(p->>'ebitda'), dpr_num(p->>'interest'),
         dpr_num(p->>'depreciation'), dpr_num(p->>'pat'), dpr_num(p->>'principal'), dpr_num(p->>'dscr')
  from jsonb_array_elements(case when jsonb_typeof(c->'projections')='array' then c->'projections' else '[]' end) with ordinality as x(p, o);
  delete from dpr_step08_viability where application_id = sid;
  insert into dpr_step08_viability values (sid, dpr_num(c#>>'{totals,avg_dscr}'), dpr_num(c#>>'{totals,breakeven_pct}'),
    dpr_int(c#>>'{totals,payback_year}'), now());

  -- Step 9
  delete from dpr_step09_infrastructure where application_id = sid;
  insert into dpr_step09_infrastructure values (sid, dpr_txt(d->>'premises'), dpr_num(d->>'area'), dpr_int(d->>'floors'),
    dpr_yes(d->>'lift'), dpr_num(d->>'power'), dpr_num(d->>'dg'), dpr_txt(d->>'o2'), dpr_num(d->>'water'),
    dpr_num(d->>'rent'), dpr_num(d->>'utilPct'), dpr_int(d->>'months'), now());

  -- Step 10
  delete from dpr_step10_swot where application_id = sid;
  insert into dpr_step10_swot values (sid, dpr_txt(d->>'sw_s'), dpr_txt(d->>'sw_w'), dpr_txt(d->>'sw_o'), dpr_txt(d->>'sw_t'), now());

  -- Step 11
  delete from dpr_step11_community_impact where application_id = sid;
  insert into dpr_step11_community_impact values (sid, dpr_int(d->>'empLocal'), dpr_int(d->>'empWomen'), dpr_int(d->>'empYouth'),
    dpr_int(d->>'camps'), dpr_yes(d->>'pmjay'), dpr_txt(d->>'bmw'), dpr_yes(d->>'training'), dpr_txt(d->>'eco'), now());

  -- Step 12
  delete from dpr_step12_credit where application_id = sid;
  insert into dpr_step12_credit values (sid, dpr_int(d->>'cibil'), dpr_yes(d->>'prevLoan'), dpr_num(d->>'existLoan'),
    dpr_num(d->>'outstanding'), dpr_num(d->>'existEmi'), dpr_yes(d->>'default'), now());

  -- Step 13
  delete from dpr_step13_licences where application_id = sid;
  insert into dpr_step13_licences (application_id, licence_name)
  select distinct sid, l from jsonb_array_elements_text(case when jsonb_typeof(d->'lic')='array' then d->'lic' else '[]' end) l
  where dpr_txt(l) is not null;
  delete from dpr_step13_images where application_id = sid;
  insert into dpr_step13_images (application_id, slot, storage_bucket, storage_path, original_name, bytes, width, height, uploaded_at)
  select sid, k, v->>'bucket', v->>'path', v->>'original_name', dpr_int(v->>'bytes'), dpr_int(v->>'width'), dpr_int(v->>'height'),
         case when v->>'uploaded_at' ~ '^\d{4}-\d{2}-\d{2}T' then (v->>'uploaded_at')::timestamptz end
  from jsonb_each(case when jsonb_typeof(d->'images')='object' then d->'images' else '{}' end) as x(k, v)
  where jsonb_typeof(v) = 'object' and v ? 'path';

  -- Step 14
  delete from dpr_step14_declaration where application_id = sid;
  insert into dpr_step14_declaration values (sid, dpr_txt(d->>'declName'), dpr_txt(d->>'declDesig'), dpr_txt(d->>'declPlace'),
    coalesce(jsonb_array_length(case when jsonb_typeof(d->'declOk')='array' then d->'declOk' else '[]' end), 0) > 0,
    dpr_txt(d->>'depth'), new.status, new.email_verified, new.phone_verified, new.download_count,
    new.generated_at, new.last_downloaded_at, now());

  return new;
end;
$$;

drop trigger if exists dpr_sync_steps_trg on public.dpr_applications;
create trigger dpr_sync_steps_trg
  after insert or update on public.dpr_applications
  for each row execute function public.dpr_sync_steps();

-- ---------- one-row-per-DPR summary view across the 1:1 step tables ----------
create or replace view public.dpr_full_view with (security_invoker = true) as
select s.application_id, s.status, s.created_at, s.updated_at,
       b.facility_name, b.facility_type, b.healthcare_segment, b.project_classification, b.entity_type,
       b.contact_person, b.contact_number, b.email, b.town_city, b.district, b.state,
       ms.total_beds, ms.icu_beds, ms.operation_theatres, ms.opd_patients_per_day, ms.arpob,
       ev.equipment_total, sp.total_staff, sp.monthly_payroll,
       cf.total_project_cost, cf.bank_loan_final, cf.promoter_contribution_final, cf.subsidy_grant,
       v.avg_dscr, v.breakeven_pct, v.payback_year,
       cr.cibil_score, de.declarant_name, de.email_verified, de.phone_verified, de.download_count,
       (select count(*) from public.dpr_step02_members m where m.application_id = s.application_id) as members,
       (select count(*) from public.dpr_step04_equipment e where e.application_id = s.application_id) as equipment_items,
       (select count(*) from public.dpr_step13_licences l where l.application_id = s.application_id) as licences_obtained,
       (select count(*) from public.dpr_step13_images i where i.application_id = s.application_id) as photos
from public.dpr_applications s
left join public.dpr_step01_basic_info       b  on b.application_id = s.application_id
left join public.dpr_step03_medical_services ms on ms.application_id = s.application_id
left join public.dpr_step04_equipment_vendor ev on ev.application_id = s.application_id
left join public.dpr_step06_staffing_plan    sp on sp.application_id = s.application_id
left join public.dpr_step07_cost_finance     cf on cf.application_id = s.application_id
left join public.dpr_step08_viability        v  on v.application_id = s.application_id
left join public.dpr_step12_credit           cr on cr.application_id = s.application_id
left join public.dpr_step14_declaration      de on de.application_id = s.application_id
order by s.updated_at desc;
revoke all on public.dpr_full_view from anon, authenticated;

-- ---------- backfill existing submissions ----------
update public.dpr_applications set form_data = form_data;

-- >>>>> from resume.sql
-- =====================================================================
-- DocpreneurFin Pro — resume an old application with its resume code
-- Run in Supabase → SQL Editor (after schema.sql).
--
--   * Each application has a private resume code (its edit token), shown to
--     the user as XXXX-XXXX-XXXX-XXXX. Only someone who has the code can load
--     or change that application.
--   * load_dpr(code) returns that one application's answers — nothing else.
--   * Wrong codes return null after a short delay (slows guessing; a code has
--     80 random bits).
-- =====================================================================

-- accept the shorter, human-friendly codes (16 characters) for new applications
create or replace function public.dpr_norm_code(t text) returns text
language sql immutable as $$ select upper(regexp_replace(coalesce(t,''), '[^A-Za-z0-9]', '', 'g')) $$;

create index if not exists dpr_applications_code_idx on public.dpr_applications (public.dpr_norm_code(edit_token));

-- save_dpr: allow 16+ character tokens (was 32+)
do $$
declare src text;
begin
  select pg_get_functiondef('public.save_dpr(uuid,text,text,jsonb,jsonb)'::regprocedure) into src;
  if position('length(p_token) < 32' in src) > 0 then
    execute replace(src, 'length(p_token) < 32', 'length(p_token) < 16');
  end if;
end $$;

create or replace function public.load_dpr(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c text := public.dpr_norm_code(p_code);
  r record;
begin
  if length(c) < 16 then
    perform pg_sleep(0.4);
    return null;
  end if;
  select application_id, edit_token, form_data, status, current_step, updated_at
    into r
    from dpr_applications
   where public.dpr_norm_code(edit_token) = c
   limit 1;
  if not found then
    perform pg_sleep(0.4);
    return null;
  end if;
  return jsonb_build_object(
    'application_id', r.application_id,
    'id', r.application_id,          -- kept for the website
    'token', r.edit_token,
    'form_data', coalesce(r.form_data, '{}'::jsonb) - '_calc',
    'status', r.status,
    'current_step', r.current_step,
    'updated_at', r.updated_at);
end;
$$;

revoke all on function public.load_dpr(text) from public;
grant execute on function public.load_dpr(text) to anon, authenticated;

-- >>>>> from delete.sql
-- =====================================================================
-- DocpreneurFin Pro — let a user permanently delete their own application
-- Run in Supabase → SQL Editor (after schema.sql, storage.sql, resume.sql).
--
--   * delete_dpr(id, code) deletes ONE application, only when the code matches.
--     The per-step tables (dpr_step01_… ) are removed with it (on delete cascade).
--   * The id is remembered in dpr_deleted so a still-open browser tab cannot
--     re-create the application by autosaving.
--   * Uploaded photos: delete_dpr opens a 10-minute "delete window" for that
--     application's photo folder, and the website then removes the photos with
--     the Storage API (Supabase does not allow deleting files with SQL).
-- =====================================================================

create table if not exists public.dpr_deleted (
  application_id uuid primary key,
  deleted_at  timestamptz not null default now(),
  facility    text
);
alter table public.dpr_deleted enable row level security;   -- no policies: not readable from the website

create table if not exists public.dpr_delete_grants (
  application_id uuid primary key,
  expires_at    timestamptz not null
);
alter table public.dpr_delete_grants enable row level security;  -- only used inside storage policies

-- block re-creating a deleted application
create or replace function public.dpr_block_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from dpr_deleted d where d.application_id = new.application_id) then
    raise exception 'This application was deleted' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
drop trigger if exists dpr_block_deleted_trg on public.dpr_applications;
create trigger dpr_block_deleted_trg before insert on public.dpr_applications
  for each row execute function public.dpr_block_deleted();

-- true while a delete window is open for this photo folder
create or replace function public.dpr_can_delete_folder(p_folder text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from dpr_delete_grants g
     where g.application_id::text = p_folder
       and g.expires_at > now())
$$;
grant execute on function public.dpr_can_delete_folder(text) to anon, authenticated;

create or replace function public.delete_dpr(p_id uuid, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  c text := public.dpr_norm_code(p_code);
  r record;
begin
  select application_id, edit_token, facility_name into r
    from dpr_applications
   where application_id = p_id;
  if not found then
    -- never saved (or already deleted): nothing to do, but still block re-creation
    insert into dpr_deleted(application_id) values (p_id) on conflict do nothing;
    return jsonb_build_object('deleted', false, 'reason', 'not_found');
  end if;
  if length(c) < 16 or public.dpr_norm_code(r.edit_token) <> c then
    perform pg_sleep(0.4);
    return jsonb_build_object('deleted', false, 'reason', 'wrong_code');
  end if;

  insert into dpr_deleted(application_id, facility) values (r.application_id, r.facility_name) on conflict do nothing;
  insert into dpr_delete_grants(application_id, expires_at) values (r.application_id, now() + interval '10 minutes')
    on conflict (application_id) do update set expires_at = excluded.expires_at;
  delete from dpr_applications where application_id = r.application_id;           -- step tables go with it
  delete from dpr_delete_grants where expires_at < now() - interval '1 day';
  return jsonb_build_object('deleted', true);
end;
$$;
revoke all on function public.delete_dpr(uuid, text) from public;
grant execute on function public.delete_dpr(uuid, text) to anon, authenticated;

-- photos: the website may list + delete files in that folder only while its delete window is open
drop policy if exists "website can list photos being deleted" on storage.objects;
create policy "website can list photos being deleted" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'dpr-images' and public.dpr_can_delete_folder(split_part(name, '/', 1)));

drop policy if exists "website can delete photos being deleted" on storage.objects;
create policy "website can delete photos being deleted" on storage.objects
  for delete to anon, authenticated
  using (bucket_id = 'dpr-images' and public.dpr_can_delete_folder(split_part(name, '/', 1)));

-- =====================================================================
-- 5. one application_id → the complete application (admin / server use)
-- =====================================================================

-- get_application: master row + every sub-table, in one JSON document
--   select public.get_application('<application_id>');
create or replace function public.get_application(p_application_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  master jsonb;
  subs   jsonb := '{}'::jsonb;
  r      record;
  rows   jsonb;
  one_to_one boolean;
begin
  select to_jsonb(a) - 'edit_token' into master from dpr_applications a where a.application_id = p_application_id;
  if master is null then return null; end if;

  for r in select c.table_name from information_schema.columns c
            where c.table_schema='public' and c.column_name='application_id'
              and c.table_name like 'dpr\_step%' escape '\'
            order by c.table_name
  loop
    -- 1:1 tables use application_id as their primary key → return an object; others → an array
    select exists (select 1 from pg_index i join pg_attribute a on a.attrelid=i.indrelid and a.attnum=i.indkey[0]
                    where i.indrelid=('public.'||r.table_name)::regclass and i.indisprimary and a.attname='application_id')
      into one_to_one;
    execute format(
      'select coalesce(jsonb_agg(to_jsonb(t) - ''application_id''
                 order by (to_jsonb(t)->>''sort_order'')::int nulls last,
                          (to_jsonb(t)->>''year_no'')::int nulls last,
                          (to_jsonb(t)->>''id'')::bigint nulls last), ''[]''::jsonb)
         from public.%I t where t.application_id = $1', r.table_name)
      into rows using p_application_id;
    subs := subs || jsonb_build_object(r.table_name, case when one_to_one then coalesce(rows->0, 'null'::jsonb) else rows end);
  end loop;

  return jsonb_build_object('application_id', p_application_id, 'application', master, 'sub_tables', subs);
end;
$$;

-- delete_application: deletes the master row; ON DELETE CASCADE removes every sub-table row
-- in the same transaction. Returns how many rows were removed from each table.
--   select public.delete_application('<application_id>');
create or replace function public.delete_application(p_application_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  counts jsonb := '{}'::jsonb;
  r      record;
  n      bigint;
  fac    text;
begin
  select facility_name into fac from dpr_applications where application_id = p_application_id for update;
  if not found then return jsonb_build_object('deleted', false, 'reason', 'not_found'); end if;

  for r in select c.table_name from information_schema.columns c
            where c.table_schema='public' and c.column_name='application_id' and c.table_name like 'dpr\_step%' escape '\'
  loop
    execute format('select count(*) from public.%I where application_id = $1', r.table_name) into n using p_application_id;
    if n > 0 then counts := counts || jsonb_build_object(r.table_name, n); end if;
  end loop;

  insert into dpr_deleted(application_id, facility) values (p_application_id, fac) on conflict do nothing;
  -- photos are files in Storage: open the 10-minute window so the website/admin can remove them
  insert into dpr_delete_grants(application_id, expires_at) values (p_application_id, now() + interval '10 minutes')
    on conflict (application_id) do update set expires_at = excluded.expires_at;
  delete from dpr_applications where application_id = p_application_id;   -- cascades to all sub-tables

  return jsonb_build_object('deleted', true, 'application_id', p_application_id, 'sub_table_rows_deleted', counts);
end;
$$;

-- admin-only: not callable with the website's public key
revoke all on function public.get_application(uuid)    from public, anon, authenticated;
revoke all on function public.delete_application(uuid) from public, anon, authenticated;
grant execute on function public.get_application(uuid)    to service_role;
grant execute on function public.delete_application(uuid) to service_role;

commit;
