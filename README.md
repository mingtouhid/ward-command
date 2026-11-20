# Ward Sync

Internal psychiatry ward coordination and clinical-workflow PWA for authorised staff.

Ward Sync brings together patient lists and snapshots, medication and observation records, handovers, ECT, discharge workflows, staff duty coordination and bed distribution (BDFT). Role-specific surfaces include residents, admins, consultants, interns and a separate Office Administration workspace.

## Repository overview

- **Frontend:** static single-document PWA in `index.html` (HTML, CSS and JavaScript).
- **Backend:** Supabase Postgres, RLS and RPCs.
- **Hosting:** Vercel serves the repository root; `vercel.json` defines rewrites and headers. No bundler build command is configured.
- **PWA:** `manifest.json`, `sw.js` and current install/notification assets under `icons/`.
- **OCR:** Tesseract runtime and Ward Sync OCR integration under `ocr/`.
- **BDFT push dispatch:** `supabase/functions/dispatch-bdft/`.

## Documentation

- [Repository structure](structure.md)
- [System architecture and backend contracts](WARD_SYNC_ARCHITECTURE.md)
- [Changelog](CHANGELOG.md)
- [Icon asset replacement guide](ICON-ASSET-REPLACEMENT.md)
- [Privacy notice](privacy.html)
- [Historical design specifications and plans](docs/superpowers/)

## Deployment and maintenance

The app is served as a static site from the repository root. The current frontend source is `index.html`; PWA install and update behaviour is controlled by `manifest.json` and `sw.js`. Keep the HTML app label, service-worker cache name and manifest metadata intentionally coordinated. A service-worker cache bump prompts installed clients to replace the previous app cache.

Supabase migrations under `migrations/` must be reviewed and applied separately to the intended project. A SQL file in Git is not proof that it has been applied. Some RPCs and Edge Functions referenced by the client are not represented by source files in this repository; see the architecture document's **Gaps worth knowing** section before changing those integrations.

Ward Sync is an internal staff tool. Do not commit patient identifiers, live clinical data, access tokens, service-role keys, Vault secrets or provider private keys.
