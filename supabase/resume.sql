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
