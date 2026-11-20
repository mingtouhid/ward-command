BEGIN;

-- Current published PGT rosters must use the same canonical short codes as
-- the duty cells (which are authored from BDFT). Keep historical display
-- names and all duty assignments unchanged. Older, non-current published
-- rosters remain immutable snapshots.
DO $migration$
DECLARE
  v_roster record;
  v_groups jsonb;
  v_changed integer := 0;
BEGIN
  FOR v_roster IN
    SELECT id, content
    FROM private.duty_rosters
    WHERE roster_type = 'pgt_monthly'
      AND status = 'published'
      AND is_current IS TRUE
      AND period_end >= (pg_catalog.now() AT TIME ZONE 'Asia/Kolkata')::date
    FOR UPDATE
  LOOP
    SELECT coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_set(
          g.value,
          '{members}',
          coalesce((
            SELECT pg_catalog.jsonb_agg(
              CASE
                WHEN r.id IS NOT NULL
                  THEN pg_catalog.jsonb_set(m.value, '{abbr}', pg_catalog.to_jsonb(r.bdft_short), true)
                ELSE m.value
              END
              ORDER BY m.ordinality
            )
            FROM pg_catalog.jsonb_array_elements(coalesce(g.value->'members','[]'::jsonb))
                 WITH ORDINALITY AS m(value, ordinality)
            LEFT JOIN public.residents r
              ON r.id = coalesce(m.value->>'residentId',m.value->>'resident_id')
          ), '[]'::jsonb),
          true
        )
        ORDER BY g.ordinality
      ),
      '[]'::jsonb
    )
    INTO v_groups
    FROM pg_catalog.jsonb_array_elements(coalesce(v_roster.content->'groups','[]'::jsonb))
         WITH ORDINALITY AS g(value, ordinality);

    UPDATE private.duty_rosters
    SET content = pg_catalog.jsonb_set(v_roster.content,'{groups}',v_groups,true),
        updated_at = pg_catalog.now()
    WHERE id = v_roster.id;

    v_changed := v_changed + 1;
  END LOOP;

  RAISE NOTICE 'Synchronized canonical BDFT short codes in % current published PGT roster(s)', v_changed;
END;
$migration$;

COMMIT;