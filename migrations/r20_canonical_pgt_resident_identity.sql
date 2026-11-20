BEGIN;

-- Canonical resident identity for PGT group configuration.
-- Resident IDs are stored relationally; display labels are resolved from public.residents.
CREATE UNIQUE INDEX IF NOT EXISTS residents_active_pgt_bdft_short_unique_idx
  ON public.residents (upper(btrim(bdft_short)))
  WHERE active IS TRUE
    AND lower(coalesce(role, '')) IN ('resident', 'admin')
    AND nullif(btrim(bdft_short), '') IS NOT NULL;

CREATE TABLE IF NOT EXISTS private.office_admin_pgt_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  group_set_id uuid NOT NULL
    REFERENCES private.office_admin_pgt_group_sets(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(btrim(name)) > 0),
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  UNIQUE (group_set_id, sort_order),
  UNIQUE (group_set_id, id)
);

CREATE TABLE IF NOT EXISTS private.office_admin_pgt_group_members (
  group_set_id uuid NOT NULL,
  group_id uuid NOT NULL,
  resident_id text NOT NULL
    REFERENCES public.residents(id) ON UPDATE CASCADE ON DELETE RESTRICT,
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  PRIMARY KEY (group_id, resident_id),
  UNIQUE (group_set_id, resident_id),
  UNIQUE (group_id, sort_order),
  FOREIGN KEY (group_set_id, group_id)
    REFERENCES private.office_admin_pgt_groups(group_set_id, id) ON DELETE CASCADE
);

ALTER TABLE private.office_admin_pgt_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.office_admin_pgt_group_members ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.office_admin_pgt_groups FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE private.office_admin_pgt_group_members FROM PUBLIC, anon, authenticated;

-- Used only by the guarded Office Admin RPCs. The caller must already have
-- passed private.require_office_admin(). Names and codes are never trusted
-- as identifiers; legacy name-only input is resolved once to an unambiguous ID.
CREATE OR REPLACE FUNCTION private.pgt_snapshot_groups(p_groups jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE
  v_group jsonb;
  v_member jsonb;
  v_group_name text;
  v_member_name text;
  v_name_key text;
  v_resident_id text;
  v_match_count integer;
  v_resident public.residents%rowtype;
  v_code text;
  v_seen_ids text[] := ARRAY[]::text[];
  v_seen_codes text[] := ARRAY[]::text[];
  v_members jsonb;
  v_groups jsonb := '[]'::jsonb;
BEGIN
  IF p_groups IS NULL OR pg_catalog.jsonb_typeof(p_groups) <> 'array'
     OR pg_catalog.jsonb_array_length(p_groups) < 1
     OR pg_catalog.jsonb_array_length(p_groups) > 12 THEN
    RAISE EXCEPTION 'A PGT group set must contain between 1 and 12 groups';
  END IF;

  FOR v_group IN SELECT value FROM pg_catalog.jsonb_array_elements(p_groups) LOOP
    IF pg_catalog.jsonb_typeof(v_group) <> 'object'
       OR NULLIF(pg_catalog.btrim(v_group->>'name'), '') IS NULL
       OR pg_catalog.jsonb_typeof(coalesce(v_group->'members', '[]'::jsonb)) <> 'array' THEN
      RAISE EXCEPTION 'Each PGT group needs a name and a member list';
    END IF;

    v_group_name := pg_catalog.btrim(v_group->>'name');
    v_members := '[]'::jsonb;

    FOR v_member IN
      SELECT value FROM pg_catalog.jsonb_array_elements(coalesce(v_group->'members', '[]'::jsonb))
    LOOP
      IF pg_catalog.jsonb_typeof(v_member) NOT IN ('object', 'string') THEN
        RAISE EXCEPTION 'Each PGT member must reference a registered resident';
      END IF;

      v_resident_id := NULLIF(pg_catalog.btrim(coalesce(
        v_member->>'residentId',
        v_member->>'resident_id'
      )), '');

      IF v_resident_id IS NULL THEN
        v_member_name := CASE
          WHEN pg_catalog.jsonb_typeof(v_member) = 'string' THEN v_member #>> '{}'
          ELSE coalesce(v_member->>'name', v_member->>'display_name', '')
        END;
        v_name_key := pg_catalog.regexp_replace(
          pg_catalog.lower(pg_catalog.btrim(v_member_name)),
          '^(dr[.]?|doctor)[[:space:]]*',
          ''
        );

        SELECT count(*), min(r.id)
          INTO v_match_count, v_resident_id
        FROM public.residents r
        WHERE r.active IS TRUE
          AND pg_catalog.lower(coalesce(r.role, '')) IN ('resident', 'admin')
          AND NULLIF(pg_catalog.btrim(r.bdft_short), '') IS NOT NULL
          AND (
            pg_catalog.regexp_replace(
              pg_catalog.lower(pg_catalog.btrim(r.display_name)),
              '^(dr[.]?|doctor)[[:space:]]*',
              ''
            ) = v_name_key
            OR (r.username = 'touhid' AND v_name_key = 'touhid')
          );

        IF v_match_count <> 1 OR v_resident_id IS NULL THEN
          RAISE EXCEPTION 'Could not uniquely link PGT member "%". Select a registered resident account.',
            coalesce(v_member_name, '');
        END IF;
      END IF;

      SELECT *
        INTO v_resident
      FROM public.residents r
      WHERE r.id = v_resident_id
        AND r.active IS TRUE
        AND pg_catalog.lower(coalesce(r.role, '')) IN ('resident', 'admin')
        AND NULLIF(pg_catalog.btrim(r.bdft_short), '') IS NOT NULL;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Resident ID "%" is inactive, ineligible, or has no BDFT short code',
          v_resident_id;
      END IF;

      v_code := pg_catalog.upper(pg_catalog.btrim(v_resident.bdft_short));

      IF v_resident.id = ANY(v_seen_ids) THEN
        RAISE EXCEPTION 'A resident can appear only once in a PGT group set: %',
          v_resident.display_name;
      END IF;
      IF v_code = ANY(v_seen_codes) THEN
        RAISE EXCEPTION 'Duplicate PGT short code "%" is not allowed', v_code;
      END IF;

      v_seen_ids := pg_catalog.array_append(v_seen_ids, v_resident.id);
      v_seen_codes := pg_catalog.array_append(v_seen_codes, v_code);

      v_members := v_members || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'residentId', v_resident.id,
          'name', v_resident.display_name,
          'abbr', pg_catalog.btrim(v_resident.bdft_short),
          'username', v_resident.username,
          'batch', v_resident.bdft_batch,
          'active', v_resident.active
        )
      );
    END LOOP;

    v_groups := v_groups || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('name', v_group_name, 'members', v_members)
    );
  END LOOP;

  RETURN v_groups;
END;
$function$;

REVOKE ALL ON FUNCTION private.pgt_snapshot_groups(jsonb) FROM PUBLIC, anon, authenticated;

-- Migrate saved group sets to relational resident-ID membership. Their JSON
-- column remains as an ID-only compatibility mirror; the normalized tables
-- become the authoritative group/member relationship.
DO $migration$
DECLARE
  v_set record;
  v_snapshot jsonb;
  v_group jsonb;
  v_member jsonb;
  v_group_id uuid;
  v_group_order integer;
  v_member_order integer;
  v_id_members jsonb;
  v_id_groups jsonb;
BEGIN
  FOR v_set IN
    SELECT id, groups
    FROM private.office_admin_pgt_group_sets
    ORDER BY created_at, id
  LOOP
    v_snapshot := private.pgt_snapshot_groups(v_set.groups);
    DELETE FROM private.office_admin_pgt_groups WHERE group_set_id = v_set.id;
    v_group_order := 0;
    v_id_groups := '[]'::jsonb;

    FOR v_group IN
      SELECT value FROM pg_catalog.jsonb_array_elements(v_snapshot)
    LOOP
      INSERT INTO private.office_admin_pgt_groups(group_set_id, name, sort_order)
      VALUES (v_set.id, v_group->>'name', v_group_order)
      RETURNING id INTO v_group_id;

      v_member_order := 0;
      v_id_members := '[]'::jsonb;
      FOR v_member IN
        SELECT value FROM pg_catalog.jsonb_array_elements(v_group->'members')
      LOOP
        INSERT INTO private.office_admin_pgt_group_members(
          group_set_id, group_id, resident_id, sort_order
        )
        VALUES (
          v_set.id, v_group_id, v_member->>'residentId', v_member_order
        );
        v_id_members := v_id_members || pg_catalog.jsonb_build_array(
          pg_catalog.jsonb_build_object('residentId', v_member->>'residentId')
        );
        v_member_order := v_member_order + 1;
      END LOOP;

      v_id_groups := v_id_groups || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('name', v_group->>'name', 'members', v_id_members)
      );
      v_group_order := v_group_order + 1;
    END LOOP;

    UPDATE private.office_admin_pgt_group_sets
    SET groups = v_id_groups, updated_at = pg_catalog.now()
    WHERE id = v_set.id;
  END LOOP;
END;
$migration$;

-- Link recent/current and editable PGT roster snapshots without rewriting
-- their published names or short codes. Historical labels remain immutable.
DO $migration$
DECLARE
  v_roster record;
  v_group jsonb;
  v_member jsonb;
  v_group_out jsonb;
  v_member_out jsonb;
  v_groups_out jsonb;
  v_members_out jsonb;
  v_member_name text;
  v_name_key text;
  v_resident_id text;
  v_match_count integer;
  v_seen_ids text[];
  v_content jsonb;
BEGIN
  FOR v_roster IN
    SELECT id, content
    FROM private.duty_rosters
    WHERE roster_type = 'pgt_monthly'
      AND (
        status IN ('draft', 'review')
        OR (status = 'published' AND coalesce(period_end, period_start) >=
            ((pg_catalog.now() AT TIME ZONE 'Asia/Kolkata')::date - 62))
      )
      AND pg_catalog.jsonb_typeof(content->'groups') = 'array'
  LOOP
    v_groups_out := '[]'::jsonb;
    v_seen_ids := ARRAY[]::text[];

    FOR v_group IN
      SELECT value FROM pg_catalog.jsonb_array_elements(v_roster.content->'groups')
    LOOP
      v_members_out := '[]'::jsonb;
      FOR v_member IN
        SELECT value FROM pg_catalog.jsonb_array_elements(coalesce(v_group->'members', '[]'::jsonb))
      LOOP
        v_resident_id := NULLIF(pg_catalog.btrim(coalesce(
          v_member->>'residentId',
          v_member->>'resident_id'
        )), '');

        IF v_resident_id IS NULL THEN
          v_member_name := CASE
            WHEN pg_catalog.jsonb_typeof(v_member) = 'string' THEN v_member #>> '{}'
            ELSE coalesce(v_member->>'name', v_member->>'display_name', '')
          END;
          v_name_key := pg_catalog.regexp_replace(
            pg_catalog.lower(pg_catalog.btrim(v_member_name)),
            '^(dr[.]?|doctor)[[:space:]]*',
            ''
          );

          SELECT count(*), min(r.id)
            INTO v_match_count, v_resident_id
          FROM public.residents r
          WHERE r.active IS TRUE
            AND pg_catalog.lower(coalesce(r.role, '')) IN ('resident', 'admin')
            AND (
              pg_catalog.regexp_replace(
                pg_catalog.lower(pg_catalog.btrim(r.display_name)),
                '^(dr[.]?|doctor)[[:space:]]*',
                ''
              ) = v_name_key
              OR (r.username = 'touhid' AND v_name_key = 'touhid')
            );

          IF v_match_count <> 1 OR v_resident_id IS NULL THEN
            RAISE EXCEPTION 'Could not link current PGT roster member "%"; no roster data was changed',
              coalesce(v_member_name, '');
          END IF;
        ELSIF NOT EXISTS (SELECT 1 FROM public.residents r WHERE r.id = v_resident_id) THEN
          RAISE EXCEPTION 'PGT roster contains an unknown resident ID "%"', v_resident_id;
        END IF;

        IF v_resident_id = ANY(v_seen_ids) THEN
          RAISE EXCEPTION 'PGT roster % lists one resident more than once', v_roster.id;
        END IF;
        v_seen_ids := pg_catalog.array_append(v_seen_ids, v_resident_id);

        IF pg_catalog.jsonb_typeof(v_member) = 'object' THEN
          v_member_out := (v_member - 'resident_id') ||
            pg_catalog.jsonb_build_object('residentId', v_resident_id);
        ELSE
          v_member_out := pg_catalog.jsonb_build_object(
            'residentId', v_resident_id,
            'name', v_member #>> '{}',
            'abbr', ''
          );
        END IF;

        v_members_out := v_members_out || pg_catalog.jsonb_build_array(v_member_out);
      END LOOP;

      v_group_out := pg_catalog.jsonb_set(v_group, '{members}', v_members_out, true);
      v_groups_out := v_groups_out || pg_catalog.jsonb_build_array(v_group_out);
    END LOOP;

    v_content := pg_catalog.jsonb_set(v_roster.content, '{groups}', v_groups_out, true);
    UPDATE private.duty_rosters
    SET content = v_content, updated_at = pg_catalog.now()
    WHERE id = v_roster.id;
  END LOOP;
END;
$migration$;

CREATE OR REPLACE FUNCTION public.office_admin_list_pgt_group_sets(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_sets jsonb;
BEGIN
  v_actor := private.require_office_admin(p_token);

  SELECT coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', s.id,
        'name', s.name,
        'groups', coalesce((
          SELECT pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'name', g.name,
              'members', coalesce((
                SELECT pg_catalog.jsonb_agg(
                  pg_catalog.jsonb_build_object(
                    'residentId', gm.resident_id,
                    'name', r.display_name,
                    'abbr', r.bdft_short,
                    'username', r.username,
                    'batch', r.bdft_batch,
                    'active', r.active
                  ) ORDER BY gm.sort_order
                )
                FROM private.office_admin_pgt_group_members gm
                JOIN public.residents r ON r.id = gm.resident_id
                WHERE gm.group_id = g.id
              ), '[]'::jsonb)
            ) ORDER BY g.sort_order
          )
          FROM private.office_admin_pgt_groups g
          WHERE g.group_set_id = s.id
        ), '[]'::jsonb),
        'created_at', s.created_at,
        'updated_at', s.updated_at
      ) ORDER BY s.updated_at DESC, s.name
    ), '[]'::jsonb
  )
  INTO v_sets
  FROM private.office_admin_pgt_group_sets s;

  RETURN pg_catalog.jsonb_build_object('ok', true, 'sets', v_sets);
END;
$function$;

CREATE OR REPLACE FUNCTION public.office_admin_list_users(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_users jsonb;
BEGIN
  v_actor := private.require_office_admin(p_token);
  SELECT coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'id', r.id,
        'username', r.username,
        'display_name', r.display_name,
        'role', r.role,
        'active', r.active,
        'created_at', r.created_at,
        'email', r.email,
        'designation', r.designation,
        'bdft_short', r.bdft_short,
        'bdft_batch', r.bdft_batch,
        'bdft_order', r.bdft_order,
        'phone', (
          SELECT rp.phone_e164
          FROM public.resident_phones rp
          WHERE rp.resident_id = r.id
        )
      ) ORDER BY r.active DESC, r.display_name, r.username
    ), '[]'::jsonb
  )
  INTO v_users
  FROM public.residents r;

  RETURN pg_catalog.jsonb_build_object('ok', true, 'users', v_users);
END;
$function$;

CREATE OR REPLACE FUNCTION public.office_admin_save_pgt_group_set(
  p_token uuid,
  p_set_id uuid,
  p_name text,
  p_groups jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_id uuid;
  v_snapshot jsonb;
  v_group jsonb;
  v_member jsonb;
  v_group_id uuid;
  v_group_order integer := 0;
  v_member_order integer;
  v_id_members jsonb;
  v_id_groups jsonb := '[]'::jsonb;
BEGIN
  v_actor := private.require_office_admin(p_token);

  IF p_name IS NULL OR pg_catalog.length(pg_catalog.btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'Enter a group-set name';
  END IF;
  IF pg_catalog.length(pg_catalog.btrim(p_name)) > 100 THEN
    RAISE EXCEPTION 'Group-set name must be 100 characters or fewer';
  END IF;

  v_snapshot := private.pgt_snapshot_groups(p_groups);

  IF p_set_id IS NULL THEN
    INSERT INTO private.office_admin_pgt_group_sets(name, groups, created_by)
    VALUES (pg_catalog.btrim(p_name), '[]'::jsonb, v_actor)
    RETURNING id INTO v_id;
  ELSE
    UPDATE private.office_admin_pgt_group_sets
    SET name = pg_catalog.btrim(p_name), updated_at = pg_catalog.now()
    WHERE id = p_set_id
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
      RAISE EXCEPTION 'Saved group set not found';
    END IF;
  END IF;

  DELETE FROM private.office_admin_pgt_groups WHERE group_set_id = v_id;

  FOR v_group IN SELECT value FROM pg_catalog.jsonb_array_elements(v_snapshot)
  LOOP
    INSERT INTO private.office_admin_pgt_groups(group_set_id, name, sort_order)
    VALUES (v_id, v_group->>'name', v_group_order)
    RETURNING id INTO v_group_id;

    v_member_order := 0;
    v_id_members := '[]'::jsonb;

    FOR v_member IN SELECT value FROM pg_catalog.jsonb_array_elements(v_group->'members')
    LOOP
      INSERT INTO private.office_admin_pgt_group_members(
        group_set_id, group_id, resident_id, sort_order
      )
      VALUES (v_id, v_group_id, v_member->>'residentId', v_member_order);

      v_id_members := v_id_members || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('residentId', v_member->>'residentId')
      );
      v_member_order := v_member_order + 1;
    END LOOP;

    v_id_groups := v_id_groups || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('name', v_group->>'name', 'members', v_id_members)
    );
    v_group_order := v_group_order + 1;
  END LOOP;

  UPDATE private.office_admin_pgt_group_sets
  SET groups = v_id_groups, updated_at = pg_catalog.now()
  WHERE id = v_id;

  RETURN pg_catalog.jsonb_build_object('ok', true, 'id', v_id);
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'A saved group set with this name already exists';
END;
$function$;

CREATE OR REPLACE FUNCTION public.office_admin_save_roster_draft(
  p_token uuid,
  p_roster_type text,
  p_roster_id uuid,
  p_period_start date,
  p_period_end date,
  p_title text,
  p_reference_number text,
  p_issue_date date,
  p_content jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_status text;
  v_existing_type text;
  v_version integer;
  v_revision uuid;
  v_id uuid;
  v_content jsonb;
BEGIN
  v_actor := private.require_office_admin(p_token);

  IF p_roster_type NOT IN ('pgt_monthly', 'faculty_weekly') THEN
    RAISE EXCEPTION 'Invalid roster type';
  END IF;
  IF p_period_start IS NOT NULL AND p_period_end IS NOT NULL AND p_period_start > p_period_end THEN
    RAISE EXCEPTION 'Roster end date cannot precede start date';
  END IF;
  IF p_content IS NOT NULL AND pg_catalog.jsonb_typeof(p_content) <> 'object' THEN
    RAISE EXCEPTION 'Roster content must be a JSON object';
  END IF;

  v_content := coalesce(p_content, '{}'::jsonb);
  IF p_roster_type = 'pgt_monthly' THEN
    v_content := pg_catalog.jsonb_set(
      v_content,
      '{groups}',
      private.pgt_snapshot_groups(coalesce(v_content->'groups', '[]'::jsonb)),
      true
    );
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('duty-roster:' || p_roster_type));

  IF p_roster_id IS NOT NULL THEN
    SELECT r.status, r.roster_type INTO v_status, v_existing_type
    FROM private.duty_rosters r
    WHERE r.id = p_roster_id
    FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Roster not found' USING errcode = 'P0002'; END IF;
    IF v_status <> 'draft' THEN RAISE EXCEPTION 'Only draft rosters can be edited'; END IF;
    IF v_existing_type <> p_roster_type THEN RAISE EXCEPTION 'Roster type cannot be changed'; END IF;

    UPDATE private.duty_rosters SET
      period_start = p_period_start,
      period_end = p_period_end,
      title = coalesce(p_title, ''),
      reference_number = nullif(pg_catalog.btrim(coalesce(p_reference_number, '')), ''),
      issue_date = p_issue_date,
      content = v_content,
      updated_by = v_actor,
      updated_at = pg_catalog.now()
    WHERE id = p_roster_id;

    RETURN p_roster_id;
  END IF;

  SELECT coalesce(max(r.version), 0) + 1 INTO v_version
  FROM private.duty_rosters r
  WHERE r.roster_type = p_roster_type;

  SELECT r.id INTO v_revision
  FROM private.duty_rosters r
  WHERE r.roster_type = p_roster_type AND r.is_current = true
  LIMIT 1;

  INSERT INTO private.duty_rosters(
    roster_type, period_start, period_end, title, reference_number, issue_date, content,
    status, version, revision_of, is_current, created_by, updated_by
  ) VALUES (
    p_roster_type, p_period_start, p_period_end, coalesce(p_title, ''),
    nullif(pg_catalog.btrim(coalesce(p_reference_number, '')), ''),
    p_issue_date, v_content,
    'draft', v_version, v_revision, false, v_actor, v_actor
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.office_admin_publish_roster(p_token uuid, p_roster_id uuid)
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
BEGIN
  v_actor := private.require_office_admin(p_token);
  v_today := (pg_catalog.now() AT TIME ZONE 'Asia/Kolkata')::date;

  SELECT * INTO v_roster
  FROM private.duty_rosters
  WHERE id = p_roster_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Roster not found' USING errcode = 'P0002';
  END IF;
  IF v_roster.status NOT IN ('draft', 'review') THEN
    RAISE EXCEPTION 'Only a draft or ready roster can be finalized';
  END IF;
  IF NULLIF(pg_catalog.btrim(v_roster.title), '') IS NULL
     OR v_roster.period_start IS NULL
     OR v_roster.period_end IS NULL THEN
    RAISE EXCEPTION 'Roster title and date range are required before publishing';
  END IF;
  IF v_roster.period_end < v_roster.period_start THEN
    RAISE EXCEPTION 'Roster end date cannot precede start date';
  END IF;

  v_content := v_roster.content;
  IF v_roster.roster_type = 'pgt_monthly' THEN
    v_content := pg_catalog.jsonb_set(
      v_content,
      '{groups}',
      private.pgt_snapshot_groups(coalesce(v_content->'groups', '[]'::jsonb)),
      true
    );
  END IF;

  v_effective := v_roster.period_start <= v_today;
  IF v_effective THEN
    UPDATE private.duty_rosters
    SET is_current = false, updated_at = pg_catalog.now()
    WHERE roster_type = v_roster.roster_type
      AND is_current = true
      AND id <> p_roster_id;
  END IF;

  UPDATE private.duty_rosters
  SET status = 'published',
      is_current = v_effective,
      content = v_content,
      published_by = v_actor,
      published_at = pg_catalog.now(),
      updated_by = v_actor,
      updated_at = pg_catalog.now()
  WHERE id = p_roster_id;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'id', p_roster_id,
    'status', 'published',
    'is_current', v_effective,
    'scheduled', NOT v_effective
  );
END;
$function$;

-- Give profile/BDFT editors a useful error when the new canonical uniqueness
-- constraint rejects a colliding resident short code.
CREATE OR REPLACE FUNCTION public.ward_bdft_save_setup(p_token uuid, p_people jsonb, p_owners jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  a record;
  v_item jsonb;
  v_id text;
  v_bed text;
  v_res text;
  v_constraint text;
BEGIN
  SELECT * INTO a FROM public.bdft_actor(p_token);
  IF a.actor_role NOT IN ('admin', 'resident') THEN
    RAISE EXCEPTION 'Roster setup is not available for this role';
  END IF;
  IF jsonb_typeof(p_people) <> 'array' OR jsonb_typeof(p_owners) <> 'array' THEN
    RAISE EXCEPTION 'Setup payload is invalid';
  END IF;

  IF a.actor_role = 'admin' THEN
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_people) LOOP
      v_id := nullif(btrim(v_item->>'id'), '');
      IF v_id IS NULL THEN RAISE EXCEPTION 'Resident id is required'; END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.residents r
        WHERE r.id = v_id AND lower(coalesce(r.role, '')) NOT IN ('intern', 'consultant', 'viewer')
      ) THEN
        RAISE EXCEPTION 'Resident % cannot be on the bed roster', v_id;
      END IF;
      IF char_length(coalesce(v_item->>'batch', '')) > 40
         OR char_length(coalesce(v_item->>'short', '')) > 16 THEN
        RAISE EXCEPTION 'Batch or short name is too long';
      END IF;
      UPDATE public.residents
      SET bdft_batch = nullif(btrim(v_item->>'batch'), ''),
          bdft_short = nullif(btrim(v_item->>'short'), ''),
          bdft_order = nullif(v_item->>'order', '')::int
      WHERE id = v_id;
    END LOOP;

    IF EXISTS (
      SELECT 1 FROM public.bdft_bed_owners o
      JOIN public.residents r ON r.id = o.resident_id
      WHERE r.active IS FALSE
        AND NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(p_owners) x
          WHERE x->>'bedId' = o.bed_id AND x->>'residentId' = o.resident_id
        )
    ) THEN
      RAISE EXCEPTION 'Disabled owners stay on their beds';
    END IF;

    DELETE FROM public.bdft_bed_owners;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_owners) LOOP
      v_bed := nullif(btrim(v_item->>'bedId'), '');
      v_res := nullif(btrim(v_item->>'residentId'), '');
      IF v_bed IS NULL OR v_res IS NULL THEN RAISE EXCEPTION 'Bed owner is incomplete'; END IF;
      IF NOT EXISTS (SELECT 1 FROM public.beds b WHERE b.id = v_bed AND b.active IS NOT FALSE) THEN
        RAISE EXCEPTION 'Unknown bed %', v_bed;
      END IF;
      IF NOT EXISTS (
        SELECT 1 FROM public.residents r
        WHERE r.id = v_res AND lower(coalesce(r.role, '')) NOT IN ('intern', 'consultant', 'viewer')
      ) THEN
        RAISE EXCEPTION 'Owner % is not a resident', v_res;
      END IF;
      INSERT INTO public.bdft_bed_owners(bed_id, resident_id, updated_by, updated_at)
      VALUES (v_bed, v_res, a.actor_id, now());
    END LOOP;
  ELSE
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_people) LOOP
      v_id := nullif(btrim(v_item->>'id'), '');
      IF v_id = a.actor_id THEN
        IF char_length(coalesce(v_item->>'batch', '')) > 40
           OR char_length(coalesce(v_item->>'short', '')) > 16 THEN
          RAISE EXCEPTION 'Batch or short name is too long';
        END IF;
        UPDATE public.residents
        SET bdft_batch = nullif(btrim(v_item->>'batch'), ''),
            bdft_short = nullif(btrim(v_item->>'short'), ''),
            bdft_order = nullif(v_item->>'order', '')::int
        WHERE id = a.actor_id;
      END IF;
    END LOOP;

    DELETE FROM public.bdft_bed_owners WHERE resident_id = a.actor_id;
    FOR v_item IN SELECT value FROM jsonb_array_elements(p_owners) LOOP
      v_bed := nullif(btrim(v_item->>'bedId'), '');
      v_res := nullif(btrim(v_item->>'residentId'), '');
      IF v_res = a.actor_id AND v_bed IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM public.beds b WHERE b.id = v_bed AND b.active IS NOT FALSE) THEN
          RAISE EXCEPTION 'Unknown bed %', v_bed;
        END IF;
        INSERT INTO public.bdft_bed_owners(bed_id, resident_id, updated_by, updated_at)
        VALUES (v_bed, a.actor_id, a.actor_id, now())
        ON CONFLICT (bed_id) DO UPDATE
        SET resident_id = excluded.resident_id,
            updated_by = excluded.updated_by,
            updated_at = excluded.updated_at;
      END IF;
    END LOOP;
  END IF;

  RETURN public.ward_bdft_state(p_token);
EXCEPTION
  WHEN unique_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint = 'residents_active_pgt_bdft_short_unique_idx' THEN
      RAISE EXCEPTION 'This BDFT short code is already assigned to another active resident'
        USING ERRCODE = '23505';
    END IF;
    RAISE;
END;
$function$;

COMMIT;