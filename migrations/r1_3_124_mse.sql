-- R1.3.124 Mental Status Examination (MSE)
-- Applied to ward-flow on 2026-10-25 as migration r1_3_124_mse.
-- Creates public.mse_entries (RPC-only access, like ect_sessions), the
-- ward_save_mse write RPC and adds 'mse_entries' to ward_read_ward_state.

create table if not exists public.mse_entries (
  id text primary key,
  patient_id text not null references public.patients(id) on delete cascade,
  kind text not null default 'routine',
  admitted_at timestamptz,
  data jsonb not null default '{}'::jsonb,
  high_risk boolean not null default false,
  summary text,
  created_by text references public.residents(id),
  created_by_name text,
  created_at timestamptz not null default now(),
  recorded_at timestamptz not null default now()
);

do $$ begin
  if not exists (select 1 from pg_constraint where conname='mse_entries_kind_check' and conrelid='public.mse_entries'::regclass) then
    alter table public.mse_entries add constraint mse_entries_kind_check check (kind in ('routine','discharge'));
  end if;
  if not exists (select 1 from pg_constraint where conname='mse_entries_data_object_check' and conrelid='public.mse_entries'::regclass) then
    alter table public.mse_entries add constraint mse_entries_data_object_check check (jsonb_typeof(data)='object' and pg_column_size(data) < 32768);
  end if;
  if not exists (select 1 from pg_constraint where conname='mse_entries_summary_len_check' and conrelid='public.mse_entries'::regclass) then
    alter table public.mse_entries add constraint mse_entries_summary_len_check check (summary is null or length(summary) <= 8000);
  end if;
end $$;

create index if not exists mse_entries_patient_created_idx on public.mse_entries(patient_id, created_at desc);
create index if not exists mse_entries_high_risk_idx on public.mse_entries(patient_id) where high_risk;

-- Same posture as ect_sessions: RLS on + forced, no policies, no anon/authenticated grants.
alter table public.mse_entries enable row level security;
alter table public.mse_entries force row level security;
revoke all on table public.mse_entries from anon, authenticated;
grant all on table public.mse_entries to service_role;

CREATE OR REPLACE FUNCTION public.ward_save_mse(p_token uuid, p_row jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_resident_id text;
  v_role text;
  v_name text;
  v_id text;
  v_patient_id text;
  v_kind text;
  v_admitted timestamptz;
  v_at timestamptz;
  v_data jsonb;
  v_existing text;
BEGIN
  SELECT s.resident_id, lower(coalesce(r.role,'')), r.display_name
    INTO v_resident_id, v_role, v_name
  FROM public.ward_sessions s
  JOIN public.residents r ON r.id=s.resident_id
  WHERE s.token=p_token
    AND s.expires_at>now()
    AND r.active=true;

  IF v_resident_id IS NULL THEN
    RAISE EXCEPTION 'Invalid or expired ward session';
  END IF;
  IF v_role IN ('consultant','viewer') THEN
    RAISE EXCEPTION 'This account is view-only';
  END IF;

  v_id=nullif(trim(p_row->>'id'),'');
  v_patient_id=nullif(trim(p_row->>'patient_id'),'');
  v_kind=coalesce(nullif(trim(p_row->>'kind'),''),'routine');
  v_data=coalesce(p_row->'data','{}'::jsonb);

  IF v_id IS NULL OR v_patient_id IS NULL THEN
    RAISE EXCEPTION 'MSE identifiers are required';
  END IF;
  IF v_kind NOT IN ('routine','discharge') THEN
    RAISE EXCEPTION 'Unknown MSE kind';
  END IF;
  IF jsonb_typeof(v_data)<>'object' THEN
    RAISE EXCEPTION 'MSE data must be an object';
  END IF;

  -- Idempotent replay from the offline outbox.
  SELECT patient_id INTO v_existing FROM public.mse_entries WHERE id=v_id;
  IF FOUND THEN
    IF v_existing<>v_patient_id THEN
      RAISE EXCEPTION 'MSE id already exists for another patient';
    END IF;
    RETURN jsonb_build_object('ok',true,'mse_id',v_id,'idempotent',true);
  END IF;

  IF v_kind='routine' THEN
    SELECT admitted_at INTO v_admitted FROM public.patients
    WHERE id=v_patient_id AND active_status<>'discharged';
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Active patient not found';
    END IF;
  ELSE
    SELECT admitted_at INTO v_admitted FROM public.patients WHERE id=v_patient_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Patient not found';
    END IF;
  END IF;

  -- Client time is kept for offline saves, but never in the future.
  v_at=least(coalesce(nullif(p_row->>'created_at','')::timestamptz,now()),now());

  INSERT INTO public.mse_entries(id,patient_id,kind,admitted_at,data,high_risk,summary,created_by,created_by_name,created_at,recorded_at)
  VALUES (
    v_id, v_patient_id, v_kind, v_admitted, v_data,
    coalesce((p_row->>'high_risk')::boolean,false),
    left(nullif(trim(p_row->>'summary'),''),8000),
    v_resident_id, v_name, v_at, now()
  );

  RETURN jsonb_build_object('ok',true,'mse_id',v_id,'recorded_by',v_resident_id,'admitted_at',v_admitted);
END;
$function$;

revoke all on function public.ward_save_mse(uuid,jsonb) from public;
grant execute on function public.ward_save_mse(uuid,jsonb) to anon, authenticated, service_role;

-- Add mse_entries to ward_read_ward_state (patch the live definition in place).
do $$
declare
  v_def text;
begin
  select pg_get_functiondef('public.ward_read_ward_state(uuid)'::regprocedure) into v_def;
  if position('v_mse jsonb' in v_def) > 0 then
    raise notice 'ward_read_ward_state already has mse_entries';
    return;
  end if;
  if position('v_pedits jsonb;' in v_def) = 0 or position('''patient_edits'', v_pedits' in v_def) = 0
     or position('  return jsonb_build_object(' in v_def) = 0 then
    raise exception 'ward_read_ward_state anchors not found; patch manually';
  end if;
  v_def := replace(v_def, 'v_pedits jsonb;', 'v_pedits jsonb; v_mse jsonb;');
  v_def := replace(v_def, '  return jsonb_build_object(',
    E'  select coalesce(jsonb_agg(to_jsonb(m) order by m.created_at desc, m.id), ''[]''::jsonb) into v_mse from (\n'
    || E'    select id, patient_id, kind, admitted_at, data, high_risk, summary, created_by, created_by_name, created_at from public.mse_entries) m;\n\n'
    || '  return jsonb_build_object(');
  v_def := replace(v_def, '''patient_edits'', v_pedits', '''patient_edits'', v_pedits, ''mse_entries'', v_mse');
  execute v_def;
end $$;

-- Realtime: no publication change. Like ect_sessions, other devices refresh via the
-- client's 'MSE recorded' activity_log event (mse_entries has no RLS policies).

notify pgrst, 'reload schema';
