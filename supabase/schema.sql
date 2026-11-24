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
