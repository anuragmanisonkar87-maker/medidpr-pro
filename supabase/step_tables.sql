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
