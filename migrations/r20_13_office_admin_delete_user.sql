-- Applied to production 2026-11-21 ~16:18 IST.
-- Read-only reconstruction of the live objects. Do not re-run against production.
-- A one-off delete of 11 inactive test/legacy accounts was run at the same time.
-- Those accounts had no clinical references. Their rows were archived in
-- private.deleted_accounts_archive before the resident row was removed.

BEGIN;

CREATE TABLE IF NOT EXISTS private.deleted_accounts_archive (
  id text PRIMARY KEY,
  username text NOT NULL,
  display_name text,
  role text,
  designation text,
  email text,
  bdft_batch text,
  bdft_short text,
  bdft_order integer,
  created_at timestamptz,
  deleted_at timestamptz NOT NULL DEFAULT now(),
  deleted_by text NOT NULL,
  cleanup jsonb NOT NULL DEFAULT '{}'::jsonb
);

ALTER TABLE private.deleted_accounts_archive ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.deleted_accounts_archive FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.office_admin_delete_user(p_token uuid, p_username text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  v_actor text;
  v_id text;
begin
  v_actor := private.require_office_admin(p_token);
  select id into v_id from public.residents where lower(username) = lower(btrim(coalesce(p_username,'')));
  if v_id is null then raise exception 'User not found' using errcode='P0002'; end if;
  return private.delete_resident_account(v_id, v_actor);
end;
$function$;

REVOKE ALL ON FUNCTION public.office_admin_delete_user(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.office_admin_delete_user(uuid, text) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION private.delete_resident_account(p_id text, p_actor text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
declare
  r public.residents%rowtype;
  v_block jsonb := '{}'::jsonb;
  v_counts jsonb := '{}'::jsonb;
  v_n bigint;
  c record;
  c record;
  v_checks text[][] := array[
    ['public','patients','updated_by'],['public','patients','consultant_id'],['public','patients','consultant_id_2'],
    ['public','patient_bed_assignments','assigned_by'],['public','patient_snapshots','updated_by'],
    ['public','risk_assessments','updated_by'],['public','progress_notes','author_id'],
    ['public','ect_sessions','recorded_by'],['public','ect_plans','created_by'],
    ['public','medication_orders','created_by'],['public','medication_doses','given_by'],
    ['public','medication_changes','changed_by'],['public','prn_records','given_by'],
    ['public','tasks','assigned_to'],['public','tasks','created_by'],
    ['public','handovers','from_id'],['public','handovers','to_id'],['public','handovers','acknowledged_by'],
    ['public','discharge_checks','completed_by'],['public','activity_log','actor_id'],
    ['public','lab_reports','created_by'],['public','lab_reports','updated_by'],['public','lab_reports','deleted_by'],
    ['public','lab_report_edits','edited_by'],['public','mse_entries','created_by'],['public','mse_entries','deleted_by'],
    ['public','ward_broadcasts','sender_id'],['public','ward_broadcasts','deleted_by'],
    ['public','critical_status_updates','created_by'],['public','patient_edits','edited_by'],
    ['public','discharge_certificates','printed_by'],['public','discharge_certificates','updated_by'],
    ['public','discharge_edit_versions','edited_by'],['public','observation_stays','started_by'],
    ['public','observation_stays','ended_by'],['public','ward_duty','resident_id'],
    ['public','patient_advice','issued_by'],['public','patient_advice','removed_by'],
    ['public','patient_advice_acks','resident_id'],['public','patient_vitals','recorded_by'],
    ['public','scale_assessments','rated_by'],['public','scale_assessments','deleted_by'],['public','scale_assessments','restored_by'],
    ['public','admission_undo','admitted_by'],['public','admission_undo','resolved_by'],
    ['public','discharge_review_overrides','resident_id'],['public','ect_schedule_completions','completed_by'],
    ['public','ect_schedule_completions','undone_by'],['public','intern_assignments','assigned_by'],
    ['public','intern_assignments','completed_by'],['public','patients','referred_by'],
    ['public','ward_se_logs','recorded_by'],['public','ward_backups','created_by'],
    ['public','bdft_rows','owner_id'],['public','bdft_distributions','created_by'],
    ['public','bdft_distributions','updated_by'],['public','bdft_distributions','replaced_by'],
    ['public','resident_phone_audit','actor_id'],
    ['private','duty_rosters','created_by'],['private','duty_rosters','updated_by'],
    ['private','duty_rosters','reviewed_by'],['private','duty_rosters','published_by'],
    ['private','office_admin_pgt_group_members','resident_id'],['private','office_admin_pgt_group_sets','created_by']
  ];
  i int;
begin
  select * into r from public.residents where id = p_id for update;
  if r.id is null then raise exception 'User not found' using errcode='P0002'; end if;
  if r.role = 'admin' then raise exception 'Admin accounts cannot be deleted here' using errcode='42501'; end if;
  if r.active then raise exception 'Deactivate the account before deleting it' using errcode='42501'; end if;
  if r.id = p_actor then raise exception 'You cannot delete your own account' using errcode='42501'; end if;

  for i in 1 .. array_length(v_checks,1) loop
    execute format('select count(*) from %I.%I where %I = $1', v_checks[i][1], v_checks[i][2], v_checks[i][3])
      into v_n using r.id;
    if v_n > 0 then v_block := v_block || jsonb_build_object(v_checks[i][2]||'.'||v_checks[i][3], v_n); end if;
  end loop;
  select count(*) into v_n from public.patients where r.id = any(discharge_requested_by);
  if v_n > 0 then v_block := v_block || jsonb_build_object('patients.discharge_requested_by', v_n); end if;
  select count(*) into v_n from private.duty_rosters where content::text like '%"'||r.id||'"%';
  if v_n > 0 then v_block := v_block || jsonb_build_object('duty_rosters.content', v_n); end if;
  select count(*) into v_n from private.office_admin_pgt_group_sets where groups::text like '%"'||r.id||'"%';
  if v_n > 0 then v_block := v_block || jsonb_build_object('pgt_group_sets.groups', v_n); end if;

  if v_block <> '{}'::jsonb then
    raise exception 'This account has clinical or roster records and cannot be deleted; keep it deactivated'
      using errcode='23503', detail = v_block::text;
  end if;

  delete from public.ward_sessions where resident_id = r.id;            get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('ward_sessions', v_n);
  delete from public.ward_intern_sessions where resident_id = r.id;     get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('ward_intern_sessions', v_n);
  delete from private.office_admin_sessions where resident_id = r.id;   get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('office_admin_sessions', v_n);
  delete from public.push_subscriptions where resident_id = r.id;       get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('push_subscriptions', v_n);
  delete from public.fcm_device_tokens where resident_id = r.id;        get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('fcm_device_tokens', v_n);
  delete from public.notification_preferences where resident_id = r.id; get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('notification_preferences', v_n);
  delete from public.notification_deliveries where resident_id = r.id;  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('notification_deliveries', v_n);
  delete from public.ward_broadcast_reads where resident_id = r.id;     get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('ward_broadcast_reads', v_n);
  delete from public.ward_resident_photos where resident_id = r.id;     get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('ward_resident_photos', v_n);
  delete from public.resident_phones where resident_id = r.id;          get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('resident_phones', v_n);
  delete from public.resident_phone_audit where resident_id = r.id;     get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('resident_phone_audit', v_n);
  delete from public.consultant_name_map where resident_id = r.id;      get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('consultant_name_map', v_n);
  delete from public.bdft_bed_owners where resident_id = r.id;          get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('bdft_bed_owners', v_n);
  update public.bdft_bed_owners set updated_by = null where updated_by = r.id;
  update public.bdft_distributions set absent_ids = array_remove(absent_ids, r.id) where r.id = any(absent_ids);
  get diagnostics v_n = row_count; v_counts := v_counts || jsonb_build_object('bdft_distributions.absent_ids', v_n);

  insert into private.deleted_accounts_archive(id,username,display_name,role,designation,email,
      bdft_batch,bdft_short,bdft_order,created_at,deleted_by,cleanup)
  values (r.id,r.username,r.display_name,r.role,r.designation,r.email,
      r.bdft_batch,r.bdft_short,r.bdft_order,r.created_at,p_actor,v_counts)
  on conflict (id) do update set deleted_at = now(), deleted_by = excluded.deleted_by, cleanup = excluded.cleanup;

  delete from public.residents where id = r.id;
  return jsonb_build_object('ok', true, 'id', r.id, 'username', r.username, 'removed', v_counts);
end;
$function$;

COMMIT;
