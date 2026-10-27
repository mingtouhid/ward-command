# R1.3.134 — Scan a lab report (pilot, Phase 1 + part of Phase 2)

Status: LIVE on 27 Oct 2026. Migration `20261027113205 r1_3_134_lab_ocr_phase1` applied to ward-flow at 17:02 IST (function md5 c513d0196c078a864ec50bbad32c8d9c, same as the locally tested copy). The OCR engine files under `ocr/` went in first (commits aca8d0a…5d586cf); this release commit adds the app, service worker, headers, notes and the migration file. Rollout: CBC only.

## What's new
- **Scan report** in Add investigations (patient card). Camera or gallery or forwarded image → 4-corner crop with auto page detection → on-phone OCR → the values fill the normal investigations form.
- **On-device only.** Tesseract.js 7.0.0 (LSTM, eng best_int) + the ward-ocr parser (AMCH CBC / urine R/E / Biochemistry templates, a digit re-read of each value, plausibility and decimal rules, panel cross-checks). No cloud OCR.
- **The photo is never kept**: memory only; released on save, cancel or close. No image in IndexedDB, localStorage, Cache Storage, the outbox or any request (tested).
- **Review**: each scanned value is green, amber (with a reason and the crop of the paper) or red. Save is blocked until each amber or red value is ticked "Matches paper" or corrected. Criticals still need the red-box tick (server-enforced). Low-resolution (WhatsApp-type) images show a warning.
- **Patient check on the printed NAME only** (no hospital number). Fuzzy: OCR errors, word order, initials, titles (Mr/Mrs/Md…), spacing. A match shows a green tick. A mismatch or unreadable name shows both names, Cancel and "Use for this patient anyway" (reason required; saved in the audit trail and in the timeline detail "Name override: …").
- **First-time engine download (6.7 MB)**: consent card (size, mobile-data note, Download / Not now); a real streamed progress bar (% and "x.x of y.y MB", file n of 5; indeterminate only when the size is unknown); a 20 s stall timeout; SHA-256 and size checks on every file before the cache is marked ready; a failure card with the reason, Retry and Enter manually, and no partial cache left behind. Once cached: "Scanner ready (offline)", never asked again; asked again if the browser evicts the cache.
- The sample number is stored silently. Lithium and valproate ranges and critical limits are unchanged (standard values).
- Amylase and lipase short labels.

## Rollout: CBC only
- Scanning pre-fills **CBC reports only** in this release. Accuracy on the real-photo test set: CBC 41/42 values correct (about 10% amber) passed the gate; Biochemistry (63/81) and Urine R/E (7/18) did not.
- If the parser classifies a scanned page as Urine R/E or Biochemistry (or cannot recognise it), nothing is filled in: the sheet shows "Not a CBC report — Scanning for this report type is coming soon — please enter manually" with an "Enter manually" button. The manual form is left exactly as it was and the photo is discarded.
- The scan sheet's tips line says "For now the scanner fills CBC reports only".
- The gate is one list in index.html (`LAB_OCR_TPLS=["cbc"]`). Adding "bio" or "urine" later is a one-line change once those templates pass the accuracy gate.
- Verified at 360 and 412 px (synthetic reports): CBC scan, fixes, critical tick and save unchanged; CBC name mismatch with override and cancel; low-res CBC with initials-only name; two biochemistry pages (KFT/electrolytes, LFT) show the "coming soon" card with no values filled, no OCR state and the form unchanged.

## Vendor note
- `ocr/worker.min.js` is tesseract.js 7.0.0 with a **one-line patch**: language objects are joined by `code` instead of `data` in initialize (the upstream bug made in-browser init fail with "Couldn't load any languages"). The manifest's engine string says so. Re-run the manifest generator whenever a file in `ocr/` changes (SHA-256 + size are verified on download).

## Migration (applied 27 Oct 2026, 17:02 IST — version 20261027113205)
`migrations/R1.3.134-lab-ocr-phase1.sql` — lab_report_edits.source, action 'create'; lab_reports.ocr_stats (<2 KB) and match_reason; ward_save_lab_report accepts entry_method 'ocr' with match_status exact | probable_confirmed | override (+ reason ≥ 3 chars), keeps ocr_value / ocr_conf / field_state, engine, mean confidence, stats, page fields and the sample number; "Investigations added (scanned)" timeline title. Manual entry unchanged. Rollback block at the end restores the R1.3.133 function exactly (md5 verified on a local copy).
Applied as one migration with BEGIN/COMMIT removed (the migration tool wraps it) and the rollback comment block left out; every UPDATE/DELETE has a WHERE (safeupdate-safe).

## Verified (synthetic data only)
- Regression suite identical to R1.3.133 (hx0 kb0 dv0 mv0 dbg1 ect1 audit0, 360 + 412 px); lab-form suite identical to R1.3.133 at 360 and 412 px.
- Download e2e (success, slow progress, 503, mid-stream abort, corrupt file, stall, offline before/mid, cancel, retry, eviction).
- Scan e2e at 360 and 412 px (review, fixes, critical, name match / mismatch / override / cancel, low-res, no photo kept).
