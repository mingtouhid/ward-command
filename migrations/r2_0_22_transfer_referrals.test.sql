-- Structural / security checks for r2_0_22_transfer_referrals.
do $$
declare
  v_rls boolean;
  v_fn regprocedure;
begin
  select c.relrowsecurity into v_rls
  from pg_class c
  where c.oid = 'public.patient_transfer_referrals'::regclass;
  if v_rls is distinct from true then
    raise exception 'patient_transfer_referrals must have RLS enabled';
  end if;

  if has_table_privilege('anon','public.patient_transfer_referrals','select')
     or has_table_privilege('authenticated','public.patient_transfer_referrals','select')
     or has_table_privilege('service_role','public.patient_transfer_referrals','select') then
    raise exception 'Direct referral table access must remain revoked';
  end if;

  v_fn := to_regprocedure(
    'public.ward_transfer_patient(uuid,jsonb,text,text,text,text[],jsonb,text,jsonb,text,text,integer,text[],text,jsonb,jsonb)'
  );
  if v_fn is null then
    raise exception 'ward_transfer_patient RPC is missing';
  end if;

  if not has_function_privilege('anon',v_fn,'execute') then
    raise exception 'ward_transfer_patient must be callable through the ward session-token RPC path';
  end if;
end;
$$;
