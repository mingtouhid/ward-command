# Ward Sync icon asset integration

The approved Ward Sync heart-ECG icon artwork is uploaded in this repository.

## Canonical files under `icons/`

- `icon-192.png` — 192 × 192 standard PWA icon
- `icon-512.png` — 512 × 512 standard PWA icon
- `icon-192-maskable.png` — 192 × 192 Android maskable icon
- `icon-512-maskable.png` — 512 × 512 Android maskable icon
- `apple-touch-icon.png` — 180 × 180 iOS/iPadOS icon
- `icon-180.png` — 180 × 180 Apple touch compatibility alias
- `favicon-16.png` and `favicon-32.png` — browser favicons

Matching root-level compatibility files are also present: `icon-192.png`, `icon-512.png`, `icon-180.png`, `apple-touch-icon.png`, `favicon-16.png`, and `favicon-32.png`.

## Platform requirements

- App icons are square, opaque RGB PNGs. Do not bake rounded corners, transparent corners or an outer border into the artwork.
- iOS applies its own Home Screen mask to the full-bleed Apple touch icon.
- Android applies the launcher mask to the maskable icon. Keep the emblem centered and within the mask-safe area.
- Manifest `background_color` and `theme_color` remain `#001c65` to match the artwork and PWA launch background.
- Keep `icons/icon-notif-192.png` and `icons/badge-96.png` unchanged. They are notification-specific assets, not launcher icons.

## Cache and refresh

The service-worker cache name is `ward-sync-pwa-r2.0.0-13`. After deployment, clients install the refreshed app shell. If an iOS Home Screen icon remains cached, remove and re-add the PWA shortcut.
