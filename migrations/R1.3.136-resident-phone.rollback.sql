-- R1.3.136 rollback · removes the phone RPCs and tables. WARNING: saved phone numbers and their audit rows are deleted.
-- Safe with the R1.3.136 app still deployed: the app treats the missing RPCs as "feature not available" (no chips, no field errors).
begin;
drop function if exists public.ward_list_duty_phones(uuid);
drop function if exists public.ward_phone_status(uuid);
drop function if exists public.ward_get_my_phone(uuid);
drop function if exists public.ward_set_resident_phone(uuid,text,text);
drop function if exists public.ward_phone_e164(text);
drop table if exists public.resident_phone_audit;
drop table if exists public.resident_phones;
commit;
