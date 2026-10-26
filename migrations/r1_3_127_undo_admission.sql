-- R1.3.127 Undo admission (2-minute window)
-- NOT APPLIED. Idempotent: safe to run twice. Apply BEFORE deploying the R1.3.127 client.
-- (A R1.3.127 client against an un-migrated DB simply shows no undo popup: it only opens the
--  popup when the admit RPC returns admission_id.)
--
-- 1. notification_events: + held_until timestamptz, + dispatch_due boolean.
--    An admission/transfer push created by an admit is HELD (hidden from the inbox, not dispatched)
--    until the admitting resident taps Confirm, or the 2:00 window + 30 s grace runs out.
-- 2. admission_undo: one row per admission = the undo ledger AND the audit row
--    (kind, who, when, pre-admission snapshot, what the admit created, outcome). RLS forced, no policies,
--    service_role only. The pre-admission patient copy is purged after 30 days.
-- 3. ward_admit_patient / ward_convert_observation: the live R1.3.126 bodies are renamed to
--    *_r126 (no longer callable by clients) and wrapped by same-signature functions that
--    snapshot the pre-admission state, call the original, hold the notifications and return
--    admission_id / undo_until / server_now in addition to the original result.
-- 4. ward_confirm_admission(p_token, p_admission_id): finalise early; returns the notification ids the
--    client must dispatch (claimed exactly once).
-- 5. ward_undo_admission(p_token, p_patient_id, p_admission_id, p_owned): same resident, inside the
--    window (+30 s grace), refuses if clinical data was added after the admission, reverses everything.
-- 6. ward_release_held_admissions(): pg_cron every minute. Expires pending rows past the window,
--    un-hides their notifications and dispatches the push via pg_net + dispatch-notification
--    (authenticated with the admitting resident's own live ward session token, so the v7 edge
--    function needs no change). Needs the vault secret 'ward_dispatch_anon_key' (see PUSH STEPS).
-- 7. ward_list_notification_inbox: hides held events.
--
-- PUSH STEPS (one-time, after applying):
--   select vault.create_secret('<project anon / publishable key>', 'ward_dispatch_anon_key');
--   Without it the cron still releases (inbox shows the admission) but cannot send the push; the
--   admitting phone sends it on Confirm / on its next open.
--
-- ROLLBACK (manual):
--   select cron.unschedule('ward-release-held-admissions');
--   drop function public.ward_admit_patient(uuid,jsonb,jsonb,text,jsonb);
--   alter function public.ward_admit_patient_r126(uuid,jsonb,jsonb,text,jsonb) rename to ward_admit_patient;
--   drop function public.ward_convert_observation(uuid,text,text,jsonb,jsonb);
--   alter function public.ward_convert_observation_r126(uuid,text,text,jsonb,jsonb) rename to ward_convert_observation;
--   grant execute on both renamed functions to anon, authenticated, service_role;
--   update public.notification_events set held_until=null where held_until is not null;
--
-- NOTE for later migrations: ward_admit_patient and ward_convert_observation are now WRAPPERS.
-- Change admission logic in *_r126, not in the wrappers.

-- ---------------------------------------------------------------------------
-- 1. notification_events hold columns
-- ---------------------------------------------------------------------------
alter table public.notification_events add column if not exists held_until timestamptz;
alter table public.notification_events add column if not exists dispatch_due boolean not null default false;
create index if not exists notification_events_held_idx on public.notification_events(held_until) where held_until is not null;

-- ---------------------------------------------------------------------------
-- 2. admission_undo ledger / audit
-- ---------------------------------------------------------------------------
create table if not exists public.admission_undo (
  id uuid primary key default gen_random_uuid(),
  patient_id text not null,              -- no FK: a fresh admission's patient row is deleted on undo
  kind text not null,
  admitted_by text not null,
  bed_id text,
  assignment_id text,
  created_at timestamptz not null default now(),
  window_ends_at timestamptz not null,
  status text not null default 'pending',
  resolved_at timestamptz,
  resolved_by text,
  pre jsonb not null default '{}'::jsonb,
  created jsonb not null default '{}'::jsonb,
  undo_summary jsonb
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname='admission_undo_kind_check' and conrelid='public.admission_undo'::regclass) then
    alter table public.admission_undo add constraint admission_undo_kind_check check (kind in ('fresh','readmit','from_observation'));
  end if;
  if not exists (select 1 from pg_constraint where conname='admission_undo_status_check' and conrelid='public.admission_undo'::regclass) then
    alter table public.admission_undo add constraint admission_undo_status_check check (status in ('pending','confirmed','expired','undone'));
  end if;
end $$;
create index if not exists admission_undo_pending_idx on public.admission_undo(window_ends_at) where status='pending';
create index if not exists admission_undo_patient_idx on public.admission_undo(patient_id, created_at desc);
create unique index if not exists admission_undo_assignment_uq on public.admission_undo(assignment_id) where assignment_id is not null;
alter table public.admission_undo enable row level security;
alter table public.admission_undo force row level security;
revoke all on table public.admission_undo from anon, authenticated;
grant all on table public.admission_undo to service_role;

-- ---------------------------------------------------------------------------
-- 3a. helpers (internal; not callable by clients)
-- ---------------------------------------------------------------------------
-- Row counts per patient-linked table. Used to detect clinical data added after the admission.
create or replace function public.ward_admission_counts(p_patient_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_t text; v_n bigint; v_out jsonb := '{}'::jsonb;
begin
  foreach v_t in array array['activity_log','critical_status_updates','discharge_certificates','discharge_checks',
    'discharge_plans','ect_plans','ect_sessions','handover_items','medication_changes','medication_doses',
    'medication_orders','mse_entries','observation_stays','patient_advice','patient_bed_assignments',
    'patient_edits','prn_records','progress_notes','risk_assessments','tasks'] loop
    if to_regclass('public.'||v_t) is not null then
      execute format('select count(*) from public.%I where patient_id = $1', v_t) into v_n using p_patient_id;
      v_out := v_out || jsonb_build_object(v_t, v_n);
    end if;
  end loop;
  return v_out;
end $$;

create or replace function public.ward_admission_capture_pre(p_patient_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  return jsonb_build_object(
    'patient',     (select to_jsonb(p) from public.patients p where p.id = p_patient_id),
    'snapshot',    (select to_jsonb(s) from public.patient_snapshots s where s.patient_id = p_patient_id),
    'stay',        (select to_jsonb(o) from public.observation_stays o where o.patient_id = p_patient_id and o.ended_at is null limit 1),
    'beds',        coalesce((select jsonb_agg(b.id) from public.beds b where b.current_patient_id = p_patient_id), '[]'::jsonb),
    'assignments', coalesce((select jsonb_agg(to_jsonb(a)) from public.patient_bed_assignments a where a.patient_id = p_patient_id and a.released_at is null), '[]'::jsonb),
    'orders',      coalesce((select jsonb_agg(to_jsonb(m)) from public.medication_orders m where m.patient_id = p_patient_id), '[]'::jsonb),
    'counts',      public.ward_admission_counts(p_patient_id)
  );
end $$;

-- Overwrite every column (except the key) of one row from a to_jsonb() copy.
create or replace function public.ward_admission_restore_row(p_table text, p_key text, p_row jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare v_cols text; v_rcols text;
begin
  if p_row is null or jsonb_typeof(p_row) <> 'object' then return; end if;
  select string_agg(format('%I', a.attname), ', ' order by a.attnum),
         string_agg(format('r.%I', a.attname), ', ' order by a.attnum)
    into v_cols, v_rcols
  from pg_attribute a
  where a.attrelid = format('public.%I', p_table)::regclass and a.attnum > 0 and not a.attisdropped
    and a.attname <> p_key and a.attgenerated = '';
  execute format('update public.%I t set (%s) = (select %s from jsonb_populate_record(null::public.%I, $1) r) where t.%I = $2',
                 p_table, v_cols, v_rcols, p_table, p_key)
    using p_row, p_row->>p_key;
end $$;

-- Book the admission into the undo ledger and hold its notifications. Called by both wrappers
-- in the same transaction as the admission, after the original function returned.
create or replace function public.ward_admission_register(p_kind text, p_patient_id text, p_actor text,
  p_pre jsonb, p_res jsonb, p_bed_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_until timestamptz := now() + interval '120 seconds';
  v_asg text; v_bed text; v_bedno text; v_name text; v_nid uuid; v_notifs jsonb; v_acts jsonb;
begin
  select id, bed_id into v_asg, v_bed from public.patient_bed_assignments
   where patient_id = p_patient_id and released_at is null order by assigned_at desc limit 1;
  v_bed := coalesce(v_bed, p_bed_id);
  select bed_number into v_bedno from public.beds where id = v_bed;
  select name into v_name from public.patients where id = p_patient_id;

  -- A readmission (reused patient id) or a re-admitted observation patient collides with the
  -- previous 'admission:<pid>' dedupe key, so the original function created no new event.
  -- Create a fresh one for THIS admission so the push is correct and undo can remove it cleanly.
  if not exists (select 1 from public.notification_events
                  where patient_id = p_patient_id and event_type = 'admission' and created_at >= now()) then
    insert into public.notification_events(event_type, category, priority, patient_id, actor_id, title, body,
      target_url, recipient_scope, dedupe_key, metadata)
    values ('admission','clinical','normal', p_patient_id, p_actor, 'New admission',
      coalesce(v_name,'Patient') || case when p_kind = 'from_observation' then ' admitted from observation'
                                         else ' admitted to bed ' || coalesce(v_bedno, v_bed, '') end,
      './#/snap/' || p_patient_id, 'active_team',
      'admission:' || p_patient_id || ':' || coalesce(v_asg, gen_random_uuid()::text),
      jsonb_build_object('bed_id', v_bed, 'bed_number', v_bedno, 'from_observation', p_kind = 'from_observation'))
    on conflict (dedupe_key) do nothing;
  end if;

  with h as (
    update public.notification_events
       set held_until = v_until + interval '30 seconds', dispatch_due = true
     where patient_id = p_patient_id and created_at >= now() and event_type in ('admission','transfer')
    returning id, event_type
  ) select coalesce(jsonb_agg(id), '[]'::jsonb),
           (array_agg(id) filter (where event_type = 'admission'))[1]
      into v_notifs, v_nid from h;
  select coalesce(jsonb_agg(id), '[]'::jsonb) into v_acts
    from public.activity_log where patient_id = p_patient_id and created_at >= now();

  insert into public.admission_undo(patient_id, kind, admitted_by, bed_id, assignment_id, window_ends_at, pre, created)
  values (p_patient_id, p_kind, p_actor, v_bed, v_asg, v_until, coalesce(p_pre, '{}'::jsonb),
          jsonb_build_object('notifications', v_notifs, 'activity', v_acts, 'assignment', v_asg))
  returning id into v_id;

  return coalesce(p_res, '{}'::jsonb) || jsonb_build_object(
    'admission_id', v_id, 'undo_kind', p_kind, 'undo_until', v_until, 'server_now', now(),
    'notification_held', true, 'notification_id', coalesce(v_nid, (p_res->>'notification_id')::uuid),
    'bed_id', v_bed, 'bed_number', v_bedno);
end $$;

-- ---------------------------------------------------------------------------
-- 3b. rename the live R1.3.126 admission functions (once) and wrap them
-- ---------------------------------------------------------------------------
do $$ begin
  if to_regprocedure('public.ward_admit_patient_r126(uuid,jsonb,jsonb,text,jsonb)') is null then
    alter function public.ward_admit_patient(uuid,jsonb,jsonb,text,jsonb) rename to ward_admit_patient_r126;
  end if;
  if to_regprocedure('public.ward_convert_observation_r126(uuid,text,text,jsonb,jsonb)') is null then
    alter function public.ward_convert_observation(uuid,text,text,jsonb,jsonb) rename to ward_convert_observation_r126;
  end if;
end $$;

create or replace function public.ward_admit_patient(p_token uuid, p_patient jsonb, p_snapshot jsonb, p_bed_id text, p_assignment jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_pid text; v_asg text; v_pre jsonb; v_res jsonb; v_actor text; v_row public.admission_undo%rowtype;
begin
  v_pid := nullif(trim(coalesce(p_patient->>'id','')), '');
  v_asg := nullif(trim(coalesce(p_assignment->>'id','')), '');
  -- Idempotent retry of the same admission: return the original result + the existing undo row.
  if v_asg is not null and exists (select 1 from public.patient_bed_assignments where id = v_asg) then
    v_res := public.ward_admit_patient_r126(p_token, p_patient, p_snapshot, p_bed_id, p_assignment);
    select * into v_row from public.admission_undo where assignment_id = v_asg;
    if found then
      v_res := v_res || jsonb_build_object('admission_id', v_row.id, 'undo_kind', v_row.kind,
        'undo_until', v_row.window_ends_at, 'server_now', now(), 'undo_status', v_row.status,
        'notification_held', v_row.status = 'pending');
    end if;
    return v_res;
  end if;
  if v_pid is not null then v_pre := public.ward_admission_capture_pre(v_pid); end if;
  v_res := public.ward_admit_patient_r126(p_token, p_patient, p_snapshot, p_bed_id, p_assignment);
  if coalesce(v_res->>'ok','false') <> 'true' or coalesce(v_res->>'idempotent','false') = 'true' then return v_res; end if;
  v_pid := coalesce(v_res->>'patient_id', v_pid);
  v_actor := coalesce(v_res->>'actor_id', (select resident_id from public.ward_sessions where token = p_token));
  return public.ward_admission_register(
    case when v_pre is null or v_pre->'patient' is null or jsonb_typeof(v_pre->'patient') = 'null' then 'fresh' else 'readmit' end,
    v_pid, v_actor, v_pre, v_res, p_bed_id);
end $$;

create or replace function public.ward_convert_observation(p_token uuid, p_patient_id text, p_to_bed_id text, p_assignment jsonb, p_details jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_pid text; v_pre jsonb; v_res jsonb; v_actor text;
begin
  v_pid := nullif(trim(coalesce(p_patient_id,'')), '');
  if v_pid is not null then v_pre := public.ward_admission_capture_pre(v_pid); end if;
  v_res := public.ward_convert_observation_r126(p_token, p_patient_id, p_to_bed_id, p_assignment, p_details);
  if coalesce(v_res->>'ok','false') <> 'true' then return v_res; end if;
  select resident_id into v_actor from public.ward_sessions where token = p_token;
  return public.ward_admission_register('from_observation', v_pid, v_actor, v_pre, v_res, v_res->>'bed_id');
end $$;

-- ---------------------------------------------------------------------------
-- 4. confirm (early) — idempotent; returns the ids to dispatch exactly once
-- ---------------------------------------------------------------------------
create or replace function public.ward_confirm_admission(p_token uuid, p_admission_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_res text; v_row public.admission_undo%rowtype; v_ids uuid[]; v_claimed jsonb;
begin
  v_res := public.ward_ensure_session_writer(p_token);
  select * into v_row from public.admission_undo where id = p_admission_id for update;
  if not found then raise exception 'Admission not found'; end if;
  if v_row.admitted_by <> v_res then raise exception 'Only the resident who admitted this patient can confirm it'; end if;
  if v_row.status = 'undone' then
    return jsonb_build_object('ok', true, 'status', 'undone', 'notification_ids', '[]'::jsonb);
  end if;
  if v_row.status = 'pending' then
    update public.admission_undo set status = 'confirmed', resolved_at = now(), resolved_by = v_res where id = v_row.id;
  end if;
  select coalesce(array_agg(x::uuid), '{}') into v_ids from jsonb_array_elements_text(coalesce(v_row.created->'notifications','[]'::jsonb)) x;
  update public.notification_events set held_until = null where id = any(v_ids) and held_until is not null;
  with c as (update public.notification_events set dispatch_due = false where id = any(v_ids) and dispatch_due returning id)
  select coalesce(jsonb_agg(id), '[]'::jsonb) into v_claimed from c;
  return jsonb_build_object('ok', true, 'status', case when v_row.status = 'pending' then 'confirmed' else v_row.status end,
                            'notification_ids', v_claimed);
end $$;

-- ---------------------------------------------------------------------------
-- 5. undo
-- p_owned: what the admitting phone wrote right after the admit RPC (from its own outbox):
--   {"events":[activity_log ids], "orders":[new medication_order ids], "stopped":[pre-existing order ids it stopped]}
-- ---------------------------------------------------------------------------
create or replace function public.ward_undo_admission(p_token uuid, p_patient_id text, p_admission_id uuid, p_owned jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_res text; v_row public.admission_undo%rowtype; v_p public.patients%rowtype;
  v_pre jsonb; v_t0 timestamptz;
  v_bed text; v_open text;
  v_ev text[]; v_orders text[]; v_stopped text[]; v_pre_orders text[]; v_notifs uuid[]; v_created_asg text;
  v_now jsonb; v_k text; v_delta bigint; v_allow bigint; v_o jsonb; v_cur jsonb; v_ver int;
  v_labels jsonb := '{"activity_log":"timeline entries","critical_status_updates":"a critical status update","discharge_certificates":"a discharge certificate","discharge_checks":"discharge checks","discharge_plans":"a discharge plan","ect_plans":"an ECT plan","ect_sessions":"an ECT session","handover_items":"a handover item","medication_changes":"a medication change","medication_doses":"a medication dose","medication_orders":"a medication order","mse_entries":"an MSE","observation_stays":"an observation stay","patient_advice":"advice","patient_bed_assignments":"a bed move","patient_edits":"a record edit","prn_records":"a PRN dose","progress_notes":"a progress note","risk_assessments":"a risk assessment","tasks":"a task"}'::jsonb;
  v_n_orders int := 0; v_n_events int := 0; v_n_notifs int := 0;
begin
  v_res := public.ward_ensure_session_writer(p_token);
  p_owned := coalesce(p_owned, '{}'::jsonb);
  select * into v_row from public.admission_undo where id = p_admission_id for update;
  if not found or v_row.patient_id is distinct from nullif(trim(p_patient_id),'') then raise exception 'Admission not found'; end if;
  if v_row.status = 'undone' then
    return jsonb_build_object('ok', true, 'idempotent', true, 'admission_id', v_row.id, 'kind', v_row.kind, 'patient_id', v_row.patient_id);
  end if;
  if v_row.admitted_by <> v_res then raise exception 'Only the resident who admitted this patient can undo it'; end if;
  if v_row.status <> 'pending' then raise exception 'This admission is already confirmed and can no longer be undone'; end if;
  if now() > v_row.window_ends_at + interval '30 seconds' then raise exception 'The 2-minute undo window has passed'; end if;

  v_pre := v_row.pre; v_t0 := v_row.created_at;
  select * into v_p from public.patients where id = v_row.patient_id for update;
  if not found then raise exception 'Patient record has changed; undo is not possible'; end if;
  if v_p.active_status <> 'admitted' then raise exception 'Patient is no longer admitted; undo is not possible'; end if;
  if v_p.updated_by is distinct from v_res and v_p.updated_at > v_t0 then
    raise exception 'Another resident edited this patient after admission; undo is blocked';
  end if;
  if exists (select 1 from public.patient_snapshots where patient_id = v_row.patient_id and updated_at > v_t0 and updated_by is distinct from v_res) then
    raise exception 'Another resident updated this patient''s snapshot after admission; undo is blocked';
  end if;
  select id into v_bed from public.beds where current_patient_id = v_row.patient_id for update;
  select id into v_open from public.patient_bed_assignments where patient_id = v_row.patient_id and released_at is null;
  if v_bed is distinct from v_row.bed_id or v_open is distinct from (v_row.created->>'assignment') then
    raise exception 'Patient was moved after admission; undo is blocked';
  end if;

  -- what this admission owns
  select coalesce(array_agg(x), '{}') into v_pre_orders from jsonb_array_elements(coalesce(v_pre->'orders','[]'::jsonb)) o, lateral (select o->>'id' x) y;
  select coalesce(array_agg(m.id), '{}') into v_orders from public.medication_orders m
   where m.patient_id = v_row.patient_id and m.created_by = v_res and m.created_at >= v_t0 - interval '10 minutes'
     and m.id in (select jsonb_array_elements_text(coalesce(p_owned->'orders','[]'::jsonb)))
     and not (m.id = any(v_pre_orders));
  select coalesce(array_agg(x), '{}') into v_stopped from jsonb_array_elements_text(coalesce(p_owned->'stopped','[]'::jsonb)) x where x = any(v_pre_orders);
  select coalesce(array_agg(a.id), '{}') into v_ev from public.activity_log a
   where a.patient_id = v_row.patient_id
     and (a.id in (select jsonb_array_elements_text(coalesce(v_row.created->'activity','[]'::jsonb)))
          or (a.actor_id = v_res and a.created_at >= v_t0 - interval '10 minutes'
              and a.id in (select jsonb_array_elements_text(coalesce(p_owned->'events','[]'::jsonb)))));
  if exists (select 1 from public.medication_doses d where d.order_id = any(v_orders) and d.status <> 'pending') then
    raise exception 'A dose was recorded after admission; undo is blocked';
  end if;

  -- refuse when anything clinical was added after the admission
  v_now := public.ward_admission_counts(v_row.patient_id);
  for v_k in select jsonb_object_keys(v_now) loop
    v_delta := (v_now->>v_k)::bigint - coalesce((v_pre->'counts'->>v_k)::bigint, 0);
    v_allow := case v_k
      when 'activity_log' then coalesce(array_length(v_ev,1),0)
      when 'medication_orders' then coalesce(array_length(v_orders,1),0)
      when 'medication_doses' then (select count(*) from public.medication_doses d where d.order_id = any(v_orders))
      when 'patient_bed_assignments' then (select count(*) from public.patient_bed_assignments a where a.patient_id = v_row.patient_id
                                             and a.id = v_row.created->>'assignment'
                                             and not exists (select 1 from jsonb_array_elements(coalesce(v_pre->'assignments','[]'::jsonb)) pa where pa->>'id' = a.id))
      else 0 end;
    if v_delta > v_allow then
      raise exception 'New clinical data (%) was added after admission; undo is blocked', coalesce(v_labels->>v_k, v_k);
    end if;
  end loop;
  -- pre-existing orders changed by anyone other than this admission's own stops
  for v_o in select * from jsonb_array_elements(coalesce(v_pre->'orders','[]'::jsonb)) loop
    if v_o->>'id' = any(v_stopped) then continue; end if;
    select to_jsonb(m) into v_cur from public.medication_orders m where m.id = v_o->>'id';
    if v_cur is null or (v_cur - 'updated_at') <> (v_o - 'updated_at') then
      raise exception 'Medication orders were changed after admission; undo is blocked';
    end if;
  end loop;

  -- ---------------- reverse ----------------
  select coalesce(array_agg(x::uuid), '{}') into v_notifs from jsonb_array_elements_text(coalesce(v_row.created->'notifications','[]'::jsonb)) x;
  with d as (delete from public.notification_events
              where id = any(v_notifs)
                 or (patient_id = v_row.patient_id and event_type in ('admission','transfer') and created_at >= v_t0)
             returning 1) select count(*) into v_n_notifs from d;
  with d as (delete from public.activity_log where id = any(v_ev) returning 1) select count(*) into v_n_events from d;
  with d as (delete from public.medication_orders where id = any(v_orders) returning 1) select count(*) into v_n_orders from d;
  for v_o in select * from jsonb_array_elements(coalesce(v_pre->'orders','[]'::jsonb)) loop
    if v_o->>'id' = any(v_stopped) then perform public.ward_admission_restore_row('medication_orders', 'id', v_o); end if;
  end loop;

  -- free the admission bed / assignment
  update public.beds set current_patient_id = null where current_patient_id = v_row.patient_id;
  v_created_asg := v_row.created->>'assignment';
  if not exists (select 1 from jsonb_array_elements(coalesce(v_pre->'assignments','[]'::jsonb)) pa where pa->>'id' = v_created_asg) then
    delete from public.patient_bed_assignments where id = v_created_asg;
  end if;

  if v_row.kind = 'fresh' then
    delete from public.activity_log where patient_id = v_row.patient_id;
    delete from public.patients where id = v_row.patient_id;           -- children cascade
  else
    -- previous bed assignment(s) and bed(s) (observation patients keep their bed)
    for v_o in select * from jsonb_array_elements(coalesce(v_pre->'assignments','[]'::jsonb)) loop
      perform public.ward_admission_restore_row('patient_bed_assignments', 'id', v_o);
    end loop;
    if v_row.kind = 'from_observation' then
      update public.beds b set current_patient_id = v_row.patient_id
       where b.id in (select jsonb_array_elements_text(coalesce(v_pre->'beds','[]'::jsonb)));
    end if;
    -- patient row exactly as before (admit-form extra fields included)
    perform public.ward_admission_restore_row('patients', 'id', v_pre->'patient');
    -- snapshot
    if v_pre->'snapshot' is null or jsonb_typeof(v_pre->'snapshot') = 'null' then
      delete from public.patient_snapshots where patient_id = v_row.patient_id;
    else
      select row_version into v_ver from public.patient_snapshots where patient_id = v_row.patient_id;
      perform public.ward_admission_restore_row('patient_snapshots', 'patient_id', v_pre->'snapshot');
      update public.patient_snapshots set row_version = greatest(coalesce(v_ver,0), coalesce((v_pre->'snapshot'->>'row_version')::int,0)) + 1
       where patient_id = v_row.patient_id;
    end if;
    -- reopen the observation stay
    if v_row.kind = 'from_observation' and v_pre->'stay' is not null and jsonb_typeof(v_pre->'stay') = 'object' then
      perform public.ward_admission_restore_row('observation_stays', 'id', v_pre->'stay');
    end if;
  end if;

  update public.admission_undo
     set status = 'undone', resolved_at = now(), resolved_by = v_res,
         undo_summary = jsonb_build_object('orders_deleted', v_n_orders, 'orders_restored', coalesce(array_length(v_stopped,1),0),
                                           'events_deleted', v_n_events, 'notifications_deleted', v_n_notifs)
   where id = v_row.id;
  return jsonb_build_object('ok', true, 'admission_id', v_row.id, 'kind', v_row.kind, 'patient_id', v_row.patient_id,
                            'bed_id', v_row.bed_id, 'orders_deleted', v_n_orders, 'orders_restored', coalesce(array_length(v_stopped,1),0),
                            'events_deleted', v_n_events, 'notifications_deleted', v_n_notifs);
end $$;

-- ---------------------------------------------------------------------------
-- 6. server release (pg_cron) + push dispatch via pg_net
-- ---------------------------------------------------------------------------
create or replace function public.ward_admission_dispatch(p_notification_id uuid, p_actor text)
returns text language plpgsql security definer set search_path = public as $$
declare v_key text; v_tok uuid; v_req bigint;
begin
  if to_regnamespace('net') is null or to_regclass('vault.decrypted_secrets') is null then return 'skipped: no pg_net/vault'; end if;
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'ward_dispatch_anon_key' limit 1;
  if v_key is null then return 'skipped: no ward_dispatch_anon_key'; end if;
  select token into v_tok from public.ward_sessions
   where resident_id = p_actor and expires_at > now() + interval '1 minute' order by created_at desc limit 1;
  if v_tok is null then return 'skipped: no live session'; end if;
  select net.http_post(
    url := 'https://ocgmhwetdpcthwbcnbqz.supabase.co/functions/v1/dispatch-notification',
    headers := jsonb_build_object('Content-Type','application/json','apikey',v_key,'Authorization','Bearer '||v_key),
    body := jsonb_build_object('notification_id', p_notification_id, 'session_token', v_tok),
    timeout_milliseconds := 10000) into v_req;
  return 'requested ' || v_req;
end $$;

create or replace function public.ward_release_held_admissions()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_row public.admission_undo%rowtype; v_ids uuid[]; v_id uuid; v_r text; v_n int := 0; v_sent jsonb := '[]'::jsonb;
begin
  for v_row in select * from public.admission_undo
                where status = 'pending' and now() > window_ends_at + interval '30 seconds'
                order by window_ends_at for update skip locked loop
    update public.admission_undo set status = 'expired', resolved_at = now() where id = v_row.id;
    select coalesce(array_agg(x::uuid), '{}') into v_ids from jsonb_array_elements_text(coalesce(v_row.created->'notifications','[]'::jsonb)) x;
    update public.notification_events set held_until = null where id = any(v_ids) and held_until is not null;
    -- claim only when the push request was actually queued; if it was skipped (no vault key / no live session)
    -- dispatch_due stays true so the admitting phone dispatches it on its next open (idempotent confirm).
    for v_id in select id from public.notification_events where id = any(v_ids) and dispatch_due for update loop
      v_r := public.ward_admission_dispatch(v_id, v_row.admitted_by);
      if v_r like 'requested%' then
        update public.notification_events set dispatch_due = false where id = v_id;
      end if;
      v_sent := v_sent || jsonb_build_array(jsonb_build_object('id', v_id, 'result', v_r));
    end loop;
    v_n := v_n + 1;
  end loop;
  -- safety net: never leave an event hidden for long (e.g. a hold left by an aborted flow)
  update public.notification_events set held_until = null, dispatch_due = false
   where held_until is not null and held_until < now() - interval '10 minutes';
  -- privacy: drop the pre-admission copy from resolved ledger rows after 30 days
  update public.admission_undo set pre = jsonb_build_object('purged', true)
   where status <> 'pending' and created_at < now() - interval '30 days' and not (pre ? 'purged');
  return jsonb_build_object('ok', true, 'released', v_n, 'dispatched', v_sent);
end $$;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('ward-release-held-admissions', '* * * * *', 'select public.ward_release_held_admissions()');
  else
    raise notice 'pg_cron not installed: ward-release-held-admissions not scheduled';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. inbox: hide held admission/transfer events
-- ---------------------------------------------------------------------------
create or replace function public.ward_list_notification_inbox(p_session_token uuid, p_limit integer default 40)
returns jsonb language plpgsql security definer set search_path = public as $fn$
DECLARE
  v_resident_id text;
  v_role text;
  v_limit integer;
  v_notifications jsonb;
BEGIN
  SELECT ws.resident_id, lower(r.role)
    INTO v_resident_id, v_role
  FROM public.ward_sessions ws
  JOIN public.residents r ON r.id = ws.resident_id
  WHERE ws.token = p_session_token AND ws.expires_at > now()
  LIMIT 1;
  IF v_resident_id IS NULL THEN RAISE EXCEPTION 'Invalid or expired ward session'; END IF;
  v_limit := greatest(1, least(coalesce(p_limit,40),100));
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC), '[]'::jsonb)
  INTO v_notifications
  FROM (
    SELECT
      e.id, e.event_type, e.category, e.priority, e.patient_id, e.task_id, e.handover_id, e.ect_plan_id,
      e.actor_id, coalesce(r.display_name, e.actor_id) AS actor_name,
      e.title, e.body, e.target_url, e.created_at,
      EXISTS (
        SELECT 1 FROM public.notification_deliveries d
        WHERE d.notification_id = e.id AND d.resident_id = v_resident_id AND d.read_at IS NOT NULL
      ) AS read,
      (
        SELECT min(d.read_at) FROM public.notification_deliveries d
        WHERE d.notification_id = e.id AND d.resident_id = v_resident_id
      ) AS read_at,
      e.created_at AS delivered_at,
      true AS delivered
    FROM public.notification_events e
    LEFT JOIN public.residents r ON r.id = e.actor_id
    WHERE
      -- R1.3.127: an admission push held for the 2-minute undo window stays hidden until released.
      (e.held_until IS NULL OR e.held_until < now())
      AND (
      v_role IN ('consultant','admin')
      OR e.recipient_scope = 'active_team'
      OR EXISTS (
        SELECT 1 FROM public.notification_deliveries d
        WHERE d.notification_id = e.id AND d.resident_id = v_resident_id
      )
      OR (
        e.recipient_scope = 'handover'
        AND EXISTS (
          SELECT 1 FROM public.handovers h
          WHERE h.id = e.handover_id AND h.to_id = v_resident_id
        )
      )
      OR (
        e.recipient_scope = 'task_assignees'
        AND EXISTS (
          SELECT 1 FROM public.tasks t
          WHERE t.id = e.task_id AND t.assigned_to = v_resident_id
        )
      )
      )
    ORDER BY e.created_at DESC
    LIMIT v_limit
  ) x;
  RETURN jsonb_build_object('ok', true, 'resident_id', v_resident_id, 'notifications', v_notifications);
END;
$fn$;

-- ---------------------------------------------------------------------------
-- grants
-- ---------------------------------------------------------------------------
revoke all on function public.ward_admit_patient_r126(uuid,jsonb,jsonb,text,jsonb) from public, anon, authenticated;
grant execute on function public.ward_admit_patient_r126(uuid,jsonb,jsonb,text,jsonb) to service_role;
revoke all on function public.ward_convert_observation_r126(uuid,text,text,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.ward_convert_observation_r126(uuid,text,text,jsonb,jsonb) to service_role;

revoke all on function public.ward_admission_counts(text) from public, anon, authenticated;
revoke all on function public.ward_admission_capture_pre(text) from public, anon, authenticated;
revoke all on function public.ward_admission_restore_row(text,text,jsonb) from public, anon, authenticated;
revoke all on function public.ward_admission_register(text,text,text,jsonb,jsonb,text) from public, anon, authenticated;
revoke all on function public.ward_admission_dispatch(uuid,text) from public, anon, authenticated;
revoke all on function public.ward_release_held_admissions() from public, anon, authenticated;
grant execute on function public.ward_admission_counts(text) to service_role;
grant execute on function public.ward_admission_capture_pre(text) to service_role;
grant execute on function public.ward_admission_restore_row(text,text,jsonb) to service_role;
grant execute on function public.ward_admission_register(text,text,text,jsonb,jsonb,text) to service_role;
grant execute on function public.ward_admission_dispatch(uuid,text) to service_role;
grant execute on function public.ward_release_held_admissions() to service_role;

revoke all on function public.ward_admit_patient(uuid,jsonb,jsonb,text,jsonb) from public;
grant execute on function public.ward_admit_patient(uuid,jsonb,jsonb,text,jsonb) to anon, authenticated, service_role;
revoke all on function public.ward_convert_observation(uuid,text,text,jsonb,jsonb) from public;
grant execute on function public.ward_convert_observation(uuid,text,text,jsonb,jsonb) to anon, authenticated, service_role;
revoke all on function public.ward_confirm_admission(uuid,uuid) from public;
grant execute on function public.ward_confirm_admission(uuid,uuid) to anon, authenticated, service_role;
revoke all on function public.ward_undo_admission(uuid,text,uuid,jsonb) from public;
grant execute on function public.ward_undo_admission(uuid,text,uuid,jsonb) to anon, authenticated, service_role;
revoke all on function public.ward_list_notification_inbox(uuid,integer) from public;
grant execute on function public.ward_list_notification_inbox(uuid,integer) to anon, authenticated, service_role;
