-- R1.3.135 · lab sync window — ward_read_ward_state never drops a just-saved lab report
-- NOT APPLIED. Apply only after the go-ahead ("Push"), in the Supabase SQL editor or via apply_migration, as ONE transaction.
--
-- Change (only the lab_reports filter of ward_read_ward_state; every other part of the function is byte-identical to live):
--   + any report of a NOT-discharged patient created or updated in the last 14 days, whatever its report date
--   + every tombstone (deleted_at) from the last 14 days, so devices drop removed old-dated reports
-- Payload stays bounded by save activity (14 days, current admissions) instead of growing with report history.
--
-- Drift-check baselines (md5 of pg_get_functiondef, read from live 28 Oct 2026 IST):
--   ward_read_ward_state(uuid)            3b2711f80e3d916c70582dd168749113  (7903 chars)  -> replaced; new md5 f7737a140e4984ff524f45084414696a (8448 chars)
--   ward_lab_report_json(text)            6ef197bc17239dca93957f0171ee0d2b  (703)   unchanged, checked only
--   ward_read_lab_history(uuid,text)      5065333c49fb20e78aafe68e88cfab1e  (795)   unchanged, checked only
--   ward_save_lab_report(uuid,jsonb)      c513d0196c078a864ec50bbad32c8d9c  (20042) unchanged, checked only
-- If any baseline differs, the DO block raises and nothing changes. Rollback: migrations/R1.3.135-lab-sync-window.rollback.sql
begin;
do $chk$
declare r record;
begin
  for r in select * from (values
      ('public.ward_read_ward_state(uuid)','3b2711f80e3d916c70582dd168749113'),
      ('public.ward_lab_report_json(text)','6ef197bc17239dca93957f0171ee0d2b'),
      ('public.ward_read_lab_history(uuid,text)','5065333c49fb20e78aafe68e88cfab1e'),
      ('public.ward_save_lab_report(uuid,jsonb)','c513d0196c078a864ec50bbad32c8d9c')) v(fn,md) loop
    if md5(pg_get_functiondef(r.fn::regprocedure)) <> r.md then
      raise exception 'R1.3.135 drift check failed for %: live md5 % <> baseline %', r.fn, md5(pg_get_functiondef(r.fn::regprocedure)), r.md;
    end if;
  end loop;
end $chk$;

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
  v_ect_plans jsonb; v_ect_sessions jsonb; v_events jsonb; v_obs jsonb; v_duty jsonb; v_pedits jsonb; v_mse jsonb; v_dcert jsonb; v_labs jsonb;
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
           address, phone, secondary_dx, tertiary_dx, comorbidities, discharge_advice, discharge_meds, discharge_review, discharge_ect_sessions,
           discharge_requested_by, discharge_requester_name, admit_consultants
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

  select coalesce(jsonb_agg(to_jsonb(dc) order by dc.discharged_at desc, dc.id), '[]'::jsonb) into v_dcert from (
    select id, patient_id, discharged_at, discharge_mode, edits, key_drugs, version, printed_hash, print_count,
           printed_by, printed_by_name, printed_at, first_printed_at, updated_by, updated_by_name, updated_at
    from public.discharge_certificates) dc;

  -- R1.3.128: lab reports of on-ward patients' current admission, plus any report from the last 14 days
  -- R1.3.135: plus every report of a not-discharged patient that was saved/edited in the last 14 days whatever its
  --           report date (a just-saved old-dated report is never dropped), and every tombstone from the last 14 days
  --           (so devices learn of removals of old-dated reports). Bounded by save activity, not by report dates.
  select coalesce(jsonb_agg(public.ward_lab_report_json(lr.id) order by coalesce(lr.collected_at, lr.reported_at) desc, lr.id), '[]'::jsonb) into v_labs
  from public.lab_reports lr join public.patients pp on pp.id=lr.patient_id
  where (lr.deleted_at is null or lr.deleted_at > now() - interval '14 days')
    and (coalesce(lr.collected_at, lr.reported_at) > now() - interval '14 days'
         or (coalesce(pp.active_status,'admitted') <> 'discharged' and coalesce(lr.collected_at, lr.reported_at) >= pp.admitted_at - interval '2 days')
         or lr.deleted_at > now() - interval '14 days'
         or (coalesce(pp.active_status,'admitted') <> 'discharged' and greatest(lr.created_at, lr.updated_at) > now() - interval '14 days'));

  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc, m.id), '[]'::jsonb) into v_mse from (
    select id, patient_id, kind, admitted_at, data, high_risk, summary, created_by, created_by_name, created_at from public.mse_entries) m;

  return jsonb_build_object(
    'ok', true, 'resident_id', v_resident_id,
    'unit', v_unit, 'sections', v_sections, 'consultants', v_consultants, 'residents', v_residents,
    'beds', v_beds, 'patients', v_patients, 'assignments', v_assignments, 'snapshots', v_snapshots,
    'orders', v_orders, 'doses', v_doses, 'tasks', v_tasks, 'handovers', v_handovers,
    'handover_items', v_handover_items, 'ect_plans', v_ect_plans, 'ect_sessions', v_ect_sessions,
    'events', v_events, 'observation_stays', v_obs, 'duty', v_duty, 'patient_edits', v_pedits, 'mse_entries', v_mse, 'discharge_certificates', v_dcert, 'lab_reports', v_labs
  );
end
$function$;

do $post$
begin
  if md5(pg_get_functiondef('public.ward_read_ward_state(uuid)'::regprocedure)) <> 'f7737a140e4984ff524f45084414696a' then
    raise exception 'R1.3.135 post-check: ward_read_ward_state md5 is %', md5(pg_get_functiondef('public.ward_read_ward_state(uuid)'::regprocedure));
  end if;
end $post$;
commit;
