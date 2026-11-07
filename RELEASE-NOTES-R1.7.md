# R1.7

Baseline R1.6.2 (`d252785`). Not merged and not deployed by this change.

- Intern Home lists today's pending vitals first, with Completed and Remaining counts, a separate Saving or Failed indicator, and Record vitals. A set counts only when it is saved on the server for the current admission and the current IST day. Any intern's saved set counts once.
- Residents can assign intern tasks (report or general) with a patient and a due date. Report tasks close only when a saved report is linked. General tasks are completed and undone with a name. Interns do not receive resident tasks, MSE, or discharge access.
- Discharge entry warns when this admission has no eligible MSE or no eligible report. It does not block discharge. Continue asks for a reason. The audit row is written only with a successful discharge, and only when the new database function is installed.
- Today's schedule can mark a scheduled ECT complete and undo it. That does not schedule the next ECT and does not change the session count.
- Fixed resident bed assignments are not in this release.

Service worker cache: `ward-sync-pwa-r1.7`.

The monthly archive embeds app-core outside this repo. On an eventual Push, regenerate that bundle from this `index.html`. Do not invent the edge source here.

Migrations (not applied): `migrations/r17_intern_tasks_discharge_review_ect.sql` and `migrations/r17_intern_tasks_discharge_review_ect.rollback.sql`.
