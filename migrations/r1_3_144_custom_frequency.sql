-- R1.3.144 r1_3_144_custom_frequency  (PREPARED, NOT APPLIED)
-- Custom medication frequency (taper / titration text, up to 200 characters + SOS/PRN/STAT add-ons).
-- medication_orders.frequency is plain text with no check constraint, enum or length limit: no change there.
-- Discharge medicines (patients.discharge_meds jsonb) are cleaned by three RPCs that cut 'frequency' to 40 characters;
-- this raises that cut to 240 in ward_discharge_patient, ward_edit_discharge and ward_close_observation.
-- Nothing else in the function bodies changes. CREATE OR REPLACE keeps owner and grants.
-- Safe to re-run. No UPDATE/DELETE. No BEGIN/COMMIT (the migration runner wraps it).

-- ward_close_observation: frequency cut 40 -> 240
CREATE OR REPLACE FUNCTION public.ward_close_observation(p_token uuid, p_patient_id text, p_outcome text, p_referral_to text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_discharge_mode text DEFAULT NULL::text, p_discharge_outcome text DEFAULT NULL::text, p_discharge_meds jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_res text; v_role text; v_status text; v_stay text; v_mode text; v_dout text;
  v_meds jsonb := '[]'::jsonb;
begin
  select ws.resident_id, lower(coalesce(r.role,'')) into v_res, v_role
  from ward_sessions ws join residents r on r.id=ws.resident_id and r.active=true
  where ws.token=p_token and ws.expires_at>now() limit 1;
  if v_res is null then raise exception 'Invalid or expired ward session'; end if;
  if v_role in ('consultant','viewer') then raise exception 'This account is view-only'; end if;
  p_patient_id := nullif(trim(p_patient_id),'');
  p_outcome := lower(nullif(trim(p_outcome),''));
  if p_patient_id is null then raise exception 'Patient is required'; end if;
  if p_outcome not in ('referred','disposed') then raise exception 'Outcome must be referred or disposed'; end if;
  if p_outcome='referred' and nullif(trim(coalesce(p_referral_to,'')),'') is null then
    raise exception 'Department name is required to refer';
  end if;

  if p_outcome='disposed' then
    v_mode := lower(nullif(trim(coalesce(p_discharge_mode,'')),''));
    v_dout := lower(nullif(trim(coalesce(p_discharge_outcome,'')),''));
    if v_mode is null or v_mode not in ('advice','request','lama') then
      raise exception 'Mode of discharge is required';
    end if;
    if v_dout is null or v_dout not in ('improved','unchanged') then
      raise exception 'Outcome is required';
    end if;
  end if;

  -- R1.3.116: optional medication list (sanitised; never creates medication_orders)
  if p_discharge_meds is not null and jsonb_typeof(p_discharge_meds) <> 'null' then
    if jsonb_typeof(p_discharge_meds) <> 'array' then raise exception 'Medications must be a list'; end if;
    if jsonb_array_length(p_discharge_meds) > 40 then raise exception 'Too many medications (max 40)'; end if;
    select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
             'name', left(trim(m->>'name'),160),
             'dose', nullif(left(trim(coalesce(m->>'dose','')),60),''),
             'route', nullif(left(trim(coalesce(m->>'route','')),30),''),
             'frequency', nullif(left(trim(coalesce(m->>'frequency','')),240),''),
             'source', case when m->>'source'='ongoing' then 'ongoing' else 'new' end,
             'order_id', nullif(left(trim(coalesce(m->>'order_id','')),80),''),
             'modified', case when (m->>'modified')='true' then true else null end
           )) order by ord), '[]'::jsonb)
      into v_meds
      from jsonb_array_elements(p_discharge_meds) with ordinality as t(m, ord)
     where jsonb_typeof(m)='object' and nullif(trim(coalesce(m->>'name','')),'') is not null;
  end if;

  select active_status into v_status from patients where id=p_patient_id for update;
  if v_status is null then raise exception 'Patient not found'; end if;
  if v_status <> 'observation' then raise exception 'Patient is not under observation'; end if;
  select id into v_stay from observation_stays where patient_id=p_patient_id and ended_at is null for update;
  if v_stay is null then raise exception 'No open observation stay'; end if;

  update patient_bed_assignments set released_at=now() where patient_id=p_patient_id and released_at is null;
  update beds set current_patient_id=null, updated_at=now() where current_patient_id=p_patient_id;

  if p_outcome='referred' then
    v_mode := 'transfer';
    v_dout := 'unchanged';
  end if;

  update patients set active_status='discharged', discharged_at=now(), discharge_mode=v_mode,
    discharge_outcome=v_dout, updated_by=v_res, updated_at=now() where id=p_patient_id;

  update observation_stays set
    ended_at=now(), ended_by=v_res, outcome=p_outcome,
    referral_to=nullif(trim(coalesce(p_referral_to,'')),''),
    note=coalesce(nullif(trim(coalesce(p_reason,'')),''), note),
    discharge_meds=v_meds,
    updated_at=now()
  where id=v_stay;

  insert into activity_log(id,patient_id,kind,title,detail,actor_id,created_at)
  values ('ev-'||substr(md5(v_stay||p_outcome||now()::text),1,14), p_patient_id, 'note',
          'Observation ended · '||p_outcome,
          trim(coalesce(p_referral_to,'')||case when nullif(trim(coalesce(p_reason,'')),'') is null then '' else ' · '||trim(p_reason) end),
          v_res, now());

  return jsonb_build_object(
    'ok', true,
    'patient_id', p_patient_id,
    'stay_id', v_stay,
    'outcome', p_outcome,
    'referral_to', p_referral_to,
    'reason', p_reason,
    'discharge_mode', v_mode,
    'discharge_outcome', v_dout,
    'discharge_meds', v_meds
  );
end
$function$;

-- ward_discharge_patient: frequency cut 40 -> 240
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
             'frequency', nullif(left(trim(coalesce(m->>'frequency','')),240),''),
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

-- ward_edit_discharge: frequency cut 40 -> 240
CREATE OR REPLACE FUNCTION public.ward_edit_discharge(p_token uuid, p_patient_id text, p_changes jsonb, p_reason text, p_expected_updated_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_edit_id text DEFAULT NULL::text, p_restored_from text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_res text; v_name text;
  v_old public.patients%rowtype; v_after public.patients%rowtype;
  v_reason text := left(trim(coalesce(p_reason,'')),500);
  v_allowed text[] := array['name','age','sex','hospital_no','mrd_no','admitted_at','diagnosis','secondary_dx','tertiary_dx','comorbidities',
    'discharged_at','discharge_mode','discharge_outcome','treatment_mode','discharge_ect_sessions','discharge_meds',
    'discharge_advice','discharge_review','discharge_requested_by','discharge_requester_name','cert_edits'];
  v_ident text[] := array['name','age','sex','hospital_no','mrd_no','admitted_at','diagnosis','secondary_dx','tertiary_dx','comorbidities'];
  v_lbl jsonb := '{"name":"Name","age":"Age","sex":"Sex","hospital_no":"Hospital No.","mrd_no":"M.R.D. No.","admitted_at":"Date of admission",
    "diagnosis":"Primary diagnosis","secondary_dx":"Secondary diagnosis","tertiary_dx":"Tertiary diagnosis","comorbidities":"Comorbidities",
    "discharged_at":"Date & time of discharge","discharge_mode":"Mode of discharge","discharge_outcome":"Condition at discharge",
    "treatment_mode":"Mode of treatment","discharge_ect_sessions":"ECT sessions","discharge_meds":"Medications on discharge",
    "discharge_advice":"Instructions to the patient","discharge_review":"Review after","discharge_requested_by":"Requested by",
    "discharge_requester_name":"Requester name","cert_edits":"Certificate wording / MSE / investigations"}'::jsonb;
  k text; v jsonb; v_c jsonb; v_prior jsonb; v_new jsonb; v_post jsonb;
  v_name_n text; v_age int; v_sex text; v_hosp text; v_mrd text; v_adm timestamptz; v_dis timestamptz;
  v_mode text; v_out text; v_treat text; v_ect int; v_meds jsonb; v_req text[]; v_reqn text; v_cert jsonb; v_other text;
  v_changed text[] := array[]::text[]; v_lines text[] := array[]::text[];
  v_eid text := coalesce(nullif(left(trim(coalesce(p_edit_id,'')),80),''), 'de-'||replace(gen_random_uuid()::text,'-',''));
  v_ver int; v_crow public.discharge_certificates%rowtype; v_has_cert boolean := false; v_evt jsonb; v_at timestamptz := now();
begin
  v_res := public.ward_ensure_session_writer(p_token);
  select display_name into v_name from public.residents where id=v_res;
  if length(v_reason) < 3 then raise exception 'A reason for the change is required'; end if;
  if p_changes is null or jsonb_typeof(p_changes)<>'object' then raise exception 'No changes supplied'; end if;
  for k in select jsonb_object_keys(p_changes) loop
    if not (k = any(v_allowed)) then raise exception 'Field % cannot be edited here', k; end if;
  end loop;
  if exists(select 1 from public.discharge_edit_versions where id=v_eid) then
    return jsonb_build_object('ok',true,'idempotent',true,'edit_id',v_eid);
  end if;

  select * into v_old from public.patients where id=p_patient_id for update;
  if not found then raise exception 'Patient not found'; end if;
  if coalesce(v_old.active_status,'')<>'discharged' or v_old.discharged_at is null then raise exception 'Patient is not discharged'; end if;
  if p_expected_updated_at is not null and v_old.updated_at is not null
     and abs(extract(epoch from (v_old.updated_at - p_expected_updated_at))) > 1 then
    raise exception 'CONFLICT: the discharge was changed by someone else';
  end if;

  v_prior := public.ward_dedit_snapshot(p_patient_id);
  v_c := p_changes;

  v_name_n := case when v_c ? 'name' then nullif(left(trim(coalesce(v_c->>'name','')),200),'') else v_old.name end;
  if v_name_n is null then raise exception 'Name is required'; end if;
  if v_c ? 'age' then
    if nullif(trim(coalesce(v_c->>'age','')),'') is null then v_age := null;
    elsif (v_c->>'age') !~ '^\s*\d{1,3}\s*$' or (v_c->>'age')::int > 120 then raise exception 'Age must be a number from 0 to 120';
    else v_age := (v_c->>'age')::int; end if;
  else v_age := v_old.age; end if;
  v_sex := case when v_c ? 'sex' then v_c->>'sex' else v_old.sex end;
  if coalesce(v_sex,'') not in ('M','F','O') then raise exception 'Sex must be M, F or O'; end if;
  v_hosp := case when v_c ? 'hospital_no' then nullif(left(trim(coalesce(v_c->>'hospital_no','')),60),'') else v_old.hospital_no end;
  if v_c ? 'hospital_no' and v_hosp is null then raise exception 'Hospital number is required'; end if;
  v_mrd := case when v_c ? 'mrd_no' then nullif(left(trim(coalesce(v_c->>'mrd_no','')),60),'') else v_old.mrd_no end;
  if v_c ? 'mrd_no' and v_mrd is not null then
    select name into v_other from public.patients where id<>p_patient_id and mrd_no is not null and lower(trim(mrd_no))=lower(v_mrd) limit 1;
    if found then raise exception 'MRD No. already belongs to %', coalesce(v_other,'another patient'); end if;
  end if;
  v_adm := case when v_c ? 'admitted_at' then nullif(v_c->>'admitted_at','')::timestamptz else v_old.admitted_at end;
  if v_c ? 'admitted_at' and v_adm is null then raise exception 'Date of admission is required'; end if;
  v_dis := case when v_c ? 'discharged_at' then nullif(v_c->>'discharged_at','')::timestamptz else v_old.discharged_at end;
  if v_dis is null then raise exception 'Date of discharge is required'; end if;
  if v_dis > now() + interval '6 hours' then raise exception 'Discharge date is in the future'; end if;
  if v_adm is not null and v_dis < v_adm then raise exception 'Discharge date cannot precede admission'; end if;
  if v_adm is not null and v_adm > now() + interval '10 minutes' then raise exception 'Date of admission cannot be in the future'; end if;

  v_mode := case when v_c ? 'discharge_mode' then v_c->>'discharge_mode' else v_old.discharge_mode end;
  if coalesce(v_mode,'') not in ('advice','request','dama','lama','abscond','transfer','death') then raise exception 'Unknown mode of discharge'; end if;
  v_out := case when v_c ? 'discharge_outcome' then v_c->>'discharge_outcome' else v_old.discharge_outcome end;
  if v_mode='death' then v_out := 'death'; end if;
  if coalesce(v_out,'') not in ('improved','partial','unchanged','worse','death') then raise exception 'Unknown condition at discharge'; end if;
  if v_out='death' and v_mode<>'death' then raise exception 'Condition "Death" needs mode "Death"'; end if;
  v_treat := case when v_c ? 'treatment_mode' then nullif(v_c->>'treatment_mode','') else v_old.treatment_mode end;
  if v_treat is not null and v_treat not in ('conservative','ect','conservative_ect') then raise exception 'Unknown mode of treatment'; end if;
  if v_c ? 'discharge_ect_sessions' then
    if nullif(trim(coalesce(v_c->>'discharge_ect_sessions','')),'') is null then v_ect := null;
    elsif (v_c->>'discharge_ect_sessions') !~ '^\s*\d{1,2}\s*$' then raise exception 'ECT sessions must be between 0 and 99';
    else v_ect := (v_c->>'discharge_ect_sessions')::int; end if;
  else v_ect := v_old.discharge_ect_sessions; end if;
  if coalesce(v_treat,'') not ilike '%ect%' then v_ect := null; end if;

  if v_c ? 'discharge_meds' then
    v := v_c->'discharge_meds';
    if v is null or jsonb_typeof(v)='null' then v_meds := '[]'::jsonb;
    else
      if jsonb_typeof(v)<>'array' then raise exception 'Medications must be a list'; end if;
      if jsonb_array_length(v) > 40 then raise exception 'Too many medications (max 40)'; end if;
      select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
               'name', left(trim(m->>'name'),160),
               'dose', nullif(left(trim(coalesce(m->>'dose','')),60),''),
               'route', nullif(left(trim(coalesce(m->>'route','')),30),''),
               'frequency', nullif(left(trim(coalesce(m->>'frequency','')),240),''),
               'instructions', nullif(left(trim(coalesce(m->>'instructions','')),200),''),
               'source', case when m->>'source'='ongoing' then 'ongoing' else 'new' end,
               'order_id', nullif(left(trim(coalesce(m->>'order_id','')),80),''),
               'modified', case when (m->>'modified')='true' then true else null end)) order by ord), '[]'::jsonb)
        into v_meds from jsonb_array_elements(v) with ordinality t(m,ord)
       where jsonb_typeof(m)='object' and nullif(trim(coalesce(m->>'name','')),'') is not null;
    end if;
  else v_meds := coalesce(v_old.discharge_meds,'[]'::jsonb); end if;

  if v_c ? 'discharge_requested_by' then
    v := v_c->'discharge_requested_by';
    if v is null or jsonb_typeof(v)='null' then v_req := null;
    elsif jsonb_typeof(v)<>'array' then raise exception 'Requested by must be a list';
    else
      select coalesce(array_agg(x order by array_position(array['self','father','mother','spouse','sibling','other']::text[], x)),'{}'::text[])
        into v_req from (select distinct lower(trim(u)) x from jsonb_array_elements_text(v) u where nullif(trim(u),'') is not null) q;
      if not (v_req <@ array['self','father','mother','spouse','sibling','other']::text[]) then raise exception 'Unknown requester'; end if;
      if cardinality(v_req)=0 then v_req := null; end if;
    end if;
  else v_req := v_old.discharge_requested_by; end if;
  v_reqn := case when v_c ? 'discharge_requester_name' then nullif(left(trim(coalesce(v_c->>'discharge_requester_name','')),120),'') else v_old.discharge_requester_name end;
  if v_mode not in ('request','dama') then v_req := null; v_reqn := null; end if;
  if v_mode='dama' and v_req is not null and 'self'=any(v_req) then raise exception 'Patient himself/herself is only for On request'; end if;

  v_cert := v_prior->'cert_edits';
  if v_c ? 'cert_edits' then
    v_cert := coalesce(v_c->'cert_edits','{}'::jsonb);
    if jsonb_typeof(v_cert)='null' then v_cert := '{}'::jsonb; end if;
    if jsonb_typeof(v_cert)<>'object' or pg_column_size(v_cert) >= 32768 then raise exception 'Certificate edits are invalid or too large'; end if;
    for k in select jsonb_object_keys(v_cert) loop
      if k in ('dept','admitted','disease','remarks','advice','review') and jsonb_typeof(v_cert->k)<>'string' then raise exception 'Certificate text % is invalid', k; end if;
      if k='mse' and jsonb_typeof(v_cert->k)<>'string' then raise exception 'MSE choice is invalid'; end if;
      if k='labs_hide' and (jsonb_typeof(v_cert->k)<>'array' or jsonb_array_length(v_cert->k)>200) then raise exception 'Investigation choice is invalid'; end if;
    end loop;
  end if;

  v_new := jsonb_build_object(
    'name',v_name_n,'age',v_age,'sex',v_sex,'hospital_no',v_hosp,'mrd_no',v_mrd,'admitted_at',v_adm,
    'diagnosis',case when v_c ? 'diagnosis' then coalesce(left(trim(coalesce(v_c->>'diagnosis','')),500),'') else v_old.diagnosis end,
    'secondary_dx',case when v_c ? 'secondary_dx' then nullif(left(trim(coalesce(v_c->>'secondary_dx','')),500),'') else v_old.secondary_dx end,
    'tertiary_dx',case when v_c ? 'tertiary_dx' then nullif(left(trim(coalesce(v_c->>'tertiary_dx','')),500),'') else v_old.tertiary_dx end,
    'comorbidities',case when v_c ? 'comorbidities' then nullif(left(trim(coalesce(v_c->>'comorbidities','')),500),'') else v_old.comorbidities end,
    'discharged_at',v_dis,'discharge_mode',v_mode,'discharge_outcome',v_out,'treatment_mode',v_treat,'discharge_ect_sessions',v_ect,
    'discharge_meds',v_meds,
    'discharge_advice',case when v_c ? 'discharge_advice' then nullif(left(trim(coalesce(v_c->>'discharge_advice','')),4000),'') else v_old.discharge_advice end,
    'discharge_review',case when v_c ? 'discharge_review' then nullif(left(trim(coalesce(v_c->>'discharge_review','')),200),'') else v_old.discharge_review end,
    'discharge_requested_by',to_jsonb(v_req),'discharge_requester_name',v_reqn,'cert_edits',v_cert);

  -- normalise timestamps the same way for comparison
  foreach k in array v_allowed loop
    if k in ('admitted_at','discharged_at') then
      if (v_prior->>k)::timestamptz is distinct from (v_new->>k)::timestamptz then v_changed := v_changed||k; end if;
    elsif coalesce(v_prior->k,'null'::jsonb) is distinct from coalesce(v_new->k,'null'::jsonb) then
      v_changed := v_changed||k;
    end if;
  end loop;
  if array_length(v_changed,1) is null then
    return jsonb_build_object('ok',true,'nochange',true);
  end if;

  begin
    update public.patients set
      name=v_name_n, age=v_age, sex=v_sex, hospital_no=v_hosp, mrd_no=v_mrd, admitted_at=v_adm,
      diagnosis=v_new->>'diagnosis', secondary_dx=v_new->>'secondary_dx', tertiary_dx=v_new->>'tertiary_dx', comorbidities=v_new->>'comorbidities',
      discharged_at=v_dis, discharge_mode=v_mode, discharge_outcome=v_out, treatment_mode=v_treat, discharge_ect_sessions=v_ect,
      discharge_meds=v_meds, discharge_advice=v_new->>'discharge_advice', discharge_review=v_new->>'discharge_review',
      discharge_requested_by=v_req, discharge_requester_name=v_reqn,
      updated_by=v_res, updated_at=now()
    where id=p_patient_id;
  exception when unique_violation then
    if sqlerrm ilike '%mrd%' then raise exception 'MRD No. already on file'; end if;
    raise exception 'Hospital number already on file';
  end;

  -- certificate row follows the episode (keeps its version history); version/hash untouched so the next print is a new version
  select * into v_crow from public.discharge_certificates where patient_id=p_patient_id and discharged_at=v_old.discharged_at for update;
  v_has_cert := found;
  if v_has_cert then
    update public.discharge_certificates set discharged_at=v_dis, discharge_mode=v_mode, edits=v_cert,
      updated_by=v_res, updated_by_name=v_name, updated_at=now()
    where id=v_crow.id returning * into v_crow;
  elsif v_cert <> '{}'::jsonb and v_mode not in ('lama','transfer') then
    insert into public.discharge_certificates(id, patient_id, discharged_at, discharge_mode, edits, updated_by, updated_by_name)
    values ('dc-'||p_patient_id||'-'||(extract(epoch from v_dis)*1000)::bigint::text, p_patient_id, v_dis, v_mode, v_cert, v_res, v_name)
    on conflict (patient_id, discharged_at) do update set edits=excluded.edits, updated_by=excluded.updated_by, updated_by_name=excluded.updated_by_name, updated_at=now()
    returning * into v_crow;
    v_has_cert := true;
  end if;

  v_post := public.ward_dedit_snapshot(p_patient_id);
  foreach k in array v_changed loop
    v_lines := v_lines || ((v_lbl->>k)||': '||public.ward_dedit_txt(k, v_prior->k)||' → '||public.ward_dedit_txt(k, v_post->k));
    if k = any(v_ident) then
      insert into public.patient_edits(patient_id, field, old_value, new_value, edited_by, edit_group)
      values (p_patient_id, k, v_prior->>k, v_post->>k, v_res, v_eid);
    end if;
  end loop;

  select coalesce(max(version_no),0)+1 into v_ver from public.discharge_edit_versions where patient_id=p_patient_id;
  insert into public.discharge_edit_versions(id, patient_id, version_no, discharged_at, prior, after, changed, reason, restored_from, edited_by, edited_by_name, edited_at)
  values (v_eid, p_patient_id, v_ver, v_dis, v_prior, v_post, v_changed, v_reason, nullif(left(trim(coalesce(p_restored_from,'')),80),''), v_res, v_name, v_at);

  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('dedit-'||v_eid, p_patient_id, 'note',
          case when p_restored_from is not null then 'Discharge record restored' else 'Discharge record edited' end||' · edit '||v_ver,
          'Reason: '||v_reason||E'\n'||array_to_string(v_lines, E'\n'), v_res, v_at)
  on conflict (id) do nothing;

  select * into v_after from public.patients where id=p_patient_id;
  v_evt := jsonb_build_object('id','dedit-'||v_eid,'title',case when p_restored_from is not null then 'Discharge record restored' else 'Discharge record edited' end||' · edit '||v_ver,
    'detail','Reason: '||v_reason||E'\n'||array_to_string(v_lines, E'\n'),'created_at',v_at,'actor_id',v_res);
  return jsonb_build_object('ok',true,'edit_id',v_eid,'version_no',v_ver,'changed',to_jsonb(v_changed),
    'patient',to_jsonb(v_after),'certificate',case when v_has_cert then to_jsonb(v_crow) else null end,'event',v_evt);
end $function$;
