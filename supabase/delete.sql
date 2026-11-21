-- =====================================================================
-- MediDPR Pro — let a user permanently delete their own application
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
