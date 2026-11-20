-- Verification checks for migrations/r20_canonical_pgt_resident_identity.sql.
-- Run after applying the migration. This file is read-only.

DO $verify$
DECLARE
  v_missing_config_links bigint;
  v_orphan_members bigint;
  v_duplicate_codes bigint;
  v_unlinked_recent_roster_members bigint;
  v_rls_groups boolean;
  v_rls_members boolean;
  v_index_exists boolean;
  v_group_policy_count integer;
  v_member_policy_count integer;
  v_group_fk_index boolean;
  v_resident_fk_index boolean;
BEGIN
  SELECT count(*) INTO v_missing_config_links
  FROM private.office_admin_pgt_group_sets s
  CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(coalesce(s.groups, '[]'::jsonb)) g
  CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(coalesce(g->'members', '[]'::jsonb)) m
  WHERE NULLIF(m->>'residentId', '') IS NULL;
  IF v_missing_config_links > 0 THEN
    RAISE EXCEPTION 'Found % saved PGT members without residentId', v_missing_config_links;
  END IF;

  SELECT count(*) INTO v_orphan_members
  FROM private.office_admin_pgt_group_members gm
  LEFT JOIN public.residents r ON r.id = gm.resident_id
  WHERE r.id IS NULL;
  IF v_orphan_members > 0 THEN
    RAISE EXCEPTION 'Found % PGT membership rows without a resident record', v_orphan_members;
  END IF;

  SELECT count(*) INTO v_duplicate_codes
  FROM (
    SELECT upper(btrim(bdft_short))
    FROM public.residents
    WHERE active IS TRUE
      AND lower(coalesce(role, '')) IN ('resident', 'admin')
      AND NULLIF(btrim(bdft_short), '') IS NOT NULL
    GROUP BY upper(btrim(bdft_short))
    HAVING count(*) > 1
  ) d;
  IF v_duplicate_codes > 0 THEN
    RAISE EXCEPTION 'Found % duplicate active resident/admin BDFT codes', v_duplicate_codes;
  END IF;

  SELECT count(*) INTO v_unlinked_recent_roster_members
  FROM private.duty_rosters d
  CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(coalesce(d.content->'groups', '[]'::jsonb)) g
  CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(coalesce(g->'members', '[]'::jsonb)) m
  WHERE d.roster_type = 'pgt_monthly'
    AND (
      d.status IN ('draft', 'review')
      OR (d.status = 'published' AND coalesce(d.period_end, d.period_start) >=
          ((pg_catalog.now() AT TIME ZONE 'Asia/Kolkata')::date - 62))
    )
    AND NULLIF(coalesce(m->>'residentId', m->>'resident_id'), '') IS NULL;
  IF v_unlinked_recent_roster_members > 0 THEN
    RAISE EXCEPTION 'Found % recent/current or editable roster members without residentId', v_unlinked_recent_roster_members;
  END IF;

  SELECT c.relrowsecurity INTO v_rls_groups
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'private' AND c.relname = 'office_admin_pgt_groups';

  SELECT c.relrowsecurity INTO v_rls_members
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'private' AND c.relname = 'office_admin_pgt_group_members';

  IF coalesce(v_rls_groups, false) IS NOT TRUE OR coalesce(v_rls_members, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'RLS is not enabled on the private PGT identity tables';
  END IF;

  SELECT count(*) INTO v_group_policy_count FROM pg_catalog.pg_policies
  WHERE schemaname='private' AND tablename='office_admin_pgt_groups';
  SELECT count(*) INTO v_member_policy_count FROM pg_catalog.pg_policies
  WHERE schemaname='private' AND tablename='office_admin_pgt_group_members';
  IF v_group_policy_count < 1 OR v_member_policy_count < 1 THEN
    RAISE EXCEPTION 'Private PGT identity tables need explicit deny-by-default policies';
  END IF;

  SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname='private'
    AND indexname='office_admin_pgt_group_members_group_set_group_idx') INTO v_group_fk_index;
  SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_indexes WHERE schemaname='private'
    AND indexname='office_admin_pgt_group_members_resident_idx') INTO v_resident_fk_index;
  IF NOT v_group_fk_index OR NOT v_resident_fk_index THEN
    RAISE EXCEPTION 'Supporting indexes for PGT membership foreign keys are missing';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_catalog.pg_indexes
    WHERE schemaname = 'public'
      AND indexname = 'residents_active_pgt_bdft_short_unique_idx'
  ) INTO v_index_exists;
  IF NOT v_index_exists THEN
    RAISE EXCEPTION 'Canonical active PGT short-code unique index is missing';
  END IF;
END;
$verify$;

SELECT s.name AS group_set,
       count(DISTINCT g.id) AS groups,
       count(gm.resident_id) AS linked_residents
FROM private.office_admin_pgt_group_sets s
LEFT JOIN private.office_admin_pgt_groups g ON g.group_set_id = s.id
LEFT JOIN private.office_admin_pgt_group_members gm ON gm.group_id = g.id
GROUP BY s.id, s.name
ORDER BY s.name;

SELECT d.title,
       count(*) FILTER (WHERE NULLIF(m->>'residentId', '') IS NOT NULL) AS members_with_resident_id,
       count(*) FILTER (WHERE NULLIF(m->>'residentId', '') IS NULL) AS members_without_resident_id
FROM private.duty_rosters d
CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(coalesce(d.content->'groups', '[]'::jsonb)) g
CROSS JOIN LATERAL pg_catalog.jsonb_array_elements(coalesce(g->'members', '[]'::jsonb)) m
WHERE d.roster_type = 'pgt_monthly'
GROUP BY d.id, d.title
ORDER BY d.title;
