-- R20.20 rollback — Transfer discharge referral workflow
-- Removes the new RPC entry points but intentionally retains ward_discharge_referrals.
-- Referral details are clinical history and must not be destroyed by an application rollback.
begin;
drop function if exists public.ward_list_discharge_referrals(uuid);
drop function if exists public.ward_discharge_with_transfer(
  uuid, jsonb, text, text[], jsonb, text, jsonb, text, text, integer, text[], text, jsonb, jsonb, text, text
);
notify pgrst, 'reload schema';
commit;
