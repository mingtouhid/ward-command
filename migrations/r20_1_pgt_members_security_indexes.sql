BEGIN;

-- Cover both child-side foreign keys for predictable delete/update and join costs.
CREATE INDEX IF NOT EXISTS office_admin_pgt_group_members_group_set_group_idx
  ON private.office_admin_pgt_group_members (group_set_id, group_id);

CREATE INDEX IF NOT EXISTS office_admin_pgt_group_members_resident_idx
  ON private.office_admin_pgt_group_members (resident_id);

-- The tables live in the unexposed private schema and are accessed by
-- postgres-owned SECURITY DEFINER RPCs. Explicit deny policies keep any future
-- direct grants closed by default; the table/function owner bypasses RLS.
DO $policy$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
    WHERE schemaname='private'
      AND tablename='office_admin_pgt_groups'
      AND policyname='deny_direct_access'
  ) THEN
    CREATE POLICY deny_direct_access
      ON private.office_admin_pgt_groups
      AS PERMISSIVE
      FOR ALL
      TO PUBLIC
      USING (false)
      WITH CHECK (false);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
    WHERE schemaname='private'
      AND tablename='office_admin_pgt_group_members'
      AND policyname='deny_direct_access'
  ) THEN
    CREATE POLICY deny_direct_access
      ON private.office_admin_pgt_group_members
      AS PERMISSIVE
      FOR ALL
      TO PUBLIC
      USING (false)
      WITH CHECK (false);
  END IF;
END;
$policy$;

COMMIT;