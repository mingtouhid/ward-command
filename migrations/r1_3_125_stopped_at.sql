-- Ward Sync R1.3.125: medication stop TIME (stopped_at) + backfill.
-- Applied to ward-flow as migration r1_3_125_stopped_at. Idempotent; safe for older clients
-- (stop_date is still written and kept; older clients ignore the new column).

-- 1. Column
alter table public.medication_orders add column if not exists stopped_at timestamptz;
comment on column public.medication_orders.stopped_at is 'R1.3.125: exact time the order was stopped (null = only the stop DATE is known)';

-- 2. Trigger: every stop path (upsert RPC from chart stop / admit untick / obs dispose-refer / discharge,
--    ward_edit_med_order edit-replaces-order, any direct write) gets a time without touching those RPCs.
create or replace function public.ward_medication_orders_stopped_at()
returns trigger language plpgsql set search_path to '' as $fn$
declare v_today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if new.status = 'stopped' or new.stop_date is not null then
    if new.stopped_at is null and tg_op = 'UPDATE' then new.stopped_at := old.stopped_at; end if;
    if new.stopped_at is not null then
      if new.stopped_at > now() then new.stopped_at := now(); end if;
      if new.stop_date is null then
        new.stop_date := greatest(new.start_date, (new.stopped_at at time zone 'Asia/Kolkata')::date);
      end if;
    elsif not (tg_op = 'UPDATE' and (old.status = 'stopped' or old.stop_date is not null)) then
      -- being stopped right now by a client that sent no time: stamp now(), but only when the stop day is today
      -- (an offline stop synced on a later day stays date-only rather than getting a wrong time)
      if new.stop_date is null or new.stop_date = v_today then
        new.stopped_at := now();
        if new.stop_date is null then new.stop_date := greatest(new.start_date, v_today); end if;
      end if;
    end if;
  else
    new.stopped_at := null;
  end if;
  return new;
end
$fn$;
revoke all on function public.ward_medication_orders_stopped_at() from public, anon, authenticated;
drop trigger if exists medication_orders_stopped_at on public.medication_orders;
create trigger medication_orders_stopped_at before insert or update on public.medication_orders
  for each row execute function public.ward_medication_orders_stopped_at();

-- 3. Upsert RPC accepts the client's stopped_at (first stop time wins)
CREATE OR REPLACE FUNCTION public.ward_upsert_medication_order(p_token uuid, p_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_resident_id text;
  v_id text;
  v_patient_id text;
  v_status text;
  v_start date;
  v_stop date;
  v_stopped timestamptz;
begin
  v_resident_id := public.ward_ensure_session_writer(p_token);

  v_id=nullif(trim(p_row->>'id'),'');
  v_patient_id=nullif(trim(p_row->>'patient_id'),'');
  v_status=coalesce(nullif(trim(p_row->>'status'),''),'active');
  v_start=coalesce(nullif(p_row->>'start_date','')::date,current_date);
  v_stop=nullif(p_row->>'stop_date','')::date;
  -- R1.3.125: exact stop time from the client (never in the future); the trigger fills/guards the rest
  v_stopped=nullif(p_row->>'stopped_at','')::timestamptz;
  if v_stopped > now() then v_stopped := now(); end if; -- (least() would turn a NULL into now())

  if v_id is null then raise exception 'Medication order id is required'; end if;
  if v_patient_id is null then raise exception 'Medication patient is required'; end if;
  if nullif(trim(p_row->>'drug'),'') is null then raise exception 'Medication drug is required'; end if;
  if nullif(trim(p_row->>'dose'),'') is null then raise exception 'Medication dose is required'; end if;
  if nullif(trim(p_row->>'route'),'') is null then raise exception 'Medication route is required'; end if;
  if nullif(trim(p_row->>'frequency'),'') is null then raise exception 'Medication frequency is required'; end if;
  if v_stop is not null and v_stop<v_start then raise exception 'Medication stop date cannot precede start date'; end if;

  perform 1 from public.patients where id=v_patient_id and active_status<>'discharged' for update;
  if not found then raise exception 'Active patient not found'; end if;

  if exists(select 1 from public.medication_orders where id=v_id and patient_id<>v_patient_id) then
    raise exception 'Medication order belongs to another patient';
  end if;

  -- R1.3.89: an order replaced by an edit is frozen; stale clients cannot revive or rewrite it.
  if exists(select 1 from public.medication_orders where supersedes=v_id) then
    return jsonb_build_object('ok',true,'order_id',v_id,'patient_id',v_patient_id,'ignored','superseded');
  end if;

  insert into public.medication_orders(
    id, patient_id, drug, dose, route, frequency, scheduled_time, start_date, stop_date, stopped_at, status, indication, created_by, created_at, updated_at
  ) values(
    v_id, v_patient_id, trim(p_row->>'drug'), trim(p_row->>'dose'), trim(p_row->>'route'), trim(p_row->>'frequency'),
    nullif(trim(p_row->>'scheduled_time'),''), v_start, v_stop, v_stopped, v_status, nullif(trim(p_row->>'indication'),''),
    coalesce(nullif(trim(p_row->>'created_by'),''), v_resident_id),
    coalesce((p_row->>'created_at')::timestamptz, now()), now()
  )
  on conflict(id) do update set
    patient_id=excluded.patient_id, drug=excluded.drug, dose=excluded.dose, route=excluded.route,
    frequency=excluded.frequency, scheduled_time=excluded.scheduled_time, start_date=excluded.start_date,
    stop_date=excluded.stop_date,
    stopped_at=coalesce(public.medication_orders.stopped_at, excluded.stopped_at), status=excluded.status, indication=excluded.indication, updated_at=now();

  return jsonb_build_object('ok',true,'order_id',v_id,'patient_id',v_patient_id);
end;
$function$
;

-- 4. Ward state read returns stopped_at
CREATE OR REPLACE FUNCTION public.ward_read_ward_state(p_session_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_resident_id text;
  v_unit jsonb; v_sections jsonb; v_consultants jsonb; v_residents jsonb;
  v_beds jsonb; v_patients jsonb; v_assignments jsonb; v_snapshots jsonb;
  v_orders jsonb; v_doses jsonb; v_tasks jsonb; v_handovers jsonb; v_handover_items jsonb;
  v_ect_plans jsonb; v_ect_sessions jsonb; v_events jsonb; v_obs jsonb; v_duty jsonb; v_pedits jsonb; v_mse jsonb;
begin
  select ws.resident_id into v_resident_id
  from public.ward_sessions ws
  join public.residents r on r.id=ws.resident_id and r.active=true
  where ws.token=p_session_token and ws.expires_at>now() limit 1;
  if v_resident_id is null then raise exception 'Invalid or expired ward session'; end if;

  select coalesce(jsonb_agg(to_jsonb(u) order by u.id), '[]'::jsonb) into v_unit from (
    select id, unit_name, created_at, updated_at from public.unit_settings) u;
  select coalesce(jsonb_agg(to_jsonb(s) order by s.sort_order, s.id), '[]'::jsonb) into v_sections from (
    select id, name, sort_order, active, created_at from public.ward_sections) s;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order, c.id), '[]'::jsonb) into v_consultants from (
    select id, name, designation, active, sort_order, created_at from public.unit_consultants) c;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.display_name, r.id), '[]'::jsonb) into v_residents from (
    select id, username, display_name, role, active, created_at from public.residents where active=true) r;
  select coalesce(jsonb_agg(to_jsonb(b) order by b.bed_number, b.id), '[]'::jsonb) into v_beds from (
    select id, bed_number, section_id, active, current_patient_id, created_at, updated_at from public.beds) b;
  select coalesce(jsonb_agg(to_jsonb(p) order by p.admitted_at desc, p.id), '[]'::jsonb) into v_patients from (
    select id, patient_code, hospital_no, mrd_no, name, age, sex, diagnosis,
           admitted_at, active_status, created_at, updated_at, updated_by,
           reason_for_admission, referred_by, consultant_name, consultant_name_2,
           discharged_at, discharge_mode, discharge_outcome, treatment_mode,
           address, phone, secondary_dx, tertiary_dx, comorbidities, discharge_advice, discharge_meds, discharge_review, discharge_ect_sessions
    from public.patients) p;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.assigned_at desc, a.id), '[]'::jsonb) into v_assignments from (
    select id, patient_id, bed_id, assigned_at, released_at, assigned_by from public.patient_bed_assignments) a;
  select coalesce(jsonb_agg(to_jsonb(s) order by s.updated_at desc, s.patient_id), '[]'::jsonb) into v_snapshots from (
    select patient_id, clinical_state, risk_level, sleep_status, watch_points, current_plan, updated_by, updated_at, tags, row_version, pgt_notes from public.patient_snapshots) s;
  select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc, o.id), '[]'::jsonb) into v_orders from (
    select id, patient_id, drug, dose, route, frequency, scheduled_time, start_date, stop_date, status, indication, created_by, created_at,
           hold_at, lineage_id, supersedes, change_note, updated_at, stopped_at from public.medication_orders) o;
  select coalesce(jsonb_agg(to_jsonb(d) order by d.scheduled_at desc, d.id), '[]'::jsonb) into v_doses from (
    select id, order_id, patient_id, scheduled_at, status, given_by, given_at from public.medication_doses) d;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id), '[]'::jsonb) into v_tasks from (
    select id, patient_id, title, detail, priority, assigned_to, status, created_by, created_at, completed_at from public.tasks) t;
  select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at desc, h.id), '[]'::jsonb) into v_handovers from (
    select id, from_id, to_id, shift, status, created_at, acknowledged_by, acknowledged_at from public.handovers) h;
  select coalesce(jsonb_agg(to_jsonb(hi) order by hi.id), '[]'::jsonb) into v_handover_items from (
    select id, handover_id, patient_id, priority, problem, action_required, done from public.handover_items) hi;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc, e.id), '[]'::jsonb) into v_ect_plans from (
    select id, patient_id, indication, sessions_done, next_session_at, npo, status, created_by, created_at, updated_at from public.ect_plans) e;
  select coalesce(jsonb_agg(to_jsonb(es) order by es.session_at desc, es.session_number desc, es.id), '[]'::jsonb) into v_ect_sessions from (
    select id, plan_id, patient_id, session_number, session_at, anaesthesia, stimulus, seizure_seconds, complications, response, next_plan, recorded_by from public.ect_sessions) es;
  select coalesce(jsonb_agg(to_jsonb(al) order by al.created_at desc, al.id), '[]'::jsonb) into v_events from (
    select id, patient_id, kind, title, detail, actor_id, created_at from public.activity_log) al;
  select coalesce(jsonb_agg(to_jsonb(os) order by os.started_at desc, os.id), '[]'::jsonb) into v_obs from (
    select id, patient_id, bed_id, reason, note, started_at, started_by, ended_at, ended_by, outcome, referral_to, discharge_meds
    from public.observation_stays) os;
  select coalesce(jsonb_agg(to_jsonb(d) order by d.started_at), '[]'::jsonb) into v_duty from (
    select wd.id, wd.resident_id, r.display_name, r.username, wd.shift, wd.started_at, wd.duty_area
    from public.ward_duty wd
    join public.residents r on r.id = wd.resident_id
    where wd.ended_at is null) d;

  select coalesce(jsonb_agg(to_jsonb(pe) order by pe.edited_at desc), '[]'::jsonb) into v_pedits from (
    select e.id, e.patient_id, e.field, e.old_value, e.new_value, e.edited_by, e.edited_at, e.edit_group
    from public.patient_edits e) pe;

  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc, m.id), '[]'::jsonb) into v_mse from (
    select id, patient_id, kind, admitted_at, data, high_risk, summary, created_by, created_by_name, created_at from public.mse_entries) m;

  return jsonb_build_object(
    'ok', true, 'resident_id', v_resident_id,
    'unit', v_unit, 'sections', v_sections, 'consultants', v_consultants, 'residents', v_residents,
    'beds', v_beds, 'patients', v_patients, 'assignments', v_assignments, 'snapshots', v_snapshots,
    'orders', v_orders, 'doses', v_doses, 'tasks', v_tasks, 'handovers', v_handovers,
    'handover_items', v_handover_items, 'ect_plans', v_ect_plans, 'ect_sessions', v_ect_sessions,
    'events', v_events, 'observation_stays', v_obs, 'duty', v_duty, 'patient_edits', v_pedits, 'mse_entries', v_mse
  );
end
$function$
;

-- 5. Backfill (only rows with no time yet)
-- 5a. edit-replaced orders: the successor row was created at the exact moment the old one was stopped
update public.medication_orders o
   set stopped_at = s.created_at
  from public.medication_orders s
 where s.supersedes = o.id and o.stopped_at is null and (o.status = 'stopped' or o.stop_date is not null)
   and s.created_at is not null;

-- 5b. other stopped orders: the 'Stopped <drug>' activity_log entry for the same patient on the stop date,
--     closest to the order's last update; an entry that two orders would both claim is left unused (stay date-only)
with cand as (
  select o.id as oid, a.id as aid, a.created_at,
         abs(extract(epoch from a.created_at - coalesce(o.updated_at, a.created_at))) as dist
    from public.medication_orders o
    join public.activity_log a on a.patient_id = o.patient_id
     and (lower(a.title) = lower('Stopped '||o.drug)
          or starts_with(lower(a.title), lower('Stopped '||o.drug||' '))
          or starts_with(lower(a.title), lower('Stopped '||o.drug||':')))
     and (a.created_at at time zone 'Asia/Kolkata')::date = o.stop_date
     and a.created_at >= o.created_at - interval '1 minute'
   where o.stopped_at is null and (o.status = 'stopped' or o.stop_date is not null)
     and not exists (select 1 from public.medication_orders s where s.supersedes = o.id)
), best as (
  select distinct on (oid) oid, aid, created_at from cand order by oid, dist, created_at
), uniq as (
  select b.* from best b where (select count(*) from best b2 where b2.aid = b.aid) = 1
)
update public.medication_orders o set stopped_at = u.created_at from uniq u where o.id = u.oid;

