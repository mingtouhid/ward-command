-- =====================================================================================================================
-- Ward Sync - monthly archive v2                                         20261102_archive_v2.sql
-- Additive only. Safe under pg-safeupdate (every UPDATE/DELETE inside functions has a WHERE; no top-level UPDATE/DELETE).
-- No BEGIN/COMMIT: run as one migration (apply_migration wraps it in a transaction).
-- Rollback: 20261102_archive_v2-rollback.sql
--   1. archive_manifest: archive_version (existing rows = 1, new rows = 2), history (v1 files kept when re-run)
--   2. discharge_certificates: printed_app_version, printed_fmt, printed_render (D3: how the print looked)
--   3. ward_save_discharge_certificate: live R1.6 body + stores those three on print (older apps -> NULLs)
--   4. ward_archive_state(p_month): the month's ward state in the exact ward_read_ward_state shape, for the archive
--   5. ward_archive_rerun_claim / ward_archive_rerun_reset: one-time v1 -> v2 re-run of a verified month (D6)
-- All new archive functions: SECURITY DEFINER, service_role only.
-- =====================================================================================================================

-- 1. manifest
alter table public.archive_manifest add column if not exists archive_version integer not null default 1;
alter table public.archive_manifest alter column archive_version set default 2;
alter table public.archive_manifest add column if not exists history jsonb not null default '[]'::jsonb;

-- 2. certificate print facts
alter table public.discharge_certificates add column if not exists printed_app_version text;
alter table public.discharge_certificates add column if not exists printed_fmt integer;
alter table public.discharge_certificates add column if not exists printed_render jsonb;

-- 3. certificate save/print RPC (live definition md5 f5387043f90a426dca900bdab99b192b + the archive v2 fields)
CREATE OR REPLACE FUNCTION public.ward_save_discharge_certificate(p_token uuid, p_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_resident_id text;
  v_role text;
  v_name text;
  v_pid text;
  v_status text;
  v_pdis timestamptz;
  v_cdis timestamptz;
  v_mode text;
  v_action text;
  v_edits jsonb;
  v_keys jsonb;
  v_hash text;
  v_op text;
  v_at timestamptz;
  v_reprint boolean := false;
  v_ver integer;
  v_row public.discharge_certificates%ROWTYPE;
BEGIN
  SELECT s.resident_id, lower(coalesce(r.role,'')), r.display_name
    INTO v_resident_id, v_role, v_name
  FROM public.ward_sessions s
  JOIN public.residents r ON r.id=s.resident_id
  WHERE s.token=p_token AND s.expires_at>now() AND r.active=true;
  IF v_resident_id IS NULL THEN RAISE EXCEPTION 'Invalid or expired ward session'; END IF;
  -- Consultants countersign and may edit/print; view-only accounts may not.
  IF v_role = 'viewer' THEN RAISE EXCEPTION 'This account is view-only'; END IF;

  IF p_row IS NULL OR jsonb_typeof(p_row) <> 'object' THEN RAISE EXCEPTION 'Certificate data is required'; END IF;
  v_pid := nullif(trim(coalesce(p_row->>'patient_id','')),'');
  v_action := coalesce(nullif(trim(coalesce(p_row->>'action','')),''),'save');
  IF v_pid IS NULL THEN RAISE EXCEPTION 'Patient is required'; END IF;
  IF v_action NOT IN ('save','print') THEN RAISE EXCEPTION 'Unknown certificate action'; END IF;

  v_edits := coalesce(p_row->'edits','{}'::jsonb);
  v_keys := coalesce(p_row->'key_drugs','[]'::jsonb);
  IF jsonb_typeof(v_edits) <> 'object' OR pg_column_size(v_edits) >= 32768 THEN RAISE EXCEPTION 'Certificate edits are invalid or too large'; END IF;
  IF jsonb_typeof(v_keys) <> 'array' OR jsonb_array_length(v_keys) > 40 OR pg_column_size(v_keys) >= 16384 THEN RAISE EXCEPTION 'Key drug list is invalid or too long'; END IF;
  v_hash := coalesce(nullif(left(trim(coalesce(p_row->>'content_hash','')),128),''), md5(v_edits::text || v_keys::text));
  v_op := nullif(left(trim(coalesce(p_row->>'op_id','')),80),'');

  SELECT active_status, discharged_at, discharge_mode INTO v_status, v_pdis, v_mode
    FROM public.patients WHERE id=v_pid FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Patient not found'; END IF;
  IF coalesce(v_status,'') <> 'discharged' OR v_pdis IS NULL THEN RAISE EXCEPTION 'Patient is not discharged'; END IF;
  IF coalesce(v_mode,'') IN ('lama','transfer') THEN RAISE EXCEPTION 'No discharge certificate for LAMA or transfer'; END IF;
  v_cdis := nullif(p_row->>'discharged_at','')::timestamptz;
  IF v_cdis IS NOT NULL AND abs(extract(epoch from (v_cdis - v_pdis))) > 1 THEN
    RAISE EXCEPTION 'Discharge details changed; refresh and try again';
  END IF;

  SELECT * INTO v_row FROM public.discharge_certificates WHERE patient_id=v_pid AND discharged_at=v_pdis FOR UPDATE;
  IF FOUND AND v_op IS NOT NULL AND v_row.last_op_id = v_op THEN
    RETURN jsonb_build_object('ok',true,'idempotent',true,'certificate',to_jsonb(v_row));
  END IF;
  IF NOT FOUND THEN
    INSERT INTO public.discharge_certificates(id, patient_id, discharged_at, discharge_mode, updated_by, updated_by_name)
    VALUES ('dc-'||v_pid||'-'||(extract(epoch from v_pdis)*1000)::bigint::text, v_pid, v_pdis, v_mode, v_resident_id, v_name)
    RETURNING * INTO v_row;
  END IF;

  IF v_action = 'save' THEN
    UPDATE public.discharge_certificates SET
      edits=v_edits, key_drugs=v_keys, discharge_mode=v_mode,
      updated_by=v_resident_id, updated_by_name=v_name, updated_at=now(), last_op_id=coalesce(v_op,last_op_id)
    WHERE id=v_row.id RETURNING * INTO v_row;
    RETURN jsonb_build_object('ok',true,'idempotent',false,'certificate',to_jsonb(v_row));
  END IF;

  -- print (client time kept for offline prints, never in the future)
  v_at := least(coalesce(nullif(p_row->>'printed_at','')::timestamptz, now()), now());
  v_reprint := v_row.version > 0 AND v_row.printed_hash IS NOT DISTINCT FROM v_hash;
  v_ver := CASE WHEN v_reprint THEN v_row.version ELSE v_row.version + 1 END;
  UPDATE public.discharge_certificates SET
    edits=v_edits, key_drugs=v_keys, discharge_mode=v_mode,
    version=v_ver, printed_hash=v_hash, print_count=print_count+1,
    printed_by=v_resident_id, printed_by_name=v_name, printed_at=v_at,
    first_printed_at=coalesce(first_printed_at, v_at),
    updated_by=v_resident_id, updated_by_name=v_name, updated_at=now(), last_op_id=coalesce(v_op,last_op_id),
    -- archive v2 (D3): what this print looked like, so the monthly archive re-creates the same page.
    -- Older apps send none of these keys -> NULLs (the archive then flags the app version as unknown).
    printed_app_version=nullif(left(trim(coalesce(p_row->>'app_version','')),40),''),
    printed_fmt=CASE WHEN coalesce(p_row->>'cert_fmt','') ~ '^[0-9]{1,6}$' THEN (p_row->>'cert_fmt')::int END,
    printed_render=jsonb_build_object(
      'reprint', CASE WHEN jsonb_typeof(p_row->'reprint')='boolean' THEN (p_row->'reprint') ELSE to_jsonb(v_reprint) END,
      'version', CASE WHEN coalesce(p_row->>'print_version','') ~ '^[0-9]{1,6}$' THEN to_jsonb((p_row->>'print_version')::int) ELSE to_jsonb(v_ver) END,
      'at', coalesce(nullif(p_row->>'printed_at',''), to_jsonb(v_at)#>>'{}'),
      'server_reprint', v_reprint, 'server_version', v_ver)
  WHERE id=v_row.id RETURNING * INTO v_row;

  INSERT INTO public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  VALUES ('dcert-'||coalesce(v_op, v_row.id||'-'||v_row.print_count::text), v_pid, 'note',
          'Discharge certificate '||CASE WHEN v_reprint THEN 're-printed' ELSE 'printed' END||' · v'||v_ver,
          CASE WHEN v_reprint THEN 'Re-print · version '||v_ver ELSE 'Version '||v_ver END,
          v_resident_id, v_at)
  ON CONFLICT (id) DO NOTHING;

  RETURN jsonb_build_object('ok',true,'idempotent',false,'reprint',v_reprint,'version',v_ver,'certificate',to_jsonb(v_row));
END
$function$
;

-- 4. the month's ward state for the archive (service_role only; no session; no time windows for the month's patients)
create or replace function public.ward_archive_state(p_month text)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_m date; v_start timestamptz; v_end timestamptz; v_pids text[];
  v_unit jsonb; v_sections jsonb; v_consultants jsonb; v_residents jsonb;
  v_beds jsonb; v_patients jsonb; v_assignments jsonb; v_snapshots jsonb;
  v_orders jsonb; v_doses jsonb; v_tasks jsonb; v_handovers jsonb; v_handover_items jsonb;
  v_ect_plans jsonb; v_ect_sessions jsonb; v_events jsonb; v_obs jsonb; v_pedits jsonb; v_mse jsonb; v_dcert jsonb;
  v_labs jsonb; v_vitals jsonb; v_scales jsonb;
  v_faculty jsonb; v_links jsonb; v_advice jsonb; v_crit jsonb; v_dev jsonb; v_undo jsonb; v_mse_del jsonb;
begin
  if p_month is null or p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'p_month must be YYYY-MM'; end if;
  v_m := to_date(p_month || '-01', 'YYYY-MM-DD');
  v_start := (v_m::timestamp) at time zone 'Asia/Kolkata';
  v_end := ((v_m + interval '1 month')::timestamp) at time zone 'Asia/Kolkata';

  -- the month's patients: in the ward at any time during the month, or on an observation stay overlapping it
  select coalesce(array_agg(distinct x.id), '{}') into v_pids from (
    select p.id from public.patients p
     where coalesce(p.admitted_at, p.created_at) < v_end
       and (p.discharged_at is null or p.discharged_at >= v_start)
    union
    select os.patient_id from public.observation_stays os
     where os.started_at < v_end and (os.ended_at is null or os.ended_at >= v_start)) x
  where x.id is not null;

  select coalesce(jsonb_agg(to_jsonb(u) order by u.id), '[]'::jsonb) into v_unit from (
    select id, unit_name, created_at, updated_at from public.unit_settings) u;
  select coalesce(jsonb_agg(to_jsonb(s) order by s.sort_order, s.id), '[]'::jsonb) into v_sections from (
    select id, name, sort_order, active, created_at from public.ward_sections) s;
  select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order, c.id), '[]'::jsonb) into v_consultants from (
    select id, name, designation, active, sort_order, created_at from public.unit_consultants) c;
  -- all staff (incl. since-deactivated), so names on month-old entries still resolve
  select coalesce(jsonb_agg(to_jsonb(r) order by r.display_name, r.id), '[]'::jsonb) into v_residents from (
    select id, username, display_name, role, active, created_at from public.residents) r;
  select coalesce(jsonb_agg(to_jsonb(b) order by b.bed_number, b.id), '[]'::jsonb) into v_beds from (
    select id, bed_number, section_id, active, current_patient_id, created_at, updated_at from public.beds) b;
  select coalesce(jsonb_agg(to_jsonb(p) order by p.admitted_at desc, p.id), '[]'::jsonb) into v_patients from (
    select id, patient_code, hospital_no, mrd_no, name, age, sex, diagnosis,
           admitted_at, active_status, created_at, updated_at, updated_by,
           reason_for_admission, referred_by, consultant_name, consultant_name_2,
           discharged_at, discharge_mode, discharge_outcome, treatment_mode,
           address, phone, secondary_dx, tertiary_dx, comorbidities, discharge_advice, discharge_meds, discharge_review, discharge_ect_sessions,
           discharge_requested_by, discharge_requester_name, admit_consultants
    from public.patients where id = any(v_pids)) p;
  select coalesce(jsonb_agg(to_jsonb(a) order by a.assigned_at desc, a.id), '[]'::jsonb) into v_assignments from (
    select id, patient_id, bed_id, assigned_at, released_at, assigned_by from public.patient_bed_assignments where patient_id = any(v_pids)) a;
  select coalesce(jsonb_agg(to_jsonb(s) order by s.updated_at desc, s.patient_id), '[]'::jsonb) into v_snapshots from (
    select patient_id, clinical_state, risk_level, sleep_status, watch_points, current_plan, updated_by, updated_at, tags, row_version, pgt_notes
    from public.patient_snapshots where patient_id = any(v_pids)) s;
  select coalesce(jsonb_agg(to_jsonb(o) order by o.created_at desc, o.id), '[]'::jsonb) into v_orders from (
    select id, patient_id, drug, dose, route, frequency, scheduled_time, start_date, stop_date, status, indication, created_by, created_at,
           hold_at, lineage_id, supersedes, change_note, updated_at, stopped_at from public.medication_orders where patient_id = any(v_pids)) o;
  select coalesce(jsonb_agg(to_jsonb(d) order by d.scheduled_at desc, d.id), '[]'::jsonb) into v_doses from (
    select id, order_id, patient_id, scheduled_at, status, given_by, given_at from public.medication_doses where patient_id = any(v_pids)) d;
  select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc, t.id), '[]'::jsonb) into v_tasks from (
    select id, patient_id, title, detail, priority, assigned_to, status, created_by, created_at, completed_at from public.tasks where patient_id = any(v_pids)) t;
  select coalesce(jsonb_agg(to_jsonb(hi) order by hi.id), '[]'::jsonb) into v_handover_items from (
    select id, handover_id, patient_id, priority, problem, action_required, done from public.handover_items where patient_id = any(v_pids)) hi;
  select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at desc, h.id), '[]'::jsonb) into v_handovers from (
    select id, from_id, to_id, shift, target_date, status, created_at, acknowledged_by, acknowledged_at from public.handovers h0
    where (h0.created_at >= v_start and h0.created_at < v_end)
       or exists (select 1 from public.handover_items i where i.handover_id = h0.id and i.patient_id = any(v_pids))) h;
  select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at desc, e.id), '[]'::jsonb) into v_ect_plans from (
    select id, patient_id, indication, sessions_done, next_session_at, npo, status, created_by, created_at, updated_at from public.ect_plans where patient_id = any(v_pids)) e;
  select coalesce(jsonb_agg(to_jsonb(es) order by es.session_at desc, es.session_number desc, es.id), '[]'::jsonb) into v_ect_sessions from (
    select id, plan_id, patient_id, session_number, session_at, anaesthesia, stimulus, seizure_seconds, complications, response, next_plan, recorded_by
    from public.ect_sessions where patient_id = any(v_pids)) es;
  select coalesce(jsonb_agg(to_jsonb(al) order by al.created_at desc, al.id), '[]'::jsonb) into v_events from (
    select id, patient_id, kind, title, detail, actor_id, created_at from public.activity_log
    where patient_id = any(v_pids) or (patient_id is null and created_at >= v_start and created_at < v_end)) al;
  select coalesce(jsonb_agg(to_jsonb(os) order by os.started_at desc, os.id), '[]'::jsonb) into v_obs from (
    select id, patient_id, bed_id, reason, note, started_at, started_by, ended_at, ended_by, outcome, referral_to, discharge_meds
    from public.observation_stays where patient_id = any(v_pids)) os;
  select coalesce(jsonb_agg(to_jsonb(pe) order by pe.edited_at desc), '[]'::jsonb) into v_pedits from (
    select e.id, e.patient_id, e.field, e.old_value, e.new_value, e.edited_by, e.edited_at, e.edit_group
    from public.patient_edits e where e.patient_id = any(v_pids)) pe;
  -- certificates + how each was printed (printed_*; NULL for prints made before R1.6.1). print_reprint_log: the
  -- server's own record of the last print ('re-printed' or not), for prints made before printed_render existed.
  select coalesce(jsonb_agg(to_jsonb(dc) order by dc.discharged_at desc, dc.id), '[]'::jsonb) into v_dcert from (
    select c.id, c.patient_id, c.discharged_at, c.discharge_mode, c.edits, c.key_drugs, c.version, c.printed_hash, c.print_count,
           c.printed_by, c.printed_by_name, c.printed_at, c.first_printed_at, c.updated_by, c.updated_by_name, c.updated_at,
           c.printed_app_version, c.printed_fmt, c.printed_render,
           (select al.title ~* 're-printed' from public.activity_log al where c.last_op_id is not null and al.id = 'dcert-' || c.last_op_id) as print_reprint_log
    from public.discharge_certificates c where c.patient_id = any(v_pids)) dc;
  -- whole stay, no 14-day window; deleted reports come with their deleted_at marker (the app drops them, the JSON keeps them)
  select coalesce(jsonb_agg(public.ward_lab_report_json(lr.id) order by coalesce(lr.collected_at, lr.reported_at) desc, lr.id), '[]'::jsonb) into v_labs
  from public.lab_reports lr where lr.patient_id = any(v_pids);
  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc, m.id), '[]'::jsonb) into v_mse from (
    select id, patient_id, kind, admitted_at, data, high_risk, summary, created_by, created_by_name, created_at
    from public.mse_entries where deleted_at is null and patient_id = any(v_pids)) m;
  select coalesce(jsonb_agg(to_jsonb(v) order by v.recorded_at desc, v.id), '[]'::jsonb) into v_vitals from (
    select pv.id, pv.patient_id, pv.recorded_at, pv.bp_systolic, pv.bp_diastolic, pv.pulse, pv.resp_rate, pv.spo2, pv.temp_f,
           pv.abnormal, pv.recorded_by, pv.recorded_by_name, pv.created_at
    from public.patient_vitals pv where pv.patient_id = any(v_pids)) v;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.rated_at desc, x.id), '[]'::jsonb) into v_scales from (
    select sa.id, sa.patient_id, sa.scale_id, sa.scale_version, sa.answers, sa.total, sa.subscores, sa.severity, sa.tone,
           sa.rated_at, sa.rated_by, sa.rated_by_name, sa.rated_by_role, sa.note, sa.informant, sa.created_at,
           sa.deleted_at, sa.deleted_by_name, sa.deleted_reason
    from public.scale_assessments sa where sa.patient_id = any(v_pids)) x;

  -- the same extras the app loads after the ward state (ward_list_faculty / _patient_consultants / _patient_advice /
  -- _critical_status_updates), without the session check
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'username',r.username,'name',r.display_name,'designation',coalesce(r.designation,''))
           order by r.display_name), '[]'::jsonb) into v_faculty
    from public.residents r
   where lower(r.role)='consultant' and r.active and lower(r.username)<>'consultant'
     and r.display_name !~* '\mtest\M' and r.display_name !~* '^\s*dr\.?\s*x\s*$';
  select coalesce(jsonb_object_agg(id, jsonb_build_array(consultant_id, consultant_id_2)), '{}'::jsonb) into v_links
    from public.patients where id = any(v_pids) and (consultant_id is not null or consultant_id_2 is not null);
  select coalesce(jsonb_agg(public.ward_advice_row(a.id) order by a.created_at desc), '[]'::jsonb) into v_advice
    from public.patient_advice a where a.removed_at is null and a.patient_id = any(v_pids);
  select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'patient_id',c.patient_id,'message',c.message,'created_by',c.created_by,
           'created_by_name',coalesce(nullif(trim(r.display_name),''),nullif(trim(r.username),''),c.created_by,'Clinician'),'created_at',c.created_at)
           order by c.created_at desc), '[]'::jsonb) into v_crit
    from public.critical_status_updates c left join public.residents r on r.id=c.created_by
   where c.patient_id = any(v_pids);
  -- edit history the app does not load (archive appendix + JSON)
  select coalesce(jsonb_agg(to_jsonb(x) order by x.edited_at, x.id), '[]'::jsonb) into v_dev
    from public.discharge_edit_versions x where x.patient_id = any(v_pids);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]'::jsonb) into v_undo
    from public.admission_undo x where x.patient_id = any(v_pids);
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at, x.id), '[]'::jsonb) into v_mse_del
    from public.mse_entries x where x.patient_id = any(v_pids) and x.deleted_at is not null;

  return jsonb_build_object(
    'ok', true, 'archive', true, 'month', p_month, 'range', jsonb_build_object('start', v_start, 'end', v_end, 'tz', 'Asia/Kolkata'),
    'generated_at', now(), 'patient_ids', to_jsonb(v_pids),
    'ward_state', jsonb_build_object(
      'ok', true, 'resident_id', null,
      'unit', v_unit, 'sections', v_sections, 'consultants', v_consultants, 'residents', v_residents,
      'beds', v_beds, 'patients', v_patients, 'assignments', v_assignments, 'snapshots', v_snapshots,
      'orders', v_orders, 'doses', v_doses, 'tasks', v_tasks, 'handovers', v_handovers,
      'handover_items', v_handover_items, 'ect_plans', v_ect_plans, 'ect_sessions', v_ect_sessions,
      'events', v_events, 'observation_stays', v_obs, 'duty', '[]'::jsonb, 'patient_edits', v_pedits, 'mse_entries', v_mse,
      'discharge_certificates', v_dcert, 'lab_reports', v_labs, 'vitals', v_vitals, 'scales', v_scales),
    'extra', jsonb_build_object('faculty', v_faculty, 'consultant_links', v_links, 'advice', v_advice, 'critical_updates', v_crit,
      'discharge_edit_versions', v_dev, 'admission_undo', v_undo, 'mse_deleted', v_mse_del));
end
$function$;

-- 5a. re-run (D6): lease a VERIFIED v1 month for the one-time move of its files into _v1/. Never touches a v2 row.
create or replace function public.ward_archive_rerun_claim(p_month text, p_lease_seconds integer default 300)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare v_m date; v_row public.archive_manifest%rowtype;
begin
  if p_month is null or p_month !~ '^\d{4}-(0[1-9]|1[0-2])$' then raise exception 'p_month must be YYYY-MM'; end if;
  v_m := to_date(p_month || '-01', 'YYYY-MM-DD');
  if p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 900 then p_lease_seconds := 300; end if;
  select * into v_row from public.archive_manifest where month = v_m;
  if v_row.id is null then return jsonb_build_object('claimed', false, 'reason', 'no archive for this month'); end if;
  if v_row.archive_version >= 2 then return jsonb_build_object('claimed', false, 'reason', 'already v2', 'row', to_jsonb(v_row)); end if;
  if v_row.status <> 'verified' then return jsonb_build_object('claimed', false, 'reason', 'v1 archive is not verified (' || v_row.status || ')', 'row', to_jsonb(v_row)); end if;
  update public.archive_manifest
     set lease_until = now() + make_interval(secs => p_lease_seconds), last_run_at = now(), updated_at = now()
   where id = v_row.id and archive_version = 1 and status = 'verified'
     and (lease_until is null or lease_until < now())
  returning * into v_row;
  if not found then
    select * into v_row from public.archive_manifest where month = v_m;
    return jsonb_build_object('claimed', false, 'reason', 'another run holds the lease', 'row', to_jsonb(v_row));
  end if;
  return jsonb_build_object('claimed', true, 'row', to_jsonb(v_row));
end $function$;

-- 5b. re-run (D6): after the v1 files are in _v1/ (moved + checksummed by the edge function), keep the v1 manifest in
-- history and start the month again as v2. Refuses unless the row is still a verified v1 row.
create or replace function public.ward_archive_rerun_reset(p_id uuid, p_v1 jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare v_row public.archive_manifest%rowtype;
begin
  if p_v1 is null or jsonb_typeof(p_v1) <> 'object' or coalesce(p_v1->>'folder_id','') = '' or jsonb_typeof(p_v1->'files') <> 'object' then
    raise exception 'p_v1 must carry the _v1 folder_id and the moved files';
  end if;
  update public.archive_manifest a set
    history     = a.history || jsonb_build_array(jsonb_build_object(
                    'archive_version', a.archive_version, 'status', a.status, 'verified_at', a.verified_at,
                    'files', a.files, 'checksums', a.checksums, 'row_counts', a.row_counts, 'patient_ids', to_jsonb(a.patient_ids),
                    'folder_id', a.folder_id, 'moved_to', p_v1, 'reset_at', now())),
    archive_version = 2, status = 'pending', files = '{}'::jsonb, checksums = '{}'::jsonb, row_counts = '{}'::jsonb,
    patient_ids = '{}'::text[], queue = '{}'::text[], done = '{}'::text[], verified_at = null, error = null, attempts = 0,
    lease_until = null, updated_at = now()
  where a.id = p_id and a.archive_version = 1 and a.status = 'verified'
  returning * into v_row;
  if v_row.id is null then raise exception 'archive_manifest row is not a verified v1 archive'; end if;
  return to_jsonb(v_row);
end $function$;

revoke all on function public.ward_archive_state(text) from public, anon, authenticated;
revoke all on function public.ward_archive_rerun_claim(text, integer) from public, anon, authenticated;
revoke all on function public.ward_archive_rerun_reset(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.ward_archive_state(text) to service_role;
grant execute on function public.ward_archive_rerun_claim(text, integer) to service_role;
grant execute on function public.ward_archive_rerun_reset(uuid, jsonb) to service_role;
