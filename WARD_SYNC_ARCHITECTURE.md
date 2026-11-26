# Ward Sync architecture

This note describes the Ward Sync source and PWA assets as of 19 November 2026, including the application update in commit `566a8d514c1ea3d0d0798b4db7535280f52a858f` and the subsequent root icon-alias refresh in commit `f5c5e816a69d5da993a0694f33dca1d307c72ba4`. It follows the checked-in client, SQL files and included Edge Function source. It distinguishes repository state from production database/deployment state: a file or RPC call in the client does not prove that a migration has been applied.

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

`privacy.html` (updated 19 November 2026) describes the clinical, staff-account, roster and ward-configuration data handled by the app, including the separation between clinical and Office Administration workspaces.

## Frontend structure

Almost all application code is in `index.html` (about 1.93 MB in the 19 November 2026 repository snapshot). It is one static HTML document containing markup, styles and client-side JavaScript. There is no frontend bundler or package-manager build step; `vercel.json` serves the repository root directly.

The HTML client reports `APP_VERSION = "R2.0.7"`. The inlined BDFT engine reports `BDFT_APP_VERSION = "7.0"`. Feature comments inside the file include later markers such as R2.0.10, R2.0.11, R2.0.14 and R2.0.15; these comments do not change the value printed by `APP_VERSION`.

The application has separate role surfaces:
- The standard clinical shell is used by residents, admins and consultants with role-specific capabilities.
- Interns use a reduced intern shell and a restricted RPC allow-list.
- `office_admin` uses the isolated Office Administration workspace, not the clinical patient shell.

Other frontend/runtime files:
- `sw.js` — service worker cache `ward-sync-pwa-r2.0.0-3`; separate OCR cache `ocr-assets-v7`; install/activate, precache, offline/network strategy, push display and notification routing.
- `manifest.json` — standalone Ward Sync PWA metadata. Icon declarations use the canonical `icons/` folder and distinct regular/maskable 192px and 512px assets. Custom metadata values `1.3.20` and `R1.3.20 icons` remain legacy values, not the HTML app label.
- `icons/` — current install, favicon, Apple touch, notification and badge assets. Root-level icon PNGs remain as legacy paths and are still precached for compatibility.
- `ocr/` — Tesseract assets and `ocr/ward-ocr.js`. The scanner pilot is controlled by local storage key `ws_ocr_pilot` and requires WebAssembly and Cache API support.
- `.github/workflows/assemble-index.yml` — legacy/manual assembler for `_b64/part*.b64`. There is no `_b64/` directory in the current tree; manual index uploads are not performed by this workflow.

Rendering remains a full HTML render into `#app`; hash routes are handled in the client. Application state is persisted in local storage and synchronised with Supabase through RPCs and the ward session token. Seeded demo data is fallback/demo content, not the production roster.

## Navigation and routes

Residents, admins and consultants use the standard clinical shell: Home, Patients, Handovers and More. Exact pages and actions depend on role.

The principal route groups are:
- **Home:** ward overview, duty status, clinical flags and BDFT status.
- **Patients:** patient list, snapshot, medication chart, notes, MSE, results, scales, vitals and discharge workflows.
- **Handovers:** shift handovers.
- **More:** census/admission-discharge register, observation, ECT, tasks, activity, broadcast, consultant advice, BDFT, profile, ward setup, user management, settings, connection and about.

Interns do not use the standard shell. Their reduced shell exposes Home, Vitals (`ivitals`) and Reports (`ireports`), with its own page map and RPC allow-list.

Office Admin does not enter the clinical shell. After an `office_admin` login, the isolated workspace has four primary areas: roster management, saved PGT groups, user management and ward setup. It has a horizontal desktop/landscape layout with its own sidebar and scrollable content area.

Published duty rosters are also available in a separate read-only staff roster library. The client calls `ward_list_published_rosters`; PGT monthly and Faculty weekly schedules are listed separately and opened in read-only detail views.

## Auth and roles

Clinical sign-in is `cloudLogin()` → `ward_login(p_username, p_password)`. The returned session token is held as `sessionTok` and stored as `wc_tok` in session and local storage. Session validation uses `ward_session_user`. The ward session token is the authority inside the RPCs; it is not a Supabase Auth user JWT.

`normRole()` recognises:
- `admin` and legacy `SR` → `admin`
- `consultant` / `Consultant` → `consultant`
- `intern` / `Intern` → `intern`
- `office_admin` / `officeAdmin` → `office_admin`
- Other ordinary resident roles → `resident`

The session login role is authoritative for intern and Office Admin routing. `canWrite()` excludes consultants, interns and Office Admin; the normal clinical write surface is for residents and admins. Office Admin is not a clinical user role and cannot use the normal patient workflow through its isolated workspace. The Office Admin ward-setup UI explicitly states that patient identity and occupancy are not available there. Client checks are not a substitute for server-side RPC/RLS enforcement.

Interns retain their reduced shell even when the read-state response omits a full resident profile. Their client RPC allow-list is `INTERN_RPCS`: `ward_login`, `ward_intern_read_state`, `ward_intern_save_lab_report`, `ward_save_vitals`, `ward_intern_save_scale`, `ward_complete_intern_task`, `ward_undo_intern_task`, and `ward_link_intern_report_task`. The client comment describes a corresponding server-side intern-session boundary. Interns do not subscribe to realtime.

Other capability checks include `canAdmin()` for clinical admin-only controls, `canBroadcast()` for signed-in broadcast access, `canAccessBdft()` for BDFT, and `canDeleteRecords()` for eligible clinical roles. Duty sign-in remains separate from account login. Shifts use IST: morning 08:00–14:00, evening 14:00–22:00, night 22:00–08:00.

The clinical user-management surface supports residents, consultants, interns and Office Admin accounts. The Office Admin user form offers resident, consultant, intern and office_admin roles; it does not offer creation of a top-level admin account.

Phone numbers, profile photos and self-profile data use their dedicated RPCs and tables/keys as described in the data-model section. Do not add personal phone numbers or photos to broad ward-state payloads or logs.

## Office Administration and published rosters

The Office Admin frontend is embedded in `index.html`, but it is a separate workspace. An `office_admin` session sets the role explicitly and enters the `OA` controller rather than the ordinary patient-care page map. The client excludes this role from `canWrite()`, the clinical resident directory and BDFT people lists. The workspace is a desktop workbench with its own sidebar and independently scrollable main area. From `R2.0.12` the office theme is plain blue and white and the shell no longer forces a 1160px minimum width, so a 1024px landscape window does not spill past the viewport. Production `office_admin_*` RPCs already require `private.require_office_admin`. They can create and edit ward setup, users, PGT groups and rosters. They refuse the `admin` role and refuse edits to an existing admin account. `office_admin_delete_user(p_token uuid, p_username text)` calls `private.delete_resident_account`. It refuses admin accounts, active accounts, and the signed-in office admin. It also refuses any account that still has clinical, duty, BDFT, or roster references. A successful delete archives the account row, without the password hash, in `private.deleted_accounts_archive` and then removes it from `public.residents`. That archive table has row level security enabled and no privileges for public, anon, or authenticated. `office_admin_invite_user` and `office_admin_update_user` accept a resident year through `p_year`. `migrations/r20_14_office_admin_resident_year.sql` was applied to production on 2026-11-21 at about 20:05 IST. It writes the existing `residents.bdft_batch` column. A resident year must be `1st Year`, `2nd Year`, or `3rd Year`, matching the BDFT settings batch labels. Faculty roster phone numbers are fields inside the roster content JSON, not a separate table. Clinical RPCs read `ward_sessions` (or the clinical actor lookup), not `office_admin_sessions`, so an office-admin token is not a clinical session. Intern wide screens do not use the resident tablet rail; the intern shell is a centred column, and a desktop-only connection line is added. The phone intern layout is unchanged.

### Roster management

Two roster types are exposed:
- `pgt_monthly` — monthly PGT duty roster, including the night-duty column (10 PM to 8 AM) in the default template.
- `faculty_weekly` — weekly Faculty / VP / Resident Physician-GDMO roster.

The roster builder stores editable structured content: dates, columns, rows, group assignments and notes. It can generate dates from the selected period, add/remove rows and columns, show an on-page preview and export an editable Word `.docx`. PGT rosters can select a saved group set; group membership and short abbreviations are copied into that month's roster. Group editing includes resident-name suggestions and reusable saved sets.

The client lifecycle is draft → review/ready for publication → published. Office Admin has explicit save-draft, mark-ready and finalise-publish actions. A published roster can be restored as a new draft. Published rosters are shown to staff through `ward_list_published_rosters` and the read-only resident roster library; roster cards distinguish active, scheduled and archived periods.

#### Canonical PGT resident identity

PGT membership is stored in the private relational tables `office_admin_pgt_groups` and `office_admin_pgt_group_members`. Each member row references `public.residents.id` with a foreign key; a resident can occur only once in a saved group set. The JSON `office_admin_pgt_group_sets.groups` field is retained as an ID-only compatibility mirror, while `office_admin_list_pgt_group_sets` resolves the current display name, BDFT short code, username and batch from the resident profile. The picker accepts active resident/admin accounts with a configured BDFT short code; it does not accept free-text identity or abbreviation overrides.

`office_admin_save_roster_draft` and `office_admin_publish_roster` validate resident IDs and snapshot each PGT member's `residentId`, `display_name` and `bdft_short` into the roster's `content.groups`. This is intentionally separate from the live group configuration: profile changes update future drafts/publications, while previously published roster labels remain historical snapshots. Existing recent/current published snapshots are linked by resident ID without rewriting their visible names or codes.

The resident-facing **My Duties** view matches the signed-in session's `residents.id` to the published roster member's `residentId`. It then uses that roster snapshot's code, name and group label to interpret duty cells. Text/name matching remains only for older rosters without an ID link. Duplicate short codes in an old roster are excluded from code-only matching and shown as an attribution warning. Active resident/admin BDFT short codes are protected by a case-insensitive unique index; BDFT save reports a specific validation error if a collision is attempted.

### User management and ward setup

The Office Admin user page groups accounts by role and supports create/edit/deactivate flows for roles exposed by its form. Ward setup manages unit settings, sections, beds and consultant directory entries. The interface presents this as configuration work and does not expose patient identity or bed occupancy.

### Client loading and backend contract

The OA client uses short-lived in-memory caches: roster list about 20 seconds; saved groups and user list about 60 seconds; ward setup about 30 seconds. Mutating RPCs invalidate those caches. The frontend references an `office_admin_*` RPC family for session, roster lifecycle, groups, accounts, phone and ward-configuration operations. The published read-only library calls `ward_list_published_rosters`.

The checked-in `migrations/r20_canonical_pgt_resident_identity.sql` versions the PGT group identity tables and the relevant Office Admin list/save/publish RPCs. Other Office Admin RPCs still have live database definitions not fully represented in this repository. The migration is applied separately to Supabase; file presence alone does not prove production apply status.

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
| `r20_20_transfer_discharge_referrals.sql` | Episode-keyed `ward_discharge_referrals`, atomic `ward_discharge_with_transfer`, and session-protected `ward_list_discharge_referrals`. Prepared migration; apply status must be verified separately. |

RLS on the new clinical and BDFT tables in these files is enabled and forced, with no policies, and `anon` / `authenticated` have table privileges revoked. Access is `SECURITY DEFINER` RPCs. Grants to `anon` and `authenticated` are `EXECUTE` on the session-token RPCs the browser calls. Helpers such as `bdft_compute`, `bdft_actor`, `ward_bdft_service_claim`, and `ward_archive_state` are revoked from `anon` and `authenticated`.

`bdft_distributions` has a partial unique index `bdft_one_current` so only one row has `status = 'current'`. Status is `current` or `archived`. Census on that table is `live` or `empty`.

### Session RPCs the client calls

Grouped by area. Signatures are in the SQL files or, for older RPCs, only implied by the client arguments.

Auth, users, duty, phones: `ward_login`, `ward_invite_user`, `ward_update_user`, `ward_set_user_designation`, `ward_set_role`, `ward_deactivate_user`, `ward_sign_duty`, `ward_set_duty_area`, `ward_end_duty`, `ward_set_resident_phone`, `ward_get_my_phone`, `ward_phone_status`, `ward_list_duty_phones`.

Read models: `ward_read_ward_state`, `ward_intern_read_state`, `ward_list_r17_status`, `ward_list_faculty`, `ward_list_patient_consultants`, `ward_list_ect_plan_meta`.

Census and movement: `ward_admit_patient` (named by the assemble workflow and the undo migration), `ward_confirm_admission`, `ward_undo_admission`, `ward_start_observation`, `ward_convert_observation`, `ward_close_observation`, `ward_close_observation_with_review`, `ward_discharge_patient` (SQL), `ward_discharge_with_review`, `ward_discharge_with_transfer`, `ward_list_discharge_referrals`, `ward_edit_patient`, `ward_edit_discharge`, `ward_discharge_edit_versions`.

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

**Discharge.** Discharge captures mode (advice, request, DAMA, LAMA, abscond, transfer, death), outcome, medicines with instructions, review text, ECT session count, and requester. R1.7 `r17EnterDischarge` warns when MSE or a report is missing and can store `discharge_review_overrides` through `ward_discharge_with_review`. Transfer additionally requires a receiving department and clinical reason. Its episode-keyed details are stored in `ward_discharge_referrals`; `ward_discharge_with_transfer` calls the existing R1.7 discharge/MSE wrapper and inserts the referral plus activity event in the same transaction. A missing Transfer RPC is a hard failure and never falls back to the legacy outbox discharge path. `ward_list_discharge_referrals` returns episode details through a session-validated RPC. Transfer remains certificate-ineligible alongside LAMA. A certificate (`openDischargeCert`, `ward_save_discharge_certificate`) stores the printed render facts used by archive v2 (`app_version`, `cert_fmt`, reprint). Recent discharges can be edited (`ward_edit_discharge`) with versions from `ward_discharge_edit_versions`.

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

`bdftHomeCard` is shown to eligible residents and admins; interns and consultants get nothing. The Home summary checks the active ward-wide distribution for today or tomorrow, rather than relying only on the signed-in resident's personal assignment. The Make BDFT prompt is suppressed when such a distribution already exists. Bed numbers are shown as tappable chips rather than repeated in a summary sentence. A resident with no personally assigned beds can still open the complete read-only distribution.

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

The service worker `push` handler shows the notification (high priority vibrates longer). `notificationclick` focuses an open window and posts `{type:"ward-notif"}`, or opens the absolute `data.url` when no window exists. The page keeps one pending destination in `sessionStorage` (`ws_notif_nav`) and applies it with `go()` after the session and ward list are ready. The destination comes from the stored URL and ids, not from the title. BDFT notification payloads are normalised to the BDFT page with no distribution edit id; the page clears any previous edit id and explicitly selects read-only mode before navigating. A legacy payload with no route opens the notification list.

The device registers with `ward_register_push_subscription` using the VAPID public key embedded in the page (`VAPID_PUBLIC_KEY`). Preferences: `ward_get_notification_preferences` / `ward_set_notification_preferences`, with a local fallback. The in-app inbox is `ward_list_notification_inbox` (BDFT rows are included for residents and admins by the R1.8 replacement of that function) and `ward_mark_notification_read`.

ECT completion (`markEctDone`) sends event type `ect` after `ward_record_ect_session` succeeds, with dedupe key `ect:<plan id>:session:<session id>`.

## Monthly archive and Drive

Two different "monthly" features exist.

1. **On-device report.** `exportMonthly` builds an xlsx/csv from `S` for admins and consultants. It does not call Drive.
2. **Server archive.** `r161_archive_v2.sql` adds service-role functions `ward_archive_state` (one month shaped like `ward_read_ward_state`), `ward_archive_rerun_claim`, and `ward_archive_rerun_reset`. Certificate prints store `printed_app_version`, `printed_fmt`, and `printed_render` so a later archive can recreate the print. `ward_save_discharge_certificate` in that file writes those columns.
3. **Rerun.** `r161_archive_rerun_request.sql` adds `ward_archive_request_rerun`, `ward_archive_rerun_tick`, `ward_archive_post`, and `ward_archive_rerun_requested`. `ward_archive_post` reads Vault secret `ward_archive_cron_secret` and `pg_net`-posts the project's `monthly-archive` function with header `x-ward-archive-secret`. The SQL file contains the function URL. It is not repeated here. The edge function source is not in this repository. A rollback comment mentions a backup `ma_src.ts` that is also absent. Job name for the one-shot rerun is `ward-archive-rerun`.

`privacy.html` is the product description of the Drive side: the "Ward Sync Archive" Google app uses `drive.file` and writes monthly copies into the ward's own Drive.

`ward_create_nightly_backup` is a separate admin/client RPC (`saveWardBackup`). It is not the Drive monthly job.

## Design tokens (R2.0.0)

Colour, type, and density stay on the existing `html` attributes. The boot script reads `ward-command-theme` and `ward-command-accent-v1`. The stored accent defaults to `blue`. `html[data-accent]` overrides `--teal` and the active-nav colour. Purple on dark and night is `#8A43D5`. Blue, rose, amber, and green keep their own values. Nothing in the layout hardcodes purple for every theme.

The Day / Night control stores `light` or `ot`. `data-theme="ot"` is that Night preference. `data-theme="dark"` and `data-theme="night"` share the same dashboard palette: background `#000000`, filled tiles `#242424`, borders `#242424`–`#303030`, text `#F5F5F5`, secondary `#A6A6A6`, muted `#777777`. Status colours are success `#00B85A`, warning `#E8752A`, the duty Sign in button `#2587D5`, and critical `#D83B3B`. `data-theme="light"` keeps the light slate palette. `data-theme="ot"` keeps the green night-duty palette. `data-density` still tightens cards. The font stack is Inter, then the system UI fonts.

Home for residents and admins (`canWrite()` and not a consultant or intern) is `.r2-home`. The sync control is `#home-sync` under the greeting. `paintHomeSync` still writes the class and the label in place. Consultants keep the older header. Interns stay on `internShell`. Tablet landscape (`min-width: 1024px` and landscape) shows `.side-nav` with Home, Patients, Handovers, ECT, BDFT, Tasks, Activity, and More. Those are existing `go()` destinations. Activity is the existing activity log. Phone and tablet portrait keep the four-icon bottom nav (Home, Patients, Handovers, More) with the same `aria-label`s and active route.

Assigned beds and Make BDFT sit inside the Bed Distribution card. Opinion stays a clinical-flag chip. Needs you, including side-effect rows, sits after Clinical flags and still waits for duty sign-in. The Discharged tile still opens recent discharges. The on-duty photo grid is the On-duty team section. Sign in and End shift live on the Duty status card.

## Keep-alive and storage

`migrations/r19_2_keepalive_storage.sql` is not applied. `ward_ping` returns `{ok:true, at:now()}` and reads no tables. `anon` and `authenticated` may execute it. `.github/workflows/keepalive.yml` POSTs that RPC every two days with the same publishable key the page already ships. The job fails unless the response is HTTP 2xx and `ok` is true.

`ward_storage_check` is service-role only. pg_cron job `ward-storage-check` runs it at 23:00 UTC on the 1st (`0 23 1 * *`), which is 04:30 IST on the 2nd. It records `pg_database_size` in `ward_storage_stats` (RLS forced, no policies). Above 350 MB the level is `warn`. Above 450 MB it is `urgent`. A warn or urgent result inserts one `notification_events` row for that level in the current IST month: event type `archive`, category `archive`, recipient scope `admins`, `dispatch_due` true, priority `high` only when urgent, target `./#/home`. That is the same archive-admin shape the existing check already allows, so `dispatch-notification` can send it. An ok reading inserts no notification. A second call for the same level in that month does not insert another row. `p_simulate_bytes` is for a rolled-back test and is rejected unless the caller is `postgres`, `supabase_admin`, or `service_role`. `migrations/r19_3_weekly_cleanup.sql` is applied: `ward-weekly-cleanup` runs `ward_weekly_cleanup` at 22:00 UTC Saturday (`0 22 * * 6`), Sunday 03:30 IST, deleting cron run logs older than 7 days and notification events older than 30 days whose hold has ended.

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

Vercel serves the repository root as a static site (`vercel.json` version 2). No build command or output bundling is configured. `index.html` and `sw.js` are `Cache-Control: no-cache`; `sw.js` has `Service-Worker-Allowed: /`. OCR `manifest.json` is `no-cache`; OCR `.js` and `.bin` files have a one-day public cache and `nosniff`. Other extension-less paths rewrite to `index.html`.

The service worker uses:
- App cache: `ward-sync-pwa-r2.0.0-3`
- Separate OCR cache: `ocr-assets-v7` (kept during app-cache activation)

The precache contains the app shell, manifest, legacy root icon paths, current `icons/` PWA assets, notification glyph and badge. Install calls `skipWaiting`; activate deletes older app caches while preserving the current app cache and OCR cache, then calls `clients.claim()`. Same-origin app-shell requests use network-first with a 4-second navigation timeout and a 12-second resource timeout, falling back to cached `index.html`. Same-origin non-shell GETs are network-first. Cross-origin GETs are stale-while-revalidate, except Supabase and `/ocr/`, which are not intercepted for caching.

The manifest points to `icons/icon-192.png` and `icons/icon-512.png` for regular installation icons, with separate `icons/icon-192-maskable.png` and `icons/icon-512-maskable.png` entries for maskable display. The HTML head links to the `icons/` favicons and Apple touch icons. The four root-level paths still precached by `sw.js` (`icon-192.png`, `icon-512.png`, `apple-touch-icon.png`, `favicon-32.png`) are refreshed compatibility aliases of the canonical assets under `icons/`. Current HTML and manifest declarations use `icons/`.

Version values in the current source snapshot are not aligned and must be read separately:
- `APP_VERSION`: `R2.0.7` (HTML client label).
- `BDFT_APP_VERSION`: `7.0` (BDFT engine).
- `sw.js` `VERSION`: `ward-sync-pwa-r2.0.0-3` (cache invalidation key).
- `manifest.json` custom `version` / `build`: `1.3.20` / `R1.3.20 icons` (legacy metadata).

Do not infer that a cache suffix or CSS comment is an app release number. When shipping, intentionally choose and record the client label and service-worker cache version. OCR cache changes only when OCR asset bytes change.

## Related documents

- `README.md` — project entry point and deployment overview.
- `structure.md` — repository/file map and maintainer checklist.
- `CHANGELOG.md` — dated changes from 2026-11-10 onward.
- `privacy.html` — staff-facing privacy notice.
- `RELEASE-NOTES-R1.3.130.md` through `RELEASE-NOTES-R1.3.136.md`, `RELEASE-NOTES-R1.7.md`, `RELEASE-NOTES-R1.8.md` — historical release notes.
- `docs/superpowers/specs/2026-11-07-ward-sync-r17-design.md` and `docs/superpowers/plans/2026-11-07-ward-sync-r17.md` — R1.7 design and implementation plan.
- `docs/superpowers/specs/2026-11-07-ward-sync-r18-bdft-design.md` and `docs/superpowers/plans/2026-11-07-ward-sync-r18-bdft.md` — original R1.8 BDFT design and plan.
- `supabase/functions/dispatch-bdft/SCHEDULE.md` — BDFT cron and Vault header.
- `.github/workflows/keepalive.yml` — scheduled keep-alive call.

## Gaps worth knowing

- The frontend calls the `office_admin_*` RPC family and `ward_list_published_rosters`. The PGT identity and related group/roster RPC subset is now versioned in `migrations/r20_canonical_pgt_resident_identity.sql`; the rest of the Office Admin RPC family is not fully represented in this repository. Verify migration application against the target database; do not infer production state from the frontend.
- `monthly-archive` and `dispatch-notification` are invoked by the client and have no source in this repository.
- The checked-in migration files do not provide a reliable production apply ledger. Some migration headers describe old not-applied states. Verify the target database before applying or reapplying a migration.
- The live BDFT publisher remains the browser engine plus `ward_bdft_save_distribution`. The server-side `ward_bdft_generate` path is separate and is not the client generation path.
- `ward_bdft_save_distribution` server-side role enforcement must be checked independently of client button visibility. Client-side access checks are not a security boundary.
- Realtime does not include every clinical subsystem; BDFT, MSE, labs, scales, vitals and intern task data may refresh on the next pull or explicit reload rather than immediately through a table subscription.
- Version identifiers are currently out of alignment: HTML `APP_VERSION` is `R2.0.7`, the service-worker cache is `ward-sync-pwa-r2.0.0-3`, and custom manifest metadata remains `1.3.20` / `R1.3.20 icons`. The top-of-file HTML release comment is historical. Coordinate a deliberate version clean-up rather than changing these values implicitly.
- `.github/workflows/assemble-index.yml` expects `_b64/part*.b64`, but that directory is not in the current tree. The committed `index.html` is the current frontend source; the assembler is not the current index production path.

