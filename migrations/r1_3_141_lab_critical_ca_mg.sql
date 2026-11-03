-- R1.3.141 r1_3_141_lab_critical_ca_mg  (PREPARED, NOT APPLIED)
-- Adds total calcium and magnesium critical bands to ward_lab_critical; mirrors labCrit() in index.html.
-- No table, data or permission changes. The R1.3.141 sync fix is client-only and needs no server change.
CREATE OR REPLACE FUNCTION public.ward_lab_critical(p_code text, p_v numeric)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select case
    when p_v is null then null
    when p_code = 'k'   then case when p_v < 2.5 then 'CRIT_L' when p_v >= 6.0 then 'CRIT_H' end
    when p_code = 'na'  then case when p_v < 120 then 'CRIT_L' when p_v >= 160 then 'CRIT_H' end
    when p_code = 'hb'  then case when p_v < 7 then 'CRIT_L' end
    when p_code in ('rbs','fbs','ppbs') then case when p_v < 50 then 'CRIT_L' when p_v > 400 then 'CRIT_H' end
    when p_code = 'plt' then case when p_v < 10000 then 'URGENT' when p_v < 20000 then 'CRIT_L' end
    when p_code = 'li'  then case when p_v >= 1.5 then 'CRIT_H' end
    when p_code = 'vpa' then case when p_v > 150 then 'CRIT_H' end
    when p_code = 'ca'  then case when p_v <= 6.5 then 'CRIT_L' when p_v >= 13 then 'CRIT_H' end
    when p_code = 'mg'  then case when p_v <= 1.0 then 'CRIT_L' when p_v >= 4.5 then 'CRIT_H' end
  end
$function$;
