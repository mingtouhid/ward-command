-- R1.9.2 keep-alive ping and monthly storage alert. NOT APPLIED.
-- Additive and idempotent. No RLS policies. No drops of existing rows.
-- Archive alerts use the existing notification_events path:
--   event_type archive, category archive, recipient_scope admins, dispatch_due true.
-- The CHECK already allows that triple (priority normal or high). This file does not change it.
-- dispatch-notification is what sends a row once dispatch_due is true. Its source is not in this repo.
--
-- Rollback:
-- select cron.unschedule('ward-storage-check');
-- revoke all on function public.ward_storage_check(bigint) from public, service_role;
-- revoke all on function public.ward_ping() from public, anon, authenticated;
-- drop function if exists public.ward_storage_check(bigint);
-- drop function if exists public.ward_ping();
-- drop table if exists public.ward_storage_stats;

create or replace function public.ward_ping()
returns jsonb
language sql
stable
security invoker
set search_path to pg_catalog
as $fn$
  select jsonb_build_object('ok', true, 'at', now());
$fn$;

revoke all on function public.ward_ping() from public;
grant execute on function public.ward_ping() to anon, authenticated;

create table if not exists public.ward_storage_stats (
  id bigserial primary key,
  measured_at timestamptz not null default now(),
  db_bytes bigint,
  level text not null check (level in ('ok', 'warn', 'urgent'))
);

alter table public.ward_storage_stats enable row level security;
alter table public.ward_storage_stats force row level security;
revoke all on table public.ward_storage_stats from public, anon, authenticated;
revoke all on sequence public.ward_storage_stats_id_seq from public, anon, authenticated;

comment on table public.ward_storage_stats is
  'R1.9.2: one row per storage measurement. No policies. Written only by ward_storage_check.';

create or replace function public.ward_storage_check(p_simulate_bytes bigint default null)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_bytes bigint;
  v_level text;
  v_mb numeric;
  v_month text;
  v_key text;
  v_exists boolean;
  v_id uuid;
  v_priority text;
begin
  if p_simulate_bytes is not null
     and current_user not in ('postgres', 'supabase_admin', 'service_role') then
    raise exception 'simulated storage checks are service-role only';
  end if;
  v_bytes := coalesce(p_simulate_bytes, pg_catalog.pg_database_size(current_database()));
  if v_bytes > 450 * 1024 * 1024 then
    v_level := 'urgent';
  elsif v_bytes > 350 * 1024 * 1024 then
    v_level := 'warn';
  else
    v_level := 'ok';
  end if;
  insert into public.ward_storage_stats(db_bytes, level) values (v_bytes, v_level);
  v_mb := round(v_bytes / 1024.0 / 1024.0, 1);
  if v_level = 'ok' then
    return jsonb_build_object('ok', true, 'bytes', v_bytes, 'mb', v_mb, 'level', v_level, 'notified', false);
  end if;
  v_month := to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM');
  v_key := 'storage:' || v_level || ':' || v_month;
  v_priority := case when v_level = 'urgent' then 'high' else 'normal' end;
  select exists (
    select 1 from public.notification_events e
    where e.event_type = 'archive'
      and e.category = 'archive'
      and e.recipient_scope = 'admins'
      and (
        e.dedupe_key = v_key
        or (
          e.metadata->>'level' = v_level
          and to_char(e.created_at at time zone 'Asia/Kolkata', 'YYYY-MM') = v_month
        )
      )
  ) into v_exists;
  if v_exists then
    return jsonb_build_object('ok', true, 'bytes', v_bytes, 'mb', v_mb, 'level', v_level, 'notified', false, 'deduped', true);
  end if;
  insert into public.notification_events(
    event_type, category, priority, title, body, target_url, recipient_scope,
    dedupe_key, metadata, dispatch_due
  ) values (
    'archive', 'archive', v_priority,
    case when v_level = 'urgent' then 'Database storage urgent' else 'Database storage warning' end,
    'The ward database is ' || v_mb || ' MB. Warning starts above 350 MB. Urgent starts above 450 MB.',
    './#/home',
    'admins',
    v_key,
    jsonb_build_object('level', v_level, 'bytes', v_bytes, 'mb', v_mb, 'month', v_month, 'kind', 'storage'),
    true
  )
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  return jsonb_build_object(
    'ok', true, 'bytes', v_bytes, 'mb', v_mb, 'level', v_level,
    'notified', v_id is not null, 'deduped', v_id is null, 'notification_id', v_id
  );
end;
$fn$;

revoke all on function public.ward_storage_check(bigint) from public, anon, authenticated;
grant execute on function public.ward_storage_check(bigint) to service_role;

do $sched$
begin
  if to_regprocedure('cron.schedule(text,text,text)') is null or to_regclass('cron.job') is null then
    raise exception 'pg_cron is required for the monthly storage check';
  end if;
  if exists (select 1 from cron.job where jobname = 'ward-storage-check') then
    perform cron.unschedule('ward-storage-check');
  end if;
  perform cron.schedule('ward-storage-check', '0 23 1 * *', 'select public.ward_storage_check()');
end;
$sched$;
