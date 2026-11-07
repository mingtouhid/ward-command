# Ward Sync R1.7 design

Approved for implementation on 2026-11-07. Baseline is `main` at `d252785` (R1.6.2), confirmed against `origin/main` on that date. This document records the approved behaviour. It is not a new design proposal.

Fixed resident bed assignments are explicitly out of scope and are not implemented.

## Release boundary

- Version becomes **R1.7**. Service-worker cache name becomes `ward-sync-pwa-r1.7` in the same change as `APP_VERSION`.
- Ship on a branch and pull request only. Do not merge `main`, deploy Vercel, apply migrations, or change production data.
- The single-file PWA stays a single file. New rules live in `index.html` and are covered by synthetic unit tests. No patient data, screenshots, PDFs, photos, private backups, secrets, or `/tmp` files are committed.
- Monthly archive embeds app-core in production, and that edge source is not in this repo. On an eventual Push the archive bundle must be regenerated from the released `index.html`. This change does not add or deploy edge-function source.
- `ward_dispatch_anon_key` is not created.

## 1. Intern Home — today's vitals

The existing daily vitals rule remains the clinical rule: one qualifying vitals set per admitted patient per IST calendar day. No extra vital-sign schedule is added.

A set qualifies only when all of the following are true:

- The patient is still on the ward (not discharged).
- `recorded_at` falls on the current IST calendar day (`UTC+05:30`, same conversion the certificate clock already uses).
- `recorded_at` is on the current admission (`admitted_at` minus one minute of clock skew). An earlier admission does not qualify.
- The row is **server-saved**. A queued or retrying outbox row is Saving, not completed. A failed outbox row is Failed, not completed. Absence of an unacked outbox op means the row came from the server (or has been acked).

Any intern's saved set counts once for that patient. The row shows who saved it. A second intern does not add a second completion.

Home layout:

- Pending patients (remaining, saving, failed) are listed before completed patients.
- Compact counts: **Completed** and **Remaining**. Remaining is everyone without a server-saved qualifying set.
- Saving and Failed are separate indicators. They are never added to Completed.
- Each not-yet-completed row has a **Record vitals** action that opens the existing intern vitals sheet.
- At 1024px and wider the list is one aligned table (bed, patient, status, action). Below that it is compact cards, including tablet and 360/390 phones.
- Counts recompute when the IST date changes, when the ward refresh returns, and when a vitals save is acked or fails.
- Empty ward, empty search, and "all complete" are distinct.
- Offline or unsynced saves stay Saving or Failed. The screen does not say Completed until the server has the row.

Reports stay on the Reports tab. Resident-assigned intern tasks are a separate block under the vitals list. Neither is mixed into the vitals rows.

The Vitals tab uses the same saved-today predicate, so a queued set is not labelled done there either.

## 2. Intern tasks assigned by a resident

Existing resident `tasks` stay resident tasks. They are not added to `ward_intern_read_state`. Interns still cannot call resident clinical RPCs. Intern permissions stay vitals, reports, CIWA-Ar, and COWS. MSE and discharge are not granted.

New table `intern_assignments` is a narrow shared status row: id, patient, kind (`report` or `general`), short title, due date, status, assigner name, completer name and time, linked report id. It does not store report bodies, MSE text, medicines, or other clinical content.

- A resident or admin assigns one task to the intern group for one admitted patient, with a due date and a kind. Consultants and interns cannot assign.
- **Report** tasks cannot be ticked complete. A non-deleted, server-saved report for that patient on the current admission links the oldest open report task and marks it done. One report closes one task. Deleting that report reopens the task. The intern read model receives the status and the report id, not the report contents.
- **General** tasks are marked complete by a signed-in intern. The server records who and when. A second complete call is idempotent and does not create a second completion. Undo is allowed for the intern who completed it, and for a resident or admin. Undo is persisted.
- Completion is shown only after the server accepts it. Offline attempts stay open and say they were not saved.
- Every intern sees the same rows from `ward_intern_read_state`. Residents and consultants see the same narrow rows from `ward_list_r17_status` on the task board. That list is not the resident task table.

## 3. Advisory discharge review

Every ward-discharge entry asks the same question before the form or the commit:

- open discharge from the patient page and the More drawer (`openSnapDischarge`)
- the small discharge panel that continues into that form
- Census → Discharge → Continue
- the legacy immediate `dischargePatient` path
- observation dispose and observation refer (`closeObservation`)
- Confirm discharge rechecks before the patient is marked discharged

The warning appears only when the **current admission** has no eligible MSE, or no eligible report, or neither.

Eligible MSE:

- not deleted
- not only a local draft
- persisted (no unacked outbox op)
- `created_at` on this admission, using the existing six-hour admission slack (`mseCurrentAdmission`)
- any kind, including an older routine MSE from earlier in the same admission
- no "must be from today" rule

Eligible report:

- not deleted
- persisted
- `reported_at`, or `created_at` when there is no reported time, on this admission with the same six-hour slack
- one saved report is enough for this check

A saved report does **not** mean every investigation is complete. The warning says that in those words whenever it is shown.

A discharge MSE that is only filled on the device is **prepared**, not eligible. The warning says it is not saved yet and that it counts only when the discharge transaction saves it. The pre-submit warning does not treat it as present. `ward_discharge_with_review` inserts that MSE in the same transaction as `ward_discharge_patient` when the payload is valid. An invalid payload is skipped and does not roll back a clinically necessary discharge. If the new RPC is not installed, the client keeps today's behaviour: the existing discharge RPC runs, and the prepared MSE is queued afterwards, which is not atomic. The screen must not claim it was saved atomically.

Prior-admission and deleted rows do not qualify. When they are the latest on record, the warning shows that date and why it is not counted. When nothing exists, the warning says none is on record.

Actions: **Update MSE**, **Review or add reports**, **Continue discharge**, **Cancel**. Cancel leaves the patient admitted. Continue asks for a reason of at least three characters. The warning never replaces required discharge fields (MRD, DAMA requester, medicines, instructions, review interval, date) and never blocks a discharge the clinician continues.

Recheck at final submit. An override captured for an earlier evaluation is reused only when the fingerprint still matches (admission time, missing parts, eligible record ids, whether a prepared MSE will be sent). A changed evaluation asks again.

The audit row is written only inside the successful discharge transaction, with the session resident, server `now()`, admission timestamp, missing flags, and record ids. It does not copy MSE text or report results. If the new RPC is absent, discharge still proceeds through the existing RPC and the client says the review note was not stored on the server. It does not invent a server audit.

## 4. Today's schedule — mark a scheduled ECT complete

Home → Today's schedule lists planned ECT whose `next_session_at` is the current IST day for a patient on the current admission. Each of those rows gets a **Mark complete** control on the right of the time, course, and bed text.

`markEctDone` on the ECT page records a course session and sets the next ECT day. Calling it here would schedule the next session, which this control must not do. The schedule control therefore does **not** call `markEctDone`, does **not** change `sessions_done`, and does **not** change `next_session_at`. It writes one `ect_schedule_completions` row for that plan and that `next_session_at`.

That is one completion state for the scheduled occurrence, not a second course counter. The ECT page Session done button is unchanged.

Rules:

- Resident or admin only. Consultants see the completed state and do not get the button. Interns do not see this home card.
- The occurrence must still be the plan's current `next_session_at`, the plan must be `planned`, and the patient must be on this admission.
- A second save for the same plan and occurrence returns the existing row (unique where not undone). The plan row is locked during the write.
- Success shows **Completed**, the resident's name, and the server time in IST, plus **Undo**.
- Undo clears that completion and does not move the next session.
- The control is not shown as completed until the server accepts it. Offline leaves the row uncompleted and says it was not saved.
- Non-ECT schedule rows, if any are added later, render without this button. This release still has no other schedule source.

## 5. Explicitly deferred

Fixed resident bed assignments are not designed further and are not implemented.

## Data touch points

| Piece | Role |
| --- | --- |
| `r17*` functions in `index.html` | IST day, vitals board, discharge review, task rules, schedule rows, and the HTML those screens share |
| `intern_assignments` | Shared intern-task status |
| `ect_schedule_completions` | One completion per scheduled ECT occurrence |
| `discharge_review_overrides` | Audit of a continued warning, written only with a successful discharge |
| `ward_intern_read_state` | Adds `intern_tasks` only. No resident tasks, MSE, or discharge payloads |
| `ward_list_r17_status` | Narrow task and ECT-completion read for ward sessions |
| `ward_discharge_with_review` | Calls existing `ward_discharge_patient`, then optional atomic MSE and override |

Migrations are the usual forward file plus a rollback file. Nothing in this change applies them.

## Testing

Synthetic unit tests load only the `R17_RULES` block. They cover IST midnight, admission boundaries, queued versus saved versus failed vitals, single credit for any intern, discharge deletions and prior admissions, prepared versus atomic MSE, the "not every investigation" line, task permission and idempotency, report-link rules, and ECT completion that does not schedule the next session.

No existing automated suite is in the repo. `node --check` covers the app script. Screenshots use invented patients only.

## Self-review

- No placeholder requirements remain. Bed assignments are named as deferred, not left open.
- Vitals completion, task completion, and ECT completion use three different records because they are three different clinical acts. They do not share a status field.
- The discharge warning cannot be satisfied by a prepared MSE before the server transaction returns. That matches the atomic-save rule and avoids a false "MSE present".
- Intern read access grows only by the assignment-status columns listed above.
- Schedule completion does not call the course-session function, so it cannot move `next_session_at`.
