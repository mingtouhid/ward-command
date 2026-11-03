-- R1.3.143 r1_3_143_rating_scales  (PREPARED, NOT APPLIED)
-- Psychiatric rating scales: BPRS, YMRS, HAM-D 17, CIWA-Ar, COWS, Y-BOCS, BFCRS, CGI-S, CGI-I, C-SSRS screener, CAM (short).
-- Adds: tables scale_defs + scale_assessments (RLS forced, no policies, grants to postgres/service_role only),
--       helper functions ward_scale_calc / ward_scale_insert / ward_scale_json (not executable by anon/authenticated),
--       RPCs ward_save_scale, ward_intern_save_scale, ward_delete_scale, ward_restore_scale, ward_read_scale_history,
--       and a 'scales' list in ward_read_ward_state and ward_intern_read_state (interns: CIWA-Ar and COWS only).
-- The server recomputes every total from the answers and rejects a client total that does not match.
-- Safe to re-run. No UPDATE/DELETE without WHERE. No BEGIN/COMMIT (the migration runner wraps it).

create table if not exists public.scale_defs (
  scale_id text not null,
  version integer not null,
  short_name text not null,
  kind text not null,
  items jsonb not null,
  bands jsonb not null,
  meta jsonb not null default '{}'::jsonb,
  intern_ok boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (scale_id, version)
);
alter table public.scale_defs enable row level security;
alter table public.scale_defs force row level security;
revoke all on table public.scale_defs from public, anon, authenticated;
grant all on table public.scale_defs to postgres, service_role;

insert into public.scale_defs (scale_id, version, short_name, kind, items, bands, meta, intern_ok) values
  ('bprs', 1, 'BPRS', 'bprs', '[{"k":"somatic","vals":[0,1,2,3,4,5,6,7]},{"k":"anxiety","vals":[0,1,2,3,4,5,6,7]},{"k":"withdrawal","vals":[0,1,2,3,4,5,6,7]},{"k":"concept","vals":[0,1,2,3,4,5,6,7]},{"k":"guilt","vals":[0,1,2,3,4,5,6,7]},{"k":"tension","vals":[0,1,2,3,4,5,6,7]},{"k":"manner","vals":[0,1,2,3,4,5,6,7]},{"k":"grandiose","vals":[0,1,2,3,4,5,6,7]},{"k":"depress","vals":[0,1,2,3,4,5,6,7]},{"k":"hostile","vals":[0,1,2,3,4,5,6,7]},{"k":"suspic","vals":[0,1,2,3,4,5,6,7]},{"k":"halluc","vals":[0,1,2,3,4,5,6,7]},{"k":"retard","vals":[0,1,2,3,4,5,6,7]},{"k":"uncoop","vals":[0,1,2,3,4,5,6,7]},{"k":"unusual","vals":[0,1,2,3,4,5,6,7]},{"k":"blunted","vals":[0,1,2,3,4,5,6,7]},{"k":"excite","vals":[0,1,2,3,4,5,6,7]},{"k":"disorient","vals":[0,1,2,3,4,5,6,7]}]'::jsonb, '[[0,"Less than mildly ill","ok"],[31,"Mildly ill","mild"],[41,"Moderately ill","mod"],[53,"Markedly ill","high"],[70,"Severely ill","crit"]]'::jsonb, '{"kind":"bprs","min":18,"max":126,"screen_n":null,"screen_cut":null,"subs":{},"modes":[]}'::jsonb, false),
  ('ymrs', 1, 'YMRS', 'sum', '[{"k":"mood","vals":[0,1,2,3,4]},{"k":"motor","vals":[0,1,2,3,4]},{"k":"sexual","vals":[0,1,2,3,4]},{"k":"sleep","vals":[0,1,2,3,4]},{"k":"irrit","vals":[0,2,4,6,8]},{"k":"speech","vals":[0,2,4,6,8]},{"k":"lang","vals":[0,1,2,3,4]},{"k":"content","vals":[0,2,4,6,8]},{"k":"aggr","vals":[0,2,4,6,8]},{"k":"appear","vals":[0,1,2,3,4]},{"k":"insight","vals":[0,1,2,3,4]}]'::jsonb, '[[0,"Not ill","ok"],[6,"Borderline","ok"],[12,"Mildly ill","mild"],[20,"Moderately ill","mod"],[30,"Markedly ill","high"],[40,"Severely ill","crit"],[52,"Among the most extremely ill","crit"]]'::jsonb, '{"kind":"sum","min":0,"max":60,"screen_n":null,"screen_cut":null,"subs":{},"modes":[]}'::jsonb, false),
  ('hamd', 1, 'HAM-D', 'sum', '[{"k":"mood","vals":[0,1,2,3,4]},{"k":"guilt","vals":[0,1,2,3,4]},{"k":"suicide","vals":[0,1,2,3,4]},{"k":"ins_e","vals":[0,1,2]},{"k":"ins_m","vals":[0,1,2]},{"k":"ins_l","vals":[0,1,2]},{"k":"work","vals":[0,1,2,3,4]},{"k":"retard","vals":[0,1,2,3,4]},{"k":"agit","vals":[0,1,2,3,4]},{"k":"anx_p","vals":[0,1,2,3,4]},{"k":"anx_s","vals":[0,1,2,3,4]},{"k":"som_gi","vals":[0,1,2]},{"k":"som_g","vals":[0,1,2]},{"k":"genital","vals":[0,1,2]},{"k":"hypoch","vals":[0,1,2,3,4]},{"k":"weight","vals":[0,1,2,"na"],"vals_b":[0,1,2,"na"]},{"k":"insight","vals":[0,1,2]}]'::jsonb, '[[0,"No depression","ok"],[8,"Mild depression","mild"],[17,"Moderate depression","mod"],[24,"Severe depression","crit"]]'::jsonb, '{"kind":"sum","min":0,"max":52,"screen_n":null,"screen_cut":null,"subs":{},"modes":[]}'::jsonb, false),
  ('ciwa', 1, 'CIWA-Ar', 'sum', '[{"k":"nausea","vals":[0,1,2,3,4,5,6,7]},{"k":"tremor","vals":[0,1,2,3,4,5,6,7]},{"k":"sweats","vals":[0,1,2,3,4,5,6,7]},{"k":"anxiety","vals":[0,1,2,3,4,5,6,7]},{"k":"agitation","vals":[0,1,2,3,4,5,6,7]},{"k":"tactile","vals":[0,1,2,3,4,5,6,7]},{"k":"auditory","vals":[0,1,2,3,4,5,6,7]},{"k":"visual","vals":[0,1,2,3,4,5,6,7]},{"k":"headache","vals":[0,1,2,3,4,5,6,7]},{"k":"orient","vals":[0,1,2,3,4]}]'::jsonb, '[[0,"Mild withdrawal","ok"],[10,"Moderate withdrawal","mod"],[19,"Severe withdrawal","crit"]]'::jsonb, '{"kind":"sum","min":0,"max":67,"screen_n":null,"screen_cut":null,"subs":{},"modes":[]}'::jsonb, true),
  ('cows', 1, 'COWS', 'sum', '[{"k":"pulse","vals":[0,1,2,4]},{"k":"sweat","vals":[0,1,2,3,4]},{"k":"restless","vals":[0,1,3,5]},{"k":"pupil","vals":[0,1,2,5]},{"k":"aches","vals":[0,1,2,4]},{"k":"nose","vals":[0,1,2,4]},{"k":"gi","vals":[0,1,2,3,5]},{"k":"tremor","vals":[0,1,2,4]},{"k":"yawn","vals":[0,1,2,4]},{"k":"anxiety","vals":[0,1,2,4]},{"k":"goose","vals":[0,3,5]}]'::jsonb, '[[0,"Below withdrawal range","ok"],[5,"Mild withdrawal","mild"],[13,"Moderate withdrawal","mod"],[25,"Moderately severe withdrawal","high"],[37,"Severe withdrawal","crit"]]'::jsonb, '{"kind":"sum","min":0,"max":48,"screen_n":null,"screen_cut":null,"subs":{},"modes":[]}'::jsonb, true),
  ('ybocs', 1, 'Y-BOCS', 'sum', '[{"k":"obs_time","vals":[0,1,2,3,4]},{"k":"obs_int","vals":[0,1,2,3,4]},{"k":"obs_dis","vals":[0,1,2,3,4]},{"k":"obs_res","vals":[0,1,2,3,4]},{"k":"obs_ctl","vals":[0,1,2,3,4]},{"k":"com_time","vals":[0,1,2,3,4]},{"k":"com_int","vals":[0,1,2,3,4]},{"k":"com_dis","vals":[0,1,2,3,4]},{"k":"com_res","vals":[0,1,2,3,4]},{"k":"com_ctl","vals":[0,1,2,3,4]}]'::jsonb, '[[0,"Mild or less","ok"],[14,"Moderate","mod"],[26,"Moderate–severe","high"],[35,"Severe","crit"]]'::jsonb, '{"kind":"sum","min":0,"max":40,"screen_n":null,"screen_cut":null,"subs":{"obs":["obs_time","obs_int","obs_dis","obs_res","obs_ctl"],"comp":["com_time","com_int","com_dis","com_res","com_ctl"]},"modes":[]}'::jsonb, false),
  ('bfcrs', 1, 'BFCRS', 'bfcrs', '[{"k":"stupor","vals":[0,1,2,3]},{"k":"mutism","vals":[0,1,2,3]},{"k":"staring","vals":[0,1,2,3]},{"k":"posturing","vals":[0,1,2,3]},{"k":"grimace","vals":[0,1,2,3]},{"k":"echo","vals":[0,1,2,3]},{"k":"stereo","vals":[0,1,2,3]},{"k":"manner","vals":[0,1,2,3]},{"k":"verbig","vals":[0,1,2,3]},{"k":"rigid","vals":[0,1,2,3]},{"k":"negat","vals":[0,1,2,3]},{"k":"waxy","vals":[0,3]},{"k":"withdraw","vals":[0,1,2,3]},{"k":"excite","vals":[0,1,2,3]},{"k":"impuls","vals":[0,1,2,3]},{"k":"autoob","vals":[0,1,2,3]},{"k":"mitgehen","vals":[0,3]},{"k":"gegen","vals":[0,3]},{"k":"ambi","vals":[0,3]},{"k":"grasp","vals":[0,3]},{"k":"persev","vals":[0,3]},{"k":"combat","vals":[0,1,2,3]},{"k":"autonom","vals":[0,1,2,3]}]'::jsonb, '[[0,"Screen negative","ok"],[1,"Screen positive (≥2 of items 1–14)","high"]]'::jsonb, '{"kind":"bfcrs","min":0,"max":69,"screen_n":14,"screen_cut":2,"subs":{},"modes":[]}'::jsonb, false),
  ('cgis', 1, 'CGI-S', 'single', '[{"k":"sev","vals":[1,2,3,4,5,6,7]}]'::jsonb, '[[1,"Normal, not at all ill","ok"],[2,"Borderline mentally ill","ok"],[3,"Mildly ill","mild"],[4,"Moderately ill","mod"],[5,"Markedly ill","high"],[6,"Severely ill","crit"],[7,"Among the most extremely ill patients","crit"]]'::jsonb, '{"kind":"single","min":1,"max":7,"screen_n":null,"screen_cut":null,"subs":{},"modes":[]}'::jsonb, false),
  ('cgii', 1, 'CGI-I', 'single', '[{"k":"imp","vals":[1,2,3,4,5,6,7]}]'::jsonb, '[[1,"Very much improved","ok"],[2,"Much improved","ok"],[3,"Minimally improved","mild"],[4,"No change","mod"],[5,"Minimally worse","high"],[6,"Much worse","crit"],[7,"Very much worse","crit"]]'::jsonb, '{"kind":"single","min":1,"max":7,"screen_n":null,"screen_cut":null,"subs":{},"modes":[]}'::jsonb, false),
  ('cssrs', 1, 'C-SSRS', 'cssrs', '[{"k":"q1","vals":[0,1]},{"k":"q2","vals":[0,1]},{"k":"q3","vals":[0,1],"if":"q2"},{"k":"q4","vals":[0,1],"if":"q2"},{"k":"q5","vals":[0,1],"if":"q2"},{"k":"q6","vals":[0,1]},{"k":"q6r","vals":[0,1],"if":"q6","mode":"recent"}]'::jsonb, '[[0,"No risk identified","ok"],[1,"Low risk","mild"],[2,"Moderate risk","high"],[3,"High risk","crit"]]'::jsonb, '{"kind":"cssrs","min":0,"max":3,"screen_n":null,"screen_cut":null,"subs":{},"modes":["recent","slc"]}'::jsonb, false),
  ('cam', 1, 'CAM', 'cam', '[{"k":"f1a","vals":[0,1]},{"k":"f1b","vals":[0,1]},{"k":"f2","vals":[0,1]},{"k":"f3","vals":[0,1]},{"k":"f4","vals":[0,1,2,3,4]}]'::jsonb, '[[0,"CAM negative","ok"],[1,"CAM positive – delirium suggested","crit"]]'::jsonb, '{"kind":"cam","min":0,"max":1,"screen_n":null,"screen_cut":null,"subs":{},"modes":[]}'::jsonb, false)
on conflict (scale_id, version) do update
  set short_name = excluded.short_name, kind = excluded.kind, items = excluded.items, bands = excluded.bands,
      meta = excluded.meta, intern_ok = excluded.intern_ok, active = true;

create table if not exists public.scale_assessments (
  id text primary key check (id ~ '^[A-Za-z0-9._:-]{1,80}$'),
  patient_id text not null references public.patients(id) on delete cascade,
  admitted_at timestamptz,
  scale_id text not null,
  scale_version integer not null,
  answers jsonb not null,
  total numeric not null,
  subscores jsonb not null default '{}'::jsonb,
  severity text not null,
  tone text,
  rated_at timestamptz not null,
  rated_by text not null references public.residents(id),
  rated_by_name text,
  rated_by_role text,
  note text,
  informant text,
  op_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by text,
  deleted_by_name text,
  deleted_reason text,
  restored_at timestamptz,
  restored_by text,
  foreign key (scale_id, scale_version) references public.scale_defs(scale_id, version)
);
create index if not exists scale_assessments_patient_idx on public.scale_assessments (patient_id, scale_id, rated_at desc);
alter table public.scale_assessments enable row level security;
alter table public.scale_assessments force row level security;
revoke all on table public.scale_assessments from public, anon, authenticated;
grant all on table public.scale_assessments to postgres, service_role;

CREATE OR REPLACE FUNCTION public.ward_scale_calc(p_scale text, p_version integer, p_ans jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare d public.scale_defs%rowtype; it jsonb; v jsonb; k text; v_mode text; v_applies boolean; v_allowed jsonb;
  v_total numeric := 0; v_na integer := 0; v_sub jsonb := '{}'::jsonb; v_keys text[] := '{}'; v_lv integer;
  v_band jsonb; b jsonb; v_scr integer; v_pos boolean; sk text; f1 boolean; f2 boolean; f3 boolean; f4 boolean; v_sev text;
begin
  select * into d from public.scale_defs where scale_id = p_scale and version = p_version and active;
  if not found then raise exception 'Unknown rating scale or version'; end if;
  if p_ans is null or jsonb_typeof(p_ans) <> 'object' then raise exception 'Rating scale answers must be an object'; end if;
  v_mode := p_ans->>'_mode';
  if jsonb_array_length(coalesce(d.meta->'modes', '[]'::jsonb)) > 0 then
    if v_mode is null or not ((d.meta->'modes') ? v_mode) then raise exception 'Rating scale version (mode) must be chosen'; end if;
  elsif p_ans ? '_mode' then
    raise exception 'Rating scale answers must not include a mode';
  end if;
  for it in select e from jsonb_array_elements(d.items) e loop
    k := it->>'k';
    v_keys := v_keys || k;
    if it ? 'vals_b' then v_keys := v_keys || (k || '_m'); end if;
    v_applies := (it->>'mode' is null or it->>'mode' = v_mode)
             and (it->>'if' is null or p_ans->(it->>'if') = '1'::jsonb);
    v := p_ans->k;
    if v = 'null'::jsonb then v := null; end if;
    if not v_applies then
      if v is not null then raise exception 'Rating scale answer given for a skipped item (%)', k; end if;
      continue;
    end if;
    if v is null then raise exception 'Rating scale must be complete: item % is not answered', k; end if;
    v_allowed := it->'vals';
    if it ? 'vals_b' then
      if coalesce(p_ans->>(k || '_m'), 'a') not in ('a', 'b') then raise exception 'Rating scale answers must use a valid rating method for %', k; end if;
      if p_ans->>(k || '_m') = 'b' then v_allowed := it->'vals_b'; end if;
    end if;
    if jsonb_typeof(v) not in ('number', 'string') or not (v_allowed @> jsonb_build_array(v)) then
      raise exception 'Rating scale answer out of range for item %', k;
    end if;
    if v = '"na"'::jsonb or (d.kind = 'bprs' and v = '0'::jsonb) then
      v_na := v_na + 1;
    else
      v_total := v_total + (v #>> '{}')::numeric;
    end if;
  end loop;
  if exists (select 1 from jsonb_object_keys(p_ans) x where x <> '_mode' and not (x = any(v_keys))) then
    raise exception 'Rating scale answers must only use the scale''s items';
  end if;

  if d.kind = 'cssrs' then
    v_lv := 0;
    if p_ans->'q1' = '1'::jsonb or p_ans->'q2' = '1'::jsonb then v_lv := 1; end if;
    if p_ans->'q2' = '1'::jsonb and p_ans->'q3' = '1'::jsonb then v_lv := greatest(v_lv, 2); end if;
    if p_ans->'q2' = '1'::jsonb and (p_ans->'q4' = '1'::jsonb or p_ans->'q5' = '1'::jsonb) then v_lv := 3; end if;
    if p_ans->'q6' = '1'::jsonb then
      v_lv := greatest(v_lv, case when v_mode = 'recent' and p_ans->'q6r' = '0'::jsonb then 2 else 3 end);
    end if;
    v_total := v_lv;
  elsif d.kind = 'cam' then
    f1 := p_ans->'f1a' = '1'::jsonb or p_ans->'f1b' = '1'::jsonb;
    f2 := p_ans->'f2' = '1'::jsonb;
    f3 := p_ans->'f3' = '1'::jsonb;
    f4 := (p_ans->>'f4')::numeric > 0;
    v_sub := jsonb_build_object('f1', f1::int, 'f2', f2::int, 'f3', f3::int, 'f4', f4::int);
    v_total := case when f1 and f2 and (f3 or f4) then 1 else 0 end;
  elsif d.kind = 'bfcrs' then
    select count(*) into v_scr
    from jsonb_array_elements(d.items) with ordinality t(e, n)
    where n <= (d.meta->>'screen_n')::int and (p_ans->>(e->>'k'))::numeric > 0;
    v_pos := v_scr >= (d.meta->>'screen_cut')::int;
    v_sub := jsonb_build_object('screen', v_scr);
  elsif jsonb_typeof(d.meta->'subs') = 'object' then
    for sk in select jsonb_object_keys(d.meta->'subs') loop
      v_sub := v_sub || jsonb_build_object(sk, (
        select coalesce(sum((p_ans->>x)::numeric), 0) from jsonb_array_elements_text(d.meta->'subs'->sk) x
        where jsonb_typeof(p_ans->x) = 'number'));
    end loop;
  end if;

  if d.kind = 'bfcrs' then
    v_band := case when v_pos then d.bands->1 else d.bands->0 end;
  else
    v_band := d.bands->0;
    for b in select e from jsonb_array_elements(d.bands) e loop
      if v_total >= (b->>0)::numeric then v_band := b; end if;
    end loop;
  end if;
  v_sev := v_band->>1;
  if d.kind = 'bprs' and v_na > 0 then v_sev := v_sev || ' (partial)'; end if;
  return jsonb_build_object('total', v_total, 'severity', v_sev, 'tone', v_band->>2, 'subscores', v_sub, 'na', v_na, 'positive', v_pos);
end;
$function$;

CREATE OR REPLACE FUNCTION public.ward_scale_json(p_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select to_jsonb(x) from (
    select sa.id, sa.patient_id, sa.scale_id, sa.scale_version, sa.answers, sa.total, sa.subscores, sa.severity, sa.tone,
           sa.rated_at, sa.rated_by, sa.rated_by_name, sa.rated_by_role, sa.note, sa.informant, sa.created_at,
           sa.deleted_at, sa.deleted_by_name, sa.deleted_reason
    from public.scale_assessments sa where sa.id = p_id) x
$function$;

CREATE OR REPLACE FUNCTION public.ward_scale_insert(p_actor text, p_name text, p_role text, p_row jsonb, p_intern boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare d public.scale_defs%rowtype; v_old public.scale_assessments%rowtype; v_id text; v_pid text; v_sid text; v_ver integer;
  v_adm timestamptz; v_at timestamptz; v_calc jsonb; v_inf text; v_detail text;
begin
  if p_row is null or jsonb_typeof(p_row) <> 'object' then raise exception 'Rating is required'; end if;
  if octet_length(p_row::text) > 16384 then raise exception 'Rating entry is too large'; end if;
  v_id := nullif(btrim(coalesce(p_row->>'id', '')), '');
  v_pid := nullif(btrim(coalesce(p_row->>'patient_id', '')), '');
  v_sid := lower(btrim(coalesce(p_row->>'scale_id', '')));
  if v_id is null or v_id !~ '^[A-Za-z0-9._:-]{1,80}$' then raise exception 'Rating id is invalid'; end if;
  if coalesce(p_row->>'scale_version', '') !~ '^[0-9]{1,4}$' then raise exception 'Rating scale version must be a number'; end if;
  v_ver := (p_row->>'scale_version')::int;
  select * into v_old from public.scale_assessments where id = v_id;
  if found then
    if v_old.rated_by <> p_actor or v_old.patient_id is distinct from v_pid then raise exception 'Rating id is already used'; end if;
    return jsonb_build_object('ok', true, 'idempotent', true, 'scale', public.ward_scale_json(v_id));
  end if;
  select * into d from public.scale_defs where scale_id = v_sid and version = v_ver and active;
  if not found then raise exception 'Unknown rating scale or version'; end if;
  if p_intern and not d.intern_ok then
    raise exception 'This rating scale is not available for interns (interns can record CIWA-Ar and COWS only)';
  end if;
  select admitted_at into v_adm from public.patients where id = v_pid and coalesce(active_status, 'admitted') <> 'discharged';
  if not found then raise exception 'Patient not found'; end if;
  v_calc := public.ward_scale_calc(v_sid, v_ver, coalesce(p_row->'answers', 'null'::jsonb));
  if jsonb_typeof(p_row->'total') = 'number' and abs((p_row->>'total')::numeric - (v_calc->>'total')::numeric) > 0.001 then
    raise exception 'Rating scale total does not match the answers (server total %)', v_calc->>'total';
  end if;
  v_at := coalesce(nullif(p_row->>'rated_at', '')::timestamptz, now());
  if v_at > now() + interval '5 minutes' then raise exception 'Rating time is in the future'; end if;
  if v_at < now() - interval '24 hours' then raise exception 'Ratings older than 24 hours cannot be added'; end if;
  v_at := least(v_at, now());
  v_inf := nullif(lower(btrim(coalesce(p_row->>'informant', ''))), '');
  if v_inf is not null and v_inf not in ('patient', 'family', 'staff', 'chart') then
    raise exception 'Informant must be patient, family, staff or chart';
  end if;
  insert into public.scale_assessments(id, patient_id, admitted_at, scale_id, scale_version, answers, total, subscores, severity, tone,
                                       rated_at, rated_by, rated_by_name, rated_by_role, note, informant, op_id)
  values (v_id, v_pid, v_adm, v_sid, v_ver, p_row->'answers', (v_calc->>'total')::numeric, coalesce(v_calc->'subscores', '{}'::jsonb),
          v_calc->>'severity', v_calc->>'tone', v_at, p_actor, p_name, p_role,
          left(nullif(btrim(coalesce(p_row->>'note', '')), ''), 1000), v_inf,
          nullif(left(btrim(coalesce(p_row->>'op_id', '')), 80), ''));
  v_detail := case
    when v_sid = 'ciwa' and (v_calc->>'total')::numeric >= 20 then 'CIWA-Ar 20 or more: inform the consultant and the resident on duty'
    when v_sid = 'ciwa' and (v_calc->>'total')::numeric >= 15 then 'CIWA-Ar 15 or more: inform the resident on duty'
    when v_sid = 'cssrs' and (v_calc->>'total')::numeric >= 3 then 'C-SSRS high risk'
    when v_sid = 'cam' and (v_calc->>'total')::numeric >= 1 then 'CAM positive: delirium suggested'
  end;
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('scl:' || v_id, v_pid, 'scale',
          d.short_name || case when d.kind in ('cssrs', 'cam') then '' else ' ' || (v_calc->>'total') end || ' · ' || (v_calc->>'severity'),
          v_detail, p_actor, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'idempotent', false, 'scale', public.ward_scale_json(v_id));
end;
$function$;

CREATE OR REPLACE FUNCTION public.ward_save_scale(p_token uuid, p_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_res text; v_name text; v_role text;
begin
  select s.resident_id, coalesce(r.display_name, r.username), lower(coalesce(r.role, ''))
    into v_res, v_name, v_role
  from public.ward_sessions s join public.residents r on r.id = s.resident_id and r.active = true
  where s.token = p_token and s.expires_at > now() limit 1;
  if v_res is null then raise exception 'Invalid or expired ward session'; end if;
  if v_role in ('intern', 'viewer') then raise exception 'This account cannot record rating scales here (view-only)'; end if;
  return public.ward_scale_insert(v_res, v_name,
    case when v_role in ('admin', 'sr') then 'admin' when v_role = 'consultant' then 'consultant' else 'resident' end, p_row, false);
end;
$function$;

CREATE OR REPLACE FUNCTION public.ward_intern_save_scale(p_token uuid, p_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare a record;
begin
  select * into a from public.ward_intern_actor(p_token);
  return public.ward_scale_insert(a.resident_id, a.actor_name, 'intern', p_row, true);
end;
$function$;

CREATE OR REPLACE FUNCTION public.ward_delete_scale(p_token uuid, p_id text, p_reason text, p_op_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_res text; v_name text; v_role text; m public.scale_assessments%rowtype; v_reason text := public.ward_clean_reason(p_reason);
  v_op text := nullif(left(regexp_replace(coalesce(p_op_id, ''), '[^A-Za-z0-9._-]', '', 'g'), 60), ''); v_short text;
begin
  select s.resident_id, coalesce(r.display_name, r.username), lower(coalesce(r.role, ''))
    into v_res, v_name, v_role
  from public.ward_sessions s join public.residents r on r.id = s.resident_id and r.active = true
  where s.token = p_token and s.expires_at > now() limit 1;
  if v_res is null then raise exception 'Invalid or expired ward session'; end if;
  if v_role in ('intern', 'viewer') then raise exception 'Only residents, consultants and admins can delete ratings'; end if;
  if length(v_reason) < 3 then raise exception 'Give a reason (at least 3 characters)'; end if;
  select * into m from public.scale_assessments where id = p_id for update;
  if not found then raise exception 'Rating not found'; end if;
  if m.deleted_at is not null then
    return jsonb_build_object('ok', true, 'idempotent', true, 'id', m.id, 'patient_id', m.patient_id, 'deleted_at', m.deleted_at);
  end if;
  if v_role not in ('admin', 'sr', 'consultant') then
    if m.rated_by <> v_res then raise exception 'Residents can delete only their own ratings'; end if;
    if m.created_at < now() - interval '24 hours' then raise exception 'Ratings older than 24 hours can be deleted only by a consultant or admin'; end if;
  end if;
  update public.scale_assessments
     set deleted_at = now(), deleted_by = v_res, deleted_by_name = v_name, deleted_reason = v_reason, updated_at = now()
   where id = m.id;
  select short_name into v_short from public.scale_defs where scale_id = m.scale_id and version = m.scale_version;
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('scld:' || m.id || ':' || coalesce(v_op, replace(gen_random_uuid()::text, '-', '')), m.patient_id, 'scale',
          'Rating deleted · ' || coalesce(v_short, m.scale_id) || ' of ' || to_char(m.rated_at at time zone 'Asia/Kolkata', 'DD Mon YYYY HH24:MI'),
          'Reason: ' || v_reason, v_res, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'idempotent', false, 'id', m.id, 'patient_id', m.patient_id, 'deleted_at', now());
end;
$function$;

CREATE OR REPLACE FUNCTION public.ward_restore_scale(p_token uuid, p_id text, p_op_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_res text; v_name text; v_role text; m public.scale_assessments%rowtype; v_short text;
  v_op text := nullif(left(regexp_replace(coalesce(p_op_id, ''), '[^A-Za-z0-9._-]', '', 'g'), 60), '');
begin
  select s.resident_id, coalesce(r.display_name, r.username), lower(coalesce(r.role, ''))
    into v_res, v_name, v_role
  from public.ward_sessions s join public.residents r on r.id = s.resident_id and r.active = true
  where s.token = p_token and s.expires_at > now() limit 1;
  if v_res is null then raise exception 'Invalid or expired ward session'; end if;
  if v_role in ('intern', 'viewer') then raise exception 'Only residents, consultants and admins can restore ratings'; end if;
  select * into m from public.scale_assessments where id = p_id for update;
  if not found then raise exception 'Rating not found'; end if;
  if m.deleted_at is null then
    return jsonb_build_object('ok', true, 'idempotent', true, 'scale', public.ward_scale_json(m.id));
  end if;
  if v_role not in ('admin', 'sr', 'consultant') then
    if m.rated_by <> v_res then raise exception 'Residents can restore only their own ratings'; end if;
    if m.created_at < now() - interval '24 hours' then raise exception 'Ratings older than 24 hours can be restored only by a consultant or admin'; end if;
  end if;
  update public.scale_assessments
     set deleted_at = null, deleted_by = null, deleted_by_name = null, deleted_reason = null,
         restored_at = now(), restored_by = v_res, updated_at = now()
   where id = m.id;
  select short_name into v_short from public.scale_defs where scale_id = m.scale_id and version = m.scale_version;
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values ('sclr:' || m.id || ':' || coalesce(v_op, replace(gen_random_uuid()::text, '-', '')), m.patient_id, 'scale',
          'Rating restored · ' || coalesce(v_short, m.scale_id) || ' of ' || to_char(m.rated_at at time zone 'Asia/Kolkata', 'DD Mon YYYY HH24:MI'),
          null, v_res, now())
  on conflict (id) do nothing;
  return jsonb_build_object('ok', true, 'idempotent', false, 'scale', public.ward_scale_json(m.id));
end;
$function$;

CREATE OR REPLACE FUNCTION public.ward_read_scale_history(p_token uuid, p_patient_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_res text; v_list jsonb;
begin
  select s.resident_id into v_res
  from public.ward_sessions s join public.residents r on r.id = s.resident_id and r.active = true
  where s.token = p_token and s.expires_at > now() limit 1;
  if v_res is null then raise exception 'Invalid or expired ward session'; end if;
  select coalesce(jsonb_agg(public.ward_scale_json(sa.id) order by sa.rated_at desc, sa.id), '[]'::jsonb) into v_list
  from public.scale_assessments sa where sa.patient_id = p_patient_id;
  return jsonb_build_object('ok', true, 'patient_id', p_patient_id, 'scales', v_list);
end;
$function$;

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
  -- R1.3.143: interns see CIWA-Ar and COWS ratings of on-ward patients only
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


revoke all on function public.ward_scale_calc(text, integer, jsonb) from public, anon, authenticated;
revoke all on function public.ward_scale_json(text) from public, anon, authenticated;
revoke all on function public.ward_scale_insert(text, text, text, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.ward_scale_calc(text, integer, jsonb) to postgres, service_role;
grant execute on function public.ward_scale_json(text) to postgres, service_role;
grant execute on function public.ward_scale_insert(text, text, text, jsonb, boolean) to postgres, service_role;
revoke all on function public.ward_save_scale(uuid, jsonb) from public;
revoke all on function public.ward_intern_save_scale(uuid, jsonb) from public;
revoke all on function public.ward_delete_scale(uuid, text, text, text) from public;
revoke all on function public.ward_restore_scale(uuid, text, text) from public;
revoke all on function public.ward_read_scale_history(uuid, text) from public;
grant execute on function public.ward_save_scale(uuid, jsonb) to anon, authenticated, service_role;
grant execute on function public.ward_intern_save_scale(uuid, jsonb) to anon, authenticated, service_role;
grant execute on function public.ward_delete_scale(uuid, text, text, text) to anon, authenticated, service_role;
grant execute on function public.ward_restore_scale(uuid, text, text) to anon, authenticated, service_role;
grant execute on function public.ward_read_scale_history(uuid, text) to anon, authenticated, service_role;
