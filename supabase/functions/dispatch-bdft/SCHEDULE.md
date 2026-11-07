# dispatch-bdft schedule

The migration creates a random Vault secret named `ward_bdft_cron_secret` and a pg_cron job named `ward-bdft-dispatch`. The job runs `select public.ward_bdft_tick()` every two minutes. The tick reads that secret inside the database and posts it only as the `x-ward-bdft-secret` header. The command text does not contain the secret. The function does not return it.

`dispatch-bdft` is deployed with `verify_jwt = false` in `supabase/config.toml`. It asks `ward_bdft_cron_ok` whether the header matches, then drains only the bed-distribution outbox. A wrong or missing header is rejected before a claim. The clinical dispatcher and the archive scheduler credential are not used.

This repository does not run the migration against production. The parent release applies `migrations/r18_bdft.sql`. Rollback is `migrations/r18_bdft.rollback.sql`. Applying it removes the job and the Vault secret. No edge environment variable has to be set for this credential. The function still needs the platform database role it already receives at deploy time, and the existing VAPID or FCM environment, before a push can leave the worker.
