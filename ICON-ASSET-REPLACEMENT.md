# Ward Sync icon asset replacement guide

This repository is a static PWA. Its manifest and application use stable filenames, so upload the new binary artwork **in place** at the paths below. Do not rename the files or change the URLs in `manifest.json`.

## Required app-icon files

| Upload path | Purpose | Artwork requirement |
| --- | --- | --- |
| `icons/icon-192.png` | Standard PWA icon, 192 × 192 | Full-bleed square artwork; no baked rounded corners |
| `icons/icon-512.png` | Standard PWA icon, 512 × 512 | Full-bleed square artwork; no baked rounded corners |
| `icons/icon-192-maskable.png` | Android maskable PWA icon, 192 × 192 | Same design with all meaningful emblem detail inside the central mask-safe area |
| `icons/icon-512-maskable.png` | Android maskable PWA icon, 512 × 512 | Same design with all meaningful emblem detail inside the central mask-safe area |
| `icons/apple-touch-icon.png` | iOS/iPadOS Home Screen icon, 180 × 180 | Opaque full-bleed square; **do not pre-round the corners** |
| `icons/icon-180.png` | Legacy Apple touch icon alias, 180 × 180 | Same artwork as the Apple touch icon |

## Root compatibility copies

Upload matching copies at the root as well, because the service worker precaches these legacy URLs:

- `icon-192.png` — copy of `icons/icon-192.png`
- `icon-512.png` — copy of `icons/icon-512.png`
- `icon-180.png` — copy of `icons/icon-180.png`
- `apple-touch-icon.png` — copy of `icons/apple-touch-icon.png`
- `favicon-16.png` — compact favicon derived from the approved mark
- `favicon-32.png` — compact favicon derived from the approved mark

The older root-level `root-icon-192.png` and `root-icon-512.png` are compatibility aliases only; refresh them too if maintaining every legacy copy.

## Assets to leave unchanged

- `icons/icon-notif-192.png`: notification small icon; retain its simple monochrome notification glyph.
- `icons/badge-96.png`: Android notification badge; retain the existing small monochrome badge.

Do not replace these with the complete blue app icon; notification surfaces apply their own monochrome rendering.

## Splash and iOS border behaviour

- Keep `manifest.json` `background_color` and `theme_color` at `#001c65`, matching the deep-blue artwork and launch background.
- Android/Chrome applies its launcher mask to the maskable icon. Keep maskable files square, with the emblem comfortably inside the mask-safe area and no black corner pixels.
- iOS applies its own Home Screen icon mask. Apple touch artwork must remain square and opaque, with no baked corner radius, border, outer shadow or transparent corner pixels.
- The web PWA does not reference a separate static splash PNG in its manifest. Its install splash background is derived from the manifest colours and icon. Do not add the wallpaper preview as a runtime splash asset.

## Verification after upload

1. Confirm the six required files under `icons/` and six root compatibility files exist with the stated dimensions.
2. Confirm each app icon is square and opaque; inspect maskable variants inside an Android adaptive-icon preview.
3. Confirm the notification glyph and badge are unchanged.
4. Merge/deploy this configuration branch only after the binary files have been uploaded. The service-worker cache is `ward-sync-pwa-r2.0.0-13`; installed clients will then fetch the refreshed app shell.
5. On iOS, remove and re-add the old Home Screen shortcut if its previous icon remains cached. On Android, allow the launcher to refresh the installed shortcut or reinstall the PWA if necessary.
