-- R1.3.136 · resident phone numbers, visible only to consultants (Call chip on the on-duty list)
-- NOT APPLIED. Apply only after the go-ahead ("Push"), in the Supabase SQL editor or via apply_migration, as ONE transaction.
-- Order with R1.3.135 does not matter (both ward_read_ward_state baselines are accepted; this file does not touch it).
--
-- Design (additive only — no existing function, table, grant or publication is changed):
--   * public.resident_phones       one row per user: resident_id -> phone_e164 (+91XXXXXXXXXX). Separate table, NOT a
--                                  residents column, because ward_session_user() returns the whole residents row and
--                                  ward_login()/ward_read_ward_state() read residents: a new column there could leak.
--   * public.resident_phone_audit  who changed whose number and when (action set/changed/cleared). The number itself is
--                                  never written to the audit or to activity_log (activity_log is shown to everyone).
--   * Both tables: RLS enabled + forced, NO policies, ALL privileges revoked from PUBLIC/anon/authenticated,
--     not added to any realtime publication -> unreadable through PostgREST, GraphQL and realtime.
--   * Access only through SECURITY DEFINER RPCs (session token checked against ward_sessions like every other RPC):
--       ward_set_resident_phone(token, username, phone)  self, or admin for anyone non-consultant; '' clears
--       ward_get_my_phone(token)                         own number only
--       ward_phone_status(token)                         admin only; username + has_phone (no numbers)
--       ward_list_duty_phones(token)                     consultant only; numbers of active residents with an open
--                                                        duty sign-in started in the last 20 h. Everyone else: error.
--   * ward_phone_e164(text) is an internal validator (not executable by anon/authenticated).
--
-- Drift-check baselines (md5 of pg_get_functiondef, read from live 28 Oct 2026 IST). These functions are NOT changed;
-- they are checked because the no-leak argument depends on them not reading the new tables:
--   ward_session_user(uuid)          b645f3f787a38e6801a3bbd664f3a87a
--   ward_login(text,text)            a60a170066589506f65ec2c60cf6703a
--   ward_list_faculty(uuid)          7796c3791502aef5440e98f618145436
--   ward_read_ward_state(uuid)       3b2711f80e3d916c70582dd168749113 (R1.3.134) or f7737a140e4984ff524f45084414696a (R1.3.135)
--   ward_invite_user(uuid,text,text,text,text)        ed6948714844ca1d83c4d9d158c5eb6e
--   ward_update_user(uuid,text,text,text,text,text)   c50af7a4673ccf128d2e7aaf59260d2e
--   ward_sign_duty(uuid,text,text)   3fd01fbfe515c6bd9c5baac6fec18fc8
--   ward_end_duty(uuid)              9f02d0f83dec28c1247118d51e5f7a84
-- The block also aborts if any phone object already exists (re-apply) or the residents/ward_duty shape differs.
-- Rollback: migrations/R1.3.136-resident-phone.rollback.sql (drops the two tables -> saved numbers are lost).
begin;
do $chk$
declare r record; v_md text;
begin
  for r in select * from (values
      ('public.ward_session_user(uuid)','b645f3f787a38e6801a3bbd664f3a87a',null),
      ('public.ward_login(text,text)','a60a170066589506f65ec2c60cf6703a',null),
      ('public.ward_list_faculty(uuid)','7796c3791502aef5440e98f618145436',null),
      ('public.ward_read_ward_state(uuid)','3b2711f80e3d916c70582dd168749113','f7737a140e4984ff524f45084414696a'),
      ('public.ward_invite_user(uuid,text,text,text,text)','ed6948714844ca1d83c4d9d158c5eb6e',null),
      ('public.ward_update_user(uuid,text,text,text,text,text)','c50af7a4673ccf128d2e7aaf59260d2e',null),
      ('public.ward_sign_duty(uuid,text,text)','3fd01fbfe515c6bd9c5baac6fec18fc8',null),
      ('public.ward_end_duty(uuid)','9f02d0f83dec28c1247118d51e5f7a84',null)) v(fn,md,md2) loop
    v_md := md5(pg_get_functiondef(r.fn::regprocedure));
    if v_md <> r.md and v_md is distinct from r.md2 then
      raise exception 'R1.3.136 drift check failed for %: live md5 % <> baseline %', r.fn, v_md, r.md;
    end if;
  end loop;
  if to_regclass('public.resident_phones') is not null or to_regclass('public.resident_phone_audit') is not null
     or exists (select 1 from pg_proc where pronamespace='public'::regnamespace and proname in
       ('ward_phone_e164','ward_set_resident_phone','ward_get_my_phone','ward_phone_status','ward_list_duty_phones')) then
    raise exception 'R1.3.136 drift check failed: phone objects already exist (already applied?)';
  end if;
  if not exists (select 1 from pg_constraint where conrelid='public.residents'::regclass and contype='p'
                 and pg_get_constraintdef(oid)='PRIMARY KEY (id)') then
    raise exception 'R1.3.136 drift check failed: residents primary key is not (id)';
  end if;
  if (select count(*) from information_schema.columns where table_schema='public' and table_name='ward_duty'
        and column_name in ('resident_id','started_at','ended_at')) <> 3 then
    raise exception 'R1.3.136 drift check failed: ward_duty columns differ';
  end if;
end $chk$;

create table public.resident_phones(
  resident_id text primary key references public.residents(id) on delete cascade,
  phone_e164  text not null check (phone_e164 ~ '^\+91[6-9][0-9]{9}$'),
  updated_at  timestamptz not null default now(),
  updated_by  text
);
create table public.resident_phone_audit(
  id          bigint generated always as identity primary key,
  resident_id text not null,
  actor_id    text not null,
  action      text not null check (action in ('set','changed','cleared')),
  at          timestamptz not null default now()
);
create index resident_phone_audit_res_idx on public.resident_phone_audit(resident_id, at desc);
alter table public.resident_phones enable row level security;
alter table public.resident_phones force row level security;
alter table public.resident_phone_audit enable row level security;
alter table public.resident_phone_audit force row level security;
revoke all on table public.resident_phones from public, anon, authenticated;
revoke all on table public.resident_phone_audit from public, anon, authenticated;
revoke all on sequence public.resident_phone_audit_id_seq from public, anon, authenticated;
comment on table public.resident_phones is 'R1.3.136: private. Read only via ward_get_my_phone / ward_list_duty_phones (consultants). No grants, no policies, not in realtime.';
comment on table public.resident_phone_audit is 'R1.3.136: who changed a phone number and when. Never stores the number.';

-- Indian mobile -> +91XXXXXXXXXX. NULL for blank. Raises for anything else.
create function public.ward_phone_e164(p_phone text)
 returns text
 language plpgsql
 immutable
 set search_path to 'pg_catalog'
as $function$
declare d text;
begin
  d := regexp_replace(coalesce(p_phone,''), '[\s().-]', '', 'g');
  if d = '' then return null; end if;
  if d ~ '^\+91[0-9]{10}$' then d := substr(d,4);
  elsif d ~ '^0091[0-9]{10}$' then d := substr(d,5);
  elsif d ~ '^91[0-9]{10}$' then d := substr(d,3);
  elsif d ~ '^0[0-9]{10}$' then d := substr(d,2);
  end if;
  if d !~ '^[6-9][0-9]{9}$' then
    raise exception 'Enter a 10-digit Indian mobile number' using errcode = '22023';
  end if;
  return '+91' || d;
end $function$;

create function public.ward_set_resident_phone(p_token uuid, p_username text, p_phone text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'pg_catalog', 'public'
as $function$
declare v_actor text; v_arole text; v_id text; v_trole text; v_new text; v_old text; v_act text;
begin
  select ws.resident_id, lower(coalesce(r.role,'')) into v_actor, v_arole
  from public.ward_sessions ws join public.residents r on r.id=ws.resident_id and r.active
  where ws.token=p_token and ws.expires_at>now() limit 1;
  if v_actor is null then raise exception 'Invalid or expired ward session'; end if;
  select id, lower(coalesce(role,'')) into v_id, v_trole from public.residents
  where lower(username)=lower(trim(coalesce(p_username,''))) and active;
  if v_id is null then raise exception 'User not found'; end if;
  if v_arole<>'admin' and v_id<>v_actor then raise exception 'Sign in again as admin' using errcode='42501'; end if;
  if v_trole='consultant' then raise exception 'Phone numbers are for residents only'; end if;
  v_new := public.ward_phone_e164(p_phone);
  select phone_e164 into v_old from public.resident_phones where resident_id=v_id;
  if v_new is null then
    if v_old is not null then
      delete from public.resident_phones where resident_id=v_id;
      v_act := 'cleared';
    end if;
  elsif v_old is distinct from v_new then
    insert into public.resident_phones(resident_id, phone_e164, updated_at, updated_by)
    values (v_id, v_new, now(), v_actor)
    on conflict (resident_id) do update set phone_e164=excluded.phone_e164, updated_at=excluded.updated_at, updated_by=excluded.updated_by;
    v_act := case when v_old is null then 'set' else 'changed' end;
  end if;
  if v_act is not null then
    insert into public.resident_phone_audit(resident_id, actor_id, action) values (v_id, v_actor, v_act);
  end if;
  return jsonb_build_object('ok',true,'id',v_id,'has_phone',v_new is not null,'changed',v_act is not null);
end $function$;

create function public.ward_get_my_phone(p_token uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public'
as $function$
declare v_actor text; v_phone text;
begin
  select ws.resident_id into v_actor
  from public.ward_sessions ws join public.residents r on r.id=ws.resident_id and r.active
  where ws.token=p_token and ws.expires_at>now() limit 1;
  if v_actor is null then raise exception 'Invalid or expired ward session'; end if;
  select phone_e164 into v_phone from public.resident_phones where resident_id=v_actor;
  return jsonb_build_object('ok',true,'phone',v_phone);
end $function$;

create function public.ward_phone_status(p_token uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public'
as $function$
declare v_actor text; v_role text;
begin
  select ws.resident_id, lower(coalesce(r.role,'')) into v_actor, v_role
  from public.ward_sessions ws join public.residents r on r.id=ws.resident_id and r.active
  where ws.token=p_token and ws.expires_at>now() limit 1;
  if v_actor is null then raise exception 'Invalid or expired ward session'; end if;
  if v_role<>'admin' then raise exception 'Sign in again as admin' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('username',r.username,'has_phone',true) order by r.username)
    from public.resident_phones p join public.residents r on r.id=p.resident_id and r.active),'[]'::jsonb);
end $function$;

create function public.ward_list_duty_phones(p_session_token uuid)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog', 'public'
as $function$
declare v_actor text; v_role text;
begin
  select ws.resident_id, lower(coalesce(r.role,'')) into v_actor, v_role
  from public.ward_sessions ws join public.residents r on r.id=ws.resident_id and r.active
  where ws.token=p_session_token and ws.expires_at>now() limit 1;
  if v_actor is null then raise exception 'Invalid or expired ward session'; end if;
  if v_role<>'consultant' then raise exception 'Consultants only' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('resident_id',x.resident_id,'phone',x.phone_e164) order by x.resident_id)
    from (select distinct p.resident_id, p.phone_e164
          from public.resident_phones p
          join public.residents r on r.id=p.resident_id and r.active and lower(coalesce(r.role,''))<>'consultant'
          join public.ward_duty d on d.resident_id=p.resident_id and d.ended_at is null and d.started_at>now()-interval '20 hours') x),'[]'::jsonb);
end $function$;

revoke all on function public.ward_phone_e164(text) from public, anon, authenticated;
revoke all on function public.ward_set_resident_phone(uuid,text,text) from public;
revoke all on function public.ward_get_my_phone(uuid) from public;
revoke all on function public.ward_phone_status(uuid) from public;
revoke all on function public.ward_list_duty_phones(uuid) from public;
grant execute on function public.ward_set_resident_phone(uuid,text,text) to anon, authenticated;
grant execute on function public.ward_get_my_phone(uuid) to anon, authenticated;
grant execute on function public.ward_phone_status(uuid) to anon, authenticated;
grant execute on function public.ward_list_duty_phones(uuid) to anon, authenticated;

-- post-checks: the new tables must stay private
do $post$
begin
  if exists (select 1 from information_schema.role_table_grants where table_schema='public'
             and table_name in ('resident_phones','resident_phone_audit') and grantee in ('anon','authenticated','PUBLIC')) then
    raise exception 'R1.3.136 post-check failed: phone tables have client grants';
  end if;
  if exists (select 1 from pg_publication_tables where schemaname='public' and tablename in ('resident_phones','resident_phone_audit')) then
    raise exception 'R1.3.136 post-check failed: phone tables are in a publication';
  end if;
end $post$;
commit;
