-- Rollback test for migrations/r19_2_keepalive_storage.sql.
-- Apply the migration first, then run this whole script. It ends in ROLLBACK.
-- Not executed against Supabase from this repository.

begin;

-- Anon can ping and cannot read the stats table or run the check.
set local role anon;
select public.ward_ping() as ping;
do $deny$
begin
  begin
    perform public.ward_storage_check();
    raise exception 'anon was allowed to run ward_storage_check';
  exception when insufficient_privilege then
    null;
  end;
end;
$deny$;
reset role;

-- Below 350 MB: a stats row, no notification.
select public.ward_storage_check(100::bigint * 1024 * 1024) as ok_result;
select count(*) as ok_events
from public.notification_events
where dedupe_key like 'storage:%'
  and to_char(created_at at time zone 'Asia/Kolkata', 'YYYY-MM')
      = to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM');

-- Warn once, then the same level is deduped.
select public.ward_storage_check(400::bigint * 1024 * 1024) as warn_first;
select public.ward_storage_check(400::bigint * 1024 * 1024) as warn_second;
select count(*) as warn_events
from public.notification_events
where dedupe_key = 'storage:warn:' || to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM');

-- Urgent is a different level, so it alerts once, at high priority.
select public.ward_storage_check(500::bigint * 1024 * 1024) as urgent_first;
select public.ward_storage_check(500::bigint * 1024 * 1024) as urgent_second;
select priority
from public.notification_events
where dedupe_key = 'storage:urgent:' || to_char(now() at time zone 'Asia/Kolkata', 'YYYY-MM');

select level, count(*) from public.ward_storage_stats group by level order by level;

rollback;
