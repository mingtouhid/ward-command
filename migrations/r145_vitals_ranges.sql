CREATE OR REPLACE FUNCTION public.ward_save_vitals(p_token uuid, p_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare a record; v_id text; v_pid text; v_at timestamptz; v_adm timestamptz;
  v_sys int; v_dia int; v_pr int; v_rr int; v_sp int; v_t numeric; v_ab text[] := '{}'; v_old public.patient_vitals%rowtype;
  v_title text;
  function_num constant text := '^\s*-?[0-9]+(\.[0-9]+)?\s*$';
begin
  select * into a from public.ward_intern_actor(p_token);
  if p_row is null or jsonb_typeof(p_row) <> 'object' then raise exception 'Vitals are required'; end if;
  if octet_length(p_row::text) > 4096 then raise exception 'Vitals entry is too large'; end if;
  v_id := nullif(btrim(coalesce(p_row->>'id','')), '');
  v_pid := nullif(btrim(coalesce(p_row->>'patient_id','')), '');
  if v_id is null or v_id !~ '^[A-Za-z0-9._:-]{1,80}$' then raise exception 'Vitals id is invalid'; end if;
  select * into v_old from public.patient_vitals where id = v_id;
  if found then
    if v_old.recorded_by <> a.resident_id or v_old.patient_id <> v_pid then raise exception 'Vitals id is already used'; end if;
    return jsonb_build_object('ok', true, 'idempotent', true, 'vitals', to_jsonb(v_old));
  end if;
  select admitted_at into v_adm from public.patients where id = v_pid and coalesce(active_status, 'admitted') <> 'discharged';
  if not found then raise exception 'Patient not found'; end if;
  -- numbers only
  if (p_row->>'bp_systolic') !~ function_num or (p_row->>'bp_diastolic') !~ function_num or (p_row->>'pulse') !~ function_num
     or (p_row->>'resp_rate') !~ function_num or (p_row->>'spo2') !~ function_num or (p_row->>'temp_f') !~ function_num then
    raise exception 'Vitals must be numbers';
  end if;
  v_sys := round((p_row->>'bp_systolic')::numeric); v_dia := round((p_row->>'bp_diastolic')::numeric);
  v_pr := round((p_row->>'pulse')::numeric); v_rr := round((p_row->>'resp_rate')::numeric);
  v_sp := round((p_row->>'spo2')::numeric); v_t := round((p_row->>'temp_f')::numeric, 1);
  if num_nonnulls(v_sys, v_dia, v_pr, v_rr, v_sp, v_t) = 0 then raise exception 'Enter at least one vital sign'; end if;
  if (v_sys is null) <> (v_dia is null) then raise exception 'Enter both systolic and diastolic BP'; end if;
  if v_sys is not null and (v_sys not between 40 and 300) then raise exception 'Systolic BP must be 40–300 mmHg'; end if;
  if v_dia is not null and (v_dia not between 20 and 200) then raise exception 'Diastolic BP must be 20–200 mmHg'; end if;
  if v_sys is not null and v_dia >= v_sys then raise exception 'Diastolic BP must be lower than systolic'; end if;
  if v_pr is not null and (v_pr not between 20 and 250) then raise exception 'Pulse must be 20–250 /min'; end if;
  if v_rr is not null and (v_rr not between 4 and 80) then raise exception 'Respiratory rate must be 4–80 /min'; end if;
  if v_sp is not null and (v_sp not between 40 and 100) then raise exception 'SpO2 must be 40–100 %%'; end if;
  if v_t is not null and (v_t not between 85 and 110) then raise exception 'Temperature must be 85–110 °F'; end if;
  v_at := coalesce(nullif(p_row->>'recorded_at','')::timestamptz, now());
  if v_at > now() + interval '5 minutes' then raise exception 'Vitals time is in the future'; end if;
  if v_at < now() - interval '24 hours' then raise exception 'Vitals older than 24 hours cannot be added'; end if;
  v_at := least(v_at, now());
  -- R1.3.145 adult ward ranges, one flag per parameter (same rules as vitalsAbn() in index.html):
  --   Systolic <90 or >=140 · Diastolic <60 or >=90 · Pulse <60 or >100 · RR <12 or >20
  --   SpO2 <95 low, <=92 critical · Temp >=99.5 raised, >=100.4 fever, <96.8 low (°F)
  if v_sys >= 140 then v_ab := v_ab || 'Systolic high'::text; elsif v_sys < 90 then v_ab := v_ab || 'Systolic low'::text; end if;
  if v_dia >= 90 then v_ab := v_ab || 'Diastolic high'::text; elsif v_dia < 60 then v_ab := v_ab || 'Diastolic low'::text; end if;
  if v_pr > 100 then v_ab := v_ab || 'Pulse high'::text; elsif v_pr < 60 then v_ab := v_ab || 'Pulse low'::text; end if;
  if v_rr > 20 then v_ab := v_ab || 'RR high'::text; elsif v_rr < 12 then v_ab := v_ab || 'RR low'::text; end if;
  if v_sp <= 92 then v_ab := v_ab || 'SpO2 critical'::text; elsif v_sp < 95 then v_ab := v_ab || 'SpO2 low'::text; end if;
  if v_t >= 100.4 then v_ab := v_ab || 'Fever'::text; elsif v_t >= 99.5 then v_ab := v_ab || 'Temp raised'::text; elsif v_t < 96.8 then v_ab := v_ab || 'Temp low'::text; end if;
  insert into public.patient_vitals(id, patient_id, recorded_at, bp_systolic, bp_diastolic, pulse, resp_rate, spo2, temp_f, abnormal,
                                    recorded_by, recorded_by_name, op_id)
  values (v_id, v_pid, v_at, v_sys, v_dia, v_pr, v_rr, v_sp, v_t, v_ab, a.resident_id, a.actor_name,
          nullif(left(btrim(coalesce(p_row->>'op_id','')), 80), ''))
  returning * into v_old;
  v_title := 'Vitals · ' || array_to_string(array_remove(array[
      case when v_sys is not null then 'BP ' || v_sys || '/' || v_dia end,
      case when v_pr is not null then 'PR ' || v_pr end,
      case when v_rr is not null then 'RR ' || v_rr end,
      case when v_sp is not null then 'SpO₂ ' || v_sp || '%' end,
      case when v_t is not null then 'T ' || v_t || ' °F' end], null), ' · ');
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('vit:' || v_id, v_pid, 'vitals', v_title,
          case when cardinality(v_ab) > 0 then 'Outside usual range: ' || array_to_string(v_ab, ', ') end, a.resident_id, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'idempotent', false, 'vitals', to_jsonb(v_old));
end;
$function$;
