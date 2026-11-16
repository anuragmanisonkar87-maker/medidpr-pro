-- =====================================================================
-- MediDPR Pro — photo storage (Step 13: logo, building, equipment, team)
-- Run once in Supabase → SQL Editor (after schema.sql).
--
--   * Private bucket "dpr-images": max 2 MB per file, JPG/PNG/WEBP only.
--   * The website (anon key) may UPLOAD only — no list, read, overwrite or delete.
--   * Files are stored as <submission-id>/<slot>-<timestamp>.jpg and the path is
--     saved in dpr_submissions.form_data -> 'images'.
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
select id, status, facility_name, facility_type, contact_name, email, phone, city, state,
       round(project_cost/100000.0, 2) as project_cost_lakh,
       round(bank_loan/100000.0, 2)    as bank_loan_lakh,
       avg_dscr, email_verified, phone_verified, current_step, download_count,
       created_at, updated_at,
       coalesce((select count(*) from jsonb_object_keys(coalesce(form_data->'images','{}'::jsonb))), 0) as photos
from public.dpr_submissions
order by updated_at desc;
