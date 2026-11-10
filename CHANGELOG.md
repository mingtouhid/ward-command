# Changelog

All notable changes from 2026-11-10 onward are recorded here. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Dates are Asia/Calcutta. Older product history stays in `RELEASE-NOTES-*.md` and is not copied here.

## 2026-11-10

### Added

- `WARD_SYNC_ARCHITECTURE.md` at the repository root. It describes Ward Sync as of `381a4c4` (2026-11-09): the static PWA, Supabase RPCs and RLS, the inlined BDFT v7.0 client (roster sync, local generation, finalise via `ward_bdft_save_distribution`, home card, persistence, `dispatch-bdft`, no JSONBin), ECT session completion through `ward_record_ect_session`, notifications, and the monthly Drive archive path. Edge functions `dispatch-notification` and `monthly-archive` are named as callers whose source is not in this tree.
- MSE insight Grade V (`g5`). Grades I–IV stay the stored keys `g1`–`g4`. Summary, patient MSE, and discharge certificate / PDF text take the label from the same option list.

### Changed

- Client version `R1.8.1` (`APP_VERSION` and service worker cache `ward-sync-pwa-r1.8.1`).

### Fixed

- Consultants see the Home Opinion count chip. It uses the same `opinionCount()` chip as residents and opens the patients list filtered to admission reason Opinion. That list stays view-only for consultants.
