-- R1.8 bed distribution rollback. PREPARED, NOT APPLIED to production.
-- Restores the production notification checks and inbox function captured for this release.
-- Deletes bed-distribution notice rows so the restored checks can be applied.

do $bdft_unsched$
begin
  if to_regclass('cron.job') is not null
     and to_regprocedure('cron.unschedule(text)') is not null
     and exists (select 1 from cron.job where jobname = 'ward-bdft-dispatch') then
    perform cron.unschedule('ward-bdft-dispatch');
  end if;
  if to_regclass('vault.secrets') is not null then
    delete from vault.secrets where name = 'ward_bdft_cron_secret';
  end if;
end;
$bdft_unsched$;

drop function if exists public.ward_bdft_tick();
drop function if exists public.ward_bdft_cron_ok(text);
drop function if exists public.ward_bdft_provision_cron_secret();
drop function if exists public.ward_bdft_service_apply(uuid, text, text);
drop function if exists public.ward_bdft_service_claim(uuid);
drop function if exists public.ward_bdft_dispatch_scope(uuid, uuid);
drop function if exists public.ward_bdft_apply_provider(uuid, uuid, text, text);
drop function if exists public.ward_bdft_claim_delivery(uuid, uuid);
drop function if exists public.ward_bdft_open(uuid, text);
drop function if exists public.ward_bdft_regenerate(uuid, integer, boolean);
drop function if exists public.ward_bdft_undo(uuid, integer);
drop function if exists public.ward_bdft_move(uuid, integer, text, text, boolean);
drop function if exists public.ward_bdft_generate(uuid, text, date, text[], text[], text, boolean);
drop function if exists public.ward_bdft_save_setup(uuid, jsonb, jsonb);
drop function if exists public.ward_bdft_state(uuid);
drop function if exists public.bdft_queue_notice(text, text, date);
drop function if exists public.bdft_write_rows(text, jsonb);
drop function if exists public.bdft_pack(text);
drop function if exists public.bdft_compute(text[], text[]);
drop function if exists public.bdft_on_evening(text);
drop function if exists public.bdft_actor(uuid);

drop index if exists public.bdft_inbox_delivery_uidx;
drop table if exists public.bdft_rows;
drop table if exists public.bdft_distributions;
drop table if exists public.bdft_bed_owners;

alter table public.residents drop column if exists bdft_batch;
alter table public.residents drop column if exists bdft_short;
alter table public.residents drop column if exists bdft_order;

delete from public.notification_events where event_type = 'bdft';
alter table public.notification_events drop constraint notification_events_routing_check;
alter table public.notification_events drop constraint notification_events_recipient_scope_check;
alter table public.notification_events drop constraint notification_events_event_type_check;
alter table public.notification_events add constraint notification_events_event_type_check
  check (event_type = any (array['admission'::text, 'discharge'::text, 'transfer'::text, 'handover'::text, 'task'::text, 'ect'::text, 'critical_status_update'::text, 'observation'::text, 'restrain'::text, 'broadcast'::text, 'advice'::text, 'archive'::text]));
alter table public.notification_events add constraint notification_events_recipient_scope_check
  check (recipient_scope = any (array['active_team'::text, 'handover'::text, 'task_assignees'::text, 'admins'::text]));
alter table public.notification_events add constraint notification_events_routing_check
  check (
    ((event_type = any (array['admission'::text, 'discharge'::text, 'transfer'::text, 'critical_status_update'::text, 'observation'::text, 'restrain'::text, 'advice'::text])) and category = 'clinical' and recipient_scope = 'active_team')
    or (event_type = 'handover' and category = 'handovers' and recipient_scope = 'handover')
    or (event_type = 'task' and category = 'tasks' and recipient_scope = 'task_assignees')
    or (event_type = 'ect' and category = 'ect' and recipient_scope = 'active_team')
    or (event_type = 'broadcast' and category = 'broadcast' and recipient_scope = 'active_team')
    or (event_type = 'archive' and category = 'archive' and recipient_scope = 'admins')
  );

CREATE OR REPLACE FUNCTION public.ward_list_notification_inbox(p_session_token uuid, p_limit integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_resident_id text;
  v_role text;
  v_limit integer;
  v_notifications jsonb;
BEGIN
  SELECT ws.resident_id, lower(r.role)
    INTO v_resident_id, v_role
  FROM public.ward_sessions ws
  JOIN public.residents r ON r.id = ws.resident_id
  WHERE ws.token = p_session_token AND ws.expires_at > now()
  LIMIT 1;
  IF v_resident_id IS NULL THEN RAISE EXCEPTION 'Invalid or expired ward session'; END IF;
  v_limit := greatest(1, least(coalesce(p_limit,40),100));
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC), '[]'::jsonb)
  INTO v_notifications
  FROM (
    SELECT
      e.id, e.event_type, e.category, e.priority, e.patient_id, e.task_id, e.handover_id, e.ect_plan_id,
      e.actor_id, coalesce(r.display_name, e.actor_id) AS actor_name,
      e.title, e.body, e.target_url, e.created_at,
      EXISTS (
        SELECT 1 FROM public.notification_deliveries d
        WHERE d.notification_id = e.id AND d.resident_id = v_resident_id AND d.read_at IS NOT NULL
      ) AS read,
      (
        SELECT min(d.read_at) FROM public.notification_deliveries d
        WHERE d.notification_id = e.id AND d.resident_id = v_resident_id
      ) AS read_at,
      e.created_at AS delivered_at,
      true AS delivered
    FROM public.notification_events e
    LEFT JOIN public.residents r ON r.id = e.actor_id
    WHERE
      (e.held_until IS NULL OR e.held_until < now())
      AND (
      v_role IN ('consultant','admin')
      OR e.recipient_scope = 'active_team'
      OR EXISTS (
        SELECT 1 FROM public.notification_deliveries d
        WHERE d.notification_id = e.id AND d.resident_id = v_resident_id
      )
      OR (
        e.recipient_scope = 'handover'
        AND EXISTS (
          SELECT 1 FROM public.handovers h
          WHERE h.id = e.handover_id AND (h.to_id = v_resident_id OR (h.to_id IS NULL AND h.from_id <> v_resident_id AND v_role <> 'intern'))
        )
      )
      OR (
        e.recipient_scope = 'task_assignees'
        AND EXISTS (
          SELECT 1 FROM public.tasks t
          WHERE t.id = e.task_id AND t.assigned_to = v_resident_id
        )
      )
      )
    ORDER BY e.created_at DESC
    LIMIT v_limit
  ) x;
  RETURN jsonb_build_object('ok', true, 'resident_id', v_resident_id, 'notifications', v_notifications);
END;
$function$;
