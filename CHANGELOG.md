# Changelog

All notable changes from 2026-11-10 onward are recorded here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are Asia/Calcutta. Older product history stays in `RELEASE-NOTES-*.md` and is not copied here.

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
- Residents no longer have a BDFT tile on More. That slot is My profile (username, display name, own phone from `ward_get_my_phone`, BDFT short name, owned beds, photo placeholder). Edit is self-only. The My phone tile is removed. If `ward_update_my_profile` is missing, phone and BDFT still save.
- Evening-duty residents see a Make BDFT card at the top of Home. It opens the existing generation terminal. Admins keep the BDFT tile and gain a BDFT settings tile that opens setup directly.
- BDFT distribution chips use the accent for owned beds and a separate colour for redistributed beds. The home card button is See BDFT.

### Fixed

- Consultants see the Home Opinion count chip. It uses the same `opinionCount()` chip as residents and opens the patients list filtered to admission reason Opinion. That list stays view-only for consultants.
