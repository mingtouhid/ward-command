-- R1.3.126 Discharge certificate
-- Applied to ward-flow as migration r1_3_126_discharge_certificate (26 Oct 2026, 13:26 IST). Idempotent.
-- Note: the backfill fires patients_validate (sets updated_at := now()), so backfilled rows got a new
-- updated_at even with the touch triggers disabled.
-- Apply BEFORE deploying the R1.3.126 client (the client sends p_discharge_requested_by /
-- p_discharge_requester_name only when set, but a missing RPC would push it to the legacy path).
--
-- 1. patients: discharge_requested_by text[], discharge_requester_name text,
--    admit_consultants jsonb (admission-time consultant snapshot, trigger-filled + backfill).
-- 2. discharge_certificates: one row per patient discharge (patient_id + discharged_at, so a
--    readmitted patient - same patient id - gets a fresh certificate). RLS forced, no policies.
-- 3. ward_save_discharge_certificate(p_token, p_row): save edits / record a print (versioned,
--    print count, printed_by/at) and write the timeline entry.
-- 4. ward_discharge_patient: + p_discharge_requested_by text[], p_discharge_requester_name text.
-- 5. ward_upsert_patient (non-atomic fallback), ward_read_ward_state, ward_create_nightly_backup,
--    ward_archive_month: carry the new fields.

-- ---------------------------------------------------------------------------
-- 1. patients columns
-- ---------------------------------------------------------------------------
alter table public.patients add column if not exists discharge_requested_by text[];
alter table public.patients add column if not exists discharge_requester_name text;
alter table public.patients add column if not exists admit_consultants jsonb;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='patients_discharge_requested_by_check' and conrelid='public.patients'::regclass) then
    alter table public.patients add constraint patients_discharge_requested_by_check
      check (discharge_requested_by is null or (discharge_requested_by <@ array['self','father','mother','spouse','sibling','other']::text[] and cardinality(discharge_requested_by) <= 6));
  end if;
  if not exists (select 1 from pg_constraint where conname='patients_discharge_requester_name_len_check' and conrelid='public.patients'::regclass) then
    alter table public.patients add constraint patients_discharge_requester_name_len_check
      check (discharge_requester_name is null or length(discharge_requester_name) <= 120);
  end if;
  if not exists (select 1 from pg_constraint where conname='patients_admit_consultants_check' and conrelid='public.patients'::regclass) then
    alter table public.patients add constraint patients_admit_consultants_check
      check (admit_consultants is null or (jsonb_typeof(admit_consultants)='array' and pg_column_size(admit_consultants) < 4096));
  end if;
end $$;

-- Consultant snapshot: [{slot,id,name,designation}]. Designation from the linked consultant
-- account (residents.designation), else the unit roster (unit_consultants), else the text after
-- the first comma of the stored label "Name, Designation". Blank designation stays "".
CREATE OR REPLACE FUNCTION public.ward_consultant_snapshot(p_name text, p_id text, p_name_2 text, p_id_2 text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_out jsonb := '[]'::jsonb;
  v_i int;
  v_txt text; v_id text; v_nm text; v_des text; v_rn text; v_rd text;
BEGIN
  FOR v_i IN 1..2 LOOP
    v_txt := nullif(trim(coalesce(CASE WHEN v_i=1 THEN p_name ELSE p_name_2 END,'')),'');
    v_id := nullif(trim(coalesce(CASE WHEN v_i=1 THEN p_id ELSE p_id_2 END,'')),'');
    IF v_txt IS NULL AND v_id IS NULL THEN CONTINUE; END IF;
    v_rn := NULL; v_rd := NULL;
    IF v_id IS NOT NULL THEN
      SELECT nullif(trim(display_name),''), nullif(trim(coalesce(designation,'')),'') INTO v_rn, v_rd
        FROM public.residents WHERE id=v_id;
    END IF;
    IF v_txt IS NOT NULL AND position(',' in v_txt) > 0 THEN
      v_nm := nullif(trim(split_part(v_txt, ',', 1)),'');
      v_des := nullif(trim(substr(v_txt, position(',' in v_txt)+1)),'');
    ELSE
      v_nm := v_txt; v_des := NULL;
    END IF;
    IF v_rd IS NULL AND v_des IS NULL AND coalesce(v_nm,v_rn) IS NOT NULL THEN
      SELECT nullif(trim(coalesce(designation,'')),'') INTO v_rd FROM public.unit_consultants
       WHERE lower(trim(name)) = lower(coalesce(v_nm,v_rn)) AND nullif(trim(coalesce(designation,'')),'') IS NOT NULL
       ORDER BY active DESC, sort_order LIMIT 1;
    END IF;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'slot', v_i, 'id', v_id,
      'name', left(coalesce(v_nm, v_rn, ''), 160),
      'designation', left(coalesce(v_rd, v_des, ''), 160)));
  END LOOP;
  RETURN v_out;
END
$function$;
revoke all on function public.ward_consultant_snapshot(text,text,text,text) from public, anon, authenticated;

-- BEFORE trigger, named to run after patients_zz_link_consultant (which fills consultant_id).
-- Filled on admission; refreshed on readmission (discharged -> admitted, same patient id) and
-- when the consultants are changed within 24 h of admission (the admit form saves them in a
-- second statement). Later edits during the stay do NOT change the snapshot.
CREATE OR REPLACE FUNCTION public.patients_admit_consultants()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_refresh boolean := false;
BEGIN
  IF coalesce(NEW.active_status,'') = 'discharged' THEN RETURN NEW; END IF;
  IF TG_OP='INSERT' THEN
    v_refresh := true;
  ELSIF coalesce(OLD.active_status,'') = 'discharged' THEN
    v_refresh := true; -- readmission reuses the patient id
  ELSIF NEW.admit_consultants IS NULL OR NEW.admit_consultants = '[]'::jsonb THEN
    v_refresh := true;
  ELSIF (NEW.consultant_name IS DISTINCT FROM OLD.consultant_name OR NEW.consultant_name_2 IS DISTINCT FROM OLD.consultant_name_2
         OR NEW.consultant_id IS DISTINCT FROM OLD.consultant_id OR NEW.consultant_id_2 IS DISTINCT FROM OLD.consultant_id_2)
        AND NEW.admitted_at IS NOT NULL AND now() < NEW.admitted_at + interval '24 hours' THEN
    v_refresh := true;
  END IF;
  IF v_refresh THEN
    NEW.admit_consultants := nullif(public.ward_consultant_snapshot(NEW.consultant_name, NEW.consultant_id, NEW.consultant_name_2, NEW.consultant_id_2), '[]'::jsonb);
  END IF;
  RETURN NEW;
END
$function$;
revoke all on function public.patients_admit_consultants() from public, anon, authenticated;

drop trigger if exists patients_zzz_admit_consultants on public.patients;
create trigger patients_zzz_admit_consultants before insert or update on public.patients
  for each row execute function public.patients_admit_consultants();

-- Backfill (all patients, incl. discharged) without bumping updated_at (touch triggers off).
alter table public.patients disable trigger patients_touch;
alter table public.patients disable trigger patients_updated;
alter table public.patients disable trigger patients_zzz_admit_consultants;
update public.patients
   set admit_consultants = nullif(public.ward_consultant_snapshot(consultant_name, consultant_id, consultant_name_2, consultant_id_2), '[]'::jsonb)
 where admit_consultants is null
   and (nullif(trim(coalesce(consultant_name,'')),'') is not null or nullif(trim(coalesce(consultant_name_2,'')),'') is not null
        or consultant_id is not null or consultant_id_2 is not null);
alter table public.patients enable trigger patients_touch;
alter table public.patients enable trigger patients_updated;
alter table public.patients enable trigger patients_zzz_admit_consultants;

-- ---------------------------------------------------------------------------
-- 2. discharge_certificates
-- ---------------------------------------------------------------------------
create table if not exists public.discharge_certificates (
  id text primary key,
  patient_id text not null references public.patients(id) on delete cascade,
  discharged_at timestamptz not null,
  discharge_mode text,
  edits jsonb not null default '{}'::jsonb,
  key_drugs jsonb not null default '[]'::jsonb,
  version integer not null default 0,
  printed_hash text,
  print_count integer not null default 0,
  printed_by text references public.residents(id),
  printed_by_name text,
  printed_at timestamptz,
  first_printed_at timestamptz,
  last_op_id text,
  updated_by text references public.residents(id),
  updated_by_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

do $$ begin
  if not exists (select 1 from pg_constraint where conname='discharge_certificates_episode_key' and conrelid='public.discharge_certificates'::regclass) then
    alter table public.discharge_certificates add constraint discharge_certificates_episode_key unique (patient_id, discharged_at);
  end if;
  if not exists (select 1 from pg_constraint where conname='discharge_certificates_edits_check' and conrelid='public.discharge_certificates'::regclass) then
    alter table public.discharge_certificates add constraint discharge_certificates_edits_check check (jsonb_typeof(edits)='object' and pg_column_size(edits) < 32768);
  end if;
  if not exists (select 1 from pg_constraint where conname='discharge_certificates_key_drugs_check' and conrelid='public.discharge_certificates'::regclass) then
    alter table public.discharge_certificates add constraint discharge_certificates_key_drugs_check check (jsonb_typeof(key_drugs)='array' and pg_column_size(key_drugs) < 16384);
  end if;
  if not exists (select 1 from pg_constraint where conname='discharge_certificates_counts_check' and conrelid='public.discharge_certificates'::regclass) then
    alter table public.discharge_certificates add constraint discharge_certificates_counts_check check (version >= 0 and print_count >= 0 and version <= print_count);
  end if;
end $$;

-- Same posture as mse_entries: RLS on + forced, no policies, RPC-only access.
alter table public.discharge_certificates enable row level security;
alter table public.discharge_certificates force row level security;
revoke all on table public.discharge_certificates from anon, authenticated;
grant all on table public.discharge_certificates to service_role;

-- ---------------------------------------------------------------------------
-- 3. ward_save_discharge_certificate
-- p_row: {patient_id, discharged_at, action:'save'|'print', edits{}, key_drugs[], content_hash, op_id, printed_at}
-- print: same content as the last print -> re-print of that version; changed content -> version+1.
-- ---------------------------------------------------------------------------
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
    updated_by=v_resident_id, updated_by_name=v_name, updated_at=now(), last_op_id=coalesce(v_op,last_op_id)
  WHERE id=v_row.id RETURNING * INTO v_row;

  INSERT INTO public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  VALUES ('dcert-'||coalesce(v_op, v_row.id||'-'||v_row.print_count::text), v_pid, 'note',
          'Discharge certificate '||CASE WHEN v_reprint THEN 're-printed' ELSE 'printed' END||' · v'||v_ver,
          CASE WHEN v_reprint THEN 'Re-print · version '||v_ver ELSE 'Version '||v_ver END,
          v_resident_id, v_at)
  ON CONFLICT (id) DO NOTHING;

  RETURN jsonb_build_object('ok',true,'idempotent',false,'reprint',v_reprint,'version',v_ver,'certificate',to_jsonb(v_row));
END
$function$;

revoke all on function public.ward_save_discharge_certificate(uuid,jsonb) from public;
grant execute on function public.ward_save_discharge_certificate(uuid,jsonb) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. ward_discharge_patient: new optional params. Drop the old 10-arg signature so PostgREST
--    never sees two candidates; old clients (named args, all defaulted) still resolve.
-- ---------------------------------------------------------------------------
drop function if exists public.ward_discharge_patient(uuid,jsonb,text,text[],jsonb,text,jsonb,text,text,integer);
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

revoke all on function public.ward_discharge_patient(uuid,jsonb,text,text[],jsonb,text,jsonb,text,text,integer,text[],text) from public;
grant execute on function public.ward_discharge_patient(uuid,jsonb,text,text[],jsonb,text,jsonb,text,text,integer,text[],text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5a. Non-atomic fallback (qPatient -> ward_upsert_patient): write the requester fields when the
--     keys are present (only sent for discharged On request / DAMA rows).
-- ---------------------------------------------------------------------------
do $$
declare v_def text; v_anchor text := 'PERFORM public.ward_apply_patient_dx_extra(v_id, p_row);';
begin
  select pg_get_functiondef('public.ward_upsert_patient(uuid,jsonb)'::regprocedure) into v_def;
  if position('discharge_requested_by' in v_def) > 0 then raise notice 'ward_upsert_patient already patched'; return; end if;
  if position(v_anchor in v_def) = 0 then raise exception 'ward_upsert_patient anchor not found; patch manually'; end if;
  v_def := replace(v_def, v_anchor, v_anchor || E'\n'
    || E'  -- R1.3.126: discharge requester (fallback path)\n'
    || E'  IF p_row ? ''discharge_requested_by'' OR p_row ? ''discharge_requester_name'' THEN\n'
    || E'    UPDATE public.patients SET\n'
    || E'      discharge_requested_by = CASE WHEN p_row ? ''discharge_requested_by'' THEN\n'
    || E'        CASE WHEN jsonb_typeof(p_row->''discharge_requested_by'')=''array'' AND jsonb_array_length(p_row->''discharge_requested_by'')>0\n'
    || E'             THEN ARRAY(SELECT DISTINCT lower(trim(x)) FROM jsonb_array_elements_text(p_row->''discharge_requested_by'') x\n'
    || E'                        WHERE lower(trim(x)) IN (''self'',''father'',''mother'',''spouse'',''sibling'',''other''))\n'
    || E'             ELSE NULL END ELSE discharge_requested_by END,\n'
    || E'      discharge_requester_name = CASE WHEN p_row ? ''discharge_requester_name'' THEN nullif(left(trim(coalesce(p_row->>''discharge_requester_name'','''')),120),'''') ELSE discharge_requester_name END\n'
    || E'    WHERE id = v_id AND discharge_mode IN (''request'',''dama'');\n'
    || E'  END IF;');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- 5b. ward_read_ward_state: new patient fields + discharge_certificates.
-- ---------------------------------------------------------------------------
do $$
declare
  v_def text;
  a_cols text := 'discharge_review, discharge_ect_sessions' || E'\n' || '    from public.patients) p;';
  a_mse text := '  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc, m.id), ''[]''::jsonb) into v_mse from (';
begin
  select pg_get_functiondef('public.ward_read_ward_state(uuid)'::regprocedure) into v_def;
  if position('v_dcert jsonb' in v_def) > 0 then raise notice 'ward_read_ward_state already has discharge_certificates'; return; end if;
  if position(a_cols in v_def) = 0 or position('v_mse jsonb;' in v_def) = 0 or position(a_mse in v_def) = 0
     or position('''mse_entries'', v_mse' in v_def) = 0 then
    raise exception 'ward_read_ward_state anchors not found; patch manually';
  end if;
  v_def := replace(v_def, a_cols, 'discharge_review, discharge_ect_sessions,' || E'\n'
    || '           discharge_requested_by, discharge_requester_name, admit_consultants' || E'\n' || '    from public.patients) p;');
  v_def := replace(v_def, 'v_mse jsonb;', 'v_mse jsonb; v_dcert jsonb;');
  v_def := replace(v_def, a_mse,
       E'  select coalesce(jsonb_agg(to_jsonb(dc) order by dc.discharged_at desc, dc.id), ''[]''::jsonb) into v_dcert from (\n'
    || E'    select id, patient_id, discharged_at, discharge_mode, edits, key_drugs, version, printed_hash, print_count,\n'
    || E'           printed_by, printed_by_name, printed_at, first_printed_at, updated_by, updated_by_name, updated_at\n'
    || E'    from public.discharge_certificates) dc;\n\n' || a_mse);
  v_def := replace(v_def, '''mse_entries'', v_mse', '''mse_entries'', v_mse, ''discharge_certificates'', v_dcert');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- 5c. Nightly backup payload: requester fields on each patient (cheap).
-- ---------------------------------------------------------------------------
do $$
declare v_def text; v_anchor text := '''discharge_mode'',p.discharge_mode,''bed'',b.bed_number';
begin
  select pg_get_functiondef('public.ward_create_nightly_backup(uuid)'::regprocedure) into v_def;
  if position('discharge_requested_by' in v_def) > 0 then raise notice 'backup already patched'; return; end if;
  if position(v_anchor in v_def) = 0 then raise notice 'ward_create_nightly_backup anchor not found; skipped'; return; end if;
  v_def := replace(v_def, v_anchor, '''discharge_mode'',p.discharge_mode,''discharge_requested_by'',p.discharge_requested_by,''discharge_requester_name'',p.discharge_requester_name,''bed'',b.bed_number');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- 5d. Monthly archive: discharge certificates per record (patients already via to_jsonb(p)).
-- ---------------------------------------------------------------------------
do $$
declare v_def text; v_anchor text := '''activity_log'', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from activity_log x where x.patient_id=p.id),''[]'')';
begin
  select pg_get_functiondef('public.ward_archive_month(text)'::regprocedure) into v_def;
  if position('discharge_certificates' in v_def) > 0 then raise notice 'archive already patched'; return; end if;
  if position(v_anchor in v_def) = 0 then raise notice 'ward_archive_month anchor not found; skipped'; return; end if;
  v_def := replace(v_def, v_anchor,
    '''discharge_certificates'', coalesce((select jsonb_agg(to_jsonb(x) order by x.discharged_at) from discharge_certificates x where x.patient_id=p.id),''[]''),' || E'\n      ' || v_anchor);
  execute v_def;
end $$;

notify pgrst, 'reload schema';
