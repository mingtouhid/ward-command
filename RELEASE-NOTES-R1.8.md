# Ward Sync R1.8

Bed distribution is now a native page.

Residents signed in for the evening shift can generate it. The server checks that duty. Everyone else with a resident login can view the current board from Home and from More. The creator can keep editing after the shift ends. An admin who did not generate the board cannot edit it. Roster setup stays in Users and starts empty.

Occupancy is a snapshot. Changing the chips does not move a patient. A published board stays as published until it is replaced or explicitly regenerated. Unassigned beds stay visible. Disabled owners stay flagged.

A generation stores one notice for active residents, admins, and SR accounts. The link opens that distribution, including after it is replaced. Interns and consultants do not receive it. Opting out of clinical alerts skips the push and still leaves the in-app notice. The phone or browser permission is unchanged.

`dispatch-bdft` sends Web Push and FCM for bed-distribution rows only, using the VAPID or FCM environment already used by `dispatch-notification`. If that environment is absent it returns deferred and does not claim a row. This build does not deploy the function and its tests use mocked HTTP. No cron job calls it. Unattended retry needs an operator-approved schedule that can present an eligible resident session. `ward_dispatch_anon_key` is not created.

Service worker cache: `ward-sync-pwa-r1.8`.

Prepared migration: `migrations/r18_bdft.sql`. Rollback: `migrations/r18_bdft.rollback.sql`. Neither has been applied to production.
