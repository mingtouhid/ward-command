-- R1.7 rollback. PREPARED, NOT APPLIED.
-- Drops the R1.7 objects and restores ward_intern_read_state to the R1.3.143 body
-- (scales, no intern_tasks). Does not touch patient, MSE, report, or ECT plan rows.

drop trigger if exists intern_assignment_on_report on public.lab_reports;
drop function if exists public.intern_assignment_on_report();
drop function if exists public.ward_close_observation_with_review(uuid, text, text, text, text, text, text, jsonb, jsonb);
drop function if exists public.ward_discharge_with_review(uuid, jsonb, text, text[], jsonb, text, jsonb, text, text, integer, text[], text, jsonb, jsonb);
drop function if exists public.ward_list_r17_status(uuid);
drop function if exists public.ward_undo_scheduled_ect(uuid, text);
drop function if exists public.ward_complete_scheduled_ect(uuid, text, timestamptz);
drop function if exists public.ward_link_intern_report_task(uuid, text);
drop function if exists public.ward_undo_intern_task(uuid, text);
drop function if exists public.ward_complete_intern_task(uuid, text);
drop function if exists public.ward_assign_intern_task(uuid, jsonb);
drop function if exists public.r17_write_review_override(text, text, text, text, text, text);
drop function if exists public.r17_actor(uuid);
drop function if exists public.r17_task_json(public.intern_assignments);
drop table if exists public.discharge_review_overrides;
drop table if exists public.ect_schedule_completions;
drop table if exists public.intern_assignments;

CREATE OR REPLACE FUNCTION public.ward_intern_read_state(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare a record; v_me jsonb; v_patients jsonb; v_beds jsonb; v_vitals jsonb; v_scales jsonb;
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
  return jsonb_build_object('ok', true, 'role', 'intern', 'me', v_me, 'patients', v_patients, 'beds', v_beds, 'vitals', v_vitals, 'scales', v_scales, 'server_time', now());
end;
$function$;
