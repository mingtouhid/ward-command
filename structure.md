# Ward Sync repository structure

**Repository:** `mingtouhid/ward-command`  
**Branch:** `main`  
**Snapshot:** 26 November 2026  
**Application:** Static, single-document progressive web app (PWA)

This is the quick repository map. See [WARD_SYNC_ARCHITECTURE.md](WARD_SYNC_ARCHITECTURE.md) for runtime, role, backend and deployment behaviour, and [CHANGELOG.md](CHANGELOG.md) for dated product changes.

## Root files

| Path | Purpose |
| --- | --- |
| `medical-banner-60s.svg` | Supplied 60-second animated medical banner displayed between the Home hero tile rows; source retained unchanged. |\n| `index.html` | Main application source: markup, CSS, client-side state, hash routing, clinical screens, resident/admin/consultant/intern surfaces, Office Admin workspace and read-only published-roster library. |
| `sw.js` | Service worker: app/OCR caches, precache, offline/network strategy, push display and notification-click routing. |
| `manifest.json` | PWA name, install/display settings, theme/background colours and app icon declarations. |
| `README.md` | Project entry point and links to project documentation. |
| `CHANGELOG.md` | Dated product and runtime changes. |
| `WARD_SYNC_ARCHITECTURE.md` | Detailed system architecture and known backend/deployment gaps. |
| `structure.md` | This file map and maintainer checklist. |
| `privacy.html` | User-facing privacy notice. |
| `vercel.json` | Static deployment settings, SPA rewrites and response headers. |
| `404.html` | Fallback for app routes not resolved as static files. |
| `RELEASE-NOTES-*.md` | Historical release notes for earlier R1.x releases. |

## Assets and directories

| Path | Purpose |
| --- | --- |
| `icons/` | Canonical current PWA icons: regular 192/512, maskable 192/512, Apple touch icon, favicons, notification glyph and badge. |
| Root `icon-192.png`, `icon-512.png`, `apple-touch-icon.png` and `favicon-32.png` | Compatibility aliases refreshed from the canonical `icons/` assets because the service worker also precaches these root paths. Current HTML and manifest use `icons/`. Other historical root PNGs are not referenced by the current manifest or HTML head. |
| `ocr/` | Tesseract.js runtime, trained data, workers/wasm, OCR manifest and Ward Sync OCR integration. |
| `migrations/` | Supabase SQL migrations, rollback scripts and test/precheck files, including the canonical PGT resident-identity migration and verification script. Presence in Git does not establish production apply status. |
| `supabase/functions/dispatch-bdft/` | BDFT push-dispatch Edge Function, worker module, Deno config and schedule notes. |
| `docs/superpowers/specs/` | Historical design specifications for R1.7 and R1.8 work. |
| `docs/superpowers/plans/` | Historical implementation plans associated with those specifications. |
| `.github/workflows/` | GitHub Actions jobs, including keep-alive and the legacy/manual index assembler. |

## Runtime boundaries

- `index.html` is the frontend source of truth in this repository. The current project has no frontend package/bundler build step; Vercel serves the repository root.
- Residents, admins and consultants use the clinical shell with role-specific capabilities. Interns use a reduced shell. `office_admin` uses an isolated Office Administration workspace rather than the patient-care shell.
- Office Admin covers PGT monthly and Faculty weekly roster administration, reusable PGT group sets, account management, and ward configuration. PGT group membership is keyed by `residents.id`; roster snapshots retain that ID alongside historical display name/code. The published staff roster library is read-only.
- Supabase provides Postgres, RLS and RPCs. Vercel serves the static PWA. The source for BDFT dispatch is in this repository; some other server functions invoked by the client are not included.

## Version identifiers in the 26 November 2026 source snapshot

| Identifier | Value | Meaning |
| --- | --- | --- |
| HTML `APP_VERSION` | `R2.0.15` | Build label displayed by the app. |
| BDFT `BDFT_APP_VERSION` | `7.0` | Inlined BDFT engine label. |
| Service worker `VERSION` | `ward-sync-pwa-r2.0.0-15` | Cache name; changing it triggers app cache replacement. |
| OCR cache | `ocr-assets-v7` | Separate OCR asset cache. |
| Manifest `version` / `build` | `1.3.20` / `R1.3.20 icons` | Legacy custom manifest metadata, not the displayed HTML build. |

These identifiers have different purposes and are not interchangeable. Current CSS/feature comments also include R2.0.10, R2.0.11, R2.0.14 and R2.0.15; those comments do not override the value of `APP_VERSION`.

## Backend and migration caveats

The frontend calls an `office_admin_*` RPC family for Office Admin login/session, roster lifecycle, saved PGT groups, account changes and ward configuration. The read-only roster library calls `ward_list_published_rosters`. The checked-in `migrations/r20_canonical_pgt_resident_identity.sql` versions PGT group membership and the relevant Office Admin PGT group/roster RPCs. Other Office Admin RPCs remain partly external to the checked-in migrations; verify live schema and migration status before changing them. Do not infer production schema or migration status from frontend code.

The repository also does not contain source for all external functions referenced by the frontend, including `dispatch-notification` and `monthly-archive`. See the architecture document's gaps section.

## Maintainer checklist

1. Record user-visible changes in `CHANGELOG.md` with the date and scope.
2. Update `structure.md` when files, folders or source-of-truth boundaries change.
3. Update `WARD_SYNC_ARCHITECTURE.md` when roles, RPC contracts, routing, data flow, caching or deployment behaviour changes.
4. Keep HTML app label, service-worker cache name and manifest metadata deliberately coordinated; record intentional differences.
5. Commit database migrations and rollbacks where possible, and record verified application status separately from file existence.
6. Never commit patient data, session tokens, service-role keys, Vault values, VAPID private keys or FCM credentials.

## PWA icon and splash configuration (2026-11-20)

- The web manifest declares standard and maskable app icons separately under `icons/` and uses `#001c65` for `background_color` and `theme_color`.
- The initial HTML `theme-color` matches `#001c65`; runtime theme selection may update the browser chrome colour when the user changes the in-app theme.
- The service-worker app-shell cache is `ward-sync-pwa-r2.0.0-14`.
- Root-level icon compatibility files and the PNG files under `icons/` must be updated together when publishing a new icon artwork set. Android's adaptive mask is applied by the launcher; PNG assets should not bake black corners into the square canvas.


## 2026-11-20 icon artwork integration

The approved Ward Sync heart-ECG icon PNGs are stored under `icons/`, with root-level compatibility copies for legacy PWA URLs. Standard and maskable icon declarations retain the existing manifest paths. The notification glyph and badge remain separate notification-specific assets and must not be replaced by the full app icon.


## Android splash icon separation (2026-11-20)

- `icons/icon-192.png` and `icons/icon-192-maskable.png` remain the full blue launcher artwork.
- `icons/icon-512.png` remains the full blue square app artwork.
- `icons/icon-512-maskable.png` is the dedicated Android splash artwork: a centered white medical emblem on opaque `#001c65`, matching the manifest launch background.
- Android WebAPK splash selection is platform-controlled; confirm the actual appearance after the updated WebAPK is installed.
- iOS Apple touch icon, root compatibility files, notification glyph and badge remain unchanged.


## Home hero tile layout (2026-11-20)

- The ward-category grid contains only the six ward categories.
- The final three-tile row is Observation, Admitted and Discharged. Beds free is intentionally hidden from this hero card.
- The TODAY heading is removed. The final row is separated from the ward-category grid by a 70px top margin.
- The Observation tile retains its existing Observation-page action and displays an orange status dot when its count is non-zero. Admission and Discharge retain their existing blue and red indicators.


## Home medical animation (2026-11-20)

- `medical-banner-60s.svg` is the supplied 390×65 SVG, retained unchanged.
- The Home hero card renders it between the six ward-category tiles and the Observation/Admitted/Discharged row, constrained to a maximum display height of 65px.
- The service worker precaches the SVG for offline use. Cache version: `ward-sync-pwa-r2.0.0-16`.
- No clinical data, database, Supabase, role, or workflow logic is changed.
