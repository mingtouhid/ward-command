## 2026-11-21 — Office admin account checkbox

### Fixed
- Client version stays `R2.0.12`. Service worker cache `ward-sync-pwa-r2.0.0-22`.
- In the Office Admin edit-account form, Account active is a left-aligned checkbox with its label on the same line. The label toggles the checkbox.

### Changed
- `migrations/r20_12_office_admin_bdft_short.sql` was applied to production on 2026-11-21.

## 2026-11-21 — Office admin desktop and intern wide screens

### Changed
- Client version stays `R2.0.12`. Service worker cache `ward-sync-pwa-r2.0.0-21`.
- The Office Admin user form has a BDFT short name for resident and admin accounts. It is saved on `residents.bdft_short`. `migrations/r20_12_office_admin_bdft_short.sql` was applied to production on 2026-11-21. PGT membership stays matched by resident id.
- Office Administration is plain blue and white (`#1D4ED8`, `#EFF6FF`, `#F8FAFC`). Account lists are a compact table with search and a role filter. Ward setup and rosters use compact tables. Edits stay in the existing modal or roster editor, and a Saved toast appears only after the server returns. A save refreshes only the list it changed.
- Intern pages on a wide desktop stay inside a centred column. The bottom bar matches that column, shows an icon and a label on every tab, and uses a modest selected highlight. A connection line with colour and text is shown on desktop only. The phone intern layout is unchanged.

## 2026-11-21 — Session loader logo alignment

### Changed
- Matched the visible session-loader artwork to the native Android splash logo using the supplied 690 × 1536 screenshots as measurement references.
- Increased the visible logo bounds from approximately 248 × 284 px to 298 × 327 px and shifted it down to align its centre with the native splash artwork. The title and connection status remain in their existing positions.
- Advanced the app-shell service-worker cache to ward-sync-pwa-r2.0.0-19.

## 2026-11-21 — Session loader background correction

### Fixed
- Forced the session-verification screen background and background image to the exact splash navy (#001c65), including the full-screen login wrapper.
- Added a final, higher-specificity override after the legacy session-loader theme rules, which had been reapplying the light-theme radial gradient over the new loader.
- Advanced the service-worker app-shell cache to ward-sync-pwa-r2.0.0-18.

## 2026-11-21 — Seamless animated session loader

### Changed
- Replaced the multicolour session-verification spinner and white card with a full-screen deep navy loader matching the Android splash background (#001c65).
- Added the supplied heart-ECG SVG as a standalone asset. The upper medical team/bed artwork fades away while the ECG scroll and heart pulse continue; internal navy cut-outs now match the splash background exactly.
- Kept the Ward Sync title and secure-connection status text in white beneath the animation.
- Temporarily sets the browser theme colour to #001c65 during session verification and restores the previously selected theme colour when verification ends or the login screen is shown.
- Added the SVG to the service-worker precache and advanced the app-shell cache to ward-sync-pwa-r2.0.0-17.

### Preserved
- Native Android splash artwork, manifest configuration, authentication/session verification logic and backend calls remain unchanged.
- No patient data, database schema, clinical workflows or access-control rules changed.

## 2026-11-20 — Home medical animation

### Changed
- Added the supplied `medical-banner-60s.svg` unchanged between the ward-category tiles and the Observation/Admitted/Discharged row on the Home hero card.
- Constrained the display area to 65px maximum height while preserving the SVG's 390:65 aspect ratio.
- Replaced the previous 70px empty row gap with the animation strip; the existing hero tiles and their actions remain unchanged.
- Added the SVG to the service-worker precache and advanced the cache version to `ward-sync-pwa-r2.0.0-16`.

### Preserved
- The uploaded SVG source was committed without editing its contents.
- No patient data, database schema, Supabase calls, access control or clinical workflow logic changed.

## 2026-11-20 — Home hero tile layout

### Changed
- Moved the Observation tile from the ward-category grid into the final three-tile row, replacing Beds free. Its existing action still opens the Observation page.
- Removed the TODAY section label above the final row.
- Added a 70px separation before the final row to distinguish it from the two ward-category rows.
- Added an orange status dot to the Observation tile when its count is greater than zero; the existing blue Admission and red Discharge indicators are unchanged.
- Updated the displayed client build to `R2.0.11`, manifest metadata to `1.3.24`, and service-worker cache to `ward-sync-pwa-r2.0.0-15`.

### Preserved
- Ward-category counts and actions remain unchanged.
- Admission and discharge counts, actions and indicators remain unchanged.
- No patient data, database schema, Supabase calls, access control or clinical workflow logic changed.

## 2026-11-20 — Android logo-only splash

### Changed
- Dedicated Android splash artwork is now present at `icons/icon-512-maskable.png`: white heart-ECG medical emblem on opaque `#001c65`, matching the manifest background so no separate square tile is visible.
- Kept the 192px standard and maskable icons, 512px standard icon, iOS Apple touch icon, favicons and root compatibility launcher artwork unchanged.
- Kept manifest `background_color` and `theme_color` at `#001c65`.
- Bumped the app-shell service-worker cache to `ward-sync-pwa-r2.0.0-14` so clients fetch the updated splash artwork.

### Preserved
- Notification glyph and badge remain unchanged.
- No clinical workflows, Supabase calls, roles, patient data handling or navigation code changed.

## 2026-11-20 — Heart ECG icon integration

### Changed
- Integrated the approved Ward Sync heart-ECG PNG icon assets at the existing canonical paths under `icons/` and the root compatibility paths.
- Kept the manifest splash/theme background at `#001c65` to match the deep-blue icon artwork.
- Bumped the app-shell service-worker cache to `ward-sync-pwa-r2.0.0-13` so installed clients refresh the icon assets and app shell.
- Added legacy Apple touch and favicon paths to the service-worker precache.

### Preserved
- Notification glyph and badge assets remain separate and unchanged.
- No clinical workflows, Supabase calls, roles, patient data handling or navigation code were changed.

### Fixed

- Corrected the current November 2026 PGT roster's member short-code snapshots to match each linked resident's canonical BDFT code. This fixes My Duties attribution where duty cells used the updated codes (e.g. TA) but the preserved roster snapshot still held the old codes (e.g. TO). Historical names, duty assignments and non-current published rosters remain unchanged.

# Changelog

All notable changes from 2026-11-10 onward are recorded here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are Asia/Calcutta. Older product history stays in `RELEASE-NOTES-*.md` and is not copied here.

## 2026-11-20
### Changed

- Updated the PWA manifest splash background and theme colour to `#001c65`, separated standard and maskable icon declarations, and aligned the initial HTML theme colour.
- Updated the service-worker app-shell cache to `ward-sync-pwa-r2.0.0-12`. The new PNG artwork still needs to replace the existing files under `icons/` and the root compatibility paths; this configuration commit does not itself replace binary image assets.

### Fixed

- Corrected PGT group-allocation matching in **My Duties**. Group labels such as “Group A” through “Group D” are now reliably normalised to the single-letter allocation tokens stored in OPD and evening-duty cells. Individual short-code assignments continue to match independently.



### Added

- Published PGT monthly rosters now support resident-only personal notes (up to 300 characters) and muted colour highlights on individual duty cells through an anchored contextual popup. Annotations are stored locally per signed-in resident and roster in browser storage only. The published roster remains read-only; annotation data is not sent to Supabase or other devices.

- Published PGT monthly rosters now open in a resident-specific **My Duties** view by default, with an **Entire Roster** switch preserving the existing full-table and annotation views. Duty matching uses the resident short code together with their PGT group and includes group, individual and combined (`+`) assignments. Multiple duties on one date remain separate and the monthly total counts assignments, not dates. Weekday OPD displays as OPD, Sunday OPD as Morning shift, 2–10 PM as Evening shift, and 10 PM–8 AM as Night shift; timings are not repeated in the personal list. Other duty types retain concise labels. The view is derived from the published roster and adds no Supabase writes or schema changes.

### Changed

- PGT group membership now uses a normalized resident-ID relationship with foreign keys to `public.residents.id`. The Office Admin picker selects registered active resident/admin profiles and derives names and BDFT short codes from the canonical account record; it no longer stores manually typed names or abbreviations. Active resident/admin BDFT short codes are unique.
- New and republished PGT rosters snapshot `residentId`, display name and BDFT code at publication. Existing published roster labels and assignments are preserved while resident IDs are backfilled. **My Duties** now matches the signed-in resident ID first; legacy text matching remains as a fallback, and duplicate short codes in historical snapshots are flagged instead of being treated as unique.
 
### Changed

- The resident PGT **My Duties** list now places the second duty item at the far edge of its row, reduces vertical spacing, and gives today's row a stronger accent-tinted background with a visible accent edge. This is presentation-only; date matching, resident attribution, duty ordering and the **Entire Roster** table are unchanged.
- Bumped the service-worker app-shell cache from `ward-sync-pwa-r2.0.0-10` to `ward-sync-pwa-r2.0.0-11` so installed clients refresh the updated `index.html`. The separate OCR cache is preserved.


## 2026-11-19

### Fixed

- Landscape tablet Home now places duty/sign-in beside Clinical Flags when the resident is not signed in; when a Needs You Now card is present, the duty and needs cards share the first row, with flags and schedule below. The on-duty team remains full-width.
- The Add Medication sheet now uses an explicit tablet-only class and docks as a narrow, vertically stacked panel on the right side of the landscape workspace. The patient list and clinical workflows are unchanged.
- The existing BDFT left-aligned bed chips / See BDFT action and compact patient-detail tab layouts are retained.


### Changed

- The Home BDFT card now treats the active ward-wide distribution for today or tomorrow as the source of truth, rather than relying only on the signed-in resident's personal assignment. The Make BDFT prompt is hidden once an active distribution exists. Bed numbers are shown in bed chips instead of being repeated in a summary line, and the complete distribution remains available in read-only view.
- BDFT push-notification taps are normalised to the published BDFT page. The notification route clears the distribution edit id and explicitly sets read-only mode, preventing a tap from opening the generation/edit terminal.
- PWA icon declarations now point to the canonical `icons/` directory and use separate regular and maskable 192px/512px assets. The service worker cache is `ward-sync-pwa-r2.0.0-3`; its precache includes the refreshed app icons, Apple touch icon, favicon, notification glyph and badge. The four root-level compatibility assets also precached by the service worker (`icon-192.png`, `icon-512.png`, `apple-touch-icon.png` and `favicon-32.png`) were refreshed from their canonical copies under `icons/`.

### Documentation and maintenance

- Repository documentation was refreshed: `structure.md` was added; `README.md`, `WARD_SYNC_ARCHITECTURE.md`, `privacy.html` and this changelog were updated; and the obsolete example commit subject in `.github/workflows/assemble-index.yml` was replaced. The HTML client label is `R2.0.8`, the inlined BDFT engine is `7.0`, and the current service-worker cache is `ward-sync-pwa-r2.0.0-4`; these values are separate version identifiers, not interchangeable release numbers.

## 2026-11-18

### Added

- Added the isolated `office_admin` workspace with PGT monthly and Faculty/VP/Resident Physician-GDMO weekly roster management, reusable PGT group sets, user management, and ward setup for unit settings, sections, beds and consultants.
- Added roster-builder functions for editable date ranges, adjustable columns and rows, notes, on-page preview and editable Word (`.docx`) export. PGT group configurations can be saved and reused; roster copies retain the month's selected group members and abbreviations.
- Added a published-roster library for staff. PGT monthly and Faculty weekly rosters are presented separately in a read-only view, with current, scheduled and archived status labels.

### Changed

- Office Admin uses an isolated desktop/landscape workbench with its own navigation and scrollable content area; it does not use the clinical mobile shell. The ward setup UI is configuration-only and states that patient identity and occupancy are not available in this workspace.
- Office Admin roster, saved-group, user and ward-setup reads use short-lived in-memory caches to reduce repeated RPC requests.
- The resident morning on-duty board groups sign-ins into OPD and IPD sections, displays resident photos with names/roles in a compact two-column layout, and collapses to one column on very narrow screens.
- Added a compact quick-action strip above the existing bottom navigation without replacing the primary navigation.

## 2026-11-17

### Fixed

- Intern role detection remains authoritative for the active session when the reduced intern read-state omits the full resident profile. This keeps interns in the reduced intern workspace instead of falling back to the standard patient shell.
- Intern navigation is pinned to the bottom of the screen and keeps all three navigation labels visible on phone layouts.

## 2026-11-16

### Changed

- Client version stays `R2.0.0`. Service worker cache is `ward-sync-pwa-r2.0.0-2`. On a consultant Home, the bed distribution card, the duty status card, and Today's schedule are not shown. The You need to know card keeps its patient lines and drops the action buttons. Resident, admin, and intern Home are unchanged.

## 2026-11-15

### Fixed

- Client version stays `R2.0.0`. Service worker cache `ward-sync-pwa-r2.0.0-1` so installed phones pick up this layout pass. The bottom bar stays at the bottom of the screen on every phone and tablet-portrait page, including short ones, and the last card can scroll clear of it. In the day theme the bell is a light circle with a dark icon and the red count stays visible. The greeting is 18px so "Good evening, Dr Touhid" fits beside a photo and a badge at 360px and wider.

### Changed

- Client version `R2.0.0` (service worker cache `ward-sync-pwa-r2.0.0`). Home is the dark dashboard: greeting with the sync line under the name, ward title, bed distribution, where/today overview, duty status, clinical flags, schedule, and on-duty team. At 469px the column is 400px and centred. Phones under 432px keep 16px side margins. The phone Home overview is compact: section gaps are 10px and the ward tiles are 58px. Tablet portrait puts the cards under the hero in two columns. Tablet landscape fills the screen. The bottom bar is a 64px icon row traced from the mockup. A wide landscape screen uses a sidebar of the existing pages. Day, night, accent, and density preferences still drive the colours. No clinical, auth, BDFT, or notification behaviour changed.

### Fixed

- Client version `R1.9.1` (service worker cache `ward-sync-pwa-r1.9.1`). A notification opens the page stored on it. A tap while the app is open is delivered to that window. A cold start keeps the same destination until sign-in and the ward list are ready. A missing record shows a short message and opens a safe page. The same notification id does not navigate twice in a row.

### Changed

- Database only, `R1.9.3`. `migrations/r19_3_weekly_cleanup.sql` was applied to Supabase on 2026-11-15. `ward_weekly_cleanup` runs every Sunday at 03:30 IST. It deletes scheduler run-log rows older than 7 days and notification events older than 30 days. Deliveries cascade. Held notifications are kept. The first run removed 18,927 scheduler log rows, 2 notification events, and 30 deliveries.
- Database only, `R1.9.0.1`. `migrations/r19_0_1_ect_dedupe_enforce.sql` was applied to Supabase. One accidental duplicate ECT session was removed (same patient, 14 Nov 2026, session 2 saved 36 seconds after session 1, no clinical data), that plan's `sessions_done` was set from 2 to 1, and unique index `ect_sessions_one_per_patient_ist_day` was created on `public.ect_sessions` (`patient_id`, `((session_at at time zone 'Asia/Kolkata')::date)`). This completes the Module 7 rule that the R1.9.0 migration had skipped.

### Added

- Keep-alive and storage alerts, not applied. `migrations/r19_2_keepalive_storage.sql` adds `ward_ping` and a monthly `ward_storage_check` (warn above 350 MB, urgent above 450 MB). A warn or urgent level inserts one `archive` / `admins` notification for that level each IST month and marks it ready to send. `.github/workflows/keepalive.yml` calls `ward_ping` every two days. Nothing here is applied to Supabase.
- Client version `R1.9.0` (service worker cache `ward-sync-pwa-r1.9.0`). Home shows today's or tomorrow's BDFT (IST). A distribution from yesterday or earlier leaves Home and Mine empty. Recent discharges are grouped by date. Residents see on-duty PGTs as a four-column photo grid. More has an All PGTs directory. One ECT session can be recorded per patient per day. Discharge can be reviewed and saved as a draft before confirm, with primary, secondary and tertiary diagnoses. DOR and DAMA certificates leave a line for the attendant's signature. A missing MSE or investigation is a reminder with Continue anyway, and no reason is required. Lithium and Clozapine side effects can be recorded for the bed owner. `migrations/r19_0_monitoring_directory_ect.sql` is not applied.

## 2026-11-10

### Added

- `WARD_SYNC_ARCHITECTURE.md` at the repository root. It describes Ward Sync as of `381a4c4` (2026-11-09): the static PWA, Supabase RPCs and RLS, the inlined BDFT v7.0 client (roster sync, local generation, finalise via `ward_bdft_save_distribution`, home card, persistence, `dispatch-bdft`, no JSONBin), ECT session completion through `ward_record_ect_session`, notifications, and the monthly Drive archive path. Edge functions `dispatch-notification` and `monthly-archive` are named as callers whose source is not in this tree.
- MSE insight Grade V (`g5`). Grades I–IV stay the stored keys `g1`–`g4`. Summary, patient MSE, and discharge certificate / PDF text take the label from the same option list.
- My profile page for the signed-in resident or admin. `migrations/r18_2_update_my_profile.sql` adds `ward_update_my_profile` (own username and display name only). Not applied.

### Changed

- Client version `R1.8.1` (`APP_VERSION` and service worker cache `ward-sync-pwa-r1.8.1`).
- Client version `R1.8.2`. More tiles are a smaller 3-column grid (names wrap to two lines; icon and name size unchanged). Admins open BDFT from the BDFT settings tile with the bed icon. The generation terminal has no Settings button. Resident Home shows a photo and two-line greeting, with the bell above the sync chip, and the unit name in place of Today. BDFT bed picking is grouped by section.
- Resident Home header is one row: avatar, left-aligned greeting and name, bell above the sync chip on the right.
- Client version `R1.8.3`. Admins see the same Home header and unit-name title as residents.
- Client version `R1.8.4`. The avatar header is 10% shorter, the sync chip sits above the bell, and admins and residents see that header on every page. The chip keeps a fixed width so a sync update does not move the avatar, name, or bell.
- Patients Mine for a resident is the beds currently assigned to them on the BDFT distribution, the same list as the Home beds card. Beds redistributed to them are included. Owned beds given to someone else are not. With no current assignment, the Home card stays blank and Mine shows no patients.
- Client version `R1.8.5`. Admins and residents can set, crop, and remove their own profile photo from My profile. The 256×256 JPEG replaces the single `ward_resident_photos` row (`migrations/r18_5_profile_photo.sql`, not applied) and the single `ws_my_photo_<id>` key. It is shown on My profile and in the header. Clear deletes that row. No photo history and no Storage.
- Residents no longer have a BDFT tile on More. That slot is My profile (username, display name, own phone, BDFT short name, owned beds, photo placeholder). Edit is self-only. The My phone tile is removed. If `ward_update_my_profile` is missing, phone and BDFT still save.
- Evening-duty residents see a Make BDFT card at the top of Home. It opens the existing generation terminal. Admins keep the BDFT tile and gain a BDFT settings tile that opens setup directly.
- BDFT distribution chips use the accent for owned beds and a separate colour for redistributed beds. The home card button is See BDFT.

### Fixed

- Client version `R1.8.6`. The header sync dot stays an 8×8 circle. The pill sizes to its label and stays right-aligned in a 118px column, so the bell and greeting do not move. Text ellipsizes only past that max. Service worker cache `ward-sync-pwa-r1.8.6`.
- Consultants see the Home Opinion count chip. It uses the same `opinionCount()` chip as residents and opens the patients list filtered to admission reason Opinion. That list stays view-only for consultants.
