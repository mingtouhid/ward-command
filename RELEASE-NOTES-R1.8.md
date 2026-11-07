# Ward Sync R1.8

Bed distribution is now a native page.

Residents signed in for the evening shift can generate it. The server checks that duty. Everyone else with a resident login can view the current board from Home and from More. The creator can keep editing after the shift ends. An admin who did not generate the board cannot edit it. Roster setup stays in Users and starts empty.

Occupancy is a snapshot. Changing the chips does not move a patient. A published board stays as published until it is replaced or explicitly regenerated. Unassigned beds stay visible. Disabled owners stay flagged.

A generation stores one notice for active residents, admins, and SR accounts. The link opens that distribution, including after it is replaced. Interns and consultants do not receive it. Opting out of clinical alerts skips the push and still leaves the in-app notice. The phone or browser permission is unchanged.

`dispatch-bdft` sends Web Push and FCM for bed-distribution rows only. The migration stores a random scheduler credential in Vault under `ward_bdft_cron_secret` and schedules `ward_bdft_tick` every two minutes. The tick reads that credential inside the database. A wrong header is rejected before a claim. A resident session can still request immediate delivery of one bed-distribution notice. If the VAPID or FCM environment is absent, the function returns deferred and does not claim a row. This build does not apply the migration or deploy the function. The clinical dispatcher and the archive scheduler are unchanged.

Service worker cache: `ward-sync-pwa-r1.8`.

Prepared migration: `migrations/r18_bdft.sql`. Rollback: `migrations/r18_bdft.rollback.sql`. Neither has been applied to production.
