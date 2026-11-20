# Ward Sync icon asset integration

The approved Ward Sync heart-ECG icon artwork is uploaded in this repository. Android uses a separate 512px maskable artwork for the launch splash; this one is intentionally different from the full-tile launcher icon.

## Canonical files under `icons/`

- `icon-192.png` — 192 × 192 standard PWA icon (full blue launcher tile)
- `icon-192-maskable.png` — 192 × 192 Android maskable icon (full blue launcher tile)
- `icon-512.png` — 512 × 512 standard PWA icon (full blue app artwork)
- `icon-512-maskable.png` — 512 × 512 Android maskable splash artwork (white emblem on opaque `#001c65`, no distinct tile)
- `apple-touch-icon.png` — 180 × 180 iOS/iPadOS icon
- `icon-180.png` — 180 × 180 Apple touch compatibility alias
- `favicon-16.png` and `favicon-32.png` — browser favicons

Matching root-level compatibility files are also present: `icon-192.png`, `icon-512.png`, `icon-180.png`, `apple-touch-icon.png`, `favicon-16.png`, and `favicon-32.png`.

## Android splash replacement

Replace **only** `icons/icon-512-maskable.png` with the supplied file `WardSync-Android-Splash-512-Maskable.png`.

Do not replace `icons/icon-192-maskable.png`; it remains the full blue launcher icon. Do not replace `icons/icon-512.png`; it remains the full blue standard app icon.

The new splash art is a 512 × 512 opaque RGB PNG. Its background is exactly `#001c65`, matching the manifest background/theme colour. Its white emblem is centered within the mask-safe region. On the Android splash, the solid icon field should visually blend into the full-screen background.

## Platform requirements

- App icons are square, opaque RGB PNGs. Do not bake rounded corners, transparent corners or an outer border into launcher artwork.
- iOS applies its own Home Screen mask to the full-bleed Apple touch icon; it remains unchanged.
- Android applies an adaptive mask to maskable icon artwork. The 512px splash emblem is kept inside the central safe area; the 192px maskable launcher artwork remains unchanged.
- Manifest `background_color` and `theme_color` remain `#001c65`.
- Keep `icons/icon-notif-192.png` and `icons/badge-96.png` unchanged. They are notification-specific assets, not launcher icons.

## Cache and refresh

The service-worker cache name is `ward-sync-pwa-r2.0.0-14`. After deployment and WebAPK update, Android should receive the new splash image. If the existing installed WebAPK continues showing the cached splash art, remove the Home Screen app and reinstall it from Chrome after the deployment is available. Runtime appearance has not been tested on the target Samsung device.
