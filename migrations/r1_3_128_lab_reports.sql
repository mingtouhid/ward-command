-- R1.3.128 Blood investigations, phase 0 (manual entry from the patient card; no OCR yet)
-- NOT APPLIED. Written and tested on local Postgres only (26 Oct 2026). Idempotent.
-- Apply BEFORE deploying the R1.3.128 client. (Without the RPC, the client keeps reports on the phone
-- in the outbox and shows "Pending sync"; nothing is lost.)
--
-- 1. lab_reports (one paper report), lab_results (one row per test), lab_report_edits (diff log).
--    RLS forced, no policies: only the SECURITY DEFINER RPCs below touch them.
-- 2. ward_lab_critical(code, value): the server's own critical limits (K, Na, Hb, glucose, platelets, Li, valproate).
-- 3. ward_save_lab_report(p_token, p_report): create / edit / delete, edit log, timeline entry.
-- 4. ward_read_lab_history(p_token, p_patient_id): all reports of one patient (record page).
-- 5. ward_read_ward_state: + lab_reports (current admission of on-ward patients, plus the last 14 days).
-- 6. ward_create_nightly_backup: + mrd_no per patient and lab report counts.
--    ward_archive_month: + mrd_no in the register, + lab_reports (with results) and lab_report_edits per record.
-- 7. ward_admission_counts (from R1.3.127 undo admission): + lab_reports, so a report saved during the
--    2-minute undo window blocks Undo like any other clinical data; ward_undo_admission names it
--    "an investigations report" in the blocked message. Needs R1.3.127 applied first.
-- ward_upsert_patient needs no change (labs never travel through the patient row).
--
-- Canonical units: platelets and WBC are stored per µL in value_num (the paper prints 10^3/µL;
-- value_printed / unit_printed keep what was on the paper).

-- ---------------------------------------------------------------------------
-- 1. tables
-- ---------------------------------------------------------------------------
create table if not exists public.lab_reports (
  id text primary key check (id ~ '^[A-Za-z0-9._:-]{1,80}$'),
  patient_id text not null references public.patients(id) on delete cascade,
  lab text not null default 'AMCH' check (length(lab) <= 60),
  department text not null default 'other' check (department in ('pathology','biochemistry','other')),
  template_id text check (template_id is null or length(template_id) <= 60),
  sample_no text check (sample_no is null or length(sample_no) <= 40),
  hosp_no_printed text check (hosp_no_printed is null or length(hosp_no_printed) <= 40),
  hosp_no_canonical text check (hosp_no_canonical is null or length(hosp_no_canonical) <= 40),
  page_count smallint,
  pages_present smallint[],
  report_status text not null default 'final' check (report_status in ('final','provisional')),
  match_status text not null default 'card' check (match_status in ('exact','probable_confirmed','override','card')),
  sample_type text check (sample_type is null or length(sample_type) <= 40),
  collected_at timestamptz,
  reported_at timestamptz not null,
  entry_method text not null default 'manual' check (entry_method in ('ocr','manual')),
  ocr_engine text,
  ocr_mean_conf numeric,
  has_critical boolean not null default false,
  panels text[] not null default '{}',
  confirmed boolean not null default false,
  created_by text references public.residents(id),
  created_by_name text,
  created_at timestamptz not null default now(),
  updated_by text references public.residents(id),
  updated_by_name text,
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  deleted_by text references public.residents(id),
  last_op_id text,
  edit_count integer not null default 0
);
create table if not exists public.lab_results (
  id text primary key,
  report_id text not null references public.lab_reports(id) on delete cascade,
  patient_id text not null references public.patients(id) on delete cascade,
  test_code text not null check (test_code ~ '^[a-z0-9_]{1,40}$'),
  test_name_printed text not null check (length(test_name_printed) <= 120),
  value_num numeric,
  value_text text check (value_text is null or length(value_text) <= 200),
  unit text check (unit is null or length(unit) <= 40),
  value_printed text check (value_printed is null or length(value_printed) <= 60),
  unit_printed text check (unit_printed is null or length(unit_printed) <= 40),
  ref_low numeric, ref_high numeric,
  ref_text text check (ref_text is null or length(ref_text) <= 200),
  ref_tiers jsonb check (ref_tiers is null or pg_column_size(ref_tiers) < 4096),
  value_low numeric, value_high numeric,
  page_no smallint,
  flag text check (flag is null or flag in ('H','L','A','CRIT_H','CRIT_L','URGENT')),
  tier_label text check (tier_label is null or length(tier_label) <= 60),
  ocr_value text, ocr_conf numeric,
  field_state text check (field_state is null or field_state in ('green','amber','red')),
  confirmed boolean not null default false,
  edited boolean not null default false,
  sort_order integer not null default 0,
  check (value_num is not null or value_text is not null)
);
create table if not exists public.lab_report_edits (
  id bigint generated always as identity primary key,
  report_id text not null references public.lab_reports(id) on delete cascade,
  patient_id text not null references public.patients(id) on delete cascade,
  action text not null default 'edit' check (action in ('edit','delete')),
  edited_by text references public.residents(id),
  edited_by_name text,
  edited_at timestamptz not null default now(),
  op_id text,
  changes jsonb not null default '{}'::jsonb
);
create index if not exists lab_results_patient_test_idx on public.lab_results(patient_id, test_code);
create index if not exists lab_results_report_idx on public.lab_results(report_id);
create index if not exists lab_reports_patient_time_idx on public.lab_reports(patient_id, (coalesce(collected_at, reported_at)) desc);
create index if not exists lab_report_edits_report_idx on public.lab_report_edits(report_id);

alter table public.lab_reports enable row level security;
alter table public.lab_reports force row level security;
alter table public.lab_results enable row level security;
alter table public.lab_results force row level security;
alter table public.lab_report_edits enable row level security;
alter table public.lab_report_edits force row level security;
revoke all on public.lab_reports, public.lab_results, public.lab_report_edits from anon, authenticated;
grant all on public.lab_reports, public.lab_results, public.lab_report_edits to service_role;

-- ---------------------------------------------------------------------------
-- 2. critical limits (server is the authority; the client shows the same banner)
-- plt is per µL. Glucose codes: rbs, fbs, ppbs.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ward_lab_critical(p_code text, p_v numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select case
    when p_v is null then null
    when p_code = 'k'   then case when p_v < 2.5 then 'CRIT_L' when p_v >= 6.0 then 'CRIT_H' end
    when p_code = 'na'  then case when p_v < 120 then 'CRIT_L' when p_v >= 160 then 'CRIT_H' end
    when p_code = 'hb'  then case when p_v < 7 then 'CRIT_L' end
    when p_code in ('rbs','fbs','ppbs') then case when p_v < 50 then 'CRIT_L' when p_v > 400 then 'CRIT_H' end
    when p_code = 'plt' then case when p_v < 10000 then 'URGENT' when p_v < 20000 then 'CRIT_L' end
    when p_code = 'li'  then case when p_v >= 1.5 then 'CRIT_H' end
    when p_code = 'vpa' then case when p_v > 150 then 'CRIT_H' end
  end
$function$;

-- ---------------------------------------------------------------------------
-- 3. ward_save_lab_report
-- p_report: {id, op_id, action:'save'|'delete', patient_id, lab, department, template_id, sample_no,
--   report_status, sample_type, collected_at, reported_at, panels[], confirmed, results:[{test_code,
--   test_name_printed, value_num, value_text, unit, value_printed, unit_printed, ref_low, ref_high, ref_text,
--   ref_tiers, value_low, value_high, flag, tier_label, field_state, confirmed, edited, sort_order}]}
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ward_save_lab_report(p_token uuid, p_report jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_resident_id text; v_role text; v_name text;
  v_id text; v_pid text; v_op text; v_action text;
  v_old public.lab_reports%ROWTYPE;
  v_exists boolean := false;
  v_rep timestamptz; v_col timestamptz;
  v_results jsonb; v_r jsonb; v_i int := 0;
  v_code text; v_num numeric; v_txt text; v_flag text; v_crit text; v_state text; v_conf boolean;
  v_lo numeric; v_hi numeric;
  v_codes text[] := '{}';
  v_ncrit int := 0;
  v_panels text[]; v_plabel text;
  v_diff text[] := '{}'; v_changes jsonb := '[]'::jsonb;
  v_o record; v_n record;
  v_title text; v_detail text;
  v_dept text;
BEGIN
  SELECT s.resident_id, lower(coalesce(r.role,'')), coalesce(r.display_name, r.username)
    INTO v_resident_id, v_role, v_name
  FROM public.ward_sessions s JOIN public.residents r ON r.id=s.resident_id
  WHERE s.token=p_token AND s.expires_at>now() AND r.active=true;
  IF v_resident_id IS NULL THEN RAISE EXCEPTION 'Invalid or expired ward session'; END IF;
  IF v_role IN ('consultant','viewer') THEN RAISE EXCEPTION 'This role cannot perform clinical writes'; END IF;

  IF p_report IS NULL OR jsonb_typeof(p_report) <> 'object' THEN RAISE EXCEPTION 'Report data is required'; END IF;
  IF octet_length(p_report::text) > 65536 THEN RAISE EXCEPTION 'Report is too large'; END IF;
  -- Phase 0 stores values only: never an image or a photo of the paper.
  IF position('data:image/' in p_report::text) > 0
     OR p_report ?| array['image','images','photo','photos','image_data','photo_data','data_url','img','blob']
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_report->'results')='array' THEN p_report->'results' ELSE '[]'::jsonb END) x
                WHERE jsonb_typeof(x)='object' AND x ?| array['image','photo','image_data','photo_data','data_url','img','blob','crop']) THEN
    RAISE EXCEPTION 'Images are not accepted; enter the values only';
  END IF;

  v_id := nullif(trim(coalesce(p_report->>'id','')),'');
  v_pid := nullif(trim(coalesce(p_report->>'patient_id','')),'');
  v_op := nullif(left(trim(coalesce(p_report->>'op_id','')),80),'');
  v_action := coalesce(nullif(trim(coalesce(p_report->>'action','')),''),'save');
  IF v_id IS NULL OR v_id !~ '^[A-Za-z0-9._:-]{1,80}$' THEN RAISE EXCEPTION 'Report id is invalid'; END IF;
  IF v_pid IS NULL THEN RAISE EXCEPTION 'Patient is required'; END IF;
  IF v_action NOT IN ('save','delete') THEN RAISE EXCEPTION 'Unknown report action'; END IF;
  PERFORM 1 FROM public.patients WHERE id=v_pid;
  IF NOT FOUND THEN RAISE EXCEPTION 'Patient not found'; END IF;

  SELECT * INTO v_old FROM public.lab_reports WHERE id=v_id FOR UPDATE;
  v_exists := FOUND;
  IF v_exists AND v_old.patient_id <> v_pid THEN RAISE EXCEPTION 'This report belongs to another patient'; END IF;
  IF v_exists AND v_op IS NOT NULL AND v_old.last_op_id = v_op THEN
    RETURN jsonb_build_object('ok',true,'idempotent',true,'id',v_id,'has_critical',v_old.has_critical);
  END IF;
  IF v_exists AND v_old.deleted_at IS NOT NULL THEN
    IF v_action='delete' THEN RETURN jsonb_build_object('ok',true,'idempotent',true,'id',v_id,'deleted',true); END IF;
    RAISE EXCEPTION 'This report was removed';
  END IF;

  -- delete (soft)
  IF v_action = 'delete' THEN
    IF NOT v_exists THEN RETURN jsonb_build_object('ok',true,'idempotent',true,'id',v_id,'deleted',true); END IF;
    UPDATE public.lab_reports SET deleted_at=now(), deleted_by=v_resident_id, updated_by=v_resident_id,
      updated_by_name=v_name, updated_at=now(), last_op_id=coalesce(v_op,last_op_id)
    WHERE id=v_id;
    INSERT INTO public.lab_report_edits(report_id, patient_id, action, edited_by, edited_by_name, op_id, changes)
    VALUES (v_id, v_pid, 'delete', v_resident_id, v_name, v_op,
            jsonb_build_object('reason', left(coalesce(p_report->>'reason',''),300)));
    INSERT INTO public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
    VALUES ('labd-'||coalesce(v_op, v_id), v_pid, 'lab',
            'Investigations removed · '||array_to_string(v_old.panels,' + '),
            nullif(left(coalesce(p_report->>'reason',''),300),''), v_resident_id, now())
    ON CONFLICT (id) DO NOTHING;
    RETURN jsonb_build_object('ok',true,'idempotent',false,'id',v_id,'deleted',true);
  END IF;

  IF coalesce((p_report->>'confirmed')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Report is not confirmed';
  END IF;

  v_rep := nullif(p_report->>'reported_at','')::timestamptz;
  v_col := nullif(p_report->>'collected_at','')::timestamptz;
  IF v_rep IS NULL THEN RAISE EXCEPTION 'Report date and time are required'; END IF;
  IF v_rep > now() + interval '10 minutes' OR v_col > now() + interval '10 minutes' THEN
    RAISE EXCEPTION 'Report time is in the future';
  END IF;
  IF v_rep < '2000-01-01'::timestamptz OR v_col < '2000-01-01'::timestamptz THEN RAISE EXCEPTION 'Report date is invalid'; END IF;
  v_rep := least(v_rep, now());
  v_col := CASE WHEN v_col IS NOT NULL THEN least(v_col, now()) END;  -- least() ignores NULL
  IF v_col IS NOT NULL AND v_col > v_rep + interval '10 minutes' THEN
    RAISE EXCEPTION 'Collection time is after the report time';
  END IF;

  v_dept := coalesce(nullif(p_report->>'department',''),'other');
  IF v_dept NOT IN ('pathology','biochemistry','other') THEN RAISE EXCEPTION 'Unknown lab department'; END IF;

  v_results := p_report->'results';
  IF v_results IS NULL OR jsonb_typeof(v_results) <> 'array' OR jsonb_array_length(v_results) = 0 THEN
    RAISE EXCEPTION 'Add at least one result';
  END IF;
  IF jsonb_array_length(v_results) > 120 THEN RAISE EXCEPTION 'Too many results in one report'; END IF;

  SELECT coalesce(array_agg(left(x,40)), '{}') INTO v_panels
    FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_report->'panels')='array' THEN p_report->'panels' ELSE '[]'::jsonb END) x;
  IF cardinality(v_panels) > 20 THEN RAISE EXCEPTION 'Too many panels'; END IF;

  -- validate into a temp table, recompute critical flags
  CREATE TEMP TABLE IF NOT EXISTS _lab_new (LIKE public.lab_results) ON COMMIT DROP;
  DELETE FROM _lab_new;
  FOR v_r IN SELECT * FROM jsonb_array_elements(v_results) LOOP
    v_i := v_i + 1;
    IF jsonb_typeof(v_r) <> 'object' THEN RAISE EXCEPTION 'Result % is invalid', v_i; END IF;
    v_code := lower(trim(coalesce(v_r->>'test_code','')));
    IF v_code !~ '^[a-z0-9_]{1,40}$' THEN RAISE EXCEPTION 'Result % has an invalid test code', v_i; END IF;
    IF v_code = ANY(v_codes) THEN RAISE EXCEPTION 'Test % appears twice', v_code; END IF;
    v_codes := v_codes || v_code;
    IF nullif(trim(coalesce(v_r->>'test_name_printed','')),'') IS NULL THEN RAISE EXCEPTION 'Result % needs a test name', v_i; END IF;
    BEGIN
      v_num := nullif(v_r->>'value_num','')::numeric;
      v_lo := nullif(v_r->>'ref_low','')::numeric;
      v_hi := nullif(v_r->>'ref_high','')::numeric;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Result % has a non-numeric value', v_i; END;
    v_txt := nullif(trim(coalesce(v_r->>'value_text','')),'');
    IF v_num IS NULL AND v_txt IS NULL THEN RAISE EXCEPTION 'Result % (%) has no value', v_i, v_code; END IF;
    IF v_code = 'plt' AND v_num IS NOT NULL AND (v_num < 1000 OR v_num > 2000000) THEN
      RAISE EXCEPTION 'Platelets must be stored per µL';
    END IF;
    IF v_code = 'wbc' AND v_num IS NOT NULL AND (v_num < 100 OR v_num > 500000) THEN
      RAISE EXCEPTION 'WBC must be stored per µL';
    END IF;
    v_flag := nullif(v_r->>'flag','');
    IF v_flag IS NOT NULL AND v_flag NOT IN ('H','L','A','CRIT_H','CRIT_L','URGENT') THEN RAISE EXCEPTION 'Result % has an unknown flag', v_i; END IF;
    v_state := nullif(v_r->>'field_state','');
    IF v_state IS NOT NULL AND v_state NOT IN ('green','amber','red') THEN RAISE EXCEPTION 'Result % has an unknown state', v_i; END IF;
    v_conf := coalesce((v_r->>'confirmed')::boolean, false);
    v_crit := public.ward_lab_critical(v_code, v_num);
    IF v_crit IS NOT NULL THEN
      v_flag := v_crit;
    ELSIF v_flag IN ('CRIT_H','CRIT_L','URGENT') THEN
      v_flag := CASE WHEN v_hi IS NOT NULL AND v_num > v_hi THEN 'H' WHEN v_lo IS NOT NULL AND v_num < v_lo THEN 'L' END;
    END IF;
    IF (v_crit IS NOT NULL OR v_state = 'red') AND NOT v_conf THEN
      RAISE EXCEPTION 'Confirm % against the paper before saving', coalesce(v_r->>'test_name_printed', v_code);
    END IF;
    IF v_crit IS NOT NULL THEN v_ncrit := v_ncrit + 1; END IF;
    INSERT INTO _lab_new(id, report_id, patient_id, test_code, test_name_printed, value_num, value_text, unit,
      value_printed, unit_printed, ref_low, ref_high, ref_text, ref_tiers, value_low, value_high, page_no, flag,
      tier_label, ocr_value, ocr_conf, field_state, confirmed, edited, sort_order)
    VALUES (v_id||'-'||v_code, v_id, v_pid, v_code, left(trim(v_r->>'test_name_printed'),120), v_num, left(v_txt,200),
      nullif(left(coalesce(v_r->>'unit',''),40),''),
      nullif(left(coalesce(v_r->>'value_printed',''),60),''), nullif(left(coalesce(v_r->>'unit_printed',''),40),''),
      v_lo, v_hi, nullif(left(coalesce(v_r->>'ref_text',''),200),''),
      CASE WHEN jsonb_typeof(v_r->'ref_tiers') IN ('array','object') THEN v_r->'ref_tiers' END,
      nullif(v_r->>'value_low','')::numeric, nullif(v_r->>'value_high','')::numeric,
      nullif(v_r->>'page_no','')::smallint, v_flag, nullif(left(coalesce(v_r->>'tier_label',''),60),''),
      NULL, NULL, v_state, v_conf, coalesce((v_r->>'edited')::boolean,false), coalesce(nullif(v_r->>'sort_order','')::int, v_i));
  END LOOP;

  v_plabel := coalesce(nullif(array_to_string(v_panels,' + '),''), 'Report');

  IF NOT v_exists THEN
    INSERT INTO public.lab_reports(id, patient_id, lab, department, template_id, sample_no, report_status, match_status,
      sample_type, collected_at, reported_at, entry_method, has_critical, panels, confirmed,
      created_by, created_by_name, created_at, updated_by, updated_by_name, updated_at, last_op_id)
    VALUES (v_id, v_pid, coalesce(nullif(left(p_report->>'lab',60),''),'AMCH'), v_dept,
      nullif(left(coalesce(p_report->>'template_id',''),60),''), nullif(left(trim(coalesce(p_report->>'sample_no','')),40),''),
      CASE WHEN p_report->>'report_status'='provisional' THEN 'provisional' ELSE 'final' END, 'card',
      nullif(left(coalesce(p_report->>'sample_type',''),40),''), v_col, v_rep, 'manual', v_ncrit > 0, v_panels, true,
      v_resident_id, v_name, least(coalesce(nullif(p_report->>'created_at','')::timestamptz, now()), now()),
      v_resident_id, v_name, now(), v_op);
    INSERT INTO public.lab_results SELECT * FROM _lab_new;
    SELECT string_agg(test_name_printed||' '||coalesce(value_text, trim_scale(value_num)::text)||coalesce(' '||unit,'')||
             CASE WHEN flag IN ('CRIT_H','CRIT_L','URGENT') THEN ' (critical)' ELSE ' ('||flag||')' END, '; ' ORDER BY sort_order)
      INTO v_detail FROM _lab_new WHERE flag IS NOT NULL;
    v_title := 'Investigations added · '||v_plabel||CASE WHEN v_ncrit>0 THEN ' · '||v_ncrit||' critical' ELSE '' END;
    INSERT INTO public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
    VALUES ('lab-'||coalesce(v_op, v_id), v_pid, 'lab', left(v_title,200), left(coalesce(v_detail,'All values within range'),1000), v_resident_id, now())
    ON CONFLICT (id) DO NOTHING;
    RETURN jsonb_build_object('ok',true,'idempotent',false,'id',v_id,'created',true,'has_critical',v_ncrit>0);
  END IF;

  -- edit: diff old vs new
  FOR v_o IN SELECT o.test_code, o.test_name_printed, o.value_num, o.value_text, o.unit,
                    n.test_name_printed n_name, n.value_num n_num, n.value_text n_text, n.unit n_unit, n.test_code n_code
               FROM (SELECT * FROM public.lab_results WHERE report_id=v_id) o FULL JOIN _lab_new n ON n.test_code=o.test_code
              ORDER BY coalesce(n.sort_order, o.sort_order) LOOP
    IF v_o.test_code IS NULL THEN
      v_diff := v_diff || ('+ '||v_o.n_name||' '||coalesce(v_o.n_text, trim_scale(v_o.n_num)::text)||coalesce(' '||v_o.n_unit,''));
      v_changes := v_changes || jsonb_build_object('test',v_o.n_code,'old',null,'new',coalesce(v_o.n_text, trim_scale(v_o.n_num)::text),'unit',v_o.n_unit);
    ELSIF v_o.n_code IS NULL THEN
      v_diff := v_diff || ('removed '||v_o.test_name_printed);
      v_changes := v_changes || jsonb_build_object('test',v_o.test_code,'old',coalesce(v_o.value_text, trim_scale(v_o.value_num)::text),'new',null,'unit',v_o.unit);
    ELSIF v_o.value_num IS DISTINCT FROM v_o.n_num OR v_o.value_text IS DISTINCT FROM v_o.n_text OR v_o.unit IS DISTINCT FROM v_o.n_unit THEN
      v_diff := v_diff || (v_o.n_name||' '||coalesce(v_o.value_text, trim_scale(v_o.value_num)::text)||' → '||coalesce(v_o.n_text, trim_scale(v_o.n_num)::text)||coalesce(' '||v_o.n_unit,''));
      v_changes := v_changes || jsonb_build_object('test',v_o.test_code,'old',coalesce(v_o.value_text, trim_scale(v_o.value_num)::text),'new',coalesce(v_o.n_text, trim_scale(v_o.n_num)::text),'unit',v_o.n_unit);
    END IF;
  END LOOP;
  IF v_old.reported_at IS DISTINCT FROM v_rep THEN
    v_diff := v_diff || ('report time '||to_char(v_old.reported_at at time zone 'Asia/Kolkata','DD Mon HH24:MI')||' → '||to_char(v_rep at time zone 'Asia/Kolkata','DD Mon HH24:MI'));
    v_changes := v_changes || jsonb_build_object('field','reported_at','old',v_old.reported_at,'new',v_rep);
  END IF;
  IF v_old.collected_at IS DISTINCT FROM v_col THEN
    v_changes := v_changes || jsonb_build_object('field','collected_at','old',v_old.collected_at,'new',v_col);
    v_diff := v_diff || 'collection time changed'::text;
  END IF;
  IF v_old.sample_no IS DISTINCT FROM nullif(left(trim(coalesce(p_report->>'sample_no','')),40),'') THEN
    v_changes := v_changes || jsonb_build_object('field','sample_no','old',v_old.sample_no,'new',nullif(left(trim(coalesce(p_report->>'sample_no','')),40),''));
    v_diff := v_diff || ('sample no '||coalesce(v_old.sample_no,'—')||' → '||coalesce(nullif(trim(coalesce(p_report->>'sample_no','')),''),'—'));
  END IF;
  IF v_old.department IS DISTINCT FROM v_dept THEN
    v_changes := v_changes || jsonb_build_object('field','department','old',v_old.department,'new',v_dept);
    v_diff := v_diff || ('lab '||v_old.department||' → '||v_dept);
  END IF;

  DELETE FROM public.lab_results WHERE report_id=v_id;
  INSERT INTO public.lab_results SELECT * FROM _lab_new;
  UPDATE public.lab_reports SET
    lab=coalesce(nullif(left(p_report->>'lab',60),''),lab), department=v_dept,
    template_id=nullif(left(coalesce(p_report->>'template_id',''),60),''),
    sample_no=nullif(left(trim(coalesce(p_report->>'sample_no','')),40),''),
    report_status=CASE WHEN p_report->>'report_status'='provisional' THEN 'provisional' ELSE 'final' END,
    sample_type=nullif(left(coalesce(p_report->>'sample_type',''),40),''),
    collected_at=v_col, reported_at=v_rep, has_critical=v_ncrit>0, panels=v_panels, confirmed=true,
    updated_by=v_resident_id, updated_by_name=v_name, updated_at=now(), last_op_id=coalesce(v_op,last_op_id),
    edit_count=edit_count + CASE WHEN cardinality(v_diff)>0 THEN 1 ELSE 0 END
  WHERE id=v_id;

  IF cardinality(v_diff) > 0 THEN
    INSERT INTO public.lab_report_edits(report_id, patient_id, action, edited_by, edited_by_name, op_id, changes)
    VALUES (v_id, v_pid, 'edit', v_resident_id, v_name, v_op, v_changes);
    v_title := 'Investigations edited · '||v_plabel||
      CASE WHEN v_ncrit>0 AND NOT v_old.has_critical THEN ' · '||v_ncrit||' critical' ELSE '' END;
    INSERT INTO public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
    VALUES ('labe-'||coalesce(v_op, v_id||'-'||(v_old.edit_count+1)::text), v_pid, 'lab', left(v_title,200),
            left(array_to_string(v_diff,'; '),1000), v_resident_id, now())
    ON CONFLICT (id) DO NOTHING;
  END IF;
  RETURN jsonb_build_object('ok',true,'idempotent',false,'id',v_id,'created',false,'changed',cardinality(v_diff)>0,'has_critical',v_ncrit>0);
END
$function$;

revoke all on function public.ward_save_lab_report(uuid,jsonb) from public;
grant execute on function public.ward_save_lab_report(uuid,jsonb) to anon, authenticated, service_role;
revoke all on function public.ward_lab_critical(text,numeric) from public;
grant execute on function public.ward_lab_critical(text,numeric) to anon, authenticated, service_role;

-- shape shared by read-state and history: report + nested results (deleted reports come back as tombstones)
CREATE OR REPLACE FUNCTION public.ward_lab_report_json(p_id text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select case when r.deleted_at is not null then
      jsonb_build_object('id',r.id,'patient_id',r.patient_id,'deleted_at',r.deleted_at,'reported_at',r.reported_at)
    else to_jsonb(r) - 'last_op_id' - 'ocr_engine' - 'ocr_mean_conf' || jsonb_build_object('results',
      coalesce((select jsonb_agg(to_jsonb(x) - 'ocr_value' - 'ocr_conf' - 'report_id' - 'patient_id' order by x.sort_order, x.test_code)
                from public.lab_results x where x.report_id=r.id),'[]'::jsonb)) end
  from public.lab_reports r where r.id=p_id
$function$;
revoke all on function public.ward_lab_report_json(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. ward_read_lab_history: every report of one patient (record page, "All reports")
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ward_read_lab_history(p_token uuid, p_patient_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_res text;
BEGIN
  SELECT s.resident_id INTO v_res FROM public.ward_sessions s JOIN public.residents r ON r.id=s.resident_id
   WHERE s.token=p_token AND s.expires_at>now() AND r.active=true;
  IF v_res IS NULL THEN RAISE EXCEPTION 'Invalid or expired ward session'; END IF;
  RETURN jsonb_build_object('ok',true,'patient_id',p_patient_id,'lab_reports',
    coalesce((select jsonb_agg(public.ward_lab_report_json(r.id) order by coalesce(r.collected_at,r.reported_at) desc, r.id)
              from public.lab_reports r where r.patient_id=p_patient_id),'[]'::jsonb));
END
$function$;
revoke all on function public.ward_read_lab_history(uuid,text) from public;
grant execute on function public.ward_read_lab_history(uuid,text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. ward_read_ward_state: + lab_reports
-- ---------------------------------------------------------------------------
do $$
declare v_def text;
  a_decl text := 'v_mse jsonb; v_dcert jsonb;';
  a_ret text := '''mse_entries'', v_mse, ''discharge_certificates'', v_dcert';
  a_sel text := E'  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc, m.id), ''[]''::jsonb) into v_mse from (';
begin
  select pg_get_functiondef('public.ward_read_ward_state(uuid)'::regprocedure) into v_def;
  if position('v_labs jsonb' in v_def) > 0 then raise notice 'ward_read_ward_state already has lab_reports'; return; end if;
  if position(a_decl in v_def) = 0 or position(a_ret in v_def) = 0 or position(a_sel in v_def) = 0 then
    raise exception 'ward_read_ward_state anchor not found; apply r1_3_126 first';
  end if;
  v_def := replace(v_def, a_decl, a_decl || ' v_labs jsonb;');
  v_def := replace(v_def, a_sel,
    E'  -- R1.3.128: lab reports of on-ward patients'' current admission, plus any report from the last 14 days\n'
    || E'  select coalesce(jsonb_agg(public.ward_lab_report_json(lr.id) order by coalesce(lr.collected_at, lr.reported_at) desc, lr.id), ''[]''::jsonb) into v_labs\n'
    || E'  from public.lab_reports lr join public.patients pp on pp.id=lr.patient_id\n'
    || E'  where (lr.deleted_at is null or lr.deleted_at > now() - interval ''14 days'')\n'
    || E'    and (coalesce(lr.collected_at, lr.reported_at) > now() - interval ''14 days''\n'
    || E'         or (coalesce(pp.active_status,''admitted'') <> ''discharged'' and coalesce(lr.collected_at, lr.reported_at) >= pp.admitted_at - interval ''2 days''));\n\n'
    || a_sel);
  v_def := replace(v_def, a_ret, a_ret || ', ''lab_reports'', v_labs');
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- 6. backup and archive
-- ---------------------------------------------------------------------------
do $$
declare v_def text;
  v_anchor text := '''discharge_mode'',p.discharge_mode,''discharge_requested_by'',p.discharge_requested_by,''discharge_requester_name'',p.discharge_requester_name,''bed'',b.bed_number';
  v_anchor2 text := '''ect_planned'', (select count(*) from ect_plans where status=''planned'')';
begin
  select pg_get_functiondef('public.ward_create_nightly_backup(uuid)'::regprocedure) into v_def;
  if position('lab_reports' in v_def) > 0 then raise notice 'backup already patched'; return; end if;
  if position(v_anchor in v_def) = 0 or position(v_anchor2 in v_def) = 0 then raise notice 'ward_create_nightly_backup anchor not found; skipped'; return; end if;
  v_def := replace(v_def, v_anchor, '''mrd_no'',p.mrd_no,' || v_anchor);
  v_def := replace(v_def, v_anchor2, v_anchor2 || E',\n    ''lab_reports'', (select count(*) from lab_reports where deleted_at is null),\n    ''lab_reports_7d'', (select count(*) from lab_reports where deleted_at is null and created_at > now() - interval ''7 days''),\n    ''lab_reports_critical_7d'', (select count(*) from lab_reports where deleted_at is null and has_critical and created_at > now() - interval ''7 days'')');
  execute v_def;
end $$;

do $$
declare v_def text;
  v_anchor text := '''activity_log'', coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from activity_log x where x.patient_id=p.id),''[]'')';
  v_reg text := 'select id, hospital_no, patient_code,';
begin
  select pg_get_functiondef('public.ward_archive_month(text)'::regprocedure) into v_def;
  if position('lab_reports' in v_def) > 0 then raise notice 'archive already patched'; return; end if;
  if position(v_anchor in v_def) = 0 then raise notice 'ward_archive_month anchor not found; skipped'; return; end if;
  if position(v_reg in v_def) > 0 then
    v_def := replace(v_def, v_reg, 'select id, hospital_no, mrd_no, patient_code,');
  else
    raise notice 'ward_archive_month register anchor not found; mrd_no not added to register';
  end if;
  v_def := replace(v_def, v_anchor,
    '''lab_reports'', coalesce((select jsonb_agg(to_jsonb(x)||jsonb_build_object(''results'',coalesce((select jsonb_agg(to_jsonb(y) order by y.sort_order) from lab_results y where y.report_id=x.id),''[]'')) order by coalesce(x.collected_at,x.reported_at)) from lab_reports x where x.patient_id=p.id),''[]''),'
    || E'\n      ''lab_report_edits'', coalesce((select jsonb_agg(to_jsonb(x) order by x.edited_at) from lab_report_edits x where x.patient_id=p.id),''[]''),'
    || E'\n      ' || v_anchor);
  execute v_def;
end $$;

-- ---------------------------------------------------------------------------
-- 7. undo admission (R1.3.127): count lab reports as clinical data added after the admission
-- ---------------------------------------------------------------------------
do $$
declare v_def text;
  v_anchor text := '''progress_notes'',''risk_assessments'',''tasks''';
begin
  if to_regprocedure('public.ward_admission_counts(text)') is null then
    raise exception 'ward_admission_counts not found; apply r1_3_127_undo_admission first';
  end if;
  select pg_get_functiondef('public.ward_admission_counts(text)'::regprocedure) into v_def;
  if position('''lab_reports''' in v_def) > 0 then raise notice 'ward_admission_counts already counts lab_reports'; return; end if;
  if position(v_anchor in v_def) = 0 then raise exception 'ward_admission_counts anchor not found'; end if;
  v_def := replace(v_def, v_anchor, '''lab_reports'',' || v_anchor);
  execute v_def;
end $$;
revoke all on function public.ward_admission_counts(text) from public, anon, authenticated;
grant execute on function public.ward_admission_counts(text) to service_role;
-- friendly name in the 'undo is blocked' message
do $$
declare v_def text;
  v_anchor text := '{"activity_log":"timeline entries",';
begin
  select pg_get_functiondef('public.ward_undo_admission(uuid,text,uuid,jsonb)'::regprocedure) into v_def;
  if position('"lab_reports":' in v_def) > 0 then raise notice 'ward_undo_admission already labels lab_reports'; return; end if;
  if position(v_anchor in v_def) = 0 then raise notice 'ward_undo_admission label anchor not found; label skipped'; return; end if;
  v_def := replace(v_def, v_anchor, v_anchor || '"lab_reports":"an investigations report",');
  execute v_def;
end $$;
revoke all on function public.ward_undo_admission(uuid,text,uuid,jsonb) from public;
grant execute on function public.ward_undo_admission(uuid,text,uuid,jsonb) to anon, authenticated, service_role;


notify pgrst, 'reload schema';
