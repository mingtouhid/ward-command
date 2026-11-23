-- R2.0.18: persist official roster names against the stable resident/user ID.
-- The legacy username-based setter remains available for older clients.

CREATE OR REPLACE FUNCTION public.office_admin_set_user_full_name_by_id(
  p_token uuid,
  p_user_id text,
  p_full_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_user_id text;
  v_role text;
  v_full_name text;
BEGIN
  v_actor := private.require_office_admin(p_token);

  v_user_id := NULLIF(pg_catalog.btrim(COALESCE(p_user_id, '')), '');
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'User ID is required' USING errcode = '23514';
  END IF;

  SELECT r.role
  INTO v_role
  FROM public.residents r
  WHERE r.id = v_user_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User not found' USING errcode = 'P0002';
  END IF;

  IF v_role = 'admin' THEN
    RAISE EXCEPTION 'Only an administrator can manage an admin account'
      USING errcode = '42501';
  END IF;

  v_full_name := NULLIF(pg_catalog.btrim(COALESCE(p_full_name, '')), '');
  IF v_full_name IS NOT NULL
     AND pg_catalog.char_length(v_full_name) > 120 THEN
    RAISE EXCEPTION 'Full name must be 120 characters or fewer'
      USING errcode = '23514';
  END IF;

  UPDATE public.residents
  SET full_name = v_full_name
  WHERE id = v_user_id;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'id', v_user_id,
    'full_name', v_full_name
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.office_admin_set_user_full_name_by_id(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.office_admin_set_user_full_name_by_id(uuid, text, text) TO anon, authenticated;
