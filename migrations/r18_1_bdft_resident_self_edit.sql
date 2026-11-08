-- R1.8.1 BDFT: allow residents to self-edit their own profile (short name, batch, owned beds)
-- and allow evening duty residents / admins to publish finalized bed distributions.
-- Rollback: restore migrations/r18_bdft.sql definitions.

create or replace function public.ward_bdft_save_setup(p_token uuid, p_people jsonb, p_owners jsonb)
returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare a record; v_item jsonb; v_id text; v_bed text; v_res text;
begin
  select * into a from public.bdft_actor(p_token);
  if a.actor_role not in ('admin', 'resident') then
    raise exception 'Roster setup is not available for this role';
  end if;
  if jsonb_typeof(p_people) <> 'array' or jsonb_typeof(p_owners) <> 'array' then
    raise exception 'Setup payload is invalid';
  end if;

  if a.actor_role = 'admin' then
    -- ADMIN: can update all residents
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

  else
    -- RESIDENT SELF-EDIT: can update own batch, initials and owned beds only
    for v_item in select value from jsonb_array_elements(p_people) loop
      v_id := nullif(btrim(v_item->>'id'), '');
      if v_id = a.actor_id then
        if char_length(coalesce(v_item->>'batch','')) > 40 or char_length(coalesce(v_item->>'short','')) > 16 then
          raise exception 'Batch or short name is too long';
        end if;
        update public.residents
          set bdft_batch = nullif(btrim(v_item->>'batch'), ''),
              bdft_short = nullif(btrim(v_item->>'short'), ''),
              bdft_order = nullif(v_item->>'order','')::int
          where id = a.actor_id;
      end if;
    end loop;

    -- Delete beds previously owned by this resident
    delete from public.bdft_bed_owners where resident_id = a.actor_id;

    -- Reassign only beds claimed for this resident (without touching disabled resident beds)
    for v_item in select value from jsonb_array_elements(p_owners) loop
      v_bed := nullif(btrim(v_item->>'bedId'), '');
      v_res := nullif(btrim(v_item->>'residentId'), '');
      if v_res = a.actor_id and v_bed is not null then
        if not exists (select 1 from public.beds b where b.id = v_bed and b.active is not false) then
          raise exception 'Unknown bed %', v_bed;
        end if;
        insert into public.bdft_bed_owners(bed_id, resident_id, updated_by, updated_at)
        values (v_bed, a.actor_id, a.actor_id, now())
        on conflict (bed_id) do update set resident_id = excluded.resident_id, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
      end if;
    end loop;

  end if;

  return public.ward_bdft_state(p_token);
end;
$fn$;

revoke all on function public.ward_bdft_save_setup(uuid, jsonb, jsonb) from public;
grant execute on function public.ward_bdft_save_setup(uuid, jsonb, jsonb) to anon, authenticated, service_role;

-- ward_bdft_save_distribution: allows publishing the finalized distribution to Supabase
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
begin
  select * into a from public.bdft_actor(p_token);
  if a.actor_role not in ('admin', 'resident') then
    raise exception 'Not authorized to save bed distribution';
  end if;

  v_date := coalesce(p_plan_date, current_date + 1);
  v_id := 'bdft-' || to_char(v_date, 'YYYYMMDD') || '-' || substr(md5(random()::text), 1, 6);

  perform pg_advisory_xact_lock(hashtext('ward-bdft-current'));

  -- Archive any previous current distribution
  update public.bdft_distributions
    set status = 'archived', replaced_by = v_id, replaced_at = now()
    where status = 'current';

  -- Insert new distribution
  insert into public.bdft_distributions(
    id, plan_date, status, created_by, created_at, updated_at, updated_by, version,
    occupancy_at, census, push_status
  ) values (
    v_id, v_date, 'current', a.actor_id, now(), now(), a.actor_id, 1,
    now(), 'live', 'not_queued'
  );

  -- Insert rows
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
        set holder_id = excluded.holder_id, manual = excluded.manual;
    end loop;
  end if;

  return public.ward_bdft_state(p_token);
end;
$fn$;

revoke all on function public.ward_bdft_save_distribution(uuid, date, jsonb, jsonb) from public;
grant execute on function public.ward_bdft_save_distribution(uuid, date, jsonb, jsonb) to anon, authenticated, service_role;
