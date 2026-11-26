-- R20.20 — Transfer discharge referral details
-- Additive migration. Existing discharge modes, certificate logic, and observation referral RPCs are unchanged.
-- Apply this migration before deploying the matching PWA build.
--
-- Transfer uses a separate episode-keyed table because public.patients is reused on readmission.
-- ward_discharge_with_transfer wraps the existing R1.7 discharge-review RPC and writes the referral
-- record plus activity event in the same Postgres transaction. Any failure rolls back the discharge.

begin;

create table if not exists public.ward_discharge_referrals (
  id text primary key,
  patient_id text not null references public.patients(id),
  discharged_at timestamptz not null,
  referral_to text not null,
  reason text not null,
  created_by text,
  created_by_name text,
  created_at timestamptz not null default now(),
  constraint ward_discharge_referrals_episode_key unique (patient_id, discharged_at),
  constraint ward_discharge_referrals_id_check check (id ~ '^wdr-[A-Za-z0-9._:-]{1,80}$'),
  constraint ward_discharge_referrals_department_check check (
    length(btrim(referral_to)) between 1 and 160
  ),
  constraint ward_discharge_referrals_reason_check check (
    length(btrim(reason)) between 1 and 3000
  )
);

create index if not exists ward_discharge_referrals_patient_idx
  on public.ward_discharge_referrals (patient_id, discharged_at desc);

alter table public.ward_discharge_referrals enable row level security;
alter table public.ward_discharge_referrals force row level security;
revoke all on table public.ward_discharge_referrals from public, anon, authenticated;
grant all on table public.ward_discharge_referrals to service_role;

drop function if exists public.ward_discharge_with_transfer(
  uuid, jsonb, text, text[], jsonb, text, jsonb, text, text, integer, text[], text, jsonb, jsonb, text, text
);

create function public.ward_discharge_with_transfer(
  p_token uuid,
  p_patient jsonb,
  p_bed_id text default null,
  p_assignment_ids text[] default '{}'::text[],
  p_ect_plan jsonb default null,
  p_discharge_advice text default null,
  p_discharge_meds jsonb default null,
  p_mrd_no text default null,
  p_discharge_review text default null,
  p_discharge_ect_sessions integer default null,
  p_discharge_requested_by text[] default null,
  p_discharge_requester_name text default null,
  p_discharge_mse jsonb default null,
  p_review_override jsonb default null,
  p_referral_to text default null,
  p_referral_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  a record;
  v_result jsonb;
  v_pid text;
  v_mode text;
  v_when timestamptz;
  v_referral_to text;
  v_reason text;
  v_status text;
  v_saved_mode text;
  v_saved_at timestamptz;
  v_ref public.ward_discharge_referrals%rowtype;
  v_ref_id text;
begin
  select * into a from public.r17_actor(p_token);
  if a.actor_kind = 'intern' or a.actor_role in ('consultant', 'viewer') then
    raise exception 'This role cannot perform clinical writes';
  end if;

  if p_patient is null or jsonb_typeof(p_patient) <> 'object' then
    raise exception 'Patient discharge data is required';
  end if;

  v_pid := nullif(btrim(coalesce(p_patient->>'id', '')), '');
  v_mode := lower(btrim(coalesce(p_patient->>'dischargeMode', '')));
  if v_pid is null then raise exception 'Patient is required'; end if;
  if v_mode <> 'transfer' then raise exception 'This workflow is only for Transfer discharge'; end if;

  v_referral_to := nullif(btrim(coalesce(p_referral_to, '')), '');
  v_reason := nullif(btrim(coalesce(p_referral_reason, '')), '');
  if v_referral_to is null or char_length(v_referral_to) > 160 then
    raise exception 'Enter a valid receiving department (maximum 160 characters)';
  end if;
  if v_reason is null or char_length(v_reason) > 3000 then
    raise exception 'Enter the reason for transfer (maximum 3000 characters)';
  end if;

  begin
    v_when := nullif(p_patient->>'dischargedAt', '')::timestamptz;
  exception when others then
    raise exception 'Discharge date and time are invalid';
  end;
  if v_when is null then raise exception 'Discharge date and time are required'; end if;

  -- Preserve the canonical R1.7 discharge/MSE/review behaviour. This call and the referral insert
  -- run inside this function's transaction; an exception below rolls back the discharge too.
  v_result := public.ward_discharge_with_review(
    p_token, p_patient, p_bed_id, p_assignment_ids, p_ect_plan,
    p_discharge_advice, p_discharge_meds, p_mrd_no, p_discharge_review,
    p_discharge_ect_sessions, p_discharge_requested_by, p_discharge_requester_name,
    p_discharge_mse, p_review_override
  );

  select coalesce(active_status, 'admitted'), discharge_mode, discharged_at
    into v_status, v_saved_mode, v_saved_at
  from public.patients
  where id = v_pid
  for update;

  if not found or v_status <> 'discharged' or lower(coalesce(v_saved_mode, '')) <> 'transfer'
     or v_saved_at is null or abs(extract(epoch from (v_saved_at - v_when))) > 1 then
    raise exception 'Transfer discharge was not committed for this discharge episode';
  end if;

  v_ref_id := 'wdr-' || substr(md5(v_pid || '|' || v_saved_at::text), 1, 24);
  insert into public.ward_discharge_referrals (
    id, patient_id, discharged_at, referral_to, reason,
    created_by, created_by_name, created_at
  ) values (
    v_ref_id, v_pid, v_saved_at, v_referral_to, v_reason,
    a.actor_id, a.actor_name, now()
  )
  on conflict (patient_id, discharged_at) do nothing;

  select * into v_ref
  from public.ward_discharge_referrals
  where patient_id = v_pid and discharged_at = v_saved_at;

  if not found then raise exception 'Transfer referral details could not be stored'; end if;
  if v_ref.referral_to is distinct from v_referral_to or v_ref.reason is distinct from v_reason then
    raise exception 'Transfer details already exist for this discharge episode; reload the patient record';
  end if;

  insert into public.activity_log (id, patient_id, kind, title, detail, actor_id, created_at)
  values (
    'wdr-event-' || v_ref.id,
    v_pid,
    'note',
    'Transferred to ' || v_ref.referral_to,
    'Reason for transfer: ' || v_ref.reason,
    a.actor_id,
    v_ref.created_at
  )
  on conflict (id) do nothing;

  -- Replace the generic discharge notification text with a transfer-specific message.
  update public.notification_events
  set title = 'Patient transferred',
      body = (select coalesce(name, 'Patient') from public.patients where id = v_pid)
             || ' transferred to ' || v_ref.referral_to,
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
        'discharge_mode', 'transfer',
        'referral_to', v_ref.referral_to,
        'referral_reason', v_ref.reason
      )
  where id = nullif(v_result->>'notification_id', '')::uuid;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'referral', jsonb_build_object(
      'id', v_ref.id,
      'patient_id', v_ref.patient_id,
      'discharged_at', v_ref.discharged_at,
      'referral_to', v_ref.referral_to,
      'reason', v_ref.reason,
      'created_by', v_ref.created_by,
      'created_by_name', v_ref.created_by_name,
      'created_at', v_ref.created_at
    )
  );
end;
$fn$;

revoke all on function public.ward_discharge_with_transfer(
  uuid, jsonb, text, text[], jsonb, text, jsonb, text, text, integer, text[], text, jsonb, jsonb, text, text
) from public;
grant execute on function public.ward_discharge_with_transfer(
  uuid, jsonb, text, text[], jsonb, text, jsonb, text, text, integer, text[], text, jsonb, jsonb, text, text
) to anon, authenticated, service_role;

create or replace function public.ward_list_discharge_referrals(p_token uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to pg_catalog, public
as $fn$
declare
  v_id text;
  v_role text;
  v_rows jsonb;
begin
  select s.resident_id, lower(coalesce(r.role, ''))
    into v_id, v_role
  from public.ward_sessions s
  join public.residents r on r.id = s.resident_id
  where s.token = p_token and s.expires_at > now() and r.active = true;

  if v_id is null then raise exception 'Invalid or expired ward session'; end if;
  if v_role not in ('resident', 'admin', 'sr', 'consultant', 'viewer') then
    raise exception 'This account cannot read clinical transfer records';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', x.id,
    'patient_id', x.patient_id,
    'discharged_at', x.discharged_at,
    'referral_to', x.referral_to,
    'reason', x.reason,
    'created_by', x.created_by,
    'created_by_name', x.created_by_name,
    'created_at', x.created_at
  ) order by x.discharged_at desc, x.created_at desc), '[]'::jsonb)
  into v_rows
  from public.ward_discharge_referrals x;

  return jsonb_build_object('ok', true, 'referrals', v_rows);
end;
$fn$;

revoke all on function public.ward_list_discharge_referrals(uuid) from public;
grant execute on function public.ward_list_discharge_referrals(uuid) to anon, authenticated, service_role;

notify pgrst, 'reload schema';

commit;
