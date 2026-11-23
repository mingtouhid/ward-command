-- R2.0.19: roster lifecycle safety, version rollback, and role-scoped publication notifications.
-- This migration is intentionally reviewed in source control and is not applied automatically.

ALTER TABLE public.notification_events
  DROP CONSTRAINT IF EXISTS notification_events_event_type_check,
  DROP CONSTRAINT IF EXISTS notification_events_category_check,
  DROP CONSTRAINT IF EXISTS notification_events_recipient_scope_check,
  DROP CONSTRAINT IF EXISTS notification_events_routing_check;

ALTER TABLE public.notification_events
  ADD CONSTRAINT notification_events_event_type_check
  CHECK (event_type = ANY (ARRAY[
    'admission','discharge','transfer','handover','task','ect',
    'critical_status_update','observation','restrain','broadcast',
    'advice','archive','bdft','roster_publish'
  ])),
  ADD CONSTRAINT notification_events_category_check
  CHECK (category = ANY (ARRAY[
    'clinical','handovers','tasks','ect','broadcast','archive','rosters'
  ])),
  ADD CONSTRAINT notification_events_recipient_scope_check
  CHECK (recipient_scope = ANY (ARRAY[
    'active_team','handover','task_assignees','admins','bdft_residents',
    'roster_residents','roster_consultants'
  ])),
  ADD CONSTRAINT notification_events_routing_check
  CHECK (
    ((event_type = ANY (ARRAY['admission','discharge','transfer','critical_status_update','observation','restrain','advice']))
      AND category='clinical' AND recipient_scope='active_team')
    OR (event_type='handover' AND category='handovers' AND recipient_scope='handover')
    OR (event_type='task' AND category='tasks' AND recipient_scope='task_assignees')
    OR (event_type='ect' AND category='ect' AND recipient_scope='active_team')
    OR (event_type='broadcast' AND category='broadcast' AND recipient_scope='active_team')
    OR (event_type='archive' AND category='archive' AND recipient_scope='admins')
    OR (event_type='bdft' AND category='clinical' AND recipient_scope='bdft_residents')
    OR (event_type='roster_publish' AND category='rosters'
        AND recipient_scope = ANY (ARRAY['roster_residents','roster_consultants']))
  );

-- FCM deliveries use a NULL subscription_id, so add a separate unique key for
-- notification + FCM device. PostgreSQL permits multiple NULLs in this index,
-- leaving the existing Web Push uniqueness rule unchanged.
CREATE UNIQUE INDEX IF NOT EXISTS notification_deliveries_notification_fcm_token_key
  ON public.notification_deliveries(notification_id, fcm_token_id);

CREATE OR REPLACE FUNCTION private.enqueue_duty_roster_notification(
  p_actor text,
  p_roster_id uuid,
  p_roster_type text,
  p_period_start date,
  p_period_end date,
  p_version integer
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_title text;
  v_body text;
  v_scope text;
  v_notification_id uuid;
  v_month text;
  v_period text;
BEGIN
  IF p_roster_type NOT IN ('pgt_monthly','faculty_weekly') THEN
    RAISE EXCEPTION 'Invalid roster type for notification';
  END IF;

  v_month := pg_catalog.to_char(coalesce(p_period_start, (pg_catalog.now() AT TIME ZONE 'Asia/Kolkata')::date), 'FMMonth');
  v_period := CASE
    WHEN p_period_start IS NOT NULL AND p_period_end IS NOT NULL
      THEN pg_catalog.to_char(p_period_start,'DD Mon YYYY') || ' to ' || pg_catalog.to_char(p_period_end,'DD Mon YYYY')
    WHEN p_period_start IS NOT NULL THEN pg_catalog.to_char(p_period_start,'DD Mon YYYY')
    ELSE 'the scheduled period'
  END;

  IF p_roster_type='pgt_monthly' THEN
    v_title := 'PGT Roster for ' || v_month || ' is ready';
    v_body := 'The monthly PGT duty roster for ' || v_period || ' is available.';
    v_scope := 'roster_residents';
  ELSE
    v_title := 'A new weekly roster for Faculty is ready';
    v_body := 'Faculty duty assignments for ' || v_period || ' are available.';
    v_scope := 'roster_consultants';
  END IF;

  INSERT INTO public.notification_events(
    event_type,category,priority,actor_id,title,body,target_url,
    recipient_scope,dedupe_key,metadata
  ) VALUES (
    'roster_publish','rosters','normal',p_actor,v_title,v_body,'./#/pgts/' || p_roster_id::text,
    v_scope,'roster_publish:' || p_roster_id::text,
    pg_catalog.jsonb_build_object(
      'roster_id',p_roster_id,
      'roster_type',p_roster_type,
      'roster_version',p_version,
      'period_start',p_period_start,
      'period_end',p_period_end
    )
  )
  ON CONFLICT (dedupe_key) DO NOTHING;

  SELECT id INTO v_notification_id
  FROM public.notification_events
  WHERE dedupe_key='roster_publish:' || p_roster_id::text;

  RETURN v_notification_id;
END;
$function$;

REVOKE ALL ON FUNCTION private.enqueue_duty_roster_notification(text,uuid,text,date,date,integer) FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.office_admin_delete_roster_draft(
  p_token uuid,
  p_roster_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_roster private.duty_rosters%rowtype;
BEGIN
  v_actor := private.require_office_admin(p_token);

  SELECT * INTO v_roster
  FROM private.duty_rosters
  WHERE id=p_roster_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Roster not found' USING errcode='P0002';
  END IF;
  IF v_roster.status <> 'draft' THEN
    RAISE EXCEPTION 'Only draft rosters can be deleted' USING errcode='42501';
  END IF;
  IF EXISTS (
    SELECT 1 FROM private.duty_rosters child
    WHERE child.revision_of=p_roster_id
  ) THEN
    RAISE EXCEPTION 'This draft has dependent roster versions and cannot be deleted safely';
  END IF;

  DELETE FROM private.duty_rosters WHERE id=p_roster_id AND status='draft';

  RETURN pg_catalog.jsonb_build_object('ok',true,'id',p_roster_id,'deleted',true);
END;
$function$;

REVOKE ALL ON FUNCTION public.office_admin_delete_roster_draft(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.office_admin_delete_roster_draft(uuid,uuid) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.office_admin_authorize_roster_notification(
  p_token uuid,
  p_notification_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
BEGIN
  v_actor := private.require_office_admin(p_token);

  PERFORM 1
  FROM public.notification_events e
  WHERE e.id=p_notification_id
    AND e.actor_id=v_actor
    AND e.event_type='roster_publish'
    AND e.category='rosters'
    AND e.recipient_scope IN ('roster_residents','roster_consultants')
    AND e.metadata ? 'roster_id';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Office Administration session is not authorised for this roster notification'
      USING errcode='42501';
  END IF;

  RETURN pg_catalog.jsonb_build_object('ok',true,'actor_id',v_actor);
END;
$function$;

REVOKE ALL ON FUNCTION public.office_admin_authorize_roster_notification(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.office_admin_authorize_roster_notification(uuid,uuid) TO anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION public.office_admin_publish_roster(
  p_token uuid,
  p_roster_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_roster private.duty_rosters%rowtype;
  v_today date;
  v_effective boolean;
  v_content jsonb;
  v_notification_id uuid;
BEGIN
  v_actor := private.require_office_admin(p_token);
  v_today := (pg_catalog.now() AT TIME ZONE 'Asia/Kolkata')::date;

  -- Serialise publication with the scheduled-activation and rollback routines.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('duty-roster-effective-activation')
  );

  SELECT * INTO v_roster
  FROM private.duty_rosters
  WHERE id=p_roster_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Roster not found' USING errcode='P0002';
  END IF;
  IF v_roster.status NOT IN ('draft','review') THEN
    RAISE EXCEPTION 'Only a draft or ready roster can be finalised';
  END IF;
  IF NULLIF(pg_catalog.btrim(v_roster.title),'') IS NULL
     OR v_roster.period_start IS NULL OR v_roster.period_end IS NULL THEN
    RAISE EXCEPTION 'Roster title and date range are required before publishing';
  END IF;
  IF v_roster.period_end < v_roster.period_start THEN
    RAISE EXCEPTION 'Roster end date cannot precede start date';
  END IF;

  v_content := v_roster.content;
  IF v_roster.roster_type='pgt_monthly' THEN
    v_content := pg_catalog.jsonb_set(
      v_content,'{groups}',
      private.pgt_snapshot_groups(coalesce(v_content->'groups','[]'::jsonb)),
      true
    );
  END IF;

  v_effective := v_roster.period_start <= v_today;
  IF v_effective THEN
    UPDATE private.duty_rosters
    SET is_current=false,updated_at=pg_catalog.now()
    WHERE roster_type=v_roster.roster_type
      AND is_current=true AND id<>p_roster_id;
  END IF;

  UPDATE private.duty_rosters
  SET status='published',
      is_current=v_effective,
      content=v_content,
      published_by=v_actor,
      published_at=pg_catalog.now(),
      updated_by=v_actor,
      updated_at=pg_catalog.now()
  WHERE id=p_roster_id;

  v_notification_id := private.enqueue_duty_roster_notification(
    v_actor,v_roster.id,v_roster.roster_type,
    v_roster.period_start,v_roster.period_end,v_roster.version
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok',true,'id',p_roster_id,'status','published',
    'is_current',v_effective,'scheduled',NOT v_effective,
    'notification_id',v_notification_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.office_admin_rollback_published_roster(
  p_token uuid,
  p_roster_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_current private.duty_rosters%rowtype;
  v_source private.duty_rosters%rowtype;
  v_new_id uuid;
  v_version integer;
  v_today date;
  v_notification_id uuid;
BEGIN
  v_actor := private.require_office_admin(p_token);

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('duty-roster-effective-activation')
  );

  SELECT * INTO v_current
  FROM private.duty_rosters
  WHERE id=p_roster_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Roster not found' USING errcode='P0002';
  END IF;
  IF v_current.status<>'published' OR NOT v_current.is_current THEN
    RAISE EXCEPTION 'Only the active published roster can be rolled back';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('duty-roster:' || v_current.roster_type)
  );

  WITH RECURSIVE ancestors(id,revision_of,depth) AS (
    SELECT r.id,r.revision_of,0
    FROM private.duty_rosters r
    WHERE r.id=p_roster_id
    UNION ALL
    SELECT parent.id,parent.revision_of,a.depth+1
    FROM ancestors a
    JOIN private.duty_rosters parent ON parent.id=a.revision_of
    WHERE a.depth<50
  )
  SELECT r.* INTO v_source
  FROM ancestors a
  JOIN private.duty_rosters r ON r.id=a.id
  WHERE a.depth>0
    AND r.status='published'
    AND r.roster_type=v_current.roster_type
    AND r.period_start IS NOT DISTINCT FROM v_current.period_start
    AND r.period_end IS NOT DISTINCT FROM v_current.period_end
  ORDER BY a.depth ASC
  LIMIT 1;

  IF v_source.id IS NULL THEN
    SELECT r.* INTO v_source
    FROM private.duty_rosters r
    WHERE r.id<>p_roster_id
      AND r.status='published'
      AND r.roster_type=v_current.roster_type
      AND r.period_start IS NOT DISTINCT FROM v_current.period_start
      AND r.period_end IS NOT DISTINCT FROM v_current.period_end
      AND r.version<v_current.version
    ORDER BY r.version DESC,r.published_at DESC NULLS LAST
    LIMIT 1;
  END IF;

  IF v_source.id IS NULL THEN
    RAISE EXCEPTION 'No earlier published version is available for this roster';
  END IF;

  SELECT coalesce(max(r.version),0)+1 INTO v_version
  FROM private.duty_rosters r
  WHERE r.roster_type=v_current.roster_type;

  v_today := (pg_catalog.now() AT TIME ZONE 'Asia/Kolkata')::date;

  INSERT INTO private.duty_rosters(
    roster_type,period_start,period_end,title,reference_number,issue_date,content,
    status,version,revision_of,is_current,created_by,updated_by,published_by,published_at
  ) VALUES (
    v_source.roster_type,v_source.period_start,v_source.period_end,v_source.title,
    v_source.reference_number,v_source.issue_date,v_source.content,
    'published',v_version,v_source.id,(v_source.period_start<=v_today),
    v_actor,v_actor,v_actor,pg_catalog.now()
  )
  RETURNING id INTO v_new_id;

  UPDATE private.duty_rosters
  SET is_current=(id=v_new_id),
      updated_at=pg_catalog.now()
  WHERE roster_type=v_current.roster_type
    AND status='published'
    AND is_current IS DISTINCT FROM (id=v_new_id);

  v_notification_id := private.enqueue_duty_roster_notification(
    v_actor,v_new_id,v_source.roster_type,
    v_source.period_start,v_source.period_end,v_version
  );

  RETURN pg_catalog.jsonb_build_object(
    'ok',true,'id',v_new_id,'status','published',
    'version',v_version,'rollback_source_id',v_source.id,
    'notification_id',v_notification_id
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.office_admin_rollback_published_roster(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.office_admin_rollback_published_roster(uuid,uuid) TO anon,authenticated;

COMMENT ON FUNCTION public.office_admin_delete_roster_draft(uuid,uuid) IS
  'Office Admin only. Deletes draft-only roster rows; published, review, and historical versions are protected.';
COMMENT ON FUNCTION public.office_admin_rollback_published_roster(uuid,uuid) IS
  'Office Admin only. Creates and activates a new version using the previous published version content; existing versions remain immutable.';
COMMENT ON FUNCTION public.office_admin_publish_roster(uuid,uuid) IS
  'Office Admin only. Atomically publishes a draft and creates one idempotent, role-scoped roster notification event.';


-- Make roster notifications visible only to their intended role group in the
-- in-app inbox as well as in push delivery. Return metadata for exact deep links.
CREATE OR REPLACE FUNCTION public.ward_list_notification_inbox(
  p_session_token uuid,
  p_limit integer DEFAULT 40
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
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
  JOIN public.residents r ON r.id=ws.resident_id
  WHERE ws.token=p_session_token AND ws.expires_at>pg_catalog.now()
  LIMIT 1;

  IF v_resident_id IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired ward session';
  END IF;

  v_limit := greatest(1,least(coalesce(p_limit,40),100));

  SELECT coalesce(pg_catalog.jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC),'[]'::jsonb)
    INTO v_notifications
  FROM (
    SELECT
      e.id,e.event_type,e.category,e.priority,e.patient_id,e.task_id,
      e.handover_id,e.ect_plan_id,e.actor_id,
      coalesce(r.display_name,e.actor_id) AS actor_name,
      e.title,e.body,e.target_url,e.metadata,e.created_at,
      EXISTS (
        SELECT 1 FROM public.notification_deliveries d
        WHERE d.notification_id=e.id
          AND d.resident_id=v_resident_id
          AND d.read_at IS NOT NULL
      ) AS read,
      (
        SELECT min(d.read_at) FROM public.notification_deliveries d
        WHERE d.notification_id=e.id AND d.resident_id=v_resident_id
      ) AS read_at,
      e.created_at AS delivered_at,
      true AS delivered
    FROM public.notification_events e
    LEFT JOIN public.residents r ON r.id=e.actor_id
    WHERE
      (e.held_until IS NULL OR e.held_until<pg_catalog.now())
      AND (e.event_type IS DISTINCT FROM 'bdft' OR v_role IN ('resident','admin','sr'))
      AND (
        e.event_type IS DISTINCT FROM 'roster_publish'
        OR (
          (e.recipient_scope='roster_residents' AND v_role IN ('resident','admin'))
          OR (e.recipient_scope='roster_consultants' AND v_role='consultant')
        )
      )
      AND (
        v_role IN ('consultant','admin')
        OR e.recipient_scope='active_team'
        OR (e.event_type='bdft' AND v_role IN ('resident','admin','sr'))
        -- Roster notifications are role-filtered above; include them in the
        -- inbox even when the user has no push-device delivery row.
        OR e.recipient_scope IN ('roster_residents','roster_consultants')
        OR EXISTS (
          SELECT 1 FROM public.notification_deliveries d
          WHERE d.notification_id=e.id AND d.resident_id=v_resident_id
        )
        OR (
          e.recipient_scope='handover'
          AND EXISTS (
            SELECT 1 FROM public.handovers h
            WHERE h.id=e.handover_id
              AND (h.to_id=v_resident_id OR (h.to_id IS NULL AND h.from_id<>v_resident_id AND v_role<>'intern'))
          )
        )
        OR (
          e.recipient_scope='task_assignees'
          AND EXISTS (
            SELECT 1 FROM public.tasks t
            WHERE t.id=e.task_id AND t.assigned_to=v_resident_id
          )
        )
      )
    ORDER BY e.created_at DESC
    LIMIT v_limit
  ) x;

  RETURN pg_catalog.jsonb_build_object(
    'ok',true,'resident_id',v_resident_id,'notifications',v_notifications
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.ward_list_notification_inbox(uuid,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ward_list_notification_inbox(uuid,integer) TO anon,authenticated;

