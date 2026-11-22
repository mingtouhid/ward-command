-- R20.17: allow Office Admin to revoke a publication while preserving the
-- published roster history and selecting a safe fallback active version.
ALTER TABLE private.duty_rosters
  DROP CONSTRAINT IF EXISTS duty_rosters_status_check;

ALTER TABLE private.duty_rosters
  ADD CONSTRAINT duty_rosters_status_check
  CHECK (status IN ('draft', 'review', 'published', 'revoked'));

CREATE OR REPLACE FUNCTION public.office_admin_revoke_published_roster(
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
  v_fallback uuid;
BEGIN
  v_actor := private.require_office_admin(p_token);

  -- Serialize with the resident-side scheduled activation routine.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('duty-roster-effective-activation')
  );

  SELECT * INTO v_roster
  FROM private.duty_rosters
  WHERE id = p_roster_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Roster not found' USING errcode = 'P0002';
  END IF;
  IF v_roster.status <> 'published' THEN
    RAISE EXCEPTION 'Only a published roster can be revoked';
  END IF;

  v_today := (pg_catalog.now() AT TIME ZONE 'Asia/Kolkata')::date;

  UPDATE private.duty_rosters
  SET status = 'revoked',
      is_current = false,
      updated_by = v_actor,
      updated_at = pg_catalog.now()
  WHERE id = p_roster_id;

  -- If the revoked record was active or has already become effective,
  -- restore the most recent remaining published version for this roster type.
  IF v_roster.is_current OR v_roster.period_start <= v_today THEN
    SELECT r.id INTO v_fallback
    FROM private.duty_rosters r
    WHERE r.roster_type = v_roster.roster_type
      AND r.status = 'published'
      AND r.period_start IS NOT NULL
      AND r.period_start <= v_today
    ORDER BY r.period_start DESC,
             r.published_at DESC NULLS LAST,
             r.version DESC
    LIMIT 1;

    UPDATE private.duty_rosters
    SET is_current = (id = v_fallback),
        updated_at = pg_catalog.now()
    WHERE roster_type = v_roster.roster_type
      AND status = 'published'
      AND is_current IS DISTINCT FROM (id = v_fallback);
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'id', p_roster_id,
    'status', 'revoked',
    'replacement_id', v_fallback
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.office_admin_revoke_published_roster(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.office_admin_revoke_published_roster(uuid, uuid) TO anon, authenticated;

COMMENT ON FUNCTION public.office_admin_revoke_published_roster(uuid, uuid) IS
  'Office Admin only. Revokes one published roster without deleting history; if effective, recalculates the latest remaining published version as current.';
