# Ward Sync R1.8

Bed distribution is now a native page.

Residents signed in for the evening shift can generate it. The server checks that duty. Everyone else with a resident login can view the current board from Home and from More. The creator can keep editing after the shift ends. An admin who did not generate the board cannot edit it. Roster setup stays in Users and starts empty.

Occupancy is a snapshot. Changing the chips does not move a patient. A published board stays as published until it is replaced or explicitly regenerated. Unassigned beds stay visible. Disabled owners stay flagged.

A generation queues one resident notice. This release does not send that notice. The dispatch key is still absent, and this change does not create one.

Service worker cache: `ward-sync-pwa-r1.8`.

Prepared migration: `migrations/r18_bdft.sql`. Rollback: `migrations/r18_bdft.rollback.sql`. Neither has been applied to production.
