-- R1.8.5 own profile photo. NOT APPLIED. Additive and reversible. No Storage, no RLS policies.
-- One photo per resident. resident_id is the primary key, so a new photo replaces the old row
-- (INSERT ... ON CONFLICT (resident_id) DO UPDATE). Clear deletes that row.
-- There is no history table, no version rows, and no Storage object.
-- residents.id is text (same FK as resident_phones.resident_id).
--
-- Rollback:
-- revoke all on function public.ward_get_my_photo(uuid) from public, anon, authenticated, service_role;
-- revoke all on function public.ward_clear_my_photo(uuid) from public, anon, authenticated, service_role;
-- revoke all on function public.ward_set_my_photo(uuid, text) from public, anon, authenticated, service_role;
-- drop function if exists public.ward_get_my_photo(uuid);
-- drop function if exists public.ward_clear_my_photo(uuid);
-- drop function if exists public.ward_set_my_photo(uuid, text);
-- drop table if exists public.ward_resident_photos;

do $chk$
begin
  if (select data_type from information_schema.columns
      where table_schema='public' and table_name='residents' and column_name='id')
     is distinct from 'text' then
    raise exception 'ward_resident_photos expects public.residents.id to be text';
  end if;
end
$chk$;

create table if not exists public.ward_resident_photos (
  resident_id text primary key references public.residents(id) on delete cascade,
  photo text not null,
  updated_at timestamptz not null default now()
);

alter table public.ward_resident_photos enable row level security;
alter table public.ward_resident_photos force row level security;
revoke all on table public.ward_resident_photos from public, anon, authenticated;

comment on table public.ward_resident_photos is
  'R1.8.5: one JPEG data URL per resident. A save replaces the row (resident_id primary key). Clear deletes it. No history, no Storage. No policies. Access only via ward_get_my_photo / ward_set_my_photo / ward_clear_my_photo.';

create or replace function public.ward_set_my_photo(p_token uuid, p_photo text)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_actor text;
begin
  select ws.resident_id into v_actor
  from public.ward_sessions ws
  join public.residents r on r.id = ws.resident_id and r.active
  where ws.token = p_token and ws.expires_at > now()
  limit 1;
  if v_actor is null then
    raise exception 'Invalid or expired ward session';
  end if;
  if p_photo is null
     or left(p_photo, 23) <> 'data:image/jpeg;base64,'
     or char_length(p_photo) > 200000 then
    raise exception 'Photo must be a JPEG data URL of at most 200000 characters';
  end if;
  -- Replaces the previous photo. The primary key stops a second row for the same resident.
  insert into public.ward_resident_photos(resident_id, photo, updated_at)
  values (v_actor, p_photo, now())
  on conflict (resident_id) do update
    set photo = excluded.photo,
        updated_at = excluded.updated_at;
  return jsonb_build_object('ok', true, 'id', v_actor, 'updated_at', now());
end;
$fn$;

create or replace function public.ward_clear_my_photo(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_actor text;
begin
  select ws.resident_id into v_actor
  from public.ward_sessions ws
  join public.residents r on r.id = ws.resident_id and r.active
  where ws.token = p_token and ws.expires_at > now()
  limit 1;
  if v_actor is null then
    raise exception 'Invalid or expired ward session';
  end if;
  delete from public.ward_resident_photos where resident_id = v_actor;
  return jsonb_build_object('ok', true, 'id', v_actor);
end;
$fn$;

create or replace function public.ward_get_my_photo(p_token uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_actor text;
  v_photo text;
  v_at timestamptz;
begin
  select ws.resident_id into v_actor
  from public.ward_sessions ws
  join public.residents r on r.id = ws.resident_id and r.active
  where ws.token = p_token and ws.expires_at > now()
  limit 1;
  if v_actor is null then
    raise exception 'Invalid or expired ward session';
  end if;
  select photo, updated_at into v_photo, v_at
  from public.ward_resident_photos
  where resident_id = v_actor;
  return jsonb_build_object('ok', true, 'id', v_actor, 'photo', v_photo, 'updated_at', v_at);
end;
$fn$;

revoke all on function public.ward_set_my_photo(uuid, text) from public;
revoke all on function public.ward_clear_my_photo(uuid) from public;
revoke all on function public.ward_get_my_photo(uuid) from public;
grant execute on function public.ward_set_my_photo(uuid, text) to anon, authenticated, service_role;
grant execute on function public.ward_clear_my_photo(uuid) to anon, authenticated, service_role;
grant execute on function public.ward_get_my_photo(uuid) to anon, authenticated, service_role;
