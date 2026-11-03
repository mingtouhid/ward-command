-- ROLLBACK for 20261102_r16_shift_handovers. NOT APPLIED. safeupdate-safe, no BEGIN/COMMIT.
-- Restores the R1.5.1 function bodies verbatim, then the table shape.
-- Shift-only handovers (to_id null) are re-addressed to whoever took them, else to the sender, so NOT NULL can return;
-- their target_date is lost. Deploy the R1.5.1 client (dpl_JmiAptNrbemMWna7xS6kbXUCcimL) together with this.

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
  v_ect_plans jsonb; v_ect_sessions jsonb; v_events jsonb; v_obs jsonb; v_duty jsonb; v_pedits jsonb; v_mse jsonb; v_dcert jsonb; v_labs jsonb; v_vitals jsonb; v_scales jsonb;
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
    select id, patient_id, kind, admitted_at, data, high_risk, summary, created_by, created_by_name, created_at from public.mse_entries where deleted_at is null) m; -- R1.3.139: deleted MSEs leave every list

  -- R1.3.139: vitals recorded by interns: current admission of on-ward patients, plus the last 14 days
  select coalesce(jsonb_agg(to_jsonb(v) order by v.recorded_at desc, v.id), '[]'::jsonb) into v_vitals from (
    select pv.id, pv.patient_id, pv.recorded_at, pv.bp_systolic, pv.bp_diastolic, pv.pulse, pv.resp_rate, pv.spo2, pv.temp_f,
           pv.abnormal, pv.recorded_by, pv.recorded_by_name, pv.created_at
    from public.patient_vitals pv join public.patients pp on pp.id=pv.patient_id
    where pv.recorded_at > now() - interval '14 days'
       or (coalesce(pp.active_status,'admitted') <> 'discharged' and pv.recorded_at >= pp.admitted_at - interval '2 days')) v;

  -- R1.3.143: rating scales: current admission of on-ward patients, the last 14 days, and tombstones from the last 14 days
  select coalesce(jsonb_agg(to_jsonb(x) order by x.rated_at desc, x.id), '[]'::jsonb) into v_scales from (
    select sa.id, sa.patient_id, sa.scale_id, sa.scale_version, sa.answers, sa.total, sa.subscores, sa.severity, sa.tone,
           sa.rated_at, sa.rated_by, sa.rated_by_name, sa.rated_by_role, sa.note, sa.informant, sa.created_at,
           sa.deleted_at, sa.deleted_by_name, sa.deleted_reason
    from public.scale_assessments sa join public.patients pp on pp.id=sa.patient_id
    where (sa.deleted_at is null or sa.deleted_at > now() - interval '14 days')
      and (sa.rated_at > now() - interval '14 days'
           or (coalesce(pp.active_status,'admitted') <> 'discharged' and sa.rated_at >= pp.admitted_at - interval '2 days')
           or sa.deleted_at > now() - interval '14 days')) x;

  return jsonb_build_object(
    'ok', true, 'resident_id', v_resident_id,
    'unit', v_unit, 'sections', v_sections, 'consultants', v_consultants, 'residents', v_residents,
    'beds', v_beds, 'patients', v_patients, 'assignments', v_assignments, 'snapshots', v_snapshots,
    'orders', v_orders, 'doses', v_doses, 'tasks', v_tasks, 'handovers', v_handovers,
    'handover_items', v_handover_items, 'ect_plans', v_ect_plans, 'ect_sessions', v_ect_sessions,
    'events', v_events, 'observation_stays', v_obs, 'duty', v_duty, 'patient_edits', v_pedits, 'mse_entries', v_mse, 'discharge_certificates', v_dcert, 'lab_reports', v_labs, 'vitals', v_vitals, 'scales', v_scales
  );
end
$function$;

CREATE OR REPLACE FUNCTION public.ward_list_notification_inbox(p_session_token uuid, p_limit integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.ward_create_notification_event(p_session_token uuid, p_event_type text, p_category text, p_priority text, p_patient_id text DEFAULT NULL::text, p_task_id text DEFAULT NULL::text, p_handover_id text DEFAULT NULL::text, p_ect_plan_id text DEFAULT NULL::text, p_title text DEFAULT ''::text, p_body text DEFAULT ''::text, p_target_url text DEFAULT './#/home'::text, p_recipient_scope text DEFAULT 'active_team'::text, p_dedupe_key text DEFAULT NULL::text, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_resident_id text;
  v_role text;
  v_event_id uuid;
  v_dedupe_key text;
  v_task_patient text;
  v_task_assignee text;
  v_task_creator text;
  v_handover_from text;
  v_handover_to text;
  v_ect_patient text;
  v_critical_patient text;
  v_critical_creator text;
  v_critical_id text;
BEGIN
  SELECT ws.resident_id INTO v_resident_id
  FROM public.ward_sessions ws
  WHERE ws.token = p_session_token AND ws.expires_at > now();
  IF v_resident_id IS NULL THEN RAISE EXCEPTION 'Invalid or expired ward session'; END IF;

  SELECT lower(r.role) INTO v_role
  FROM public.residents r
  WHERE r.id = v_resident_id AND r.active = true;
  IF v_role IS NULL THEN RAISE EXCEPTION 'Ward resident is inactive or missing'; END IF;

  IF p_event_type NOT IN (
    'admission','discharge','transfer','handover','task','ect','critical_status_update','restrain','observation'
  ) THEN
    RAISE EXCEPTION 'Invalid notification event type';
  END IF;
  IF p_category NOT IN ('clinical','handovers','tasks','ect') THEN RAISE EXCEPTION 'Invalid notification category'; END IF;
  IF p_priority NOT IN ('normal','high') THEN RAISE EXCEPTION 'Invalid notification priority'; END IF;
  IF p_recipient_scope NOT IN ('active_team','handover','task_assignees') THEN RAISE EXCEPTION 'Invalid notification recipient scope'; END IF;
  IF p_title IS NULL OR length(trim(p_title)) = 0 OR length(p_title) > 160 THEN RAISE EXCEPTION 'Invalid notification title'; END IF;
  IF p_body IS NULL OR length(p_body) > 1000 THEN RAISE EXCEPTION 'Invalid notification body'; END IF;
  IF p_target_url IS NULL OR p_target_url !~ '^\./#/(home|snap|handover)(/[^?#]*)?$' THEN RAISE EXCEPTION 'Invalid notification target URL'; END IF;
  IF p_metadata IS NULL THEN p_metadata := '{}'::jsonb; END IF;

  IF p_event_type IN ('admission','discharge','transfer','critical_status_update','restrain','observation')
     AND NOT (p_category='clinical' AND p_recipient_scope='active_team') THEN
    RAISE EXCEPTION 'Invalid clinical notification routing';
  END IF;
  IF p_event_type='handover' AND NOT (p_category='handovers' AND p_recipient_scope='handover') THEN
    RAISE EXCEPTION 'Invalid handover notification routing';
  END IF;
  IF p_event_type='task' AND NOT (p_category='tasks' AND p_recipient_scope='task_assignees') THEN
    RAISE EXCEPTION 'Invalid task notification routing';
  END IF;
  IF p_event_type='ect' AND NOT (p_category='ect' AND p_recipient_scope='active_team') THEN
    RAISE EXCEPTION 'Invalid ECT notification routing';
  END IF;

  IF p_event_type IN ('admission','discharge','transfer','ect','critical_status_update','restrain','observation')
     AND v_role NOT IN ('admin','consultant','doctor','resident','nurse') THEN
    RAISE EXCEPTION 'Not authorized to create this clinical notification';
  END IF;

  IF p_event_type IN ('admission','discharge','transfer','critical_status_update','restrain','observation') THEN
    IF p_patient_id IS NULL THEN RAISE EXCEPTION 'Patient is required for this notification'; END IF;
    PERFORM 1 FROM public.patients p WHERE p.id = p_patient_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Patient not found'; END IF;
  END IF;

  IF p_event_type IN ('admission','transfer','restrain') THEN
    PERFORM 1 FROM public.patients p WHERE p.id=p_patient_id AND p.active_status<>'discharged';
    IF NOT FOUND THEN RAISE EXCEPTION 'Notification requires an active patient'; END IF;
  END IF;

  IF p_event_type='task' THEN
    IF p_task_id IS NULL THEN RAISE EXCEPTION 'Task is required for task notification'; END IF;
    SELECT t.patient_id, t.assigned_to, t.created_by INTO v_task_patient, v_task_assignee, v_task_creator
    FROM public.tasks t WHERE t.id=p_task_id FOR UPDATE;
    IF v_task_patient IS NULL THEN RAISE EXCEPTION 'Task not found'; END IF;
    IF p_patient_id IS NOT NULL AND p_patient_id<>v_task_patient THEN RAISE EXCEPTION 'Task does not belong to patient'; END IF;
    IF v_resident_id<>coalesce(v_task_assignee,'') AND v_resident_id<>coalesce(v_task_creator,'') AND v_role NOT IN ('admin','consultant') THEN
      RAISE EXCEPTION 'Not authorized to notify about this task';
    END IF;
    IF p_metadata ? 'assigned_to' AND nullif(trim(p_metadata->>'assigned_to'),'') IS NOT NULL AND (p_metadata->>'assigned_to')<>coalesce(v_task_assignee,'') THEN
      RAISE EXCEPTION 'Task notification recipient does not match task assignment';
    END IF;
  END IF;

  IF p_event_type='handover' THEN
    IF p_handover_id IS NULL THEN RAISE EXCEPTION 'Handover is required for handover notification'; END IF;
    SELECT h.from_id, h.to_id INTO v_handover_from, v_handover_to FROM public.handovers h WHERE h.id=p_handover_id FOR UPDATE;
    IF v_handover_from IS NULL THEN RAISE EXCEPTION 'Handover not found'; END IF;
    IF v_resident_id<>v_handover_from AND v_resident_id<>v_handover_to AND v_role NOT IN ('admin','consultant') THEN
      RAISE EXCEPTION 'Not authorized to notify about this handover';
    END IF;
    IF p_patient_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.handover_items hi WHERE hi.handover_id=p_handover_id AND hi.patient_id=p_patient_id) THEN
      RAISE EXCEPTION 'Patient is not part of this handover';
    END IF;
  END IF;

  IF p_event_type='ect' THEN
    IF p_ect_plan_id IS NULL OR p_patient_id IS NULL THEN RAISE EXCEPTION 'ECT plan and patient are required'; END IF;
    SELECT e.patient_id INTO v_ect_patient FROM public.ect_plans e WHERE e.id=p_ect_plan_id FOR UPDATE;
    IF v_ect_patient IS NULL THEN RAISE EXCEPTION 'ECT plan not found'; END IF;
    IF v_ect_patient<>p_patient_id THEN RAISE EXCEPTION 'ECT plan does not belong to patient'; END IF;
  END IF;

  IF p_event_type='critical_status_update' THEN
    v_critical_id := nullif(trim(p_metadata->>'critical_status_update_id'),'');
    IF v_critical_id IS NULL THEN RAISE EXCEPTION 'Critical status update record is required'; END IF;
    BEGIN
      EXECUTE 'SELECT patient_id::text, created_by::text FROM public.critical_status_updates WHERE id::text=$1'
        INTO v_critical_patient, v_critical_creator USING v_critical_id;
    EXCEPTION WHEN undefined_table THEN
      RAISE EXCEPTION 'Critical status update table is missing';
    END;
    IF v_critical_patient IS NULL THEN RAISE EXCEPTION 'Critical status update not found'; END IF;
    IF v_critical_patient<>p_patient_id THEN RAISE EXCEPTION 'Critical status update does not belong to patient'; END IF;
    IF v_critical_creator<>v_resident_id THEN RAISE EXCEPTION 'Not authorized to notify this critical status update'; END IF;
  END IF;

  v_dedupe_key := nullif(trim(p_dedupe_key),'');
  IF v_dedupe_key IS NULL THEN
    v_dedupe_key := p_event_type || ':' || coalesce(p_patient_id,'') || ':' || clock_timestamp()::text;
  END IF;
  IF length(v_dedupe_key)>500 THEN RAISE EXCEPTION 'Notification dedupe key is too long'; END IF;

  INSERT INTO public.notification_events(
    event_type, category, priority, patient_id, task_id, handover_id, ect_plan_id,
    actor_id, title, body, target_url, recipient_scope, dedupe_key, metadata
  ) VALUES (
    p_event_type, p_category, p_priority, p_patient_id, p_task_id, p_handover_id, p_ect_plan_id,
    v_resident_id, trim(p_title), p_body, p_target_url, p_recipient_scope, v_dedupe_key, p_metadata
  )
  ON CONFLICT (dedupe_key) DO UPDATE SET id=public.notification_events.id
  RETURNING id INTO v_event_id;

  RETURN jsonb_build_object('ok',true,'notification_id',v_event_id,'actor_id',v_resident_id,'dedupe_key',v_dedupe_key);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ward_upsert_handover(p_session_token uuid, p_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_resident_id text;
  v_id text;
  v_to text;
  v_shift text;
begin
  select resident_id into v_resident_id
  from ward_sessions
  where token=p_session_token and expires_at>now();
  if v_resident_id is null then
    raise exception 'Invalid or expired ward session';
  end if;
  v_id=nullif(trim(p_row->>'id'),'');
  v_to=nullif(trim(p_row->>'to_id'),'');
  v_shift=coalesce(nullif(trim(p_row->>'shift'),''),'morning');
  if v_id is null then raise exception 'Handover id is required'; end if;
  if v_to is null then raise exception 'Handover recipient is required'; end if;
  if not exists(select 1 from residents where id=v_to and active=true) then
    raise exception 'Handover recipient is not active';
  end if;
  if v_shift not in ('morning','evening','night') then
    raise exception 'Invalid handover shift';
  end if;
  if exists(
    select 1 from handovers
    where id=v_id and from_id<>v_resident_id
  ) then
    raise exception 'Handover sender must be the active session resident';
  end if;
  insert into handovers(id,from_id,to_id,shift,status,created_at,acknowledged_by,acknowledged_at)
  values (
    v_id, v_resident_id, v_to, v_shift, 'sent',
    coalesce((p_row->>'created_at')::timestamptz, now()), null, null
  )
  on conflict(id) do update set
    to_id=excluded.to_id,
    shift=excluded.shift
    where handovers.status='sent' and handovers.from_id=v_resident_id;
  return jsonb_build_object('ok',true,'handover_id',v_id,'from_id',v_resident_id);
end
$function$;

CREATE OR REPLACE FUNCTION public.ward_ack_handover(p_session_token uuid, p_handover_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_resident_id text;
  v_to text;
  v_status text;
begin
  select resident_id
  into v_resident_id
  from ward_sessions
  where token=p_session_token
    and expires_at>now();

  if v_resident_id is null then
    raise exception 'Invalid or expired ward session';
  end if;

  select to_id,status
  into v_to,v_status
  from handovers
  where id=p_handover_id
  for update;

  if not found then
    raise exception 'Handover not found';
  end if;

  if v_status='acknowledged' then
    return jsonb_build_object(
      'ok',true,
      'handover_id',p_handover_id,
      'idempotent',true
    );
  end if;

  if v_to<>v_resident_id
     and not exists(
       select 1
       from residents
       where id=v_resident_id
         and active=true
         and role in ('admin','consultant')
     ) then
    raise exception
      'Only the receiving resident may acknowledge this handover';
  end if;

  update handovers
  set
    status='acknowledged',
    acknowledged_by=v_resident_id,
    acknowledged_at=now()
  where id=p_handover_id;

  return jsonb_build_object(
    'ok',true,
    'handover_id',p_handover_id,
    'acknowledged_by',v_resident_id
  );
end $function$;

CREATE OR REPLACE FUNCTION public.ward_update_handover_item(p_session_token uuid, p_item_id text, p_done boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_resident_id text;
  v_hid text;
  v_to text;
  v_done boolean;
begin
  select ws.resident_id into v_resident_id
  from public.ward_sessions ws
  join public.residents r on r.id=ws.resident_id and r.active=true
  where ws.token=p_session_token and ws.expires_at>now()
  limit 1;
  if v_resident_id is null then raise exception 'Invalid or expired ward session'; end if;
  if nullif(trim(p_item_id),'') is null then raise exception 'Handover item id is required'; end if;
  select hi.handover_id, hi.done, h.to_id
    into v_hid, v_done, v_to
  from public.handover_items hi
  join public.handovers h on h.id=hi.handover_id
  where hi.id=p_item_id
  for update of hi;
  if not found then raise exception 'Handover item not found'; end if;
  if v_resident_id is distinct from v_to then
    raise exception 'Only the receiving resident may update this handover item';
  end if;
  if coalesce(p_done,true)=coalesce(v_done,false) then
    return jsonb_build_object('ok',true,'idempotent',true,'handover_item_id',p_item_id,'done',v_done);
  end if;
  update public.handover_items set done=coalesce(p_done,true) where id=p_item_id;
  return jsonb_build_object('ok',true,'handover_item_id',p_item_id,'handover_id',v_hid,'done',coalesce(p_done,true));
end;
$function$;

CREATE OR REPLACE FUNCTION public.ward_upsert_handover_item(p_session_token uuid, p_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_resident_id text;
  v_id text;
  v_hid text;
  v_pid text;
  v_from text;
  v_to text;
begin
  select resident_id
  into v_resident_id
  from ward_sessions
  where token=p_session_token
    and expires_at>now();

  if v_resident_id is null then
    raise exception 'Invalid or expired ward session';
  end if;

  v_id=nullif(trim(p_row->>'id'),'');
  v_hid=nullif(trim(p_row->>'handover_id'),'');
  v_pid=nullif(trim(p_row->>'patient_id'),'');

  if v_id is null
     or v_hid is null
     or v_pid is null then
    raise exception
      'Handover item identifiers are required';
  end if;

  select from_id,to_id
  into v_from,v_to
  from handovers
  where id=v_hid
  for update;

  if not found then
    raise exception 'Handover not found';
  end if;

  if v_resident_id<>v_from
     and v_resident_id<>v_to
     and not exists(
       select 1
       from residents
       where id=v_resident_id
         and active=true
         and role in ('admin','consultant')
     ) then
    raise exception 'Not authorized for this handover';
  end if;

  perform 1
  from patients
  where id=v_pid
  for update;

  if not found then
    raise exception 'Patient not found';
  end if;

  if nullif(trim(p_row->>'problem'),'') is null then
    raise exception 'Handover problem is required';
  end if;

  if exists(
    select 1
    from handover_items
    where id=v_id
      and (
        handover_id<>v_hid
        or patient_id<>v_pid
      )
  ) then
    raise exception
      'Handover item belongs to another record';
  end if;

  insert into handover_items(
    id,
    handover_id,
    patient_id,
    priority,
    problem,
    action_required,
    done
  )
  values(
    v_id,
    v_hid,
    v_pid,
    coalesce(
      nullif(trim(p_row->>'priority'),''),
      'high'
    ),
    trim(p_row->>'problem'),
    coalesce(p_row->>'action_required',''),
    coalesce(
      (p_row->>'done')::boolean,
      false
    )
  )
  on conflict(id)
  do update set
    priority=excluded.priority,
    problem=excluded.problem,
    action_required=excluded.action_required,
    done=excluded.done;

  return jsonb_build_object(
    'ok',true,
    'handover_item_id',v_id
  );
end $function$;

update public.handovers set to_id = coalesce(acknowledged_by, from_id) where to_id is null;
alter table public.handovers alter column to_id set not null;
drop index if exists public.idx_handovers_slot;
alter table public.handovers drop column if exists target_date;
drop function if exists public.ward_on_duty_for(text,text,date);
drop function if exists public.ward_handover_slot_date(text,timestamptz);
drop function if exists public.ward_shift_day(timestamptz,text);
