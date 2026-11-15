-- Read-only checks before applying migrations/r19_2_keepalive_storage.sql.
-- Do not run the migration from this file.

select current_database() as db,
       pg_database_size(current_database()) as db_bytes,
       round(pg_database_size(current_database()) / 1024.0 / 1024.0, 1) as db_mb;

select jobname, schedule, command
from cron.job
where jobname like 'ward-%'
order by jobname;

select conname, pg_get_constraintdef(oid) as def
from pg_constraint
where conrelid = 'public.notification_events'::regclass
  and contype = 'c'
order by conname;
