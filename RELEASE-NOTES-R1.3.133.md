# Ward Sync R1.3.133 — discharge form produces the final certificate format

Includes R1.3.132 (no page-2 countersign, no (new)/(changed) med tags).

## Discharge form (Census → Discharge)
- **From the record** card (read-only, for confirmation): Admitted under (all consultants), Hospital No., M.R.D. No. (if on file), Admitted on, Age / Sex, Department: Psychiatry.
- **M.R.D. No. \*** asked only when missing (unchanged rule).
- Mode of treatment chips (Conservative / ECT + sessions), Mode of discharge, **Condition at discharge** (renamed from "Outcome"), requested-by chips for On request / DAMA (unchanged).
- **Date & time of discharge \*** – must be valid, not before admission, not more than 6 h ahead.
- **Medications on discharge** (required for On advice / On request / DAMA): tick ongoing orders, Edit, or + Add. Each added row has name, dose, route, frequency and a new **Taper / duration** line (e.g. "2 tabs HS x 5 days, then 1 tab HS x 5 days"). Frequency may be left empty when a taper is typed. Tick **No medications on discharge** to confirm none.
- **Instructions to the patient \*** (not required for DAMA): textarea + quick chips (Continue medications as advised · Remain abstinent from alcohol · Avoid alcohol and other substances · Take medicines regularly… · Return earlier if symptoms recur).
- **Review after \*** (not required for DAMA): chips 1 week / 2 weeks / 3 weeks / 1 month + free text; live hint shows what prints.
- MSE row says which MSE page 2 will print if no discharge MSE is filled.
- Live "Still needed: …" line; Confirm shows every missing item (toast, red outline, scrolls to the first). The line does not repaint while a drug name is being typed (updates on blur), so the sheet does not reflow under the suggestion list.

## Certificate
- **Key drugs removed.** Treatment prints the mode only, plus **Modified ECT: N sessions** (bold) when ECT was given.
- Review prints as one line: "Review after 3 weeks." (no long OPD sentence, no duplicate if the advice also had a review line).
- Medicine table: dose spacing normalised ("666mg" → "666 mg"); taper text prints in the Frequency column; tapers typed into the name on older records are split out at print time.
- Page 2 MSE: discharge MSE if filled (≤36 h), else the latest MSE of the admission.
- Page-1 "Relevant investigations" line and the investigations/key-drug cards on the certificate screen removed (investigations print on page 2 only).
- Certificate hash includes a format number, so certificates printed before this release get a new version number when re-printed.

## Database (applied 27 Oct 2026, 13:51 IST, migration version 20261027082145)
- `migrations/R1.3.133-discharge-med-instructions.sql`: `ward_discharge_patient` keeps an `instructions` key (≤200 chars) per discharge medicine. Applied before this build was deployed.
- Fallback (server without the migration): the server drops the taper text, the app keeps it on the discharging device and shows "Taper / duration text was not saved on the server…". Other devices would print the frequency only.

sw VERSION: ward-sync-pwa-r1.3.133-dc-form-cert-format
