-- R1.9.3 weekly cleanup. APPLIED to Supabase on 2026-11-15 by the operator. Do not re-apply.
-- Job ward-weekly-cleanup runs 0 22 * * 6 UTC, which is Sunday 03:30 IST.
--
-- Rollback:
-- select cron.unschedule('ward-weekly-cleanup');
-- drop function if exists public.ward_weekly_cleanup();

create or replace function public.ward_weekly_cleanup()
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_cron int := 0;
  v_ev int := 0;
  v_dl int := 0;
begin
  delete from cron.job_run_details
  where coalesce(end_time, start_time) < now() - interval '7 days';
  get diagnostics v_cron = row_count;

  select count(*) into v_dl
  from public.notification_deliveries d
  join public.notification_events e on e.id = d.notification_id
  where e.created_at < now() - interval '30 days'
    and (e.held_until is null or e.held_until < now());

  delete from public.notification_events e
  where e.created_at < now() - interval '30 days'
    and (e.held_until is null or e.held_until < now());
  get diagnostics v_ev = row_count;

  return jsonb_build_object(
    'ok', true,
    'at', now(),
    'cron_log_deleted', v_cron,
    'notification_events_deleted', v_ev,
    'notification_deliveries_deleted', v_dl
  );
end;
$fn$;

revoke all on function public.ward_weekly_cleanup() from public, anon, authenticated;
grant execute on function public.ward_weekly_cleanup() to service_role;

do $s$
begin
  if exists (select 1 from cron.job where jobname = 'ward-weekly-cleanup') then
    perform cron.unschedule('ward-weekly-cleanup');
  end if;
  perform cron.schedule('ward-weekly-cleanup', '0 22 * * 6', 'select public.ward_weekly_cleanup()');
end
$s$;
