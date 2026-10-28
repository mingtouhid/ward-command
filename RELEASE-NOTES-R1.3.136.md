# R1.3.136 — lab report sync fix (was R1.3.135) + resident phone numbers with a consultant "Call" chip

Built and tested 28 Oct 2026 (IST). Synthetic data only.
Migrations applied 28 Oct 2026: `20261028054551 r1_3_135_lab_sync_window` at 11:15:51 IST, then `20261028054557 r1_3_136_resident_phone` at 11:15:57 IST (BEGIN/COMMIT stripped).
This release combines the unreleased R1.3.135 lab-sync work with the new phone-number feature. It supersedes RELEASE-NOTES-R1.3.135.md.

## Deploy order
1. Apply `migrations/R1.3.135-lab-sync-window.sql`.
2. Apply `migrations/R1.3.136-resident-phone.sql`.
3. Push `index.html` and `sw.js`. The service worker version is `ward-sync-pwa-r1.3.136-lab-sync-phone`.

Rollback runs in reverse: `R1.3.136-resident-phone.rollback.sql`, then `R1.3.135-lab-sync-window.rollback.sql`.
The client is safe if the phone migration is missing. Phone calls fail quietly, no chips show, and saving a number shows "phone not saved".

## Part 1 — Lab report sync (from R1.3.135)
### What was wrong
A report dated before the current admission (for example, a CBC dated three weeks before the admission date) was saved to the server, but then disappeared from phones:
1. `ward_read_ward_state` only sends a lab report if it is less than 14 days old, or dated on or after the admission date minus 2 days. An older-dated report never came back on sync.
2. The client sync (`labMergeState`) removed any local report that was missing from that windowed list.
3. Opening Investigations calls `ward_read_lab_history`. That function returns `{ok, patient_id, lab_reports:[…]}`, but `labLoadHistory` only accepted a plain array. So the full-history fallback silently did nothing.

The result was that people re-entered the report, and duplicates appeared. These were the KFT and CBC duplicates cleaned up today.

### Changes
#### Client (index.html)
- **History shape:** `labLoadHistory` now accepts both `{ok,lab_reports}` and a plain array. It ignores a reply that belongs to a different patient. I audited every other RPC caller and they all read the right shape (details in the report). Only labs are windowed in ward state.
- **Sync keeps local reports:** `labMergeState` only drops a report in these cases:
  - a server tombstone exists for it, or
  - the patient is discharged or unknown and the report is older than 14 days, or
  - a full `ward_read_lab_history` reply for that patient no longer contains it. Reports saved within the last 2 minutes, unsent reports, and local-only reports are always kept.
- **Pre-admission date:** if the report date is before the admission date, an amber box appears: "Report dated <date> is before this admission (<admission date>) — check the date". Saving is blocked until "Date is correct" is tapped. Editing an existing report without changing its date skips this check.
- **Scanner date:** a date filled in by the scanner is shown in amber with "Read from the scan — check it against the paper" and a "Matches paper" button. Saving is blocked until it is tapped or the date is edited.
- **OCR date source:** the scanner now only takes a date that follows a labelled Reporting/Reported/Completion field or a Collection/Collected field, preferring the report date. If neither is found, the date is left blank. It no longer takes the first date anywhere on the page. `ocr/ward-ocr.js` is unchanged, so there is no new OCR asset download.
- **Duplicate guard:** for a new report, or an edit that changes the date, the full patient history is fetched first if it hasn't been loaded in the last 60 s and the phone is online (4 s timeout). The "Already added?" box therefore also matches reports that are not on the phone.
- **Check order:** a wrong-patient name block always shows first, then the date checks, then the per-value checks.

#### Database (migration 1 of 2)
`migrations/R1.3.135-lab-sync-window.sql` changes one function, `ward_read_ward_state(uuid)`. Only the lab filter changes. It adds two cases to the window:
- tombstones from the last 14 days, so deletions of old-dated reports reach every phone
- reports for non-discharged patients that were created or updated in the last 14 days, whatever their report date

Safety:
- It runs as one transaction.
- Before changing anything it checks the md5 of 4 live functions (drift check):

  | Function | md5 |
  |---|---|
  | `ward_read_ward_state` | 3b2711f80e3d916c70582dd168749113 |
  | `ward_read_lab_history` | 5065333c49fb20e78aafe68e88cfab1e |
  | `ward_lab_report_json` | 6ef197bc17239dca93957f0171ee0d2b |
  | `ward_save_lab_report` | c513d0196c078a864ec50bbad32c8d9c |

- It post-checks the new md5 f7737a140e4984ff524f45084414696a.
- Rollback is `migrations/R1.3.135-lab-sync-window.rollback.sql`. It restores 3b27… and checks it.

### OCR note — repeated scans of one CBC
Three scans of the same CBC were reviewed (values kept out of this file).
- Index misreads (MCH) were amber in both of the wrong copies.
- One wrong copy had a ±0.1 Hb misread that showed **green**, so a small misread can pass as high confidence.
- Both wrong copies were saved with amber values that had been acked.
- Only ack counts are recorded (`ocr_stats.acked`), not which row was acked.

**Suggested tightening (not in this build):**
1. Show the cropped digit next to each typed value, and require a second tap for any amber value that changes a flag.
2. Record per-row acks (`field_state='acked'` plus the OCR value and confidence on each result) so audits can see what was confirmed.
3. When a scan matches a saved report for the same patient, date and panel but values differ, show "Differs from the report already saved" instead of saving a second copy.
4. Consider a higher green threshold for 1-decimal indices (MCH, MCV, MCHC).

## Part 2 — Resident phone numbers

### What it does
- **Add resident:** Admin → Add user has an optional "Mobile number (+91)" field. It only appears for the Resident role.
- **Edit resident:** the admin's edit sheet has the same field, for residents only.
  - When a number is already saved, the field shows "Saved · leave blank to keep". The admin never sees the digits.
  - A "Remove saved number" button asks for confirmation and then clears the number.
- **My phone:** under More → System, any resident can view, change or remove their own number.
- **Call chip:** consultants see a green **Call** chip next to each resident in the signed-in on-duty list, including "Not specified".
  - Tapping the chip opens the phone dialler with `tel:+91…`.
  - The number is never printed on screen.
  - Residents and admins never see chips.
- **Validation:** the number must be a 10-digit Indian mobile number (starting 6–9). The app accepts 0, +91 or 91 prefixes, spaces and dashes, and stores the number as E.164 (+91XXXXXXXXXX).
  - Invalid input shows an inline red error, "Enter a 10-digit Indian mobile number", and nothing is sent.
  - Server error text is never shown raw.

### Privacy design
- Numbers live in a new table, `resident_phones`, never in `residents`. `ward_session_user` returns the whole residents row, so storing them there would leak.
- The table has RLS forced, no policies, and all grants revoked from anon and authenticated. It is not in the realtime publication.
- All access goes through 4 SECURITY DEFINER functions that check the session token:
  - `ward_set_resident_phone(token, username, phone)`: you can set your own number. An admin can set any **resident's** number, but not a consultant's.
  - `ward_get_my_phone(token)`: returns your own number only.
  - `ward_phone_status(token)`: admin only. It returns which residents have a number saved, not the numbers.
  - `ward_list_duty_phones(session_token)`: consultants only. It returns numbers only for residents with an open on-duty sign-in less than 20 h old.
- Numbers are never in `ward_read_ward_state`, the roster, `activity_log`, the timeline, localStorage or the offline cache. The app keeps them in memory only and clears them on logout or user switch.
- `resident_phone_audit` records who changed or removed whose number and when. It does not record the number.

### Known limits
- Long-pressing a Call chip on some phones previews the `tel:` link, which shows the number. A consultant can see it that way.
- Numbers are fetched on each sync. A consultant who is offline keeps the last fetched list in memory until the app is closed.

#### Database (migration 2 of 2)
`migrations/R1.3.136-resident-phone.sql`:
- Runs as one transaction.
- It does not change any existing function. It checks the md5 of 8 live functions whose no-leak behaviour it relies on:
  - `ward_session_user`
  - `ward_login`
  - `ward_list_faculty`
  - `ward_read_ward_state` (accepts the R1.3.134 md5 3b2711f8… or the R1.3.135 md5 f7737a14…)
  - `ward_invite_user`
  - `ward_update_user`
  - `ward_sign_duty`
  - `ward_end_duty`

  It also checks the shape of the residents and ward_duty tables.
- Refuses to run if any phone object already exists.
- Post-checks that there are no client grants, no policies and no publication membership.

Rollback is `migrations/R1.3.136-resident-phone.rollback.sql`. It drops the 2 tables and 5 functions, **including all saved numbers**.
