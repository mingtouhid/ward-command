-- R1.3.134 · Lab report scanning (OCR) · phase 1
-- APPLIED 27 Oct 2026 17:02 IST as migration 20261027113205 r1_3_134_lab_ocr_phase1 (BEGIN/COMMIT stripped). Rollback at the bottom.
-- What it does:
--   * lab_report_edits.source ('manual' | 'ocr', default 'manual'); action may now be 'create' (a scanned report's audit row)
--   * lab_reports.ocr_stats (jsonb, < 2 KB) and lab_reports.match_reason (text, <= 300)
--   * ward_save_lab_report: accepts entry_method 'ocr' with a NAME check (exact | probable_confirmed | override + reason),
--     keeps per-value ocr_value / ocr_conf, stores engine, mean confidence, stats, page fields and the sample number;
--     rejects any string over 2 KB; activity row says "Investigations added (scanned)".
--   * Hospital numbers are NOT extracted, matched or stored by the scanner (hosp_no columns stay unused).
--   * Manual entry behaves exactly as in R1.3.133.

BEGIN;

ALTER TABLE public.lab_report_edits ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'manual';
ALTER TABLE public.lab_report_edits DROP CONSTRAINT IF EXISTS lab_report_edits_source_check;
ALTER TABLE public.lab_report_edits ADD CONSTRAINT lab_report_edits_source_check CHECK (source IN ('manual','ocr'));
ALTER TABLE public.lab_report_edits DROP CONSTRAINT IF EXISTS lab_report_edits_action_check;
ALTER TABLE public.lab_report_edits ADD CONSTRAINT lab_report_edits_action_check CHECK (action IN ('create','edit','delete'));

ALTER TABLE public.lab_reports ADD COLUMN IF NOT EXISTS ocr_stats jsonb;
ALTER TABLE public.lab_reports ADD COLUMN IF NOT EXISTS match_reason text;
ALTER TABLE public.lab_reports DROP CONSTRAINT IF EXISTS lab_reports_ocr_stats_check;
ALTER TABLE public.lab_reports ADD CONSTRAINT lab_reports_ocr_stats_check CHECK (ocr_stats IS NULL OR (jsonb_typeof(ocr_stats)='object' AND pg_column_size(ocr_stats) < 2048));
ALTER TABLE public.lab_reports DROP CONSTRAINT IF EXISTS lab_reports_match_reason_check;
ALTER TABLE public.lab_reports ADD CONSTRAINT lab_reports_match_reason_check CHECK (match_reason IS NULL OR length(match_reason) <= 300);

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
  v_entry text := 'manual'; v_match text := 'card'; v_reason text; v_printed text; v_stats jsonb;
  v_engine text; v_mconf numeric; v_pcount smallint; v_ppresent smallint[]; v_ocrc numeric;
BEGIN
  SELECT s.resident_id, lower(coalesce(r.role,'')), coalesce(r.display_name, r.username)
    INTO v_resident_id, v_role, v_name
  FROM public.ward_sessions s JOIN public.residents r ON r.id=s.resident_id
  WHERE s.token=p_token AND s.expires_at>now() AND r.active=true;
  IF v_resident_id IS NULL THEN RAISE EXCEPTION 'Invalid or expired ward session'; END IF;
  IF v_role IN ('consultant','viewer') THEN RAISE EXCEPTION 'This role cannot perform clinical writes'; END IF;

  IF p_report IS NULL OR jsonb_typeof(p_report) <> 'object' THEN RAISE EXCEPTION 'Report data is required'; END IF;
  IF octet_length(p_report::text) > 65536 THEN RAISE EXCEPTION 'Report is too large'; END IF;
  -- R1.3.134: no single text value over 2 KB anywhere in the payload (blocks pasted images / blobs under any key)
  IF EXISTS (SELECT 1 FROM jsonb_path_query(p_report, 'lax $.**') j WHERE jsonb_typeof(j)='string' AND octet_length(j #>> '{}') > 2048) THEN
    RAISE EXCEPTION 'A text field is too long';
  END IF;
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

  -- R1.3.134: scanned (OCR) reports. The patient is matched on the printed NAME only (never the hospital number).
  v_entry := coalesce(nullif(p_report->>'entry_method',''),'manual');
  IF v_entry NOT IN ('manual','ocr') THEN RAISE EXCEPTION 'Unknown entry method'; END IF;
  IF v_entry = 'ocr' THEN
    v_match := coalesce(nullif(p_report->>'match_status',''),'');
    IF v_match NOT IN ('exact','probable_confirmed','override') THEN RAISE EXCEPTION 'A scanned report needs the patient name check'; END IF;
    v_reason := nullif(left(trim(coalesce(p_report->>'match_reason','')),300),'');
    IF v_match = 'override' AND (v_reason IS NULL OR length(v_reason) < 3) THEN RAISE EXCEPTION 'Using a report for another name needs a reason'; END IF;
    IF v_match <> 'override' THEN v_reason := NULL; END IF;
    v_printed := CASE WHEN v_match='override' THEN nullif(left(trim(coalesce(p_report->>'name_printed','')),80),'') END;
    v_stats := CASE WHEN jsonb_typeof(p_report->'ocr_stats')='object' THEN p_report->'ocr_stats' END;
    IF v_stats IS NOT NULL AND pg_column_size(v_stats) >= 2048 THEN RAISE EXCEPTION 'Scan statistics are too large'; END IF;
    v_engine := nullif(left(trim(coalesce(p_report->>'ocr_engine','')),120),'');
    BEGIN
      v_mconf := nullif(p_report->>'ocr_mean_conf','')::numeric;
      IF v_mconf IS NOT NULL THEN v_mconf := greatest(0, least(100, v_mconf)); END IF;  -- least/greatest ignore NULL
      v_pcount := nullif(p_report->>'page_count','')::smallint;
      SELECT array_agg(x::smallint) INTO v_ppresent FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_report->'pages_present')='array' THEN p_report->'pages_present' ELSE '[]'::jsonb END) x;
    EXCEPTION WHEN others THEN RAISE EXCEPTION 'Scan details are invalid'; END;
    IF v_pcount IS NOT NULL AND (v_pcount < 1 OR v_pcount > 20) THEN v_pcount := NULL; END IF;
  END IF;

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
  DELETE FROM _lab_new WHERE true; -- R1.3.129: explicit WHERE for safeupdate
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
    v_ocrc := NULL;
    IF v_entry = 'ocr' THEN
      BEGIN v_ocrc := nullif(v_r->>'ocr_conf','')::numeric; EXCEPTION WHEN others THEN v_ocrc := NULL; END;
      IF v_ocrc IS NOT NULL THEN v_ocrc := greatest(0, least(100, v_ocrc)); END IF;
    END IF;
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
      CASE WHEN v_entry='ocr' THEN nullif(left(coalesce(v_r->>'ocr_value',''),60),'') END, v_ocrc, v_state, v_conf, coalesce((v_r->>'edited')::boolean,false), coalesce(nullif(v_r->>'sort_order','')::int, v_i));
  END LOOP;

  v_plabel := coalesce(nullif(array_to_string(v_panels,' + '),''), 'Report');

  IF NOT v_exists THEN
    INSERT INTO public.lab_reports(id, patient_id, lab, department, template_id, sample_no, report_status, match_status,
      sample_type, collected_at, reported_at, entry_method, has_critical, panels, confirmed,
      created_by, created_by_name, created_at, updated_by, updated_by_name, updated_at, last_op_id,
      ocr_engine, ocr_mean_conf, ocr_stats, page_count, pages_present, match_reason)
    VALUES (v_id, v_pid, coalesce(nullif(left(p_report->>'lab',60),''),'AMCH'), v_dept,
      nullif(left(coalesce(p_report->>'template_id',''),60),''), nullif(left(trim(coalesce(p_report->>'sample_no','')),40),''),
      CASE WHEN p_report->>'report_status'='provisional' THEN 'provisional' ELSE 'final' END, v_match,
      nullif(left(coalesce(p_report->>'sample_type',''),40),''), v_col, v_rep, v_entry, v_ncrit > 0, v_panels, true,
      v_resident_id, v_name, least(coalesce(nullif(p_report->>'created_at','')::timestamptz, now()), now()),
      v_resident_id, v_name, now(), v_op,
      CASE WHEN v_entry='ocr' THEN v_engine END, CASE WHEN v_entry='ocr' THEN v_mconf END, v_stats,
      CASE WHEN v_entry='ocr' THEN v_pcount END, CASE WHEN v_entry='ocr' THEN v_ppresent END, v_reason);
    IF v_entry = 'ocr' THEN
      INSERT INTO public.lab_report_edits(report_id, patient_id, action, source, edited_by, edited_by_name, op_id, changes)
      VALUES (v_id, v_pid, 'create', 'ocr', v_resident_id, v_name, v_op,
              jsonb_strip_nulls(jsonb_build_object('match_status', v_match, 'name_override', v_match='override',
                                                   'reason', v_reason, 'printed_name', v_printed)));
    END IF;
    INSERT INTO public.lab_results SELECT * FROM _lab_new;
    SELECT string_agg(test_name_printed||' '||coalesce(value_text, trim_scale(value_num)::text)||coalesce(' '||unit,'')||
             CASE WHEN flag IN ('CRIT_H','CRIT_L','URGENT') THEN ' (critical)' ELSE ' ('||flag||')' END, '; ' ORDER BY sort_order)
      INTO v_detail FROM _lab_new WHERE flag IS NOT NULL;
    v_title := 'Investigations added'||CASE WHEN v_entry='ocr' THEN ' (scanned)' ELSE '' END||' · '||v_plabel||CASE WHEN v_ncrit>0 THEN ' · '||v_ncrit||' critical' ELSE '' END;
    INSERT INTO public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
    VALUES ('lab-'||coalesce(v_op, v_id), v_pid, 'lab', left(v_title,200),
            left(coalesce(v_detail,'All values within range')||CASE WHEN v_match='override' THEN E'\nName override: '||v_reason ELSE '' END,1000), v_resident_id, now())
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

  -- R1.3.134: keep what the scanner originally read, so later edits stay auditable
  UPDATE _lab_new n SET ocr_value=o.ocr_value, ocr_conf=o.ocr_conf
    FROM public.lab_results o WHERE o.report_id=v_id AND o.test_code=n.test_code AND o.ocr_value IS NOT NULL;
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
$function$
;

COMMIT;

-- ===================================================================================================
-- ROLLBACK (run as one block). Restores the R1.3.133 function exactly; drops the new columns/constraints.
-- Run only if no scanned reports need keeping (their audit rows use action 'create').
-- ===================================================================================================
/*
BEGIN;
DELETE FROM public.lab_report_edits WHERE action = 'create';
ALTER TABLE public.lab_report_edits DROP CONSTRAINT IF EXISTS lab_report_edits_action_check;
ALTER TABLE public.lab_report_edits ADD CONSTRAINT lab_report_edits_action_check CHECK (action IN ('edit','delete'));
ALTER TABLE public.lab_report_edits DROP CONSTRAINT IF EXISTS lab_report_edits_source_check;
ALTER TABLE public.lab_report_edits DROP COLUMN IF EXISTS source;
ALTER TABLE public.lab_reports DROP CONSTRAINT IF EXISTS lab_reports_ocr_stats_check;
ALTER TABLE public.lab_reports DROP CONSTRAINT IF EXISTS lab_reports_match_reason_check;
ALTER TABLE public.lab_reports DROP COLUMN IF EXISTS ocr_stats;
ALTER TABLE public.lab_reports DROP COLUMN IF EXISTS match_reason;
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
  DELETE FROM _lab_new WHERE true; -- R1.3.129: explicit WHERE for safeupdate
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
$function$
;
COMMIT;
*/
