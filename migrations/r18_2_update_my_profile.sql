-- R1.8.1 My profile: a signed-in person may change only their own username and display name.
-- NOT APPLIED. Do not run this against production from the client. No role or permission change.
-- Phone stays on ward_set_resident_phone / ward_get_my_phone. BDFT short name and owned beds stay on ward_bdft_save_setup.

create or replace function public.ward_update_my_profile(p_token uuid, p_username text, p_display text)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_actor text;
  v_username text;
  v_display text;
begin
  select ws.resident_id into v_actor
  from public.ward_sessions ws
  join public.residents r on r.id = ws.resident_id and r.active
  where ws.token = p_token and ws.expires_at > now()
  limit 1;
  if v_actor is null then
    raise exception 'Invalid or expired ward session';
  end if;

  v_username := lower(btrim(coalesce(p_username, '')));
  v_display := btrim(coalesce(p_display, ''));
  if v_username !~ '^[a-z0-9][a-z0-9._-]{0,31}$' then
    raise exception 'Username must be letters, numbers, dot, underscore or hyphen';
  end if;
  if v_display = '' or char_length(v_display) > 80 then
    raise exception 'Display name is required';
  end if;
  if exists (
    select 1 from public.residents
    where lower(username) = v_username and id <> v_actor
  ) then
    raise exception 'That username is already in use';
  end if;

  update public.residents
    set username = v_username,
        display_name = v_display
    where id = v_actor and active;

  return jsonb_build_object('ok', true, 'id', v_actor, 'username', v_username, 'display_name', v_display);
end;
$fn$;

revoke all on function public.ward_update_my_profile(uuid, text, text) from public;
grant execute on function public.ward_update_my_profile(uuid, text, text) to anon, authenticated, service_role;
