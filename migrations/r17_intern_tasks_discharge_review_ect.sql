-- R1.7 intern tasks, discharge-review audit, scheduled ECT completion
-- PREPARED, NOT APPLIED. Do not run against production from this change.
-- Safe to re-run. No UPDATE/DELETE of clinical rows without WHERE.
-- Rollback: migrations/r17_intern_tasks_discharge_review_ect.rollback.sql

create table if not exists public.intern_assignments (
  id text primary key,
  patient_id text not null,
  kind text not null,
  title text not null,
  due_on date not null,
  status text not null default 'open',
  assigned_by text not null,
  assigned_by_name text,
  completed_by text,
  completed_by_name text,
  completed_at timestamptz,
  report_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint intern_assignments_kind_check check (kind in ('report','general')),
  constraint intern_assignments_status_check check (status in ('open','done')),
  constraint intern_assignments_title_check check (char_length(btrim(title)) between 1 and 140)
);
create index if not exists intern_assignments_patient_idx on public.intern_assignments(patient_id, status, due_on);
alter table public.intern_assignments enable row level security;
alter table public.intern_assignments force row level security;
revoke all on table public.intern_assignments from public, anon, authenticated;
grant all on table public.intern_assignments to postgres, service_role;

create table if not exists public.ect_schedule_completions (
  id text primary key,
  plan_id text not null,
  patient_id text not null,
  occurrence_at timestamptz not null,
  completed_by text not null,
  completed_by_name text,
  completed_at timestamptz not null default now(),
  undone_by text,
  undone_by_name text,
  undone_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists ect_schedule_completions_open_uidx
  on public.ect_schedule_completions(plan_id, occurrence_at) where undone_at is null;
alter table public.ect_schedule_completions enable row level security;
alter table public.ect_schedule_completions force row level security;
revoke all on table public.ect_schedule_completions from public, anon, authenticated;
grant all on table public.ect_schedule_completions to postgres, service_role;

create table if not exists public.discharge_review_overrides (
  id text primary key,
  patient_id text not null,
  admitted_at timestamptz not null,
  resident_id text not null,
  resident_name text,
  reason text not null,
  missing_mse boolean not null,
  missing_report boolean not null,
  mse_ids text[] not null default '{}',
  report_ids text[] not null default '{}',
  included_mse_id text,
  source text not null,
  server_at timestamptz not null default now(),
  constraint discharge_review_overrides_reason_check check (char_length(btrim(reason)) >= 3),
  constraint discharge_review_overrides_source_check check (source in ('ward_discharge','observation'))
);
create index if not exists discharge_review_overrides_patient_idx
  on public.discharge_review_overrides(patient_id, server_at desc);
alter table public.discharge_review_overrides enable row level security;
alter table public.discharge_review_overrides force row level security;
revoke all on table public.discharge_review_overrides from public, anon, authenticated;
grant all on table public.discharge_review_overrides to postgres, service_role;

create or replace function public.r17_task_json(t public.intern_assignments)
returns jsonb
language sql
immutable
as $fn$
  select jsonb_build_object(
    'id', t.id, 'patient_id', t.patient_id, 'kind', t.kind, 'title', t.title,
    'due_on', t.due_on, 'status', t.status, 'assigned_by_name', t.assigned_by_name,
    'completed_by', t.completed_by, 'completed_by_name', t.completed_by_name,
    'completed_at', t.completed_at, 'report_id', t.report_id);
$fn$;

create or replace function public.r17_actor(p_token uuid)
returns table(actor_id text, actor_role text, actor_name text, actor_kind text)
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_id text; v_role text; v_name text;
begin
  begin
    select * into a from public.ward_intern_actor(p_token);
  exception when others then
    a := null;
  end;
  if a is not null and a.resident_id is not null then
    select coalesce(display_name, username, '') into v_name from public.residents where id = a.resident_id;
    actor_id := a.resident_id; actor_role := 'intern'; actor_name := coalesce(v_name, ''); actor_kind := 'intern';
    return next; return;
  end if;
  select s.resident_id, lower(coalesce(r.role, '')), coalesce(r.display_name, r.username, '')
    into v_id, v_role, v_name
  from public.ward_sessions s
  join public.residents r on r.id = s.resident_id
  where s.token = p_token and s.expires_at > now() and r.active;
  if v_id is null then raise exception 'Invalid or expired ward session'; end if;
  actor_id := v_id; actor_role := v_role; actor_name := v_name; actor_kind := 'ward';
  return next;
end;
$fn$;

create or replace function public.r17_write_review_override(
  p_patient_id text, p_resident_id text, p_resident_name text,
  p_reason text, p_source text, p_included_mse text
) returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_adm timestamptz; v_reason text; v_miss_mse boolean; v_miss_rep boolean;
  v_mse_ids text[]; v_rep_ids text[]; v_id text;
begin
  select admitted_at into v_adm from public.patients where id = p_patient_id;
  if v_adm is null then return jsonb_build_object('stored', false); end if;
  select coalesce(array_agg(id), '{}') into v_mse_ids from (
    select m.id from public.mse_entries m
    where m.patient_id = p_patient_id and m.deleted_at is null
      and m.created_at >= v_adm - interval '6 hours'
    order by m.created_at desc limit 50) s;
  select coalesce(array_agg(id), '{}') into v_rep_ids from (
    select r.id from public.lab_reports r
    where r.patient_id = p_patient_id and r.deleted_at is null
      and coalesce(r.reported_at, r.created_at) >= v_adm - interval '6 hours'
    order by r.created_at desc limit 50) s;
  v_miss_mse := cardinality(v_mse_ids) = 0;
  v_miss_rep := cardinality(v_rep_ids) = 0;
  v_reason := nullif(btrim(coalesce(p_reason, '')), '');
  if (v_miss_mse or v_miss_rep) and v_reason is not null and char_length(v_reason) >= 3 then
    v_id := 'dro_' || substr(md5(clock_timestamp()::text || random()::text || p_patient_id), 1, 16);
    insert into public.discharge_review_overrides(
      id, patient_id, admitted_at, resident_id, resident_name, reason,
      missing_mse, missing_report, mse_ids, report_ids, included_mse_id, source, server_at)
    values (v_id, p_patient_id, v_adm, p_resident_id, p_resident_name, v_reason,
      v_miss_mse, v_miss_rep, v_mse_ids, v_rep_ids, nullif(p_included_mse, ''), p_source, now());
  else
    v_id := null;
  end if;
  return jsonb_build_object('stored', v_id is not null, 'override_id', v_id,
    'missing_mse', v_miss_mse, 'missing_report', v_miss_rep);
end;
$fn$;

create or replace function public.ward_assign_intern_task(p_token uuid, p_row jsonb)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_id text; v_pid text; v_kind text; v_title text; v_due date; v_status text; v_row public.intern_assignments;
begin
  select * into a from public.r17_actor(p_token);
  if a.actor_role not in ('resident','admin') then raise exception 'Only a resident can assign intern tasks'; end if;
  if p_row is null or jsonb_typeof(p_row) <> 'object' then raise exception 'Task is required'; end if;
  v_id := nullif(btrim(coalesce(p_row->>'id','')), '');
  v_pid := nullif(btrim(coalesce(p_row->>'patient_id','')), '');
  v_kind := nullif(btrim(coalesce(p_row->>'kind','')), '');
  v_title := btrim(coalesce(p_row->>'title',''));
  if v_id is null or v_id !~ '^[A-Za-z0-9._:-]{1,80}$' then raise exception 'Task id is invalid'; end if;
  if v_kind not in ('report','general') then raise exception 'Task type is invalid'; end if;
  if char_length(v_title) < 1 or char_length(v_title) > 140 then raise exception 'Task title is invalid'; end if;
  begin
    v_due := (p_row->>'due_on')::date;
  exception when others then
    raise exception 'Due date is invalid';
  end;
  if v_due is null then raise exception 'Due date is required'; end if;
  select coalesce(active_status,'admitted') into v_status from public.patients where id = v_pid;
  if v_status is null or v_status = 'discharged' then raise exception 'Patient is not on the ward'; end if;
  select * into v_row from public.intern_assignments where id = v_id;
  if found then
    if v_row.patient_id <> v_pid then raise exception 'Task id is already used'; end if;
    return jsonb_build_object('ok', true, 'idempotent', true, 'task', public.r17_task_json(v_row));
  end if;
  insert into public.intern_assignments(id, patient_id, kind, title, due_on, status, assigned_by, assigned_by_name)
  values (v_id, v_pid, v_kind, v_title, v_due, 'open', a.actor_id, a.actor_name)
  returning * into v_row;
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('ita:'||v_id, v_pid, 'task', 'Intern task assigned', v_kind||' · due '||v_due::text, a.actor_id, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'idempotent', false, 'task', public.r17_task_json(v_row));
end;
$fn$;

create or replace function public.ward_complete_intern_task(p_token uuid, p_id text)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_row public.intern_assignments;
begin
  select * into a from public.r17_actor(p_token);
  if a.actor_role <> 'intern' then raise exception 'Interns complete intern tasks'; end if;
  select * into v_row from public.intern_assignments where id = p_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_row.kind <> 'general' then raise exception 'Report tasks complete only when a saved report is linked'; end if;
  if v_row.status = 'done' then
    return jsonb_build_object('ok', true, 'idempotent', true, 'task', public.r17_task_json(v_row));
  end if;
  update public.intern_assignments
    set status = 'done', completed_by = a.actor_id, completed_by_name = a.actor_name,
        completed_at = now(), updated_at = now()
    where id = p_id and status = 'open'
    returning * into v_row;
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('itc:'||p_id, v_row.patient_id, 'task', 'Intern task completed', 'general', a.actor_id, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'idempotent', false, 'task', public.r17_task_json(v_row));
end;
$fn$;

create or replace function public.ward_undo_intern_task(p_token uuid, p_id text)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_row public.intern_assignments;
begin
  select * into a from public.r17_actor(p_token);
  select * into v_row from public.intern_assignments where id = p_id for update;
  if not found then raise exception 'Task not found'; end if;
  if v_row.kind <> 'general' or v_row.status <> 'done' then raise exception 'Nothing to undo'; end if;
  if a.actor_role = 'intern' and a.actor_id is distinct from v_row.completed_by then
    raise exception 'Only the intern who completed it, or a resident, can undo';
  end if;
  if a.actor_role not in ('intern','resident','admin') then
    raise exception 'This login cannot undo the task';
  end if;
  update public.intern_assignments
    set status = 'open', completed_by = null, completed_by_name = null, completed_at = null, updated_at = now()
    where id = p_id
    returning * into v_row;
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('itu:'||p_id||':'||substr(md5(clock_timestamp()::text),1,8), v_row.patient_id, 'task', 'Intern task undone', 'general', a.actor_id, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'task', public.r17_task_json(v_row));
end;
$fn$;

create or replace function public.intern_assignment_on_report()
returns trigger
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare v_adm timestamptz; v_status text; v_when timestamptz; v_id text; v_name text;
begin
  if new.deleted_at is not null then
    if tg_op = 'UPDATE' and old.deleted_at is null then
      update public.intern_assignments
        set status = 'open', report_id = null, completed_by = null, completed_by_name = null,
            completed_at = null, updated_at = now()
        where report_id = new.id and kind = 'report' and status = 'done';
    end if;
    return new;
  end if;
  select admitted_at, coalesce(active_status,'admitted') into v_adm, v_status
    from public.patients where id = new.patient_id;
  if v_status is null or v_status = 'discharged' or v_adm is null then return new; end if;
  v_when := coalesce(new.reported_at, new.created_at, now());
  if v_when < v_adm - interval '6 hours' then return new; end if;
  select ia.id into v_id from public.intern_assignments ia
    where ia.patient_id = new.patient_id and ia.kind = 'report' and ia.status = 'open'
    order by ia.due_on, ia.created_at, ia.id
    limit 1
    for update;
  if v_id is null then return new; end if;
  select coalesce(display_name, username, '') into v_name from public.residents where id = new.created_by;
  update public.intern_assignments
    set status = 'done', report_id = new.id, completed_by = new.created_by,
        completed_by_name = coalesce(new.created_by_name, v_name), completed_at = now(), updated_at = now()
    where id = v_id and status = 'open';
  return new;
end;
$fn$;

drop trigger if exists intern_assignment_on_report on public.lab_reports;
create trigger intern_assignment_on_report
  after insert or update of deleted_at on public.lab_reports
  for each row execute function public.intern_assignment_on_report();

create or replace function public.ward_complete_scheduled_ect(p_token uuid, p_plan_id text, p_occurrence_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  a record; v_plan record; v_adm timestamptz; v_status text; v_row public.ect_schedule_completions;
begin
  select * into a from public.r17_actor(p_token);
  if a.actor_role not in ('resident','admin') then raise exception 'This login cannot mark ECT complete'; end if;
  select * into v_plan from public.ect_plans where id = p_plan_id for update;
  if not found then raise exception 'ECT plan not found'; end if;
  if coalesce(v_plan.status,'planned') <> 'planned' or v_plan.next_session_at is null then
    raise exception 'This ECT is not scheduled';
  end if;
  if abs(extract(epoch from (v_plan.next_session_at - p_occurrence_at))) > 1 then
    raise exception 'That is not the scheduled session';
  end if;
  select admitted_at, coalesce(active_status,'admitted') into v_adm, v_status from public.patients where id = v_plan.patient_id;
  if v_status = 'discharged' or v_adm is null then raise exception 'Patient is not on the ward'; end if;
  if p_occurrence_at < v_adm - interval '1 minute' then raise exception 'That session is not for the current admission'; end if;
  select * into v_row from public.ect_schedule_completions
    where plan_id = p_plan_id and occurrence_at = v_plan.next_session_at and undone_at is null;
  if found then
    return jsonb_build_object('ok', true, 'idempotent', true, 'schedule_next', false, 'completion', to_jsonb(v_row));
  end if;
  insert into public.ect_schedule_completions(id, plan_id, patient_id, occurrence_at, completed_by, completed_by_name, completed_at)
  values ('ectd_'||substr(md5(clock_timestamp()::text||random()::text||p_plan_id),1,16),
          p_plan_id, v_plan.patient_id, v_plan.next_session_at, a.actor_id, a.actor_name, now())
  returning * into v_row;
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('ectd:'||v_row.id, v_plan.patient_id, 'ect', 'ECT schedule marked complete',
          'Scheduled occurrence only. Next session was not changed.', a.actor_id, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'idempotent', false, 'schedule_next', false, 'completion', to_jsonb(v_row));
end;
$fn$;

create or replace function public.ward_undo_scheduled_ect(p_token uuid, p_id text)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_row public.ect_schedule_completions;
begin
  select * into a from public.r17_actor(p_token);
  if a.actor_role not in ('resident','admin') then raise exception 'This login cannot undo ECT completion'; end if;
  select * into v_row from public.ect_schedule_completions where id = p_id for update;
  if not found then raise exception 'Completion not found'; end if;
  if v_row.undone_at is not null then
    return jsonb_build_object('ok', true, 'idempotent', true, 'schedule_next', false, 'completion', to_jsonb(v_row));
  end if;
  update public.ect_schedule_completions
    set undone_at = now(), undone_by = a.actor_id, undone_by_name = a.actor_name
    where id = p_id
    returning * into v_row;
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('ectu:'||p_id, v_row.patient_id, 'ect', 'ECT schedule completion undone',
          'Next session was not changed.', a.actor_id, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'idempotent', false, 'schedule_next', false, 'completion', to_jsonb(v_row));
end;
$fn$;

create or replace function public.ward_list_r17_status(p_token uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_tasks jsonb; v_ect jsonb;
begin
  select * into a from public.r17_actor(p_token);
  if a.actor_kind = 'intern' then raise exception 'Not available for intern accounts'; end if;
  select coalesce(jsonb_agg(public.r17_task_json(ia) order by ia.due_on, ia.created_at, ia.id), '[]'::jsonb)
    into v_tasks
  from public.intern_assignments ia
  join public.patients p on p.id = ia.patient_id and coalesce(p.active_status,'admitted') <> 'discharged';
  select coalesce(jsonb_agg(to_jsonb(c) order by c.completed_at desc), '[]'::jsonb) into v_ect from (
    select id, plan_id, patient_id, occurrence_at, completed_by, completed_by_name, completed_at, undone_at
    from public.ect_schedule_completions
    where undone_at is null and occurrence_at > now() - interval '21 days'
  ) c;
  return jsonb_build_object('ok', true, 'intern_tasks', v_tasks, 'ect_done', v_ect);
end;
$fn$;

create or replace function public.ward_discharge_with_review(
  p_token uuid, p_patient jsonb, p_bed_id text default null, p_assignment_ids text[] default '{}'::text[],
  p_ect_plan jsonb default null, p_discharge_advice text default null, p_discharge_meds jsonb default null,
  p_mrd_no text default null, p_discharge_review text default null, p_discharge_ect_sessions integer default null,
  p_discharge_requested_by text[] default null, p_discharge_requester_name text default null,
  p_discharge_mse jsonb default null, p_review_override jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  a record; v_result jsonb; v_pid text; v_adm timestamptz; v_mse_id text; v_data jsonb; v_saved text; v_audit jsonb;
begin
  select * into a from public.r17_actor(p_token);
  if a.actor_kind = 'intern' or a.actor_role in ('consultant','viewer') then
    raise exception 'This role cannot perform clinical writes';
  end if;
  v_pid := nullif(btrim(coalesce(p_patient->>'id','')), '');
  select admitted_at into v_adm from public.patients where id = v_pid;
  v_result := public.ward_discharge_patient(p_token, p_patient, p_bed_id, p_assignment_ids, p_ect_plan,
    p_discharge_advice, p_discharge_meds, p_mrd_no, p_discharge_review, p_discharge_ect_sessions,
    p_discharge_requested_by, p_discharge_requester_name);
  v_saved := null;
  if p_discharge_mse is not null and jsonb_typeof(p_discharge_mse) = 'object' then
    v_mse_id := nullif(btrim(coalesce(p_discharge_mse->>'id','')), '');
    v_data := p_discharge_mse->'data';
    if v_mse_id ~ '^[A-Za-z0-9._:-]{1,80}$' and jsonb_typeof(v_data) = 'object' and octet_length(v_data::text) < 30000 then
      begin
        insert into public.mse_entries(id, patient_id, kind, admitted_at, data, high_risk, summary, created_by, created_by_name, created_at, recorded_at)
        values (v_mse_id, v_pid, 'discharge', v_adm, v_data,
          case when p_discharge_mse->>'high_risk' in ('true','t','1') then true else false end,
          nullif(left(coalesce(p_discharge_mse->>'summary',''), 8000), ''),
          a.actor_id, a.actor_name, now(), now())
        on conflict (id) do nothing;
        select id into v_saved from public.mse_entries
          where id = v_mse_id and patient_id = v_pid and deleted_at is null;
      exception when others then
        v_saved := null;
      end;
    end if;
  end if;
  v_audit := public.r17_write_review_override(v_pid, a.actor_id, a.actor_name,
    case when p_review_override is null then null else p_review_override->>'reason' end,
    'ward_discharge', v_saved);
  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('mse_id', v_saved, 'review', v_audit);
end;
$fn$;

create or replace function public.ward_close_observation_with_review(
  p_token uuid, p_patient_id text, p_outcome text, p_referral_to text default null, p_reason text default null,
  p_discharge_mode text default null, p_discharge_outcome text default null, p_discharge_meds jsonb default null,
  p_review_override jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_result jsonb; v_audit jsonb;
begin
  select * into a from public.r17_actor(p_token);
  if a.actor_kind = 'intern' or a.actor_role in ('consultant','viewer') then
    raise exception 'This role cannot perform clinical writes';
  end if;
  v_result := public.ward_close_observation(p_token, p_patient_id, p_outcome, p_referral_to, p_reason,
    p_discharge_mode, p_discharge_outcome, p_discharge_meds);
  v_audit := public.r17_write_review_override(p_patient_id, a.actor_id, a.actor_name,
    case when p_review_override is null then null else p_review_override->>'reason' end,
    'observation', null);
  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object('review', v_audit);
end;
$fn$;

create or replace function public.ward_intern_read_state(p_token uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_me jsonb; v_patients jsonb; v_beds jsonb; v_vitals jsonb; v_scales jsonb; v_tasks jsonb;
begin
  select * into a from public.ward_intern_actor(p_token);
  select to_jsonb(x) into v_me from (select id, username, display_name, role, active from public.residents where id = a.resident_id) x;
  select coalesce(jsonb_agg(to_jsonb(p) order by p.admitted_at desc, p.id), '[]'::jsonb) into v_patients from (
    select id, patient_code, hospital_no, mrd_no, name, age, sex, diagnosis, secondary_dx, tertiary_dx, comorbidities,
           admitted_at, active_status, reason_for_admission, referred_by, consultant_name, consultant_name_2, admit_consultants
    from public.patients where coalesce(active_status, 'admitted') <> 'discharged') p;
  select coalesce(jsonb_agg(to_jsonb(b) order by b.bed_number, b.id), '[]'::jsonb) into v_beds from (
    select b.id, b.bed_number, b.section_id, b.active, b.current_patient_id from public.beds b
    join public.patients p on p.id = b.current_patient_id and coalesce(p.active_status, 'admitted') <> 'discharged') b;
  select coalesce(jsonb_agg(to_jsonb(v) order by v.recorded_at desc, v.id), '[]'::jsonb) into v_vitals from (
    select pv.id, pv.patient_id, pv.recorded_at, pv.bp_systolic, pv.bp_diastolic, pv.pulse, pv.resp_rate, pv.spo2, pv.temp_f,
           pv.abnormal, pv.recorded_by, pv.recorded_by_name, pv.created_at
    from public.patient_vitals pv join public.patients p on p.id = pv.patient_id and coalesce(p.active_status, 'admitted') <> 'discharged'
    where pv.recorded_at >= least(p.admitted_at, now()) - interval '2 days' and pv.recorded_at > now() - interval '30 days') v;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.rated_at desc, x.id), '[]'::jsonb) into v_scales from (
    select sa.id, sa.patient_id, sa.scale_id, sa.scale_version, sa.answers, sa.total, sa.subscores, sa.severity, sa.tone,
           sa.rated_at, sa.rated_by, sa.rated_by_name, sa.rated_by_role, sa.created_at, sa.deleted_at
    from public.scale_assessments sa
    join public.scale_defs sd on sd.scale_id = sa.scale_id and sd.version = sa.scale_version and sd.intern_ok
    join public.patients p on p.id = sa.patient_id and coalesce(p.active_status, 'admitted') <> 'discharged'
    where (sa.deleted_at is null or sa.deleted_at > now() - interval '14 days')
      and sa.rated_at >= least(p.admitted_at, now()) - interval '2 days' and sa.rated_at > now() - interval '30 days') x;
  select coalesce(jsonb_agg(public.r17_task_json(ia) order by ia.due_on, ia.created_at, ia.id), '[]'::jsonb) into v_tasks
  from public.intern_assignments ia
  join public.patients p on p.id = ia.patient_id and coalesce(p.active_status, 'admitted') <> 'discharged';
  return jsonb_build_object('ok', true, 'role', 'intern', 'me', v_me, 'patients', v_patients, 'beds', v_beds,
    'vitals', v_vitals, 'scales', v_scales, 'intern_tasks', v_tasks, 'server_time', now());
end;
$fn$;

revoke all on function public.r17_task_json(public.intern_assignments) from public, anon, authenticated;
revoke all on function public.r17_actor(uuid) from public, anon, authenticated;
revoke all on function public.r17_write_review_override(text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.intern_assignment_on_report() from public, anon, authenticated;
grant execute on function public.r17_task_json(public.intern_assignments) to postgres, service_role;
grant execute on function public.r17_actor(uuid) to postgres, service_role;
grant execute on function public.r17_write_review_override(text, text, text, text, text, text) to postgres, service_role;
grant execute on function public.intern_assignment_on_report() to postgres, service_role;

revoke all on function public.ward_assign_intern_task(uuid, jsonb) from public;
revoke all on function public.ward_complete_intern_task(uuid, text) from public;
revoke all on function public.ward_undo_intern_task(uuid, text) from public;
revoke all on function public.ward_complete_scheduled_ect(uuid, text, timestamptz) from public;
revoke all on function public.ward_undo_scheduled_ect(uuid, text) from public;
revoke all on function public.ward_list_r17_status(uuid) from public;
revoke all on function public.ward_discharge_with_review(uuid, jsonb, text, text[], jsonb, text, jsonb, text, text, integer, text[], text, jsonb, jsonb) from public;
revoke all on function public.ward_close_observation_with_review(uuid, text, text, text, text, text, text, jsonb, jsonb) from public;
grant execute on function public.ward_assign_intern_task(uuid, jsonb) to anon, authenticated, service_role;
grant execute on function public.ward_complete_intern_task(uuid, text) to anon, authenticated, service_role;
grant execute on function public.ward_undo_intern_task(uuid, text) to anon, authenticated, service_role;
grant execute on function public.ward_complete_scheduled_ect(uuid, text, timestamptz) to anon, authenticated, service_role;
grant execute on function public.ward_undo_scheduled_ect(uuid, text) to anon, authenticated, service_role;
grant execute on function public.ward_list_r17_status(uuid) to anon, authenticated, service_role;
grant execute on function public.ward_discharge_with_review(uuid, jsonb, text, text[], jsonb, text, jsonb, text, text, integer, text[], text, jsonb, jsonb) to anon, authenticated, service_role;
grant execute on function public.ward_close_observation_with_review(uuid, text, text, text, text, text, text, jsonb, jsonb) to anon, authenticated, service_role;
