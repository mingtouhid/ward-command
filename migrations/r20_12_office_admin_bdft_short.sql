-- R2.0.12 office admin BDFT short name.
-- Applied to production 2026-11-21.
-- Adds a defaulted p_short argument to the existing office-admin user RPCs.
-- Callers that omit p_short keep the previous behaviour.
-- The value is public.residents.bdft_short. Active resident and admin codes stay unique
-- through residents_active_pgt_bdft_short_unique_idx. Roster membership stays
-- on resident id; this does not rewrite published roster snapshots.

BEGIN;

DROP FUNCTION IF EXISTS public.office_admin_invite_user(uuid, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.office_admin_update_user(uuid, text, text, text, text, text, boolean, text, text);

CREATE FUNCTION public.office_admin_invite_user(
  p_token uuid,
  p_username text,
  p_password text,
  p_display text,
  p_role text,
  p_email text DEFAULT NULL,
  p_designation text DEFAULT NULL,
  p_short text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, public, extensions
AS $function$
declare
  v_actor text;
  v_user text;
  v_role text;
  v_id text;
  v_active boolean;
  v_existing_role text;
  v_short text;
  v_constraint text;
begin
  v_actor := private.require_office_admin(p_token);
  v_user := lower(trim(p_username));
  v_role := lower(trim(coalesce(p_role,'resident')));

  if v_role not in ('resident','consultant','intern','office_admin') then
    raise exception 'Office Administration cannot assign the admin role' using errcode='42501';
  end if;
  if length(v_user)<2 then raise exception 'Username required' using errcode='23514'; end if;
  if length(coalesce(p_password,''))<6 then raise exception 'Password must be at least 6 characters' using errcode='23514'; end if;
  if length(trim(coalesce(p_display,'')))<2 then raise exception 'Display name required' using errcode='23514'; end if;

  v_short := nullif(btrim(coalesce(p_short,'')), '');
  if v_role not in ('resident','admin') then
    v_short := null;
  elsif v_short is not null and char_length(v_short) > 16 then
    raise exception 'BDFT short name must be 16 characters or fewer' using errcode='23514';
  end if;

  select id,active,role into v_id,v_active,v_existing_role
  from public.residents where lower(username)=v_user;

  if v_id is not null then
    if v_existing_role='admin' then
      raise exception 'Only an administrator can manage an admin account' using errcode='42501';
    end if;
    if v_active then raise exception 'Username already exists' using errcode='23505'; end if;
    update public.residents set
      display_name=trim(p_display), role=v_role, active=true,
      password_hash=crypt(p_password,gen_salt('bf')),
      email=coalesce(nullif(trim(coalesce(p_email,'')),''),email),
      designation=coalesce(nullif(trim(coalesce(p_designation,'')),''),designation),
      bdft_short=case when v_role in ('resident','admin') and p_short is not null then v_short else bdft_short end
    where id=v_id;
  else
    insert into public.residents(id,username,display_name,role,active,password_hash,email,designation,bdft_short)
    values ('r-'||substr(md5(random()::text),1,12),v_user,trim(p_display),v_role,true,
            crypt(p_password,gen_salt('bf')),
            nullif(trim(coalesce(p_email,'')),''),
            nullif(trim(coalesce(p_designation,'')),''),
            v_short)
    returning id into v_id;
  end if;
  return jsonb_build_object('ok',true,'id',v_id);
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'residents_active_pgt_bdft_short_unique_idx' then
      raise exception 'This BDFT short name is already used by another active resident or admin'
        using errcode='23505';
    end if;
    raise;
end;
$function$;

CREATE FUNCTION public.office_admin_update_user(
  p_token uuid,
  p_username text,
  p_new_username text,
  p_display text,
  p_password text,
  p_role text,
  p_active boolean,
  p_email text DEFAULT NULL,
  p_designation text DEFAULT NULL,
  p_short text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, public, extensions
AS $function$
declare
  v_actor text;
  v_id text;
  v_old_role text;
  v_old_active boolean;
  v_new_role text;
  v_new_username text;
  v_display text;
  v_active boolean;
  v_short text;
  v_constraint text;
begin
  v_actor := private.require_office_admin(p_token);

  select id,role,active into v_id,v_old_role,v_old_active
  from public.residents where lower(username)=lower(trim(p_username));
  if v_id is null then raise exception 'User not found' using errcode='P0002'; end if;
  if v_old_role='admin' then raise exception 'Only an administrator can modify an admin account' using errcode='42501'; end if;

  v_new_role := lower(trim(coalesce(p_role,v_old_role)));
  if v_new_role not in ('resident','consultant','intern','office_admin') then
    raise exception 'Office Administration cannot assign the admin role' using errcode='42501';
  end if;

  v_active := coalesce(p_active,v_old_active);
  if v_id=v_actor and (not v_active or v_new_role<>'office_admin') then
    raise exception 'You cannot deactivate or change the role of your own Office Administration account'
      using errcode='42501';
  end if;

  v_new_username := lower(trim(coalesce(p_new_username,p_username)));
  v_display := trim(coalesce(p_display,''));
  if length(v_new_username)<2 then raise exception 'Username required' using errcode='23514'; end if;
  if length(v_display)<2 then raise exception 'Display name required' using errcode='23514'; end if;
  if coalesce(p_password,'')<>'' and length(p_password)<6 then
    raise exception 'Password must be at least 6 characters' using errcode='23514';
  end if;
  if exists (select 1 from public.residents r where lower(r.username)=v_new_username and r.id<>v_id) then
    raise exception 'Username already exists' using errcode='23505';
  end if;

  v_short := nullif(btrim(coalesce(p_short,'')), '');
  if v_short is not null and char_length(v_short) > 16 then
    raise exception 'BDFT short name must be 16 characters or fewer' using errcode='23514';
  end if;

  update public.residents set
    username=v_new_username,
    display_name=v_display,
    role=v_new_role,
    active=v_active,
    password_hash=case when coalesce(p_password,'')<>'' then crypt(p_password,gen_salt('bf')) else password_hash end,
    email=case when p_email is null then email else nullif(trim(p_email),'') end,
    designation=case when p_designation is null then designation else nullif(trim(p_designation),'') end,
    bdft_short=case
      when v_new_role in ('resident','admin') and p_short is not null then v_short
      else bdft_short
    end
  where id=v_id;

  return jsonb_build_object('ok',true,'id',v_id,'role',v_new_role,'active',v_active);
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'residents_active_pgt_bdft_short_unique_idx' then
      raise exception 'This BDFT short name is already used by another active resident or admin'
        using errcode='23505';
    end if;
    raise;
end;
$function$;

REVOKE ALL ON FUNCTION public.office_admin_invite_user(uuid, text, text, text, text, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.office_admin_update_user(uuid, text, text, text, text, text, boolean, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.office_admin_invite_user(uuid, text, text, text, text, text, text, text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.office_admin_update_user(uuid, text, text, text, text, text, boolean, text, text, text) TO anon, authenticated, service_role;

COMMIT;
