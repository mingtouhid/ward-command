-- =====================================================================================================================
-- Ward Sync - monthly archive v2 ROLLBACK                       20261102_archive_v2-rollback.sql
-- Restores the live R1.6 ward_save_discharge_certificate (md5 f5387043f90a426dca900bdab99b192b) and drops the new
-- archive functions. Keeps the new columns (harmless to R1.6 / R1.6.1 apps and to the v1 edge function); they are
-- dropped only by the commented block at the end. No UPDATE/DELETE (pg-safeupdate safe); no BEGIN/COMMIT.
-- If the edge function is also rolled back, restore the v1 source (backup: ma_src.ts, md5 c0fc143b9d4aee7fe1f80f6366c800ed).
-- =====================================================================================================================

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
$function$
;

drop function if exists public.ward_archive_rerun_reset(uuid, jsonb);
drop function if exists public.ward_archive_rerun_claim(text, integer);
drop function if exists public.ward_archive_state(text);

-- Optional, only when no v2 archive should ever be read again (history keeps the v1 file list of re-run months):
-- alter table public.discharge_certificates drop column if exists printed_render;
-- alter table public.discharge_certificates drop column if exists printed_fmt;
-- alter table public.discharge_certificates drop column if exists printed_app_version;
-- alter table public.archive_manifest drop column if exists history;
-- alter table public.archive_manifest drop column if exists archive_version;
