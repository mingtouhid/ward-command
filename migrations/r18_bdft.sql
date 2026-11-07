-- R1.8 bed distribution. PREPARED, NOT APPLIED to production.
-- One owner per physical bed. Evening-shift residents generate. The creator edits the current board.
-- An admin who did not generate it cannot edit it. Roster setup stays an admin settings action.
-- Occupancy is read from beds. This does not write the census.
-- Rollback: migrations/r18_bdft.rollback.sql

alter table public.residents add column if not exists bdft_batch text;
alter table public.residents add column if not exists bdft_short text;
alter table public.residents add column if not exists bdft_order integer;

create table if not exists public.bdft_bed_owners (
  bed_id text primary key,
  resident_id text not null,
  updated_by text,
  updated_at timestamptz not null default now()
);
alter table public.bdft_bed_owners enable row level security;
alter table public.bdft_bed_owners force row level security;
revoke all on table public.bdft_bed_owners from public, anon, authenticated;
grant all on table public.bdft_bed_owners to postgres, service_role;

create table if not exists public.bdft_distributions (
  id text primary key,
  plan_date date not null,
  status text not null default 'current',
  created_by text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text,
  version integer not null default 1,
  occupancy_at timestamptz,
  included_beds text[] not null default '{}',
  absent_ids text[] not null default '{}',
  census text not null default 'live',
  push_status text not null default 'not_queued',
  notification_id uuid,
  undo_stack jsonb not null default '[]'::jsonb,
  replaced_by text,
  replaced_at timestamptz,
  constraint bdft_distributions_status_check check (status in ('current','archived')),
  constraint bdft_distributions_census_check check (census in ('live','empty'))
);
create unique index if not exists bdft_one_current on public.bdft_distributions(status) where status = 'current';
alter table public.bdft_distributions enable row level security;
alter table public.bdft_distributions force row level security;
revoke all on table public.bdft_distributions from public, anon, authenticated;
grant all on table public.bdft_distributions to postgres, service_role;

create table if not exists public.bdft_rows (
  distribution_id text not null,
  bed_id text not null,
  bed_label text not null,
  owner_id text,
  holder_id text,
  occupied boolean not null,
  manual boolean not null default false,
  reason text not null,
  disabled_owner boolean not null default false,
  primary key (distribution_id, bed_id)
);
alter table public.bdft_rows enable row level security;
alter table public.bdft_rows force row level security;
revoke all on table public.bdft_rows from public, anon, authenticated;
grant all on table public.bdft_rows to postgres, service_role;

create or replace function public.bdft_actor(p_token uuid)
returns table(actor_id text, actor_role text, actor_name text)
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare v_id text; v_role text; v_name text;
begin
  select s.resident_id, lower(coalesce(r.role,'')), coalesce(r.display_name, r.username, r.id)
    into v_id, v_role, v_name
  from public.ward_sessions s
  join public.residents r on r.id = s.resident_id
  where s.token = p_token and s.expires_at > now() and r.active is not false;
  if v_id is null then raise exception 'Invalid or expired ward session'; end if;
  if v_role in ('intern','consultant','viewer') then raise exception 'Not available for this login'; end if;
  if v_role = 'sr' then v_role := 'admin'; end if;
  if v_role <> 'admin' then v_role := 'resident'; end if;
  actor_id := v_id; actor_role := v_role; actor_name := v_name;
  return next;
end;
$fn$;

create or replace function public.bdft_on_evening(p_resident text)
returns boolean
language sql
stable
security definer
set search_path to pg_catalog, public
as $fn$
  select exists(
    select 1 from public.ward_duty wd
    where wd.resident_id = p_resident
      and wd.ended_at is null
      and wd.shift = 'evening'
      and wd.started_at > now() - interval '20 hours'
  );
$fn$;

create or replace function public.bdft_compute(p_included text[], p_absent text[])
returns jsonb
language plpgsql
stable
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_people jsonb := '[]'::jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_pending jsonb := '[]'::jsonb;
  v_bed text;
  v_label text;
  v_owner text;
  v_batch text;
  v_active boolean;
  v_order int;
  v_prefix text;
  v_num int;
  v_item jsonb;
  v_cand jsonb;
  v_pick text;
  v_min int;
  v_count int;
  v_clean boolean;
  v_adj boolean;
  v_held jsonb := '{}'::jsonb;
  v_counts jsonb := '{}'::jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(x) order by x.ord, x.name, x.id), '[]'::jsonb) into v_people
  from (
    select r.id, coalesce(r.bdft_batch,'') as batch, coalesce(nullif(btrim(r.bdft_short),''), r.display_name, r.username, r.id) as short,
           r.active is not false as active, coalesce(r.bdft_order, 1000000) as ord, coalesce(r.display_name, r.username, r.id) as name
    from public.residents r
    where lower(coalesce(r.role,'')) not in ('intern','consultant','viewer')
  ) x;
  foreach v_bed in array coalesce(p_included, '{}') loop
    select b.bed_number into v_label from public.beds b where b.id = v_bed and b.active is not false;
    if v_label is null then raise exception 'Unknown bed %', v_bed; end if;
    if not exists (select 1 from public.beds b where b.id = v_bed and nullif(b.current_patient_id,'') is not null) then
      raise exception 'Bed % is not occupied', v_bed;
    end if;
    select o.resident_id into v_owner from public.bdft_bed_owners o where o.bed_id = v_bed;
    if v_label ~ '^(.*?)([0-9]+)$' then
      v_prefix := substring(v_label from '^(.*?)[0-9]+$');
      v_num := substring(v_label from '([0-9]+)$')::int;
    else
      v_prefix := v_label; v_num := null;
    end if;
    v_item := jsonb_build_object('bedId', v_bed, 'label', v_label, 'prefix', v_prefix, 'num', v_num, 'ownerId', v_owner);
    if v_owner is null or not exists (select 1 from jsonb_array_elements(v_people) p where p->>'id' = v_owner) then
      v_rows := v_rows || jsonb_build_array(v_item || jsonb_build_object('holderId', null, 'manual', false, 'reason', 'unmapped', 'disabled', false));
    elsif v_owner = any(coalesce(p_absent, '{}')) then
      v_pending := v_pending || jsonb_build_array(v_item);
    else
      select (p->>'active')::boolean into v_active from jsonb_array_elements(v_people) p where p->>'id' = v_owner;
      v_held := jsonb_set(v_held, array[v_owner], coalesce(v_held->v_owner, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('prefix', v_prefix, 'num', v_num)), true);
      v_counts := jsonb_set(v_counts, array[v_owner], to_jsonb(coalesce((v_counts->>v_owner)::int, 0) + 1), true);
      v_rows := v_rows || jsonb_build_array(v_item || jsonb_build_object('holderId', v_owner, 'manual', false, 'reason', 'kept', 'disabled', not coalesce(v_active, false)));
    end if;
  end loop;
  -- stable bed order
  select coalesce(jsonb_agg(x.item order by x.item->>'prefix', coalesce((x.item->>'num')::int, 0), x.item->>'bedId'), '[]'::jsonb)
    into v_pending
  from jsonb_array_elements(v_pending) as x(item);
  for v_item in select value from jsonb_array_elements(v_pending) loop
    select coalesce(p->>'batch',''), (p->>'active')::boolean into v_batch, v_active
      from jsonb_array_elements(v_people) p where p->>'id' = v_item->>'ownerId';
    v_pick := null; v_min := null; v_clean := false;
    for v_cand in
      select value from jsonb_array_elements(v_people)
      where (value->>'active')::boolean
        and not ((value->>'id') = any(coalesce(p_absent, '{}')))
        and coalesce(value->>'batch','') = coalesce(v_batch,'')
      order by coalesce((value->>'ord')::int, 1000000), value->>'name', value->>'id'
    loop
      v_count := coalesce((v_counts->>(v_cand->>'id'))::int, 0);
      v_adj := exists (
        select 1 from jsonb_array_elements(coalesce(v_held->(v_cand->>'id'), '[]'::jsonb)) h
        where coalesce(h->>'prefix','') = coalesce(v_item->>'prefix','')
          and (h->>'num') is not null and (v_item->>'num') is not null
          and abs((h->>'num')::int - (v_item->>'num')::int) = 1
      );
      if v_min is null or v_count < v_min then
        v_min := v_count; v_pick := v_cand->>'id'; v_clean := not v_adj;
      elsif v_count = v_min and not v_adj and not v_clean then
        v_pick := v_cand->>'id'; v_clean := true;
      end if;
    end loop;
    if v_pick is null then
      v_rows := v_rows || jsonb_build_array(v_item || jsonb_build_object('holderId', null, 'manual', false, 'reason', 'orphan', 'disabled', not coalesce(v_active, true)));
    else
      v_held := jsonb_set(v_held, array[v_pick], coalesce(v_held->v_pick, '[]'::jsonb) || jsonb_build_array(jsonb_build_object('prefix', v_item->>'prefix', 'num', v_item->>'num')), true);
      v_counts := jsonb_set(v_counts, array[v_pick], to_jsonb(coalesce((v_counts->>v_pick)::int, 0) + 1), true);
      v_rows := v_rows || jsonb_build_array(v_item || jsonb_build_object('holderId', v_pick, 'manual', false, 'reason', 'redistributed', 'disabled', not coalesce(v_active, true)));
    end if;
  end loop;
  return v_rows;
end;
$fn$;

create or replace function public.bdft_pack(p_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path to pg_catalog, public
as $fn$
declare v_head public.bdft_distributions; v_rows jsonb; v_name text;
begin
  select * into v_head from public.bdft_distributions where id = p_id;
  if not found then return null; end if;
  select coalesce(display_name, username, id) into v_name from public.residents where id = v_head.created_by;
  select coalesce(jsonb_agg(jsonb_build_object(
    'bedId', r.bed_id, 'label', r.bed_label, 'ownerId', r.owner_id, 'holderId', r.holder_id,
    'occupied', r.occupied, 'manual', r.manual, 'reason', r.reason, 'disabled', r.disabled_owner
  ) order by r.bed_label, r.bed_id), '[]'::jsonb) into v_rows
  from public.bdft_rows r where r.distribution_id = p_id;
  return jsonb_build_object(
    'id', v_head.id, 'planDate', v_head.plan_date, 'status', v_head.status,
    'createdBy', v_head.created_by, 'createdName', coalesce(v_name,''),
    'updatedAt', v_head.updated_at, 'version', v_head.version,
    'occupancyAt', v_head.occupancy_at, 'census', v_head.census,
    'push', v_head.push_status, 'rows', v_rows
  );
end;
$fn$;

create or replace function public.ward_bdft_state(p_token uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_current text; v_archives jsonb; v_people jsonb; v_owners jsonb; v_beds jsonb;
begin
  select * into a from public.bdft_actor(p_token);
  select id into v_current from public.bdft_distributions where status = 'current';
  select coalesce(jsonb_agg(to_jsonb(x) order by x.ord, x.name, x.id), '[]'::jsonb) into v_people from (
    select r.id, coalesce(r.bdft_batch,'') as batch, coalesce(nullif(btrim(r.bdft_short),''), '') as short,
           r.active is not false as active, coalesce(r.bdft_order, 1000000) as ord,
           coalesce(r.display_name, r.username, r.id) as name
    from public.residents r
    where lower(coalesce(r.role,'')) not in ('intern','consultant','viewer')
  ) x;
  select coalesce(jsonb_agg(jsonb_build_object('bedId', o.bed_id, 'residentId', o.resident_id) order by o.bed_id), '[]'::jsonb)
    into v_owners from public.bdft_bed_owners o;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', b.id, 'label', b.bed_number, 'occupied', nullif(b.current_patient_id,'') is not null
  ) order by b.bed_number, b.id), '[]'::jsonb) into v_beds
  from public.beds b where b.active is not false;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', d.id, 'planDate', d.plan_date, 'createdName', coalesce(r.display_name, r.username, d.created_by),
    'updatedAt', d.updated_at
  ) order by d.created_at desc), '[]'::jsonb) into v_archives
  from (
    select * from public.bdft_distributions where status = 'archived' order by created_at desc limit 7
  ) d left join public.residents r on r.id = d.created_by;
  return jsonb_build_object(
    'ok', true,
    'me', jsonb_build_object('id', a.actor_id, 'role', a.actor_role, 'name', a.actor_name, 'evening', public.bdft_on_evening(a.actor_id)),
    'people', v_people, 'owners', v_owners, 'beds', v_beds,
    'current', public.bdft_pack(v_current),
    'archives', v_archives
  );
end;
$fn$;

create or replace function public.ward_bdft_save_setup(p_token uuid, p_people jsonb, p_owners jsonb)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_item jsonb; v_id text; v_bed text; v_res text;
begin
  select * into a from public.bdft_actor(p_token);
  if a.actor_role <> 'admin' then raise exception 'Roster setup is an admin setting'; end if;
  if jsonb_typeof(p_people) <> 'array' or jsonb_typeof(p_owners) <> 'array' then raise exception 'Setup payload is invalid'; end if;
  for v_item in select value from jsonb_array_elements(p_people) loop
    v_id := nullif(btrim(v_item->>'id'), '');
    if v_id is null then raise exception 'Resident id is required'; end if;
    if not exists (select 1 from public.residents r where r.id = v_id and lower(coalesce(r.role,'')) not in ('intern','consultant','viewer')) then
      raise exception 'Resident % cannot be on the bed roster', v_id;
    end if;
    if char_length(coalesce(v_item->>'batch','')) > 40 or char_length(coalesce(v_item->>'short','')) > 16 then
      raise exception 'Batch or short name is too long';
    end if;
    update public.residents
      set bdft_batch = nullif(btrim(v_item->>'batch'), ''),
          bdft_short = nullif(btrim(v_item->>'short'), ''),
          bdft_order = nullif(v_item->>'order','')::int
      where id = v_id;
  end loop;
  if exists (
    select 1 from public.bdft_bed_owners o
    join public.residents r on r.id = o.resident_id
    where r.active is false
      and not exists (
        select 1 from jsonb_array_elements(p_owners) x
        where x->>'bedId' = o.bed_id and x->>'residentId' = o.resident_id
      )
  ) then
    raise exception 'Disabled owners stay on their beds';
  end if;
  delete from public.bdft_bed_owners;
  for v_item in select value from jsonb_array_elements(p_owners) loop
    v_bed := nullif(btrim(v_item->>'bedId'), '');
    v_res := nullif(btrim(v_item->>'residentId'), '');
    if v_bed is null or v_res is null then raise exception 'Bed owner is incomplete'; end if;
    if not exists (select 1 from public.beds b where b.id = v_bed and b.active is not false) then
      raise exception 'Unknown bed %', v_bed;
    end if;
    if not exists (select 1 from public.residents r where r.id = v_res and lower(coalesce(r.role,'')) not in ('intern','consultant','viewer')) then
      raise exception 'Owner % is not a resident', v_res;
    end if;
    insert into public.bdft_bed_owners(bed_id, resident_id, updated_by, updated_at)
    values (v_bed, v_res, a.actor_id, now());
  end loop;
  return public.ward_bdft_state(p_token);
end;
$fn$;

create or replace function public.bdft_write_rows(p_id text, p_rows jsonb)
returns void
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare x jsonb;
begin
  delete from public.bdft_rows where distribution_id = p_id;
  for x in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    insert into public.bdft_rows(distribution_id, bed_id, bed_label, owner_id, holder_id, occupied, manual, reason, disabled_owner)
    values (p_id, x->>'bedId', x->>'label', nullif(x->>'ownerId',''), nullif(x->>'holderId',''), true,
            coalesce((x->>'manual')::boolean, false), coalesce(x->>'reason','kept'), coalesce((x->>'disabled')::boolean, false));
  end loop;
end;
$fn$;

create unique index if not exists bdft_inbox_delivery_uidx
  on public.notification_deliveries (notification_id, resident_id)
  where subscription_id is null and fcm_token_id is null;

drop function if exists public.bdft_queue_notice(text, text, date);
create or replace function public.bdft_queue_notice(p_id text, p_actor text, p_date date)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare v_nid uuid; v_key text := 'bdft:'||p_id; v_url text := './#/bdft/'||p_id;
begin
  select id into v_nid from public.notification_events where dedupe_key = v_key;
  if v_nid is null then
    insert into public.notification_events(
      event_type, category, priority, actor_id, title, body, target_url, recipient_scope,
      dedupe_key, metadata, dispatch_due
    ) values (
      'bdft', 'clinical', 'normal', p_actor, 'Bed distribution',
      'A bed distribution for '||to_char(p_date, 'YYYY-MM-DD')||' is ready.',
      v_url, 'bdft_residents', v_key,
      jsonb_build_object('distribution_id', p_id, 'plan_date', p_date, 'kind', 'bdft'),
      true
    )
    returning id into v_nid;
  end if;
  insert into public.notification_deliveries(id, notification_id, resident_id, subscription_id, fcm_token_id, status, attempts, created_at, updated_at)
  select gen_random_uuid(), v_nid, r.id, null, null, 'skipped', 0, now(), now()
  from public.residents r
  where r.active is not false
    and lower(coalesce(r.role,'')) in ('resident','admin','sr')
  on conflict (notification_id, resident_id) where subscription_id is null and fcm_token_id is null do nothing;
  return jsonb_build_object('status','queued','notificationId', v_nid, 'dedupeKey', v_key, 'targetUrl', v_url);
end;
$fn$;

create or replace function public.ward_bdft_generate(
  p_token uuid, p_id text, p_date date, p_included text[], p_absent text[], p_census text, p_replace boolean
) returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  a record; v_existing public.bdft_distributions; v_current text; v_rows jsonb; v_push jsonb; v_census text;
begin
  select * into a from public.bdft_actor(p_token);
  if p_id is null or p_id !~ '^[A-Za-z0-9._:-]{1,80}$' then raise exception 'Distribution id is invalid'; end if;
  if p_date is null then raise exception 'Date is required'; end if;
  v_census := coalesce(p_census, '');
  if v_census not in ('live','empty') then raise exception 'Occupancy snapshot is not usable'; end if;
  perform pg_advisory_xact_lock(hashtext('ward-bdft-current'));
  select * into v_existing from public.bdft_distributions where id = p_id;
  if found then
    return jsonb_build_object('ok', true, 'idempotent', true, 'push', 'queued', 'notificationId', v_existing.notification_id, 'state', public.ward_bdft_state(p_token));
  end if;
  if not public.bdft_on_evening(a.actor_id) then
    raise exception 'Bed distribution can be generated only while you are signed in for the evening shift';
  end if;
  select id into v_current from public.bdft_distributions where status = 'current' for update;
  if v_current is not null and p_replace is not true then
    return jsonb_build_object('ok', false, 'code', 'confirm_replace', 'currentId', v_current);
  end if;
  if v_census = 'empty' and coalesce(array_length(p_included, 1), 0) > 0 then
    raise exception 'An empty selection cannot include beds';
  end if;
  if exists (
    select 1 from unnest(coalesce(p_included, '{}')) u(id)
    where not exists (select 1 from public.beds b where b.id = u.id and b.active is not false and nullif(b.current_patient_id,'') is not null)
  ) then
    raise exception 'Included beds must be occupied beds on the ward';
  end if;
  v_rows := public.bdft_compute(coalesce(p_included, '{}'), coalesce(p_absent, '{}'));
  if v_current is not null then
    update public.bdft_distributions
      set status = 'archived', replaced_by = p_id, replaced_at = now()
      where id = v_current;
  end if;
  insert into public.bdft_distributions(
    id, plan_date, status, created_by, created_at, updated_at, updated_by, version,
    occupancy_at, included_beds, absent_ids, census, push_status
  ) values (
    p_id, p_date, 'current', a.actor_id, now(), now(), a.actor_id, 1,
    now(), coalesce(p_included, '{}'), coalesce(p_absent, '{}'), v_census, 'pending'
  );
  perform public.bdft_write_rows(p_id, v_rows);
  v_push := public.bdft_queue_notice(p_id, a.actor_id, p_date);
  update public.bdft_distributions
    set push_status = 'queued', notification_id = (v_push->>'notificationId')::uuid
    where id = p_id;
  return jsonb_build_object('ok', true, 'idempotent', false, 'push', 'queued', 'notificationId', v_push->>'notificationId', 'state', public.ward_bdft_state(p_token));
end;
$fn$;

create or replace function public.ward_bdft_move(
  p_token uuid, p_version integer, p_bed text, p_to text, p_allow_adjacent boolean
) returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  a record; d public.bdft_distributions; r public.bdft_rows; v_adj boolean; v_rows jsonb;
begin
  select * into a from public.bdft_actor(p_token);
  select * into d from public.bdft_distributions where status = 'current' for update;
  if not found then raise exception 'There is no current distribution'; end if;
  if d.created_by <> a.actor_id then raise exception 'Only the creator can edit this distribution'; end if;
  if d.version <> p_version then raise exception 'This distribution changed. Reload it.'; end if;
  select * into r from public.bdft_rows where distribution_id = d.id and bed_id = p_bed for update;
  if not found then raise exception 'Bed is not on this distribution'; end if;
  if p_to is not null and not exists (
    select 1 from public.residents x where x.id = p_to and x.active is not false
      and lower(coalesce(x.role,'')) not in ('intern','consultant','viewer')
  ) then raise exception 'Choose an active resident'; end if;
  if p_to is not null then
    v_adj := exists (
      select 1 from public.bdft_rows o
      where o.distribution_id = d.id and o.holder_id = p_to and o.bed_id <> r.bed_id
        and substring(o.bed_label from '^(.*?)[0-9]+$') = substring(r.bed_label from '^(.*?)[0-9]+$')
        and o.bed_label ~ '[0-9]+$' and r.bed_label ~ '[0-9]+$'
        and abs(substring(o.bed_label from '([0-9]+)$')::int - substring(r.bed_label from '([0-9]+)$')::int) = 1
    );
    if v_adj and p_allow_adjacent is not true then
      return jsonb_build_object('ok', false, 'code', 'adjacent');
    end if;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'bedId', x.bed_id, 'label', x.bed_label, 'ownerId', x.owner_id, 'holderId', x.holder_id,
    'manual', x.manual, 'reason', x.reason, 'disabled', x.disabled_owner
  )), '[]'::jsonb) into v_rows from public.bdft_rows x where x.distribution_id = d.id;
  update public.bdft_distributions
    set undo_stack = coalesce(undo_stack, '[]'::jsonb) || jsonb_build_array(v_rows),
        version = version + 1, updated_at = now(), updated_by = a.actor_id
    where id = d.id;
  update public.bdft_rows set holder_id = p_to, manual = true where distribution_id = d.id and bed_id = p_bed;
  return jsonb_build_object('ok', true, 'state', public.ward_bdft_state(p_token));
end;
$fn$;

create or replace function public.ward_bdft_undo(p_token uuid, p_version integer)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; d public.bdft_distributions; v_prev jsonb;
begin
  select * into a from public.bdft_actor(p_token);
  select * into d from public.bdft_distributions where status = 'current' for update;
  if not found then raise exception 'There is no current distribution'; end if;
  if d.created_by <> a.actor_id then raise exception 'Only the creator can edit this distribution'; end if;
  if d.version <> p_version then raise exception 'This distribution changed. Reload it.'; end if;
  if jsonb_array_length(coalesce(d.undo_stack, '[]'::jsonb)) = 0 then raise exception 'Nothing to undo'; end if;
  v_prev := d.undo_stack -> (jsonb_array_length(d.undo_stack) - 1);
  perform public.bdft_write_rows(d.id, v_prev);
  update public.bdft_distributions
    set undo_stack = d.undo_stack - (jsonb_array_length(d.undo_stack) - 1),
        version = version + 1, updated_at = now(), updated_by = a.actor_id
    where id = d.id;
  return jsonb_build_object('ok', true, 'state', public.ward_bdft_state(p_token));
end;
$fn$;

create or replace function public.ward_bdft_regenerate(p_token uuid, p_version integer, p_confirm boolean)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; d public.bdft_distributions; v_rows jsonb;
begin
  select * into a from public.bdft_actor(p_token);
  if p_confirm is not true then raise exception 'Confirm before rebuilding from the default map'; end if;
  select * into d from public.bdft_distributions where status = 'current' for update;
  if not found then raise exception 'There is no current distribution'; end if;
  if d.created_by <> a.actor_id then raise exception 'Only the creator can edit this distribution'; end if;
  if d.version <> p_version then raise exception 'This distribution changed. Reload it.'; end if;
  v_rows := public.bdft_compute(d.included_beds, d.absent_ids);
  update public.bdft_distributions
    set undo_stack = '[]'::jsonb, version = version + 1, updated_at = now(), updated_by = a.actor_id
    where id = d.id;
  perform public.bdft_write_rows(d.id, v_rows);
  return jsonb_build_object('ok', true, 'state', public.ward_bdft_state(p_token));
end;
$fn$;

revoke all on function public.bdft_actor(uuid) from public, anon, authenticated;
revoke all on function public.bdft_on_evening(text) from public, anon, authenticated;
revoke all on function public.bdft_compute(text[], text[]) from public, anon, authenticated;
revoke all on function public.bdft_pack(text) from public, anon, authenticated;
revoke all on function public.bdft_write_rows(text, jsonb) from public, anon, authenticated;
revoke all on function public.bdft_queue_notice(text, text, date) from public, anon, authenticated;
grant execute on function public.bdft_actor(uuid) to postgres, service_role;
grant execute on function public.bdft_on_evening(text) to postgres, service_role;
grant execute on function public.bdft_compute(text[], text[]) to postgres, service_role;
grant execute on function public.bdft_pack(text) to postgres, service_role;
grant execute on function public.bdft_write_rows(text, jsonb) to postgres, service_role;
grant execute on function public.bdft_queue_notice(text, text, date) to postgres, service_role;

revoke all on function public.ward_bdft_state(uuid) from public;
revoke all on function public.ward_bdft_save_setup(uuid, jsonb, jsonb) from public;
revoke all on function public.ward_bdft_generate(uuid, text, date, text[], text[], text, boolean) from public;
revoke all on function public.ward_bdft_move(uuid, integer, text, text, boolean) from public;
revoke all on function public.ward_bdft_undo(uuid, integer) from public;
revoke all on function public.ward_bdft_regenerate(uuid, integer, boolean) from public;
grant execute on function public.ward_bdft_state(uuid) to anon, authenticated, service_role;
grant execute on function public.ward_bdft_save_setup(uuid, jsonb, jsonb) to anon, authenticated, service_role;
grant execute on function public.ward_bdft_generate(uuid, text, date, text[], text[], text, boolean) to anon, authenticated, service_role;
grant execute on function public.ward_bdft_move(uuid, integer, text, text, boolean) to anon, authenticated, service_role;
grant execute on function public.ward_bdft_undo(uuid, integer) to anon, authenticated, service_role;
grant execute on function public.ward_bdft_regenerate(uuid, integer, boolean) to anon, authenticated, service_role;

-- Named production checks. Every existing route stays. bdft is clinical and uses its own recipient scope.
alter table public.notification_events drop constraint notification_events_event_type_check;
alter table public.notification_events add constraint notification_events_event_type_check
  check (event_type = any (array['admission'::text, 'discharge'::text, 'transfer'::text, 'handover'::text, 'task'::text, 'ect'::text, 'critical_status_update'::text, 'observation'::text, 'restrain'::text, 'broadcast'::text, 'advice'::text, 'archive'::text, 'bdft'::text]));

alter table public.notification_events drop constraint notification_events_recipient_scope_check;
alter table public.notification_events add constraint notification_events_recipient_scope_check
  check (recipient_scope = any (array['active_team'::text, 'handover'::text, 'task_assignees'::text, 'admins'::text, 'bdft_residents'::text]));

alter table public.notification_events drop constraint notification_events_routing_check;
alter table public.notification_events add constraint notification_events_routing_check
  check (
    ((event_type = any (array['admission'::text, 'discharge'::text, 'transfer'::text, 'critical_status_update'::text, 'observation'::text, 'restrain'::text, 'advice'::text])) and category = 'clinical' and recipient_scope = 'active_team')
    or (event_type = 'handover' and category = 'handovers' and recipient_scope = 'handover')
    or (event_type = 'task' and category = 'tasks' and recipient_scope = 'task_assignees')
    or (event_type = 'ect' and category = 'ect' and recipient_scope = 'active_team')
    or (event_type = 'broadcast' and category = 'broadcast' and recipient_scope = 'active_team')
    or (event_type = 'archive' and category = 'archive' and recipient_scope = 'admins')
    or (event_type = 'bdft' and category = 'clinical' and recipient_scope = 'bdft_residents')
  );

-- R16 inbox, plus one predicate: bed-distribution notices are for residents and admins.
CREATE OR REPLACE FUNCTION public.ward_list_notification_inbox(p_session_token uuid, p_limit integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO pg_catalog, public
AS $function$
DECLARE
  v_resident_id text;
  v_role text;
  v_limit integer;
  v_notifications jsonb;
BEGIN
  SELECT ws.resident_id, lower(r.role)
    INTO v_resident_id, v_role
  FROM public.ward_sessions ws
  JOIN public.residents r ON r.id = ws.resident_id
  WHERE ws.token = p_session_token AND ws.expires_at > now()
  LIMIT 1;
  IF v_resident_id IS NULL THEN RAISE EXCEPTION 'Invalid or expired ward session'; END IF;
  v_limit := greatest(1, least(coalesce(p_limit,40),100));
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.created_at DESC), '[]'::jsonb)
  INTO v_notifications
  FROM (
    SELECT
      e.id, e.event_type, e.category, e.priority, e.patient_id, e.task_id, e.handover_id, e.ect_plan_id,
      e.actor_id, coalesce(r.display_name, e.actor_id) AS actor_name,
      e.title, e.body, e.target_url, e.created_at,
      EXISTS (
        SELECT 1 FROM public.notification_deliveries d
        WHERE d.notification_id = e.id AND d.resident_id = v_resident_id AND d.read_at IS NOT NULL
      ) AS read,
      (
        SELECT min(d.read_at) FROM public.notification_deliveries d
        WHERE d.notification_id = e.id AND d.resident_id = v_resident_id
      ) AS read_at,
      e.created_at AS delivered_at,
      true AS delivered
    FROM public.notification_events e
    LEFT JOIN public.residents r ON r.id = e.actor_id
    WHERE
      (e.held_until IS NULL OR e.held_until < now())
      AND (e.event_type IS DISTINCT FROM 'bdft' OR v_role IN ('resident','admin','sr'))
      AND (
      v_role IN ('consultant','admin')
      OR e.recipient_scope = 'active_team'
      OR (e.event_type = 'bdft' AND v_role IN ('resident','admin','sr'))
      OR EXISTS (
        SELECT 1 FROM public.notification_deliveries d
        WHERE d.notification_id = e.id AND d.resident_id = v_resident_id
      )
      OR (
        e.recipient_scope = 'handover'
        AND EXISTS (
          SELECT 1 FROM public.handovers h
          WHERE h.id = e.handover_id AND (h.to_id = v_resident_id OR (h.to_id IS NULL AND h.from_id <> v_resident_id AND v_role <> 'intern'))
        )
      )
      OR (
        e.recipient_scope = 'task_assignees'
        AND EXISTS (
          SELECT 1 FROM public.tasks t
          WHERE t.id = e.task_id AND t.assigned_to = v_resident_id
        )
      )
      )
    ORDER BY e.created_at DESC
    LIMIT v_limit
  ) x;
  RETURN jsonb_build_object('ok', true, 'resident_id', v_resident_id, 'notifications', v_notifications);
END;
$function$;

create or replace function public.ward_bdft_open(p_token uuid, p_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; d public.bdft_distributions;
begin
  select * into a from public.bdft_actor(p_token);
  select * into d from public.bdft_distributions where id = p_id;
  if not found then raise exception 'Distribution not found'; end if;
  return jsonb_build_object(
    'ok', true,
    'editable', d.status = 'current' and d.created_by = a.actor_id,
    'distribution', public.bdft_pack(p_id)
  );
end;
$fn$;

create or replace function public.ward_bdft_dispatch_scope(p_token uuid, p_notification_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; e public.notification_events;
begin
  select * into a from public.bdft_actor(p_token);
  select * into e from public.notification_events where id = p_notification_id;
  if not found
     or e.event_type is distinct from 'bdft'
     or e.recipient_scope is distinct from 'bdft_residents'
     or coalesce(e.dedupe_key, '') not like 'bdft:%' then
    raise exception 'Not a bed-distribution notice';
  end if;
  return jsonb_build_object('ok', true, 'notificationId', e.id);
end;
$fn$;

create or replace function public.ward_bdft_service_claim(p_notification_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  e public.notification_events; d public.notification_deliveries; v_id uuid; v_ok boolean; i int;
begin
  if p_notification_id is null then
    select * into e from public.notification_events
    where event_type = 'bdft' and recipient_scope = 'bdft_residents' and coalesce(dedupe_key, '') like 'bdft:%' and dispatch_due is true
    order by created_at
    for update skip locked
    limit 1;
    if not found then return jsonb_build_object('ok', true, 'claimed', false); end if;
  else
    select * into e from public.notification_events where id = p_notification_id for update;
    if not found
       or e.event_type is distinct from 'bdft'
       or e.recipient_scope is distinct from 'bdft_residents'
       or coalesce(e.dedupe_key, '') not like 'bdft:%' then
      raise exception 'Not a bed-distribution notice';
    end if;
  end if;
  insert into public.notification_deliveries(id, notification_id, resident_id, subscription_id, fcm_token_id, status, attempts, created_at, updated_at)
  select gen_random_uuid(), e.id, r.id, null, null, 'skipped', 0, now(), now()
  from public.residents r
  where r.active is not false and lower(coalesce(r.role,'')) in ('resident','admin','sr')
  on conflict (notification_id, resident_id) where subscription_id is null and fcm_token_id is null do nothing;
  insert into public.notification_deliveries(id, notification_id, resident_id, subscription_id, status, attempts, created_at, updated_at)
  select gen_random_uuid(), e.id, s.resident_id, s.id, 'pending', 0, now(), now()
  from public.push_subscriptions s
  join public.residents r on r.id = s.resident_id
  left join public.notification_preferences p on p.resident_id = r.id
  where s.active is not false and r.active is not false
    and lower(coalesce(r.role,'')) in ('resident','admin','sr')
    and coalesce(p.clinical_alerts, true)
    and not exists (
      select 1 from public.notification_deliveries x
      where x.notification_id = e.id and x.subscription_id = s.id
    );
  insert into public.notification_deliveries(id, notification_id, resident_id, fcm_token_id, status, attempts, created_at, updated_at)
  select gen_random_uuid(), e.id, t.resident_id, t.id, 'pending', 0, now(), now()
  from public.fcm_device_tokens t
  join public.residents r on r.id = t.resident_id
  left join public.notification_preferences p on p.resident_id = r.id
  where t.active is not false and r.active is not false
    and lower(coalesce(r.role,'')) in ('resident','admin','sr')
    and coalesce(p.clinical_alerts, true)
    and not exists (
      select 1 from public.notification_deliveries x
      where x.notification_id = e.id and x.fcm_token_id = t.id
    );
  for i in 1..30 loop
    update public.notification_deliveries x
      set status = 'sending', attempts = x.attempts + 1, updated_at = now()
      where x.id = (
        select y.id from public.notification_deliveries y
        where y.notification_id = e.id
          and (y.subscription_id is not null or y.fcm_token_id is not null)
          and (
            y.status = 'pending'
            or (y.status = 'failed' and coalesce(y.last_error,'') not like 'permanent:%'
                and y.updated_at < now() - make_interval(secs => least(3600, 30 * greatest(y.attempts, 1))))
            or (y.status = 'sending' and y.updated_at < now() - interval '2 minutes')
          )
        order by y.created_at, y.id
        for update skip locked
        limit 1
      )
    returning id into v_id;
    if v_id is null then
      if not exists (
        select 1 from public.notification_deliveries y
        where y.notification_id = e.id
          and (y.subscription_id is not null or y.fcm_token_id is not null)
          and y.status in ('pending','sending','failed')
          and coalesce(y.last_error,'') not like 'permanent:%'
      ) then
        update public.notification_events set dispatch_due = false where id = e.id;
      end if;
      return jsonb_build_object('ok', true, 'claimed', false, 'notificationId', e.id);
    end if;
    select r.active is not false and lower(coalesce(r.role,'')) in ('resident','admin','sr') and coalesce(p.clinical_alerts, true)
      into v_ok
    from public.notification_deliveries y
    join public.residents r on r.id = y.resident_id
    left join public.notification_preferences p on p.resident_id = r.id
    where y.id = v_id;
    if coalesce(v_ok, false) then
      exit;
    end if;
    update public.notification_deliveries
      set status = 'failed', last_error = 'permanent: recipient is no longer eligible', updated_at = now()
      where id = v_id;
    v_id := null;
  end loop;
  if v_id is null then
    return jsonb_build_object('ok', true, 'claimed', false, 'notificationId', e.id);
  end if;
  update public.notification_events set dispatch_due = true where id = e.id and dispatch_due is not true;
  select * into d from public.notification_deliveries where id = v_id;
  return jsonb_build_object(
    'ok', true, 'claimed', true, 'deliveryId', d.id, 'notificationId', e.id,
    'residentId', d.resident_id,
    'role', (select lower(coalesce(role,'')) from public.residents where id = d.resident_id),
    'clinicalAlerts', coalesce((select clinical_alerts from public.notification_preferences where resident_id = d.resident_id), true),
    'subscriptionId', d.subscription_id, 'fcmTokenId', d.fcm_token_id,
    'attempts', d.attempts, 'tag', e.dedupe_key, 'targetUrl', e.target_url, 'title', e.title, 'body', e.body
  );
end;
$fn$;

drop function if exists public.ward_bdft_claim_delivery(uuid, uuid);
drop function if exists public.ward_bdft_apply_provider(uuid, uuid, text, text);

create or replace function public.ward_bdft_service_apply(p_delivery_id uuid, p_result text, p_error text)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare d public.notification_deliveries; v_due boolean;
begin
  select * into d from public.notification_deliveries where id = p_delivery_id for update;
  if not found then raise exception 'Delivery not found'; end if;
  if not exists (
    select 1 from public.notification_events e
    where e.id = d.notification_id and e.event_type = 'bdft' and e.recipient_scope = 'bdft_residents' and coalesce(e.dedupe_key,'') like 'bdft:%'
  ) then
    raise exception 'Not a bed-distribution delivery';
  end if;
  if p_result = 'sent' then
    update public.notification_deliveries
      set status = 'sent', sent_at = now(), last_error = null, updated_at = now()
      where id = d.id;
  elsif p_result = 'permanent' then
    update public.notification_deliveries
      set status = 'failed', last_error = 'permanent: '||coalesce(p_error,'provider rejected the device'), updated_at = now()
      where id = d.id;
  elsif p_result = 'transient' then
    update public.notification_deliveries
      set status = 'failed', last_error = coalesce(p_error,'provider unavailable'), updated_at = now()
      where id = d.id;
  else
    raise exception 'Unknown provider result';
  end if;
  v_due := exists (
    select 1 from public.notification_deliveries y
    where y.notification_id = d.notification_id
      and (y.subscription_id is not null or y.fcm_token_id is not null)
      and y.status in ('pending','sending','failed')
      and coalesce(y.last_error,'') not like 'permanent:%'
  );
  update public.notification_events set dispatch_due = v_due where id = d.notification_id;
  return jsonb_build_object('ok', true, 'dispatchDue', v_due, 'notificationId', d.notification_id);
end;
$fn$;

revoke all on function public.ward_bdft_open(uuid, text) from public;
revoke all on function public.ward_bdft_dispatch_scope(uuid, uuid) from public;
revoke all on function public.ward_bdft_service_claim(uuid) from public, anon, authenticated;
revoke all on function public.ward_bdft_service_apply(uuid, text, text) from public, anon, authenticated;
grant execute on function public.ward_bdft_open(uuid, text) to anon, authenticated, service_role;
grant execute on function public.ward_bdft_dispatch_scope(uuid, uuid) to anon, authenticated, service_role;
grant execute on function public.ward_bdft_service_claim(uuid) to service_role;
grant execute on function public.ward_bdft_service_apply(uuid, text, text) to service_role;

-- Dedicated scheduler credential. The plaintext stays in Vault and is never returned.
create or replace function public.ward_bdft_provision_cron_secret()
returns text
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare v_schema text; v_bytes bytea;
begin
  if to_regclass('vault.secrets') is null or to_regprocedure('vault.create_secret(text,text,text,uuid)') is null then
    raise exception 'vault is required for the bed distribution scheduler';
  end if;
  if exists (select 1 from vault.secrets where name = 'ward_bdft_cron_secret') then
    return 'present';
  end if;
  select n.nspname into v_schema
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where p.oid::regprocedure::text like '%gen_random_bytes(integer)'
  order by case n.nspname when 'extensions' then 0 when 'public' then 1 else 2 end
  limit 1;
  if v_schema is null then
    raise exception 'pgcrypto is required for the bed distribution scheduler';
  end if;
  execute format('select %I.gen_random_bytes(32)', v_schema) into v_bytes;
  perform vault.create_secret(encode(v_bytes, 'hex'), 'ward_bdft_cron_secret', 'BDFT scheduler credential');
  return 'created';
end;
$fn$;

create or replace function public.ward_bdft_cron_ok(p_secret text)
returns boolean
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare v_stored text; v_left text; v_right text;
begin
  if p_secret is null or length(p_secret) < 32 then
    return false;
  end if;
  if to_regclass('vault.decrypted_secrets') is null then
    return false;
  end if;
  select s.decrypted_secret into v_stored
  from vault.decrypted_secrets s
  where s.name = 'ward_bdft_cron_secret';
  if v_stored is null or length(v_stored) <> length(p_secret) then
    return false;
  end if;
  v_left := encode(sha256(convert_to(v_stored, 'UTF8')), 'hex');
  v_right := encode(sha256(convert_to(p_secret, 'UTF8')), 'hex');
  return v_left = v_right;
end;
$fn$;

create or replace function public.ward_bdft_tick()
returns text
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_secret text; v_schema text; v_post regprocedure; v_req bigint; v_headers jsonb;
begin
  if not exists (
    select 1 from public.notification_events e
    where e.event_type = 'bdft' and e.recipient_scope = 'bdft_residents'
      and coalesce(e.dedupe_key, '') like 'bdft:%' and e.dispatch_due is true
  ) then
    return 'idle';
  end if;
  if to_regclass('vault.decrypted_secrets') is null then
    return 'no cron secret';
  end if;
  select s.decrypted_secret into v_secret
  from vault.decrypted_secrets s
  where s.name = 'ward_bdft_cron_secret';
  if v_secret is null then
    return 'no cron secret';
  end if;
  v_post := coalesce(
    to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)'),
    to_regprocedure('extensions.http_post(text,jsonb,jsonb,jsonb,integer)')
  );
  if v_post is null then
    raise exception 'pg_net http_post was not found';
  end if;
  select n.nspname into v_schema
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where p.oid = v_post;
  v_headers := jsonb_build_object('Content-Type', 'application/json', 'x-ward-bdft-secret', v_secret);
  begin
    execute format(
      'select %I.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := $4)',
      v_schema
    ) into v_req using
      'https://ocgmhwetdpcthwbcnbqz.supabase.co/functions/v1/dispatch-bdft',
      jsonb_build_object('source', 'cron'),
      v_headers,
      60000;
  exception when others then
    raise exception 'bed distribution dispatch request failed';
  end;
  return 'requested ' || v_req::text;
end;
$fn$;

revoke all on function public.ward_bdft_provision_cron_secret() from public, anon, authenticated;
revoke all on function public.ward_bdft_cron_ok(text) from public, anon, authenticated;
revoke all on function public.ward_bdft_tick() from public, anon, authenticated;
grant execute on function public.ward_bdft_cron_ok(text) to service_role;

do $bdft_sched$
declare v_state text;
begin
  v_state := public.ward_bdft_provision_cron_secret();
  if v_state not in ('created', 'present') then
    raise exception 'bed distribution scheduler credential was not stored';
  end if;
  if to_regprocedure('cron.schedule(text,text,text)') is null or to_regclass('cron.job') is null then
    raise exception 'pg_cron is required for the bed distribution scheduler';
  end if;
  if exists (select 1 from cron.job where jobname = 'ward-bdft-dispatch') then
    perform cron.unschedule('ward-bdft-dispatch');
  end if;
  perform cron.schedule('ward-bdft-dispatch', '*/2 * * * *', 'select public.ward_bdft_tick()');
end;
$bdft_sched$;
