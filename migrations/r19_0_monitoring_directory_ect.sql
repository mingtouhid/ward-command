-- R1.9.0. NOT APPLIED.
-- Additive: side-effect logs, a staff directory RPC, one ECT session per patient per IST day,
-- and a same-day BDFT finalise that updates today's current plan instead of archiving it.
-- No RLS policies. No history tables. Archived BDFT plans are not deleted.
--
-- Client dependence:
--   ward_save_se_log / ward_list_se_logs — Lithium/Clozapine chart sync.
--     If missing, the entry stays on this device and Needs You still clears locally.
--   ward_list_pgts — All PGTs photos and phone numbers, and on-duty photos.
--     If missing, names come from the ward resident list and photos fall back to initials.
--   ect_sessions unique index — rejects a second session for the same patient on the same IST day.
--     The button is also disabled. If the index is skipped because old duplicates exist, the client still rejects a new one.
--   ward_bdft_save_distribution — same signature. A repeat finalise for the same date rewrites that plan's lines.
--
-- Rollback:
-- drop function if exists public.ward_list_se_logs(uuid);
-- drop function if exists public.ward_save_se_log(uuid, jsonb);
-- drop function if exists public.ward_list_pgts(uuid);
-- drop index if exists public.ect_sessions_one_per_patient_ist_day;
-- drop table if exists public.ward_se_logs;
-- Restore ward_bdft_save_distribution from migrations/r18_1_bdft_resident_self_edit.sql if this rewrite must be undone.

create table if not exists public.ward_se_logs (
  id text primary key,
  patient_id text not null references public.patients(id) on delete cascade,
  med text not null check (med in ('lithium', 'clozapine')),
  day date not null,
  effects text[] not null default '{}',
  comments text not null default '',
  recorded_by text,
  created_at timestamptz not null default now(),
  unique (patient_id, med, day)
);
alter table public.ward_se_logs enable row level security;
alter table public.ward_se_logs force row level security;
revoke all on table public.ward_se_logs from public, anon, authenticated;
comment on table public.ward_se_logs is
  'R1.9: one side-effect entry per patient, medication and day. A second save does not overwrite the first. No policies.';

create or replace function public.ward_save_se_log(p_token uuid, p_row jsonb)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_actor text;
  v_id text;
  v_med text;
  v_day date;
begin
  select ws.resident_id into v_actor
  from public.ward_sessions ws
  join public.residents r on r.id = ws.resident_id and r.active
  where ws.token = p_token and ws.expires_at > now()
  limit 1;
  if v_actor is null then
    raise exception 'Invalid or expired ward session';
  end if;
  v_id := nullif(p_row->>'id', '');
  v_med := nullif(p_row->>'med', '');
  v_day := nullif(p_row->>'day', '')::date;
  if v_id is null or v_med not in ('lithium', 'clozapine') or v_day is null then
    raise exception 'Side-effect entry is incomplete';
  end if;
  insert into public.ward_se_logs(id, patient_id, med, day, effects, comments, recorded_by)
  values (
    v_id,
    p_row->>'patient_id',
    v_med,
    v_day,
    coalesce(array(select jsonb_array_elements_text(coalesce(p_row->'effects', '[]'::jsonb))), '{}'),
    left(coalesce(p_row->>'comments', ''), 500),
    v_actor
  )
  on conflict (patient_id, med, day) do nothing;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$fn$;

create or replace function public.ward_list_se_logs(p_token uuid)
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
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', l.id,
      'patient_id', l.patient_id,
      'med', l.med,
      'day', l.day,
      'effects', l.effects,
      'comments', l.comments,
      'recorded_by', l.recorded_by,
      'created_at', l.created_at
    ) order by l.day desc, l.created_at desc)
    from public.ward_se_logs l
  ), '[]'::jsonb);
end;
$fn$;

create or replace function public.ward_list_pgts(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_actor text;
  v_sql text;
  v_phone text;
  v_photo text;
  v_rows jsonb;
begin
  select ws.resident_id into v_actor
  from public.ward_sessions ws
  join public.residents r on r.id = ws.resident_id and r.active
  where ws.token = p_token and ws.expires_at > now()
  limit 1;
  if v_actor is null then
    raise exception 'Invalid or expired ward session';
  end if;
  v_phone := case when to_regclass('public.resident_phones') is not null
    then '(select p.phone_e164 from public.resident_phones p where p.resident_id = r.id)'
    else 'null::text' end;
  v_photo := case when to_regclass('public.ward_resident_photos') is not null
    then '(select wp.photo from public.ward_resident_photos wp where wp.resident_id = r.id)'
    else 'null::text' end;
  v_sql := 'select coalesce(jsonb_agg(jsonb_build_object('
    || '''id'', r.id, ''display_name'', coalesce(r.display_name, r.username), ''phone'', '
    || v_phone || ', ''photo'', ' || v_photo || ', ''active'', true'
    || ') order by coalesce(r.display_name, r.username)), ''[]''::jsonb) '
    || 'from public.residents r where r.active is not false '
    || 'and coalesce(r.role, '''') not in (''intern'', ''consultant'')';
  execute v_sql into v_rows;
  return jsonb_build_object('ok', true, 'people', coalesce(v_rows, '[]'::jsonb));
end;
$fn$;

do $ect$
begin
  if to_regclass('public.ect_sessions') is null then
    raise notice 'ect_sessions is not present; unique index skipped';
    return;
  end if;
  if exists (
    select 1 from public.ect_sessions
    group by patient_id, ((session_at at time zone 'Asia/Kolkata')::date)
    having count(*) > 1
  ) then
    raise notice 'ECT unique index skipped because a patient already has two sessions on one IST day';
    return;
  end if;
  execute 'create unique index if not exists ect_sessions_one_per_patient_ist_day '
    || 'on public.ect_sessions (patient_id, ((session_at at time zone ''Asia/Kolkata'')::date))';
end
$ect$;

-- Same signature as r18_1. A finalise for a date that is already current rewrites that plan's lines.
-- Other current plans are archived only when the date is different. Archived rows are kept.
create or replace function public.ward_bdft_save_distribution(
  p_token uuid,
  p_plan_date date,
  p_rows jsonb,
  p_meta jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  a record; v_id text; v_current text; v_item jsonb; v_date date;
  v_push jsonb; v_state jsonb;
begin
  select * into a from public.bdft_actor(p_token);
  if a.actor_role not in ('admin', 'resident') then
    raise exception 'Not authorized to save bed distribution';
  end if;

  v_date := coalesce(p_plan_date, current_date + 1);
  perform pg_advisory_xact_lock(hashtext('ward-bdft-current'));

  select id into v_current
  from public.bdft_distributions
  where status = 'current' and plan_date = v_date
  order by created_at desc
  limit 1;

  if v_current is not null then
    v_id := v_current;
    update public.bdft_distributions
      set updated_at = now(), updated_by = a.actor_id, version = version + 1
      where id = v_id;
    delete from public.bdft_rows where distribution_id = v_id;
  else
    v_id := 'bdft-' || to_char(v_date, 'YYYYMMDD') || '-' || substr(md5(random()::text), 1, 6);
    update public.bdft_distributions
      set status = 'archived', replaced_by = v_id, replaced_at = now()
      where status = 'current';
    v_push := public.bdft_queue_notice(v_id, a.actor_id, v_date);
    insert into public.bdft_distributions(
      id, plan_date, status, created_by, created_at, updated_at, updated_by, version,
      occupancy_at, census, push_status, notification_id
    ) values (
      v_id, v_date, 'current', a.actor_id, now(), now(), a.actor_id, 1,
      now(), 'live', coalesce(v_push->>'status', 'queued'), (v_push->>'notificationId')::uuid
    );
  end if;

  if jsonb_typeof(p_rows) = 'array' then
    for v_item in select value from jsonb_array_elements(p_rows) loop
      insert into public.bdft_rows(
        distribution_id, bed_id, bed_label, owner_id, holder_id, occupied, manual, reason, disabled_owner
      ) values (
        v_id,
        coalesce(v_item->>'bedId', v_item->>'bed_id', v_item->>'label', ''),
        coalesce(v_item->>'label', v_item->>'bedLabel', ''),
        nullif(v_item->>'ownerId', ''),
        nullif(v_item->>'holderId', ''),
        coalesce((v_item->>'occupied')::boolean, true),
        coalesce((v_item->>'manual')::boolean, false),
        coalesce(v_item->>'reason', 'assigned'),
        coalesce((v_item->>'disabled')::boolean, false)
      ) on conflict (distribution_id, bed_id) do update
        set holder_id = excluded.holder_id, manual = excluded.manual, occupied = excluded.occupied, reason = excluded.reason;
    end loop;
  end if;

  v_state := public.ward_bdft_state(p_token);
  return jsonb_set(coalesce(v_state, '{}'::jsonb), '{notification_id}', to_jsonb(coalesce(v_push->>'notificationId', '')));
end;
$fn$;

revoke all on function public.ward_save_se_log(uuid, jsonb) from public;
revoke all on function public.ward_list_se_logs(uuid) from public;
revoke all on function public.ward_list_pgts(uuid) from public;
grant execute on function public.ward_save_se_log(uuid, jsonb) to anon, authenticated, service_role;
grant execute on function public.ward_list_se_logs(uuid) to anon, authenticated, service_role;
grant execute on function public.ward_list_pgts(uuid) to anon, authenticated, service_role;
