-- R1.3.129 hotfix: lab report save fails on Supabase with "DELETE requires a WHERE clause".
--
-- Root cause: ward_save_lab_report (R1.3.128) clears its scratch temp table with
--   DELETE FROM _lab_new;
-- Supabase's API role (authenticator) preloads the safeupdate extension, which rejects any
-- DELETE/UPDATE without a WHERE clause, including inside SECURITY DEFINER functions. The whole
-- RPC aborts and rolls back, so nothing was written and the phone's outbox keeps the report.
--
-- Fix: give the statement an explicit WHERE (scratch table, transaction-local, every row is ours).
-- DB-only: no app change needed; queued saves succeed on their next retry.
-- Also: a guard that scans every public function for DELETE/UPDATE without WHERE and fails this
-- migration if any remain, so the same glitch cannot hide elsewhere.
-- Idempotent. Keeps signature, SECURITY DEFINER, search_path and grants (CREATE OR REPLACE).

do $$
declare v_def text;
  v_bad text := 'DELETE FROM _lab_new;';
  v_good text := 'DELETE FROM _lab_new WHERE true; -- R1.3.129: explicit WHERE for safeupdate';
begin
  if to_regprocedure('public.ward_save_lab_report(uuid,jsonb)') is null then
    raise exception 'ward_save_lab_report missing; apply r1_3_128_lab_reports first';
  end if;
  select pg_get_functiondef('public.ward_save_lab_report(uuid,jsonb)'::regprocedure) into v_def;
  if position('DELETE FROM _lab_new WHERE true' in v_def) > 0 then
    raise notice 'ward_save_lab_report already fixed'; return;
  end if;
  if position(v_bad in v_def) = 0 then
    raise exception 'ward_save_lab_report anchor not found; inspect before patching';
  end if;
  v_def := replace(v_def, v_bad, v_good);
  execute v_def;
end $$;

-- guard: no public function may contain DELETE/UPDATE without a WHERE
do $$
declare v_list text;
begin
  select string_agg(fn || ': ' || left(regexp_replace(st, '\s+', ' ', 'g'), 120), E'\n') into v_list
  from (
    select p.oid::regprocedure::text fn, m[1] st
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace,
         regexp_matches(pg_get_functiondef(p.oid),
           '((?:\mdelete\s+from\s|\mupdate\s+[a-z_."]+(?:\s+(?:as\s+)?[a-z_]+)?\s+set\s)[^;]*;)', 'gi') m
    where n.nspname = 'public' and p.prokind = 'f'
  ) s
  where st !~* '\mwhere\M';
  if v_list is not null then
    raise exception E'DELETE/UPDATE without WHERE remains (blocked by safeupdate):\n%', v_list;
  end if;
end $$;

notify pgrst, 'reload schema';
