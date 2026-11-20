# Ward Sync icon asset integration

The approved Ward Sync heart-ECG icon artwork is present in this repository. Android uses a separate 512px maskable artwork for the launch splash; this differs from the full-tile launcher icon.

## Canonical files under `icons/`

- `icon-192.png` — 192 × 192 standard PWA icon (full blue launcher tile)
- `icon-192-maskable.png` — 192 × 192 Android maskable icon (full blue launcher tile)
- `icon-512.png` — 512 × 512 standard PWA icon (full blue app artwork)
- `icon-512-maskable.png` — 512 × 512 Android splash artwork (white emblem on opaque `#001c65`)
- `apple-touch-icon.png` — 180 × 180 iOS/iPadOS icon
- `icon-180.png` — 180 × 180 Apple touch compatibility alias
- `favicon-16.png` and `favicon-32.png` — browser favicons

Matching root-level compatibility files are also present: `icon-192.png`, `icon-512.png`, `icon-180.png`, `apple-touch-icon.png`, `favicon-16.png`, and `favicon-32.png`.

## Android splash artwork

The dedicated artwork is stored at `icons/icon-512-maskable.png`. It is 512 × 512, opaque RGB, with a white centered medical emblem on the exact `#001c65` launch background. This removes the visible blue gradient square while keeping the normal launcher artwork unchanged.

## Platform requirements

- App icons are square and opaque. Do not bake rounded corners, transparent corners or an outer border into launcher artwork.
- iOS applies its own Home Screen mask to the full-bleed Apple touch icon; it remains unchanged.
- Android applies its mask to maskable artwork. The splash emblem is centered within the safe area; the 192px maskable launcher artwork remains unchanged.
- Manifest `background_color` and `theme_color` remain `#001c65`.
- Keep `icons/icon-notif-192.png` and `icons/badge-96.png` unchanged.

## Cache and refresh

The service-worker cache name is `ward-sync-pwa-r2.0.0-14`. After deployment and WebAPK update, Android should receive the new splash image. If the installed WebAPK continues showing cached artwork, remove the Home Screen app and reinstall it from Chrome.
