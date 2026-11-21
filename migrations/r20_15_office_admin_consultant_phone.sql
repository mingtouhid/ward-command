-- R2.0.15: allow Office Administration to save phone numbers for active consultant accounts.
-- The existing private resident_phones store and Office Admin users RPC are reused.
-- Consultant phone values are not exposed through the broad clinical ward-state response.

CREATE OR REPLACE FUNCTION public.office_admin_set_user_phone(
  p_token uuid,
  p_username text,
  p_phone text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_actor text;
  v_id text;
  v_role text;
  v_new text;
  v_old text;
  v_action text;
BEGIN
  v_actor := private.require_office_admin(p_token);

  SELECT id, role INTO v_id, v_role
  FROM public.residents
  WHERE lower(username) = lower(trim(coalesce(p_username, '')))
    AND active = true;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'User not found';
  END IF;
  IF v_role = 'admin' THEN
    RAISE EXCEPTION 'Only an administrator can manage an admin account'
      USING errcode = '42501';
  END IF;

  -- Both resident and consultant accounts are valid faculty/staff contacts.
  v_new := public.ward_phone_e164(p_phone);
  SELECT phone_e164 INTO v_old
  FROM public.resident_phones
  WHERE resident_id = v_id;

  IF v_new IS NULL THEN
    IF v_old IS NOT NULL THEN
      DELETE FROM public.resident_phones WHERE resident_id = v_id;
      v_action := 'cleared';
    END IF;
  ELSIF v_old IS DISTINCT FROM v_new THEN
    INSERT INTO public.resident_phones(resident_id, phone_e164, updated_at, updated_by)
    VALUES (v_id, v_new, pg_catalog.now(), v_actor)
    ON CONFLICT (resident_id) DO UPDATE
      SET phone_e164 = excluded.phone_e164,
          updated_at = excluded.updated_at,
          updated_by = excluded.updated_by;
    v_action := CASE WHEN v_old IS NULL THEN 'set' ELSE 'changed' END;
  END IF;

  IF v_action IS NOT NULL THEN
    INSERT INTO public.resident_phone_audit(resident_id, actor_id, action)
    VALUES (v_id, v_actor, v_action);
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'id', v_id,
    'has_phone', v_new IS NOT NULL,
    'changed', v_action IS NOT NULL
  );
END;
$function$;

COMMENT ON FUNCTION public.office_admin_set_user_phone(uuid, text, text) IS
  'Office Admin only. Stores active non-admin staff phone numbers, including consultant accounts, in resident_phones; phone numbers are not exposed in broad ward state.';
