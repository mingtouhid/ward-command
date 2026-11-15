-- R1.9.0.1. Applied. The one-off duplicate cleanup was done manually on 2026-11-15
-- (one accidental duplicate ECT session for the same patient on 14 Nov 2026; session 2
-- saved 36 seconds after session 1, with no clinical data; that plan's sessions_done
-- was set from 2 to 1). This file does not delete or update any rows.

create unique index if not exists ect_sessions_one_per_patient_ist_day
  on public.ect_sessions (patient_id, ((session_at at time zone 'Asia/Kolkata')::date));
