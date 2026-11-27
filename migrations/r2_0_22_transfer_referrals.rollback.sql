-- Roll back the transfer RPC without deleting clinical referral records.
drop function if exists public.ward_transfer_patient(
  uuid, jsonb, text, text, text, text[], jsonb, text, jsonb, text,
  text, integer, text[], text, jsonb, jsonb
);
-- patient_transfer_referrals is deliberately retained to preserve recorded referral data.
