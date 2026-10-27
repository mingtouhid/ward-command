-- R1.3.133 — Discharge medications: keep the per-medicine "instructions" text (taper / duration).
-- Applied to ward-flow on 27 Oct 2026, 13:51 IST (migration version 20261027082145), before the R1.3.133 client push.
--
-- What changes: ward_discharge_patient() whitelists each p_discharge_meds item. Until now only
-- name / dose / route / frequency / source / order_id / modified were kept, so the new optional
-- "instructions" key (e.g. "2 tabs HS x 5 days, then 1 tab HS x 5 days") would be silently dropped.
-- This adds one line to that whitelist (trimmed, max 200 chars, omitted when empty).
-- Nothing else in the function body is changed (body copied from the live definition read on 27 Oct 2026).
-- Signature, defaults, security and grants are unchanged (CREATE OR REPLACE keeps existing grants).
-- No table/column change: patients.discharge_meds is already jsonb.
-- Rollback: re-run the previous definition (identical minus the 'instructions' line).

CREATE OR REPLACE FUNCTION public.ward_discharge_patient(p_token uuid, p_patient jsonb, p_bed_id text DEFAULT NULL::text, p_assignment_ids text[] DEFAULT '{}'::text[], p_ect_plan jsonb DEFAULT NULL::jsonb, p_discharge_advice text DEFAULT NULL::text, p_discharge_meds jsonb DEFAULT NULL::jsonb, p_mrd_no text DEFAULT NULL::text, p_discharge_review text DEFAULT NULL::text, p_discharge_ect_sessions integer DEFAULT NULL::integer, p_discharge_requested_by text[] DEFAULT NULL::text[], p_discharge_requester_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_resident_id text;
  v_role text;
  v_patient_id text;
  v_when timestamptz;
  v_existing_status text;
  v_existing_discharged_at timestamptz;
  v_existing_notification uuid;
  v_bed_patient text;
  v_bed_number text;
  v_patient_name text;
  v_old_diagnosis text;
  v_new_diagnosis text;
  v_edit_group text;
  v_notification_id uuid;
  v_dedupe text;
  v_mode text;
  v_outcome text;
  v_treatment text;
  v_mrd_old text;
  v_mrd_new text;
  v_advice text;
  v_review text;
  v_ect int;
  v_meds jsonb := '[]'::jsonb;
  v_req text[];
  v_req_name text;
begin

  select ws.resident_id,r.role
  into v_resident_id,v_role
  from ward_sessions ws
  join residents r on r.id=ws.resident_id
  where ws.token=p_token
    and ws.expires_at>now()
    and r.active=true
  for update of r;

  if v_resident_id is null then
    raise exception 'Invalid or expired ward session';
  end if;

  if lower(coalesce(v_role,'')) in ('consultant','viewer') then
    raise exception 'This role cannot perform clinical writes';
  end if;

  v_patient_id:=nullif(trim(p_patient->>'id'),'');

  if v_patient_id is null then
    raise exception 'Patient is required';
  end if;

  v_when:=coalesce(
    (p_patient->>'dischargedAt')::timestamptz,
    now()
  );

  v_mode:=coalesce(
    nullif(p_patient->>'dischargeMode',''),
    'advice'
  );

  v_outcome:=coalesce(
    nullif(p_patient->>'dischargeOutcome',''),
    'improved'
  );

  v_treatment:=nullif(
    p_patient->>'treatmentMode',
    ''
  );


  -- R1.3.120: optional advice + medications on discharge (sanitised like R1.3.116; never creates medication_orders)
  v_advice:=nullif(left(trim(coalesce(p_discharge_advice,'')),4000),'');
  v_review:=nullif(left(trim(coalesce(p_discharge_review,'')),200),'');
  if p_discharge_meds is not null and jsonb_typeof(p_discharge_meds) <> 'null' then
    if jsonb_typeof(p_discharge_meds) <> 'array' then raise exception 'Medications must be a list'; end if;
    if jsonb_array_length(p_discharge_meds) > 40 then raise exception 'Too many medications (max 40)'; end if;
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'name', left(trim(m->>'name'),160),
             'dose', nullif(left(trim(coalesce(m->>'dose','')),60),''),
             'route', nullif(left(trim(coalesce(m->>'route','')),30),''),
             'frequency', nullif(left(trim(coalesce(m->>'frequency','')),40),''),
             'instructions', nullif(left(trim(coalesce(m->>'instructions','')),200),''), -- R1.3.133: taper / duration text
             'source', case when m->>'source'='ongoing' then 'ongoing' else 'new' end,
             'order_id', nullif(left(trim(coalesce(m->>'order_id','')),80),''),
             'modified', case when (m->>'modified')='true' then true else null end
           )) order by ord), '[]'::jsonb)
      into v_meds
      from jsonb_array_elements(p_discharge_meds) with ordinality as t(m, ord)
     where jsonb_typeof(m)='object' and nullif(trim(coalesce(m->>'name','')),'') is not null;
  end if;
  v_mrd_new:=nullif(left(trim(coalesce(p_mrd_no,'')),60),'');
  -- R1.3.126: who requested the discharge (On request / DAMA only). Optional on the server so
  -- older clients keep working; the R1.3.126 client requires at least one for DAMA.
  if v_mode in ('request','dama') then
    if p_discharge_requested_by is not null then
      select coalesce(array_agg(x order by array_position(array['self','father','mother','spouse','sibling','other']::text[], x)), '{}'::text[])
        into v_req
        from (select distinct lower(trim(u)) as x from unnest(p_discharge_requested_by) u where nullif(trim(u),'') is not null) q;
      if not (v_req <@ array['self','father','mother','spouse','sibling','other']::text[]) then
        raise exception 'Unknown requester';
      end if;
      if v_mode='dama' and 'self'=any(v_req) then
        raise exception 'Patient himself/herself is only for On request';
      end if;
      if cardinality(v_req)=0 then v_req:=null; end if;
    end if;
    v_req_name:=nullif(left(trim(coalesce(p_discharge_requester_name,'')),120),'');
  end if;
  -- R1.3.122: ECT sessions given this admission (only kept when ECT is part of the treatment)
  if p_discharge_ect_sessions is not null then
    if p_discharge_ect_sessions < 0 or p_discharge_ect_sessions > 99 then
      raise exception 'ECT sessions must be between 0 and 99';
    end if;
    if coalesce(v_treatment,'') ilike '%ect%' then
      v_ect:=p_discharge_ect_sessions;
    end if;
  end if;


  -- --------------------------------------------------------------------------
  -- LOCK PATIENT
  -- --------------------------------------------------------------------------

  select active_status,
         discharged_at,
         name,
         diagnosis,
         mrd_no
  into v_existing_status,
       v_existing_discharged_at,
       v_patient_name,
       v_old_diagnosis,
       v_mrd_old
  from patients
  where id=v_patient_id
  for update;

  if not found then
    raise exception 'Patient not found';
  end if;


  -- --------------------------------------------------------------------------
  -- IDEMPOTENT DISCHARGE RETRY
  -- --------------------------------------------------------------------------

  if v_existing_status='discharged' then

    if v_existing_discharged_at is not null
       and v_existing_discharged_at=v_when then

      v_dedupe:=
        'discharge:'||
        v_patient_id||
        ':'||
        v_when::text;

      select id
      into v_existing_notification
      from notification_events
      where dedupe_key=v_dedupe
      limit 1;

      return jsonb_build_object(
        'ok',true,
        'workflow','discharge',
        'patient_id',v_patient_id,
        'bed_id',p_bed_id,
        'notification_id',v_existing_notification,
        'idempotent',true
      );

    end if;

    raise exception 'Patient is already discharged';

  end if;

  -- R1.3.120: MRD No. is mandatory at discharge. Fill it here when missing (same uniqueness rules as R1.3.119).
  v_mrd_old:=nullif(trim(coalesce(v_mrd_old,'')),'');
  if v_mrd_old is null then
    if v_mrd_new is null then
      raise exception 'MRD No. is required to discharge';
    end if;
    perform public.ward_apply_patient_dx_extra(v_patient_id, jsonb_build_object('mrd_no',v_mrd_new));
    insert into public.patient_edits(patient_id, field, old_value, new_value, edited_by, edit_group)
    values(v_patient_id, 'mrd_no', null, v_mrd_new, v_resident_id,
           'dis-mrd-'||v_patient_id||'-'||extract(epoch from v_when)::bigint::text);
    insert into public.activity_log(id, patient_id, kind, title, detail, actor_id)
    values('pt-edit-dis-mrd-'||v_patient_id||'-'||extract(epoch from v_when)::bigint::text, v_patient_id, 'note',
           'Patient details edited', 'MRD No.: — → '||v_mrd_new, v_resident_id)
    on conflict (id) do nothing;
    v_mrd_old:=v_mrd_new;
  end if;

  v_new_diagnosis:=coalesce(
    nullif(trim(coalesce(p_patient->>'diagnosis','')),''),
    v_old_diagnosis
  );


  -- --------------------------------------------------------------------------
  -- LOCK / LOCATE BED
  -- --------------------------------------------------------------------------

  if p_bed_id is not null then

    select current_patient_id,bed_number
    into v_bed_patient,v_bed_number
    from beds
    where id=p_bed_id
    for update;

    if not found then
      raise exception 'Bed not found';
    end if;

    if v_bed_patient is not null
       and v_bed_patient<>v_patient_id then
      raise exception 'Selected bed does not contain this patient';
    end if;

  else

    select b.current_patient_id,
           b.bed_number,
           b.id
    into v_bed_patient,
         v_bed_number,
         p_bed_id
    from beds b
    where b.current_patient_id=v_patient_id
    order by b.id
    limit 1
    for update;

  end if;


  -- --------------------------------------------------------------------------
  -- UPDATE PATIENT
  -- --------------------------------------------------------------------------

  update patients
  set discharged_at=v_when,
      discharge_mode=v_mode,
      discharge_outcome=v_outcome,
      treatment_mode=v_treatment,
      discharge_advice=v_advice,
      discharge_review=v_review,
      discharge_ect_sessions=v_ect,
      discharge_meds=v_meds,
      discharge_requested_by=v_req,
      discharge_requester_name=v_req_name,
      diagnosis=coalesce(v_new_diagnosis, diagnosis),
      active_status='discharged',
      updated_at=now(),
      updated_by=v_resident_id
  where id=v_patient_id;


  -- --------------------------------------------------------------------------
  -- RECORD DIAGNOSIS AUDIT ENTRY WHEN UPDATED AT DISCHARGE
  -- --------------------------------------------------------------------------

  if coalesce(trim(v_new_diagnosis),'') is distinct from coalesce(trim(v_old_diagnosis),'')
     and nullif(trim(coalesce(v_new_diagnosis,'')),'') is not null then

    v_edit_group:='dis-dx-'||v_patient_id||'-'||extract(epoch from v_when)::bigint::text;

    insert into public.patient_edits(
      patient_id,
      field,
      old_value,
      new_value,
      edited_by,
      edit_group
    )
    values(
      v_patient_id,
      'diagnosis',
      v_old_diagnosis,
      v_new_diagnosis,
      v_resident_id,
      v_edit_group
    );

    insert into public.activity_log(
      id,
      patient_id,
      kind,
      title,
      detail,
      actor_id
    )
    values(
      'pt-edit-'||v_edit_group,
      v_patient_id,
      'note',
      'Patient details edited',
      'Diagnosis: '||coalesce(nullif(v_old_diagnosis,''),'—')||' → '||v_new_diagnosis,
      v_resident_id
    )
    on conflict (id) do nothing;

  end if;


  -- --------------------------------------------------------------------------
  -- RELEASE ACTIVE ASSIGNMENTS
  -- --------------------------------------------------------------------------

  update patient_bed_assignments
  set released_at=coalesce(released_at,v_when)
  where patient_id=v_patient_id
    and released_at is null;


  -- --------------------------------------------------------------------------
  -- RELEASE BED
  -- --------------------------------------------------------------------------

  if p_bed_id is not null then

    update beds
    set current_patient_id=null,
        updated_at=now()
    where id=p_bed_id
      and current_patient_id=v_patient_id;

  end if;


  -- --------------------------------------------------------------------------
  -- CANCEL ECT PLAN WHEN APPROPRIATE
  -- --------------------------------------------------------------------------

  if p_ect_plan is not null
     and v_mode<>'death' then

    update ect_plans
    set status='cancelled',
        updated_at=now()
    where id=p_ect_plan->>'id'
      and patient_id=v_patient_id;

  end if;


  -- --------------------------------------------------------------------------
  -- TRANSACTIONAL DISCHARGE NOTIFICATION
  -- --------------------------------------------------------------------------

  v_dedupe:=
    'discharge:'||
    v_patient_id||
    ':'||
    v_when::text;


  insert into notification_events(
    event_type,
    category,
    priority,
    patient_id,
    actor_id,
    title,
    body,
    target_url,
    recipient_scope,
    dedupe_key,
    metadata
  )
  values(
    'discharge',
    'clinical',
    'normal',
    v_patient_id,
    v_resident_id,
    'Patient discharged',

    coalesce(v_patient_name,'Patient')||
      ' discharged · '||
      v_mode,

    './#/snap/'||v_patient_id,

    'active_team',

    v_dedupe,

    jsonb_build_object(
      'bed_number',v_bed_number,
      'discharge_mode',v_mode,
      'discharge_outcome',v_outcome,
      'treatment_mode',v_treatment,
      'diagnosis',v_new_diagnosis,
      'requested_by',to_jsonb(v_req)
    )
  )
  on conflict(dedupe_key)
  do update set id=notification_events.id
  returning id into v_notification_id;


  return jsonb_build_object(
    'ok',true,
    'workflow','discharge',
    'patient_id',v_patient_id,
    'bed_id',p_bed_id,
    'notification_id',v_notification_id,
    'idempotent',false,
    'mrd_no',v_mrd_old,
    'discharge_advice',v_advice,
    'discharge_review',v_review,
    'discharge_meds',v_meds,
    'discharge_ect_sessions',v_ect,
    'discharge_requested_by',to_jsonb(v_req),
    'discharge_requester_name',v_req_name
  );

end
$function$;
