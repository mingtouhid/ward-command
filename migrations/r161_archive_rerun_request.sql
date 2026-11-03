-- Ward Sync — archive v2, one-time re-run of a verified v1 month triggered from SQL (no API key handling).
--   select public.ward_archive_request_rerun('2026-10');
-- 1. archive_manifest.rerun_requested_at / rerun_done_at: the request is recorded on the manifest row.
-- 2. ward_archive_rerun_requested(month): the edge function lets a CRON-authenticated call do rerun=v2 only when this is true.
-- 3. ward_archive_request_rerun(month): checks the row is a verified v1 archive, records the request, schedules the
--    short-lived pg_cron job 'ward-archive-rerun' (every minute) and fires the first call at once.
-- 4. ward_archive_rerun_tick(): what that job runs. v1 verified + requested -> post rerun=v2; v2 in progress -> post one
--    normal step; v2 verified -> mark done and unschedule itself; failed -> unschedule itself (manual retry as before).
-- The edge call is the same pg_net call ward_archive_tick() makes (Vault ward_archive_cron_secret header).
-- Rollback: 20261102b_archive_rerun_request-rollback.sql

alter table public.archive_manifest add column if not exists rerun_requested_at timestamptz;
alter table public.archive_manifest add column if not exists rerun_done_at timestamptz;

create or replace function public.ward_archive_rerun_requested(p_month text)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'public'
as $function$
  select exists (select 1 from public.archive_manifest a
                  where p_month ~ '^\d{4}-(0[1-9]|1[0-2])$' and a.month = to_date(p_month || '-01', 'YYYY-MM-DD')
                    and a.rerun_requested_at is not null and a.rerun_done_at is null
                    and a.archive_version = 1 and a.status = 'verified');
$function$;

-- internal: one pg_net call to monthly-archive with the cron secret (same as ward_archive_tick)
create or replace function public.ward_archive_post(p_month text, p_rerun boolean)
returns bigint
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare v_secret text; v_req bigint;
begin
  select s.decrypted_secret into v_secret from vault.decrypted_secrets s where s.name = 'ward_archive_cron_secret';
  if v_secret is null then raise exception 'no cron secret'; end if;
  select net.http_post(
    url := 'https://ocgmhwetdpcthwbcnbqz.supabase.co/functions/v1/monthly-archive',
    body := jsonb_build_object('month', p_month, 'source', 'cron') || case when p_rerun then jsonb_build_object('rerun', 'v2') else '{}'::jsonb end,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-ward-archive-secret', v_secret),
    timeout_milliseconds := 150000) into v_req;
  return v_req;
end $function$;

create or replace function public.ward_archive_rerun_tick()
returns text
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare v_row public.archive_manifest%rowtype; v_m text;
begin
  select * into v_row from public.archive_manifest
   where rerun_requested_at is not null and rerun_done_at is null
   order by rerun_requested_at limit 1;
  if v_row.id is null then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'ward-archive-rerun';
    return 'idle';
  end if;
  v_m := to_char(v_row.month, 'YYYY-MM');
  if v_row.archive_version >= 2 and v_row.status = 'verified' then
    update public.archive_manifest set rerun_done_at = now(), updated_at = now() where id = v_row.id;
    if not exists (select 1 from public.archive_manifest where rerun_requested_at is not null and rerun_done_at is null) then
      perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'ward-archive-rerun';
    end if;
    return 'done ' || v_m;
  end if;
  if v_row.status = 'failed' then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'ward-archive-rerun';
    return 'failed ' || v_m || ' (manual retry needed; job stopped)';
  end if;
  if v_row.lease_until is not null and v_row.lease_until > now() then return 'busy ' || v_m; end if;
  if v_row.archive_version = 1 and v_row.rerun_requested_at < now() - interval '2 hours' then
    perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'ward-archive-rerun';
    return 'gave up on ' || v_m || ': the v1 -> _v1 move did not complete in 2 hours (v1 row unchanged; request again to retry)';
  end if;
  return (case when v_row.archive_version = 1 then 'rerun ' else 'step ' end) || v_m || ' requested ' ||
         public.ward_archive_post(v_m, v_row.archive_version = 1);
end $function$;

create or replace function public.ward_archive_request_rerun(p_month text)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare v_row public.archive_manifest%rowtype;
begin
  if p_month is null or p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'p_month must be YYYY-MM'; end if;
  if p_month >= to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM') then raise exception 'month % is not finished yet', p_month; end if;
  select * into v_row from public.archive_manifest where month = to_date(p_month || '-01', 'YYYY-MM-DD');
  if v_row.id is null then return jsonb_build_object('requested', false, 'reason', 'no archive for this month'); end if;
  if v_row.archive_version >= 2 then return jsonb_build_object('requested', false, 'reason', 'already v2', 'status', v_row.status); end if;
  if v_row.status <> 'verified' then return jsonb_build_object('requested', false, 'reason', 'v1 archive is not verified (' || v_row.status || ')'); end if;
  update public.archive_manifest set rerun_requested_at = now(), rerun_done_at = null, updated_at = now()
   where id = v_row.id and archive_version = 1 and status = 'verified';
  perform cron.schedule('ward-archive-rerun', '* * * * *', 'select public.ward_archive_rerun_tick()');
  return jsonb_build_object('requested', true, 'month', p_month, 'first_call', public.ward_archive_rerun_tick());
end $function$;

revoke all on function public.ward_archive_rerun_requested(text) from public, anon, authenticated;
revoke all on function public.ward_archive_post(text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.ward_archive_rerun_tick() from public, anon, authenticated, service_role;
revoke all on function public.ward_archive_request_rerun(text) from public, anon, authenticated;
grant execute on function public.ward_archive_rerun_requested(text) to service_role;
grant execute on function public.ward_archive_request_rerun(text) to service_role;
