-- R2.0.16: canonical full names and reliable consultant identity mapping.
ALTER TABLE public.residents
  ADD COLUMN IF NOT EXISTS full_name text;

COMMENT ON COLUMN public.residents.full_name IS
  'Full official name for formal documents; separate from the account display name.';

CREATE OR REPLACE FUNCTION public.ward_get_my_full_name(p_token uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_actor text;
  v_full_name text;
BEGIN
  SELECT ws.resident_id INTO v_actor
  FROM public.ward_sessions ws
  JOIN public.residents r ON r.id = ws.resident_id AND r.active = true
  WHERE ws.token = p_token
    AND ws.expires_at > pg_catalog.now()
  LIMIT 1;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired ward session' USING errcode = '42501';
  END IF;

  SELECT r.full_name INTO v_full_name
  FROM public.residents r
  WHERE r.id = v_actor;

  RETURN pg_catalog.jsonb_build_object('ok', true, 'full_name', v_full_name);
END;
$function$;

CREATE OR REPLACE FUNCTION public.ward_set_my_full_name(
  p_token uuid,
  p_full_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_actor text;
  v_full_name text;
BEGIN
  SELECT ws.resident_id INTO v_actor
  FROM public.ward_sessions ws
  JOIN public.residents r ON r.id = ws.resident_id AND r.active = true
  WHERE ws.token = p_token
    AND ws.expires_at > pg_catalog.now()
  LIMIT 1;

  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired ward session' USING errcode = '42501';
  END IF;

  v_full_name := NULLIF(pg_catalog.btrim(COALESCE(p_full_name, '')), '');
  IF v_full_name IS NOT NULL AND pg_catalog.char_length(v_full_name) > 120 THEN
    RAISE EXCEPTION 'Full name must be 120 characters or fewer' USING errcode = '23514';
  END IF;

  UPDATE public.residents
  SET full_name = v_full_name
  WHERE id = v_actor;

  RETURN pg_catalog.jsonb_build_object('ok', true, 'full_name', v_full_name);
END;
$function$;

CREATE OR REPLACE FUNCTION public.office_admin_set_user_full_name(
  p_token uuid,
  p_username text,
  p_full_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_id text;
  v_role text;
  v_full_name text;
BEGIN
  v_actor := private.require_office_admin(p_token);

  SELECT id, role INTO v_id, v_role
  FROM public.residents
  WHERE lower(username) = lower(trim(coalesce(p_username, '')))
  LIMIT 1;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'User not found' USING errcode = 'P0002';
  END IF;
  IF v_role = 'admin' THEN
    RAISE EXCEPTION 'Only an administrator can manage an admin account'
      USING errcode = '42501';
  END IF;

  v_full_name := NULLIF(pg_catalog.btrim(COALESCE(p_full_name, '')), '');
  IF v_full_name IS NOT NULL AND pg_catalog.char_length(v_full_name) > 120 THEN
    RAISE EXCEPTION 'Full name must be 120 characters or fewer' USING errcode = '23514';
  END IF;

  UPDATE public.residents
  SET full_name = v_full_name
  WHERE id = v_id;

  RETURN pg_catalog.jsonb_build_object('ok', true, 'id', v_id, 'full_name', v_full_name);
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
        'full_name', r.full_name,
        'role', r.role,
        'active', r.active,
        'created_at', r.created_at,
        'email', r.email,
        'designation', r.designation,
        'bdft_short', r.bdft_short,
        'bdft_batch', r.bdft_batch,
        'bdft_order', r.bdft_order,
        'aliases', coalesce((
          SELECT pg_catalog.jsonb_agg(m.norm_name ORDER BY m.norm_name)
          FROM public.consultant_name_map m
          WHERE m.resident_id = r.id
        ), '[]'::jsonb),
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

GRANT EXECUTE ON FUNCTION public.ward_get_my_full_name(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.ward_set_my_full_name(uuid, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.office_admin_set_user_full_name(uuid, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.office_admin_list_users(uuid) TO anon, authenticated;
