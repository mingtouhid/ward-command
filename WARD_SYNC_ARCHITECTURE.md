# Ward Sync architecture

This note describes the system as it exists in commit `381a4c412764677d217ca19d8c54a69cb9b4f929` (`fix(ect): record completed sessions to backend, advance schedule, match home card button styling with Ward Sync UI`, 2026-11-09). It is for a later implementer. It follows the code, SQL, and edge function in this tree. Where a file header and the client disagree, both are stated. Production apply status is not recorded here.

The app is an internal psychiatry ward duty board. Staff sign in, see occupied beds, and record admissions, observations, medicines, notes, MSE, vitals, rating scales, labs, ECT, handovers, tasks, and discharge. Bed-distribution (BDFT) assigns tomorrow's occupied beds across resident batches.

## Runtime topology

The running system is four pieces. Two of the edge functions are called by name and are not stored in this repository.

| Piece | Where it lives | What it does |
| --- | --- | --- |
| Static PWA | Vercel, from this Git repo | `index.html` plus `sw.js`, `manifest.json`, icons, and `/ocr/` |
| Postgres | Supabase project referenced by the client | Clinical tables, `ward_*` RPCs, RLS, pg_cron, Vault |
| Edge functions | Supabase Functions | `dispatch-bdft` is in `supabase/functions/dispatch-bdft/`. `dispatch-notification` and `monthly-archive` are called and are not in this tree |
| Drive archive | Google app named in `privacy.html` | Monthly copies of ward records, `drive.file` scope only |

The browser loads one page. Hash routes (`#/home`, `#/snap/<id>`, `#/bdft`, and the rest) are client-side. `vercel.json` rewrites extension-less paths to `index.html`. `404.html` also replaces the location with `index.html` plus the hash.

The client talks to Supabase with the JS client from `cdn.jsdelivr.net` (`@supabase/supabase-js@2.57.4`). `cloudConnect()` sets `auth.persistSession` and `autoRefreshToken` to false. Clinical calls are `sb.rpc(...)` with a ward session token. They are not Supabase Auth user JWTs. Realtime uses `postgres_changes` on a fixed table list. The service worker never caches hosts ending in `supabase.co` or `supabase.in`.

A publishable project URL and key ship inside `seed()` as `DEFAULT_SB_URL` and `DEFAULT_SB_KEY`. Admins can replace them on the Connection screen (`saveSb()`). Those values are credentials. They are not copied into this document.

`privacy.html` (updated 19 October 2026) says the product is an internal staff tool, records stay in the ward database and the ward Drive, and the archive app can see only files it creates.

## Frontend structure

Almost all application code is `index.html` (about 1.58 MB at this commit). It is one document: CSS, then one script. There is no bundler step in `vercel.json` (`buildCommand` is null, `outputDirectory` is `.`).

`APP_VERSION` in the script is `R1.8`. The visible More page prints `Build ${APP_VERSION}`. Older release comments remain in the CSS and script (`R1.3.124` in the document head, many `R1.3.*` and `R1.5`/`R1.6`/`R1.7` markers). Treat those comments as history inside the file. Behaviour at this commit is what the functions do now.

Other frontend files:

- `sw.js` — cache name `ward-sync-pwa-r1.8`, separate OCR cache `ocr-assets-v7`, push display, fetch strategy.
- `manifest.json` — PWA name "Ward Sync", portrait standalone. Its `version` field is still `1.3.20` / `R1.3.20 icons`. That string is older than `APP_VERSION`.
- `ocr/` — Tesseract assets and `ocr/ward-ocr.js`. The scanner is a pilot: `labOcrOn()` is true only when `localStorage` `ws_ocr_pilot` is `1` (also toggled by `?ocr=1` / `?ocr=0`) and `WebAssembly` and `caches` exist.
- Icons at the repo root and under `icons/` (including notification badge art).
- `.github/workflows/assemble-index.yml` can rebuild `index.html` from `_b64/part*.b64`. This commit has no `_b64/` directory. The workflow is manual or path-triggered and is not how the current `index.html` was produced.

Rendering is a full HTML string swapped into `#app` by `render()`. `go(page, id)` pushes a tab stack and `history.pushState`. `pages` maps route names to view functions (`homeView`, `patientsView`, `snapView`, `bdftView`, and so on). Interns replace that map: see Auth and roles.

Local state object `S` is JSON in `localStorage` under `ward-command-html-v2-v8748-fresh`. It holds the ward the device last pulled or edited: unit, sections, beds, patients, assignments, snapshots, orders, doses, tasks, handovers, ECT, events, and similar lists. A fresh key copies only identity and preference fields from the previous key (`FRESH_CARRY`). It does not copy patient rows or the old outbox.

`seed()` supplies a demo ward when that key is empty. Live sign-in replaces it from `ward_read_ward_state`. Do not treat the seed roster or seed patients as production data.

## Navigation and routes

Staff who can write, and consultants, use `shell()`: Home, Patients, Handovers, More.

Hash pages and the tab they belong to (`PAGE_TAB`):

| Page | Tab | Role |
| --- | --- | --- |
| `home` | Home | Today board, duty, BDFT card, attention tiles |
| `patients`, `snap`, `record`, `pedit`, `dcert`, `dedit`, `vchart`, `scale`, `srate` | Patients | List, patient page, history, edits, certificate, vitals chart, scales |
| `handover` | Handovers | Shift handovers |
| `more` and the pages below | More | Hub |
| `census` | More | Admit / discharge register |
| `observe` | More | Under observation |
| `ect` | More | ECT list and schedule |
| `tasks` | More | Shared task board |
| `activity` | More | Activity log |
| `broadcast` | More | Shift broadcast |
| `myorders` | More | Consultant advice the consultant issued |
| `bdft` | More | Bed distribution |
| `profile` | More | Signed-in resident or admin: own username, display name, phone, BDFT short name, owned beds. No one else's row |
| `ward`, `users` | More | Admin ward setup and users |
| `setup` | More | Theme, density, accent, notifications |
| `connection` | More | Sync status; admin project keys |
| `about` | More | About |

Patient page tabs (`R151_TABS`): summary, meds, notes, mse, results, scales.

Interns do not get that shell. `internShell` / `internNavHtml` are Home, Vitals (`ivitals`), Reports (`ireports`). Their `pages` map keeps `home` (`internHomeView`), `snap` (`internSnapView`), `ivitals`, `ireports`, and `ireport`.

## Auth and roles

Sign-in is `cloudLogin()` → `ward_login(p_username, p_password)`. The returned token is `sessionTok`, stored as `wc_tok` in both `sessionStorage` and `localStorage`. `ward_session_user` (described in the phone migration) joins `ward_sessions` to `residents`. Session-dead errors match "not signed in" / "invalid or expired" / "no active ward session" and call `expireSession()`.

`normRole()`:

- `admin` and legacy `SR` → `admin`
- `consultant` / `Consultant` → `consultant`
- `intern` / `Intern` → `intern`
- anything else, including `JR` → `resident`

`canWrite()` is true for admin and resident. Consultants are view-only (`needWrite()` toasts). Interns are also not `canWrite()`, and a second guard limits their RPCs.

`INTERN_RPCS` is the only set `internGuardRpc` will send while an intern is signed in: `ward_login`, `ward_intern_read_state`, `ward_intern_save_lab_report`, `ward_save_vitals`, `ward_intern_save_scale`, `ward_complete_intern_task`, `ward_undo_intern_task`, `ward_link_intern_report_task`. The client comment says the server keeps intern tokens in `ward_intern_sessions`, which other `ward_*` functions do not accept. Interns do not subscribe to realtime (`cloudListen` returns immediately).

Other capability checks: `canAdmin()` for ward setup, users, and project keys; `canBroadcast()` for any signed-in user; `canAccessBdft()` for admin or a writing non-intern non-consultant (residents); `canDeleteRecords()` for resident or admin; monthly spreadsheet export for admin or consultant (`exportMonthly`).

Duty sign-in is separate from login: `ward_sign_duty`, `ward_set_duty_area`, `ward_end_duty`. Shifts in the client are morning 08:00–14:00, evening 14:00–22:00, night 22:00–08:00 (`currentShift`). Several server helpers use IST (UTC+5:30) explicitly (`istShift`, `r17IstDay`, BDFT date labels).

Phone numbers (R1.3.136) are not columns on `residents`, because `ward_session_user` returns that row. They live in `resident_phones` / `resident_phone_audit`. The client keeps them out of `S`, UI snapshots, the outbox, and the error log. RPCs: `ward_set_resident_phone`, `ward_get_my_phone`, `ward_phone_status` (admin, presence only), `ward_list_duty_phones` (consultant, numbers of residents with an open duty sign-in in the last 20 hours). The migration header still says "NOT APPLIED". The client treats a missing RPC as "feature not available".

User administration (admin): `ward_invite_user`, `ward_update_user`, `ward_set_user_designation`, `ward_set_role`, `ward_deactivate_user`.

My profile (`profileView`, More) is the signed-in resident's or admin's own page. Phone still uses `ward_get_my_phone` and `ward_set_resident_phone` (the number is returned only to that session). BDFT short name and owned beds still use `ward_bdft_save_setup` (resident self-edit from `r18_1`). Username and display name use `ward_update_my_profile` in `migrations/r18_2_update_my_profile.sql`, which updates only the session's own `residents` row and rejects a duplicate username. That migration is not applied here. If the RPC is missing, the page keeps the previous name and still saves phone and BDFT. There is no photo upload and no password field.

New residents can also get a BDFT batch, short name, and owned beds (`bdftSaveNewResidentSetup`). BDFT is not a block inside the users editor; it is the More tile and the settings screen. Consultants are managed with `ward_upsert_consultant`, `ward_list_faculty`, `ward_set_patient_consultant`.

## Sync, outbox, and realtime

Writes that must survive a bad network go through `queue(table, row)` into an outbox. The outbox is mirrored to `localStorage` and IndexedDB (`ward-command` outbox keys; legacy DB names are deleted on a fresh start). Each queued op is stamped with the login that created it (`opMine`). A shared phone does not flush an intern's queued vitals with the next resident's token.

`flushPending` / `schedulePush` send the queue. The table name selects the RPC inside the flush path, including:

`ward_upsert_bed`, `ward_set_bed`, `ward_upsert_patient`, `ward_upsert_medication_order`, `ward_record_medication_dose`, `ward_upsert_ect_plan`, `ward_record_ect_session`, `ward_save_mse`, `ward_save_discharge_certificate`, `ward_save_lab_report` or `ward_intern_save_lab_report`, `ward_write_activity_log`, `ward_upsert_patient_bed_assignment`, `ward_withdraw_handover`, `ward_upsert_handover`, `ward_upsert_handover_item`, `ward_upsert_task`, `ward_upsert_section`, `ward_set_patient_consultant`, `ward_upsert_consultant`, `ward_upsert_unit_settings`, `ward_toggle_restrain`, `ward_patch_snapshot_field`, `ward_patch_snapshot_tags`, `ward_append_pgt_note`, `ward_save_vitals`, `ward_save_scale` or `ward_intern_save_scale`.

Some actions call an RPC immediately and only queue on failure (ECT session completion, handover take, admission). The status chip is Live / Saving / Needs attention / Offline from outbox counts plus `Sync.state`.

Pull is `ward_read_ward_state` for staff, `ward_intern_read_state` for interns. Extra reads: `ward_list_critical_status_updates`, `ward_list_patient_advice`, `ward_list_ect_plan_meta`, `ward_read_lab_history`, `ward_read_scale_history`, `ward_list_my_advice`, `ward_list_faculty`, `ward_list_patient_consultants`, `ward_discharge_edit_versions`, `ward_restrain_state`, `ward_list_r17_status`. `reconcileLocal` keeps local rows that are pending, very new, or older than the server window (so archived months are not wiped by a short pull).

Realtime channel `ward-command-live` listens for all events on: `critical_status_updates`, `activity_log`, `patient_snapshots`, `beds`, `patients`, `medication_doses`, `medication_orders`, `ect_plans`, `handovers`, `handover_items`, `tasks`, `patient_bed_assignments`, `ward_sections`, `unit_consultants`, `ward_duty`, `patient_advice`, `patient_advice_acks`. A change debounces 500 ms and pulls again. BDFT tables are not in that list. BDFT reloads on boot, when the tile or page opens, and after a save.

A 45 s timer reconnects realtime. A 15 s timer retries due outbox ops. `wardFetch` aborts a hung request after 45 s.

## Data model

`migrations/` is incremental. It does not create the original ward schema. Tables such as `patients`, `beds`, `residents`, `ward_sessions`, `ward_duty`, `medication_orders`, `medication_doses`, `ect_plans`, `handovers`, `tasks`, `patient_snapshots`, `activity_log`, `notification_events`, `notification_deliveries`, `push_subscriptions`, `fcm_device_tokens`, `archive_manifest`, and `patient_vitals` are used by later SQL and by the client, and their `CREATE TABLE` is not in this folder. Several migration headers still say "PREPARED, NOT APPLIED" or "NOT APPLIED". That is the status written in the file. The client at this commit calls the RPCs anyway and degrades when PostgREST says the function is missing.

### Tables and columns added in this folder

| Migration | What it adds |
| --- | --- |
| `r1_3_124_mse.sql` | `mse_entries` (routine or discharge). Header says applied 2026-10-25. RLS forced, no policies |
| `r1_3_125_stopped_at.sql` | Medication stop timestamp behaviour on `ward_upsert_medication_order` / `ward_read_ward_state` |
| `r1_3_126_discharge_certificate.sql` | `discharge_certificates`; certificate and discharge RPC updates; `ward_consultant_snapshot` |
| `r1_3_127_undo_admission.sql` | `admission_undo`; admit / confirm / undo / convert RPCs |
| `r1_3_128_lab_reports.sql` | `lab_reports`, `lab_results`, `lab_report_edits`. Header says local-only when written |
| `r1_3_129_lab_save_fix.sql` | `ward_save_lab_report` DELETE gets a WHERE so Supabase `safeupdate` does not abort the RPC |
| `R1.3.133-discharge-med-instructions.sql` | Discharge med JSON keeps an `instructions` string (max 200). Header says applied |
| `R1.3.134-lab-ocr-phase1.sql` | OCR fields on lab reports and edits (`entry_method`, `ocr_stats`, `match_reason`). Header says applied |
| `R1.3.135-lab-sync-window.sql` | `ward_read_ward_state` keeps recent lab rows and 14-day tombstones. Header says not applied |
| `R1.3.136-resident-phone.sql` | `resident_phones`, `resident_phone_audit`. RLS forced, no policies, not in realtime. Header says not applied |
| `r1_3_141_lab_critical_ca_mg.sql` | Extends `ward_lab_critical` |
| `r1_3_143_rating_scales.sql` | `scale_defs`, `scale_assessments`; calc/save/delete/restore/read RPCs. Seeds BPRS, YMRS, HAM-D, CIWA-Ar, COWS, Y-BOCS, BFCRS, CGI-S, CGI-I, C-SSRS, CAM. Intern flag on CIWA-Ar and COWS |
| `r1_3_144_custom_frequency.sql` | Custom frequency text survives observation close, discharge, and discharge edit |
| `r145_vitals_ranges.sql` | `ward_save_vitals` range flags on `patient_vitals` |
| `r16_shift_handovers.sql` | `handovers.target_date`, nullable `to_id`; shift-slot take. Header says not applied. Rollback file present |
| `r17_intern_tasks_discharge_review_ect.sql` | `intern_assignments`, `ect_schedule_completions`, `discharge_review_overrides`. Header says prepared, not applied |
| `r161_archive_v2.sql` | `archive_manifest.archive_version` and `history`; certificate print columns `printed_render`, `printed_fmt`, `printed_app_version`; service-only archive readers |
| `r161_archive_rerun_request.sql` | Rerun request columns and pg_cron job `ward-archive-rerun` |
| `r18_bdft.sql` | `residents.bdft_batch`, `bdft_short`, `bdft_order`; `bdft_bed_owners`, `bdft_distributions`, `bdft_rows`. Header says prepared, not applied to production |
| `r18_1_bdft_resident_self_edit.sql` | Replaces `ward_bdft_save_setup` and adds `ward_bdft_save_distribution` |

RLS on the new clinical and BDFT tables in these files is enabled and forced, with no policies, and `anon` / `authenticated` have table privileges revoked. Access is `SECURITY DEFINER` RPCs. Grants to `anon` and `authenticated` are `EXECUTE` on the session-token RPCs the browser calls. Helpers such as `bdft_compute`, `bdft_actor`, `ward_bdft_service_claim`, and `ward_archive_state` are revoked from `anon` and `authenticated`.

`bdft_distributions` has a partial unique index `bdft_one_current` so only one row has `status = 'current'`. Status is `current` or `archived`. Census on that table is `live` or `empty`.

### Session RPCs the client calls

Grouped by area. Signatures are in the SQL files or, for older RPCs, only implied by the client arguments.

Auth, users, duty, phones: `ward_login`, `ward_invite_user`, `ward_update_user`, `ward_set_user_designation`, `ward_set_role`, `ward_deactivate_user`, `ward_sign_duty`, `ward_set_duty_area`, `ward_end_duty`, `ward_set_resident_phone`, `ward_get_my_phone`, `ward_phone_status`, `ward_list_duty_phones`.

Read models: `ward_read_ward_state`, `ward_intern_read_state`, `ward_list_r17_status`, `ward_list_faculty`, `ward_list_patient_consultants`, `ward_list_ect_plan_meta`.

Census and movement: `ward_admit_patient` (named by the assemble workflow and the undo migration), `ward_confirm_admission`, `ward_undo_admission`, `ward_start_observation`, `ward_convert_observation`, `ward_close_observation`, `ward_close_observation_with_review`, `ward_discharge_patient` (SQL), `ward_discharge_with_review`, `ward_edit_patient`, `ward_edit_discharge`, `ward_discharge_edit_versions`.

Clinical writes: the flush list above, plus `ward_edit_med_order`, `ward_edit_advice`, `ward_issue_advice`, `ward_remove_advice`, `ward_ack_advice`, `ward_list_my_advice`, `ward_list_patient_advice`, `ward_create_critical_status_update`, `ward_delete_mse`, `ward_restore_mse`, `ward_delete_lab_report`, `ward_restore_lab_report`, `ward_delete_scale`, `ward_restore_scale`, `ward_take_handover`, `ward_ack_handover`, `ward_update_handover_item`, `ward_update_task`, `ward_assign_intern_task`, `ward_complete_intern_task`, `ward_undo_intern_task`, `ward_link_intern_report_task`, `ward_complete_scheduled_ect`, `ward_undo_scheduled_ect`.

Notifications and backup: `ward_create_notification_event`, `ward_list_notification_inbox`, `ward_mark_notification_read`, `ward_get_notification_preferences`, `ward_set_notification_preferences`, `ward_register_push_subscription`, `ward_unregister_push_subscription`, `ward_broadcast_list`, `ward_broadcast_mark_read`, `ward_broadcast_send`, `ward_broadcast_delete`, `ward_create_nightly_backup`.

BDFT session RPCs the client calls: `ward_bdft_state`, `ward_bdft_save_setup`, `ward_bdft_save_distribution`.

BDFT session RPCs defined in `r18_bdft.sql` with no caller in `index.html`: `ward_bdft_generate`, `ward_bdft_move`, `ward_bdft_undo`, `ward_bdft_regenerate`, `ward_bdft_open`, `ward_bdft_dispatch_scope`.

Service-only (not granted to the browser role): `ward_bdft_service_claim`, `ward_bdft_service_apply`, `ward_bdft_cron_ok`, `ward_bdft_tick`, `ward_bdft_provision_cron_secret`, `bdft_compute`, `bdft_pack`, `bdft_write_rows`, `bdft_queue_notice`, `bdft_actor`, `bdft_on_evening`, archive functions below.

## Clinical workflows

All of these are high level. Field lists and validation live in `index.html` and the matching RPC.

**Admissions.** Census "Admit / Discharge" opens an admit panel (`admitForm` / `admitCommit`). Reasons include diagnosis and management, de-addiction, opinion, and mental health certificate. Treatment mode is conservative, ECT, or both. The server path is `ward_admit_patient`, then `ward_confirm_admission`. `ward_undo_admission` can reverse a just-confirmed admission while `admission_undo` still allows it; later clinical rows (including a lab report) block undo. A 2-minute style window is described in the R1.3.128 header. The client keeps an undo token in `localStorage` and retries confirm separately.

**Observation.** Patients can be `status = "observation"` without a ward bed. `ward_start_observation` opens a stay. Outcomes are admit to a bed (`ward_convert_observation`), or refer / dispose via `ward_close_observation`. Closing can go through `ward_close_observation_with_review` when the R1.7 discharge-review gate applies. Observation stays are not the same list as ward discharges.

**Notes and snapshot.** The patient snapshot is current state, risk, sleep, watch points, tags, plan, and PGT notes. Tags and fields patch through `ward_patch_snapshot_tags` and `ward_patch_snapshot_field`. PGT notes append with `ward_append_pgt_note`. Critical status updates are a separate log (`ward_create_critical_status_update`) with a local retention helper at the top of the page. Restraint is `ward_toggle_restrain` and is shown as a held pair of events. Consultant advice is `ward_issue_advice` / `ward_edit_advice` / `ward_ack_advice`; consultants read "My orders".

**Medicines.** Orders are drug, dose, route, frequency, start, stop. Frequency is one regular code (OD, BD, TDS, QID, HS, weekly, monthly) plus optional SOS/PRN and STAT, joined with `+`. A value that is not only those codes is a custom schedule (R1.3.144) and is not expanded into dose slots. STAT is recorded as given at entry. Dose administration queues `medication_doses`. Duplicate identical running orders are blocked in the client (`medDupOf`).

**MSE.** Structured mental-status form, kinds `routine` and `discharge`, saved with `ward_save_mse` into `mse_entries`. High-risk answers feed the patient chips. Residents and admins can delete and restore with a reason (`ward_delete_mse`, `ward_restore_mse`). Discharge review can require an MSE.

**Vitals.** BP, pulse, respiratory rate, SpO₂, temperature °F. `ward_save_vitals` and the client `VIT_RULES` share adult ranges (not NEWS2): systolic &lt;90 or ≥140, diastolic &lt;60 or ≥90, pulse &lt;60 or &gt;100, RR &lt;12 or &gt;20, SpO₂ &lt;95 (≤92 critical), temperature ≥99.5 raised, ≥100.4 fever, &lt;96.8 low. Implausible values outside `VIT_LIM` cannot be saved. Abnormal values need an "I rechecked" confirmation. Interns enter today's vitals on their home board; drafts sit in `localStorage` per intern per patient. A vitals chart page is `vchart`.

**Rating scales.** Client catalogue `SCALE_DEFS` matches the SQL seed: BPRS, YMRS, HAM-D, CIWA-Ar, COWS, Y-BOCS, BFCRS, CGI-S, CGI-I, C-SSRS, CAM. The server recomputes the score in `ward_scale_calc`. Save is `ward_save_scale` or, for interns, `ward_intern_save_scale` (CIWA-Ar and COWS only on the server flag). Delete/restore require a reason. Quick-change alerts on the Today list are CIWA, COWS, C-SSRS, and CAM (`R16_QUICK_SCALES`). CIWA ≥15 is surfaced as an alert. Full history is `ward_read_scale_history`.

**Labs.** Manual structured reports (pathology, biochemistry, other) via `ward_save_lab_report`. Critical limits are server-side (`ward_lab_critical`), including calcium and magnesium after R1.3.141. The results tab and the record page use `ward_read_lab_history`. The OCR pilot can create a report with `entry_method` `ocr` after a name check; hospital numbers are not extracted (R1.3.134 header). Interns save with `ward_intern_save_lab_report` and can complete a linked report task (`ward_link_intern_report_task`).

**ECT.** A plan (`ward_upsert_ect_plan`) has indication, sessions done, next date, NPO, status planned/completed/cancelled. Marking a session done calls `ward_record_ect_session` immediately when online, advances `sessionsDone`, and sets the next date with `nextEctAt`. Offline, the same row is queued as `ect_sessions`. The ECT weekday set is `localStorage` `ward-sync-ect-days` (default Tuesday and Saturday). A separate R1.7 schedule completion (`ward_complete_scheduled_ect` / `ward_undo_scheduled_ect`, table `ect_schedule_completions`) records that a planned occurrence happened. Both paths exist in the client (`markEctDone` and `r17EctMark`).

**Discharge.** Discharge captures mode (advice, request, DAMA, LAMA, abscond, transfer, death), outcome, medicines with instructions, review text, ECT session count, and requester. R1.7 `r17EnterDischarge` warns when MSE or a report is missing and can store `discharge_review_overrides` through `ward_discharge_with_review`. A certificate (`openDischargeCert`, `ward_save_discharge_certificate`) stores the printed render facts used by archive v2 (`app_version`, `cert_fmt`, reprint). Recent discharges can be edited (`ward_edit_discharge`) with versions from `ward_discharge_edit_versions`.

**Handovers.** R1.6 posts a handover to a shift slot (IST date + morning/evening/night), not only to a named person. `ward_upsert_handover` / `ward_upsert_handover_item` write it. Anyone on duty for that slot can take it (`ward_take_handover`, with `ward_ack_handover` as fallback). The first take clears it for the shift. Withdraw is `ward_withdraw_handover`. Item done is `ward_update_handover_item`.

**Intern tasks.** Residents assign `intern_assignments` (`ward_assign_intern_task`), kind `report` or `general`, with a due date. Interns complete or undo (`ward_complete_intern_task`, `ward_undo_intern_task`). The intern home shows today's vitals plus open tasks. `ward_list_r17_status` feeds the resident-side discharge-review and ECT schedule UI.

**Other surfaces.** Shared task board (`ward_upsert_task` / `ward_update_task`). Activity log. Broadcasts to residents, faculty, or everyone (`ward_broadcast_send`), with `#bed` / `@name` suggestions. Admin ward setup edits sections, beds, and unit name. A client-side monthly spreadsheet (`exportMonthly`) downloads admissions, discharges, census, deaths, and transfers for a chosen month from data already on the device. That download is not the Drive archive.

## BDFT

BDFT v7.0 is inlined at the bottom of `index.html` (`BDFT v7.0 NATIVE INTEGRATION`, `BDFT_APP_VERSION = "7.0"`). It is one roster with Ward Sync residents. It does not keep a second user list and it does not call JSONBin. This tree has no `jsonbin` string. Commit `9b2f299` is the purge; the code now syncs settings and distributions only through the RPCs below and three `localStorage` keys.

### Engine

Generation runs in the browser: `bdftCalculateDistribution`.

- Owners come from `configuration.fixedBedMatrix` (bed codes per doctor name).
- Doctors sit in batches `3rd Year`, `2nd Year`, `1st Year` (`YEAR_ORDER`).
- Bed codes canonicalise in `bdftCanonBed` (prefix + integer, so `M-06` and `M6` match). `bdftToWardBedNo` prefers the live ward bed label.
- Occupied beds selected in the UI are the ones to assign. Unavailable doctors lose their beds.
- Those beds stay inside the same batch and go to the available doctor in that batch who currently holds the fewest, skipping a consecutive bed of the same prefix when another tied doctor exists (`createsConsecutiveConflict`). If the whole batch is unavailable, beds land in the orphan pool. They are not given to another batch by the algorithm.
- A person can move a bed onto another doctor or into the orphan pool (`bdftTransferBed`, click or drag). That does not call `ward_bdft_move`.

`ward_bdft_generate` in `r18_bdft.sql` is a different path. It requires an open evening duty (`bdft_on_evening`, last 20 hours), rebuilds rows with `bdft_compute` from included occupied bed ids and an absence list, and refuses a client-supplied finished board. `index.html` does not call it. The design note `docs/superpowers/specs/2026-11-07-ward-sync-r18-bdft-design.md` describes that server path. The client at this commit publishes the board it already built.

### Who can open it

`canAccessBdft()` shows the More tile (bed icon) to admins and residents. Interns and consultants get no tile and no home card.

`bdftTileClick`: an admin, or a resident `isEveningDuty()` (open duty row with shift evening, or current clock shift evening and duty not ended), gets the admin sheet (`bdftAdminPick`) and can open the terminal. Anyone else with access opens setup (`bdftOpenSetup`).

Settings rows: `canEdit` is admin, or `bdftIsSelf`, or evening duty. That flag is declared inside `bdftMountSetup` before the card uses it (the `canEdit` ReferenceError that froze the resident editor is fixed in `36026aa`). The modal checks the same rule again in `bdftSaveResidentModal`. Server `ward_bdft_save_setup` after `r18_1` lets an admin rewrite every resident's batch, short name, order, and the whole `bdft_bed_owners` table, and lets a resident update only their own row and their own beds. The client copy of evening-duty editing other people is wider than that SQL. If the server still has the R1.8 admin-only setup function, the client toasts that `r18_1` needs to be applied and keeps the local save.

`bdftMount` does not rebuild `#bdft-root` while a BDFT overlay is open (`bdftResidentModal`, bed picker, admin sheet, occupied modal, unavailable modal), so a tap is not lost.

### Ownership sync

`ward_bdft_state` returns people (id, name, batch, short, active, order), beds, owners, and `current` distribution rows. `bdftLoadFromSupabase` maps people into the three batches, fills `fixedBedMatrix` from `bdft_bed_owners`, and merges that over the matrix already in memory (`Object.assign` of the previous matrix and the new one). A local key that the server omits is left in place.

`bdftSyncSetupToSupabase` sends active non-intern non-consultant residents and the matrix as `{bedId, residentId}` via `ward_bdft_save_setup`. Bed ids are resolved through the live `S.beds` list. Saving the resident modal writes `localStorage` first, then this RPC.

`BDFT_DEFAULT_CONFIG` is a starter roster and matrix used before the first successful sync. It is sample content in the file. After a successful `ward_bdft_state`, the server people and owners replace the working batches. Do not treat the starter names as the live roster.

New-user create (`openAddUser` for a resident) can attach batch, short name, and beds and then calls the same setup save.

### Generation, finalise, persistence

The terminal (`bdftMountGenerate`) shows date, on-duty count, unavailable count, and assigned count. Actions: adjust occupied beds, mark doctors unavailable, **Generate for Tomorrow**, and a docked **Finalise & Save** once a distribution exists.

`bdftFinaliseAndSave`:

1. Writes a working snapshot and pushes an archive copy (max 7) to local storage.
2. If a session exists, builds rows `{bedId, label, ownerId, holderId, occupied, manual, reason, disabled}` from the tiers and orphans. Owner and holder are matched to Ward Sync residents with `bdftFindResident` (display name, username, or short name). Plan date is `bdftIstTomorrow()` (next IST calendar date).
3. Calls `ward_bdft_save_distribution`. That RPC (`r18_1`) archives the previous `current` row, inserts a new id `bdft-YYYYMMDD-…`, writes `bdft_rows`, and calls `bdft_queue_notice`. Its body allows any admin or resident session. It does not call `bdft_on_evening`. The evening check on the server remains inside the unused `ward_bdft_generate`.
4. If the RPC returns a notification id, the page POSTs `{session_token, notification_id}` to `{project}/functions/v1/dispatch-bdft` with the publishable key as `apikey`.
5. Switches the page to read-only. PNG export is not automatic.

Local keys: `bdft_configuration_v1`, `bdft_working_snapshot_v7`, `bdft_archives_v7`. `bdftInit` restores the working snapshot into `AppState` before a quiet Supabase pull. A pull replaces `AppState.distribution` only when `current.rows` is a non-empty array, then writes that snapshot back. An empty or failed pull leaves the local board. That is how a distribution survives a sync that does not return rows.

### Home card

`bdftHomeCard` is on the Today column for residents and admins. Interns and consultants get nothing. It is a compact card: a date line and a small **Full BDFT** button. `bdftDateLabel` compares the distribution date to today in IST and prints today's beds, tomorrow's beds, or a dated fallback. When the signed-in resident matches a holder, occupied and empty beds render as small bed-number chips in a horizontal grid. A chip opens that patient (`bdftTapBedPatient` → `go('snap', id)`) or toasts that the bed is vacant. A holder with no beds shows a happy-day line. If the distribution cannot be matched to the user, the card shows only the date line and a count.

Read-only mode hides the page title, shows the board, and offers **Export PNG** (`bdftExportPng`), which uses `html2canvas` (loaded from jsDelivr) on `#distribution-card`. The card subtitle is the hardcoded line "Department of Psychiatry, AMCH".

Search inside the bed picker and occupied-bed modal uses `bdftMatchBed` (alias / canonical match) and updates the grid in place (`bdftFilterBedPicker`, `bdftFilterOccupiedBeds`).

Deep links: notification URLs `#/bdft/<id>` set `ui.bdftOpenId` and open the BDFT page (`openNotification`, and `bdftReadHash` on boot).

## Notifications and push

Clinical events go through `notifyServerEvent` → `ward_create_notification_event` → `POST /functions/v1/dispatch-notification`. The client allows only these pairs: admission, discharge, transfer, critical status, observation, restrain → category `clinical`, scope `active_team`; handover → `handovers` / `handover`; task → `tasks` / `task_assignees`; ect → `ect` / `active_team`. Title, body, and target URL (`./#/home`, `./#/snap/…`, `./#/handover`) are checked in the client before the RPC. The edge function source for `dispatch-notification` is not in this repository. `dispatchNotificationId` is the same endpoint for an existing id.

`r18_bdft.sql` widens `notification_events` checks to include event type `bdft` (category `clinical`, scope `bdft_residents`) and also names `broadcast`, `advice`, and `archive` in the constraint. BDFT notices are queued inside the database by `bdft_queue_notice` (dedupe key based on the distribution id). Eligible push targets in `worker.mjs` are roles `resident`, `admin`, and `sr`.

`dispatch-bdft` (`supabase/functions/dispatch-bdft/index.ts`, `verify_jwt = false` in `supabase/config.toml`):

- A cron call presents header `x-ward-bdft-secret`. `ward_bdft_cron_ok` compares it to Vault secret `ward_bdft_cron_secret`. A mismatch is rejected before a claim. The header value is not logged.
- A resident may instead pass `session_token` and one `notification_id`. `ward_bdft_dispatch_scope` checks that session. The claim still uses the service role inside the function.
- Claims come from `ward_bdft_service_claim`. Targets are read from `push_subscriptions` (Web Push) or `fcm_device_tokens` (FCM HTTP v1 via a Google service account, or legacy FCM if only a server key is set). Results go to `ward_bdft_service_apply`.
- Provider env names, not values: `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT`, `FIREBASE_SERVICE_ACCOUNT_JSON` or `FCM_SERVER_KEY`, and `SUPABASE_URL` plus `SUPABASE_SECRET_KEYS`. If push is configured but the database role is missing, the function returns `dispatch: deferred`.
- `ward_bdft_tick` is what pg_cron job `ward-bdft-dispatch` runs every two minutes. It reads the Vault secret inside the database and posts it as the header. See `supabase/functions/dispatch-bdft/SCHEDULE.md`. This repo does not apply that migration.

The service worker `push` handler shows the notification (high priority vibrates longer) and `notificationclick` focuses an open client or opens `data.url` (default `/#/home`).

The device registers with `ward_register_push_subscription` using the VAPID public key embedded in the page (`VAPID_PUBLIC_KEY`). Preferences: `ward_get_notification_preferences` / `ward_set_notification_preferences`, with a local fallback. The in-app inbox is `ward_list_notification_inbox` (BDFT rows are included for residents and admins by the R1.8 replacement of that function) and `ward_mark_notification_read`.

ECT completion (`markEctDone`) sends event type `ect` after `ward_record_ect_session` succeeds, with dedupe key `ect:<plan id>:session:<session id>`.

## Monthly archive and Drive

Two different "monthly" features exist.

1. **On-device report.** `exportMonthly` builds an xlsx/csv from `S` for admins and consultants. It does not call Drive.
2. **Server archive.** `r161_archive_v2.sql` adds service-role functions `ward_archive_state` (one month shaped like `ward_read_ward_state`), `ward_archive_rerun_claim`, and `ward_archive_rerun_reset`. Certificate prints store `printed_app_version`, `printed_fmt`, and `printed_render` so a later archive can recreate the print. `ward_save_discharge_certificate` in that file writes those columns.
3. **Rerun.** `r161_archive_rerun_request.sql` adds `ward_archive_request_rerun`, `ward_archive_rerun_tick`, `ward_archive_post`, and `ward_archive_rerun_requested`. `ward_archive_post` reads Vault secret `ward_archive_cron_secret` and `pg_net`-posts the project's `monthly-archive` function with header `x-ward-archive-secret`. The SQL file contains the function URL. It is not repeated here. The edge function source is not in this repository. A rollback comment mentions a backup `ma_src.ts` that is also absent. Job name for the one-shot rerun is `ward-archive-rerun`.

`privacy.html` is the product description of the Drive side: the "Ward Sync Archive" Google app uses `drive.file` and writes monthly copies into the ward's own Drive.

`ward_create_nightly_backup` is a separate admin/client RPC (`saveWardBackup`). It is not the Drive monthly job.

## Security boundaries

- Browser role is the publishable key. It can execute the granted RPCs. It cannot select the RLS-forced tables that have no policies (`mse_entries`, labs, scales, BDFT tables, intern tables, phones).
- The session token is the authority inside those RPCs. `bdft_actor` rejects missing sessions and roles intern, consultant, and viewer, and maps `sr` to `admin`.
- Service-only helpers (BDFT claim/apply/cron, archive state, phone validator `ward_phone_e164`) are revoked from `anon` and `authenticated`.
- `dispatch-bdft` is `verify_jwt = false` because cron has no user JWT. It still checks the Vault header or a ward session before claiming. It does not use the clinical dispatcher or the archive cron secret (`SCHEDULE.md`).
- Phone numbers are omitted from `ward_read_ward_state` by using a side table. Audit rows store who changed a number, not the number. Activity log is visible to the ward, so phone changes are not written there.
- Intern RPC allow-list is enforced in the client and, by the client comment, by a separate session table on the server. The server function bodies for `ward_intern_sessions` are not in this migrations folder.
- Do not put Vault secret values, service-role keys, VAPID private keys, or FCM credentials in the repo, in logs, or in cron command text. The BDFT cron command is documented as reading the secret inside Postgres and sending it only as a header.
- The page embeds a VAPID public key and a default publishable key. Those are client identifiers. They are still credentials and stay out of docs and screenshots.
- `seed()` contains a demo ward. It is local fallback data, not a production roster.

## Deployment and caching

Vercel serves the repo root as a static site (`vercel.json` version 2). `index.html` and `sw.js` are `Cache-Control: no-cache`. `sw.js` has `Service-Worker-Allowed: /`. OCR `manifest.json` is `no-cache`. OCR `.js` and `.bin` files are `public, max-age=86400` with `nosniff`. Other paths with a file extension are not rewritten. Everything else rewrites to `index.html`.

The service worker precaches `./`, `index.html`, `manifest.json`, and the main icons. Install uses `skipWaiting`; activate deletes caches other than `ward-sync-pwa-r1.8` and `ocr-assets-v7`, then `clients.claim()`. App-shell GETs are network-first (4 s timeout for navigations, 12 s otherwise) and fall back to the cached `index.html`. Same-origin non-shell GETs are also network-first. Cross-origin GETs that are not Supabase and not `/ocr/` are stale-while-revalidate. `/ocr/` is ignored so the page can fill `ocr-assets-v7` itself. Supabase is ignored so API and realtime stay live.

`index.html` registers `./sw.js` on load when the protocol is not `file:`.

GitHub `main` is the branch this commit is on. Nothing in the repo auto-deploys from a workflow besides the unused assemble-index path. Hosting is whatever Vercel project is connected to the GitHub repo. This document does not change or trigger a deploy.

Version strings to bump together when shipping a client change: `APP_VERSION` (`R1.8`), `sw.js` `VERSION` (`ward-sync-pwa-r1.8`), and, if the manifest should match, `manifest.json` `version` (still `1.3.20`). OCR cache name changes only when OCR bytes change.

## Related documents

- `README.md` — one-line description.
- `RELEASE-NOTES-R1.3.130.md` through `RELEASE-NOTES-R1.3.136.md`, `RELEASE-NOTES-R1.7.md`, `RELEASE-NOTES-R1.8.md` — historical release notes. They stop at R1.8 and do not describe the later BDFT client integration or the ECT completion RPC path in `381a4c4`.
- `docs/superpowers/specs/2026-11-07-ward-sync-r17-design.md` and `docs/superpowers/plans/2026-11-07-ward-sync-r17.md` — R1.7 design. The SQL file matches that work; the client has since grown around it.
- `docs/superpowers/specs/2026-11-07-ward-sync-r18-bdft-design.md` and `docs/superpowers/plans/2026-11-07-ward-sync-r18-bdft.md` — original server-computed BDFT. Read them as the R1.8 design, then read the BDFT section above for what the client does now.
- `supabase/functions/dispatch-bdft/SCHEDULE.md` — cron and Vault header.
- `CHANGELOG.md` — notes from 2026-11-10 onward. Older history stays in the release-note files.

## Gaps worth knowing

- `monthly-archive` and `dispatch-notification` are invoked and have no source in this repo.
- Many SQL headers still say the migration was not applied. The client assumes the RPCs exist and shows a local-only or pending-sync path when they do not. This tree cannot tell you which of those files have been run on the project.
- The live BDFT publisher is the browser engine plus `ward_bdft_save_distribution`. The evening-duty and "server rebuilds the board" checks live on `ward_bdft_generate`, which the page does not call.
- `ward_bdft_save_distribution` allows every resident session, while the terminal button is shown to admins and evening-duty residents.
- Realtime does not include BDFT, MSE, labs, scales, vitals, or intern task tables. Those refresh on the next pull or on an explicit reload.
- `manifest.json` version and the HTML release comment at the top of `index.html` lag `APP_VERSION`.
