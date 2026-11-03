-- Rollback of 20261102b_archive_rerun_request.sql (stops the job, drops the functions and the two columns).
select cron.unschedule(j.jobid) from cron.job j where j.jobname = 'ward-archive-rerun';
drop function if exists public.ward_archive_request_rerun(text);
drop function if exists public.ward_archive_rerun_tick();
drop function if exists public.ward_archive_post(text, boolean);
drop function if exists public.ward_archive_rerun_requested(text);
alter table public.archive_manifest drop column if exists rerun_done_at;
alter table public.archive_manifest drop column if exists rerun_requested_at;
