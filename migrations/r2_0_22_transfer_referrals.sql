-- Ward Sync R2.0.22 — transfer discharge referral capture.
-- Transfer is an additive path: the original discharge RPC remains unchanged.
-- ward_transfer_patient wraps the original discharge, writes a referral, timeline
-- event, notification details, and optional discharge MSE in one transaction.

create table if not exists public.patient_transfer_referrals (
  id text primary key,
  patient_id text not null references public.patients(id) on delete cascade,
  discharged_at timestamptz not null,
  receiving_department text not null,
  referral_reason text not null,
  referred_by text references public.residents(id),
  created_at timestamptz not null default now(),
  constraint patient_transfer_referrals_episode_key unique (patient_id, discharged_at),
  constraint patient_transfer_referrals_department_check
    check (char_length(btrim(receiving_department)) between 1 and 120),
  constraint patient_transfer_referrals_reason_check
    check (char_length(btrim(referral_reason)) between 1 and 2000)
);

create index if not exists patient_transfer_referrals_patient_time_idx
  on public.patient_transfer_referrals (patient_id, discharged_at desc);

alter table public.patient_transfer_referrals enable row level security;
revoke all on table public.patient_transfer_referrals from public, anon, authenticated, service_role;

create or replace function public.ward_transfer_patient(
  p_token uuid,
  p_patient jsonb,
  p_receiving_department text,
  p_referral_reason text,
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
  p_review_override jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path to pg_catalog, public
as $fn$
declare
  a record;
  v_result jsonb;
  v_pid text;
  v_when timestamptz;
  v_mode text;
  v_status text;
  v_patient_name text;
  v_dept text;
  v_reason text;
  v_ref public.patient_transfer_referrals;
  v_notification_id uuid;
  v_saved_mse text;
  v_mse_id text;
  v_mse_data jsonb;
  v_audit jsonb;
  v_log_id text;
begin
  select * into a from public.r17_actor(p_token);
  if a.actor_kind = 'intern' or a.actor_role in ('consultant','viewer') then
    raise exception 'This role cannot perform clinical writes';
  end if;

  if p_patient is null or jsonb_typeof(p_patient) <> 'object' then
    raise exception 'Patient details are required';
  end if;

  v_pid := nullif(btrim(coalesce(p_patient->>'id','')), '');
  if v_pid is null then
    raise exception 'Patient is required';
  end if;

  v_mode := lower(coalesce(nullif(btrim(p_patient->>'dischargeMode'), ''), ''));
  if v_mode <> 'transfer' then
    raise exception 'Transfer workflow requires Transfer as the discharge mode';
  end if;

  v_dept := nullif(left(btrim(coalesce(p_receiving_department, '')), 120), '');
  v_reason := nullif(left(btrim(coalesce(p_referral_reason, '')), 2000), '');
  if v_dept is null then raise exception 'Receiving department is required'; end if;
  if v_reason is null then raise exception 'Reason for referral is required'; end if;

  -- Existing discharge RPC remains authoritative for MRD, bed, assignments,
  -- ECT, requester, notification creation and patient-status validation.
  v_result := public.ward_discharge_patient(
    p_token, p_patient, p_bed_id, p_assignment_ids, p_ect_plan,
    p_discharge_advice, p_discharge_meds, p_mrd_no, p_discharge_review,
    p_discharge_ect_sessions, p_discharge_requested_by, p_discharge_requester_name
  );

  select discharged_at, discharge_mode, active_status, name
    into v_when, v_mode, v_status, v_patient_name
  from public.patients
  where id = v_pid
  for update;

  if not found or v_status <> 'discharged' or v_mode <> 'transfer' or v_when is null then
    raise exception 'Transfer discharge did not complete';
  end if;

  -- One referral record per discharge episode. A retry updates the same record.
  insert into public.patient_transfer_referrals (
    id, patient_id, discharged_at, receiving_department, referral_reason, referred_by
  ) values (
    'trf_' || md5(v_pid || '|' || v_when::text),
    v_pid, v_when, v_dept, v_reason, a.actor_id
  )
  on conflict (patient_id, discharged_at) do update set
    receiving_department = excluded.receiving_department,
    referral_reason = excluded.referral_reason,
    referred_by = excluded.referred_by
  returning * into v_ref;

  -- Durable timeline item; the referral table remains the canonical structured record.
  v_log_id := 'trf-log-' || md5(v_pid || '|' || v_when::text);
  insert into public.activity_log(id, patient_id, kind, title, detail, actor_id, created_at)
  values (
    v_log_id, v_pid, 'note', 'Patient transferred · ' || v_dept,
    'Receiving department: ' || v_dept || E'\\nReason for referral: ' || v_reason,
    a.actor_id, now()
  )
  on conflict (id) do update set
    title = excluded.title,
    detail = excluded.detail,
    actor_id = excluded.actor_id;

  -- Update the notification created by the existing atomic discharge RPC.
  v_notification_id := nullif(v_result->>'notification_id', '')::uuid;
  if v_notification_id is not null then
    update public.notification_events
    set title = 'Patient transferred',
        body = coalesce(v_patient_name, 'Patient') || ' transferred to ' || v_dept || ' · ' || v_reason,
        metadata = coalesce(metadata, '{}'::jsonb) ||
          jsonb_build_object(
            'action', 'transfer',
            'discharge_mode', 'transfer',
            'receiving_department', v_dept,
            'referral_reason', v_reason
          )
    where id = v_notification_id;
  end if;

  -- Preserve the R17 discharge MSE and review-override behavior.
  v_saved_mse := null;
  v_audit := jsonb_build_object('stored', false, 'repeated', true);
  if not coalesce((v_result->>'idempotent')::boolean, false) then
    if p_discharge_mse is not null and jsonb_typeof(p_discharge_mse) = 'object' then
      v_mse_id := nullif(btrim(coalesce(p_discharge_mse->>'id','')), '');
      v_mse_data := p_discharge_mse->'data';
      if v_mse_id ~ '^[A-Za-z0-9._:-]{1,80}$'
         and jsonb_typeof(v_mse_data) = 'object'
         and octet_length(v_mse_data::text) < 30000 then
        begin
          insert into public.mse_entries(
            id, patient_id, kind, admitted_at, data, high_risk, summary,
            created_by, created_by_name, created_at, recorded_at
          )
          select
            v_mse_id, v_pid, 'discharge', p.admitted_at, v_mse_data,
            case when p_discharge_mse->>'high_risk' in ('true','t','1') then true else false end,
            nullif(left(coalesce(p_discharge_mse->>'summary',''), 8000), ''),
            a.actor_id, a.actor_name, now(), now()
          from public.patients p
          where p.id = v_pid
          on conflict (id) do nothing;

          select id into v_saved_mse
          from public.mse_entries
          where id = v_mse_id and patient_id = v_pid and deleted_at is null;
        exception when others then
          v_saved_mse := null;
        end;
      end if;
    end if;

    v_audit := public.r17_write_review_override(
      v_pid, a.actor_id, a.actor_name,
      case when p_review_override is null then null else p_review_override->>'reason' end,
      'ward_discharge', v_saved_mse
    );
  end if;

  return coalesce(v_result, '{}'::jsonb) ||
    jsonb_build_object(
      'transfer_referral', to_jsonb(v_ref),
      'mse_id', v_saved_mse,
      'review', v_audit
    );
end;
$fn$;

revoke all on function public.ward_transfer_patient(
  uuid, jsonb, text, text, text, text[], jsonb, text, jsonb, text,
  text, integer, text[], text, jsonb, jsonb
) from public, anon, authenticated;
grant execute on function public.ward_transfer_patient(
  uuid, jsonb, text, text, text, text[], jsonb, text, jsonb, text,
  text, integer, text[], text, jsonb, jsonb
) to anon, authenticated, service_role;

comment on table public.patient_transfer_referrals is
  'Canonical transfer referral details per discharge episode. Access only through the ward_transfer_patient RPC.';
