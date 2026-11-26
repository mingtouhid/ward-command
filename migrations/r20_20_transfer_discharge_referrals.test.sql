-- R20.20 verification checks (read-only; run after applying the migration).
do $$
declare v_forced boolean; v_rls boolean;
begin
  if to_regclass('public.ward_discharge_referrals') is null then
    raise exception 'Missing table public.ward_discharge_referrals';
  end if;
  select relrowsecurity, relforcerowsecurity into v_rls, v_forced
    from pg_class where oid = 'public.ward_discharge_referrals'::regclass;
  if not v_rls or not v_forced then raise exception 'Referral table RLS must be enabled and forced'; end if;
  if has_table_privilege('anon', 'public.ward_discharge_referrals', 'SELECT')
     or has_table_privilege('authenticated', 'public.ward_discharge_referrals', 'SELECT') then
    raise exception 'Direct referral table SELECT must remain revoked';
  end if;
  if to_regprocedure('public.ward_discharge_with_transfer(uuid,jsonb,text,text[],jsonb,text,jsonb,text,text,integer,text[],text,jsonb,jsonb,text,text)') is null then
    raise exception 'Missing atomic Transfer discharge RPC';
  end if;
  if to_regprocedure('public.ward_list_discharge_referrals(uuid)') is null then
    raise exception 'Missing referral read RPC';
  end if;
end $$;
select 'R20.20 transfer discharge referral checks passed' as result;
