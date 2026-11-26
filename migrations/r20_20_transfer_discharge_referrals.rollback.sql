-- R20.20 rollback — Transfer discharge referral details
-- Removes only the objects introduced by r20_20_transfer_discharge_referrals.sql.
begin;
drop function if exists public.ward_list_discharge_referrals(uuid);
drop function if exists public.ward_discharge_with_transfer(
  uuid, jsonb, text, text[], jsonb, text, jsonb, text, text, integer, text[], text, jsonb, jsonb, text, text
);
drop table if exists public.ward_discharge_referrals;
commit;
