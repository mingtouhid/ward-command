# R1.3.131 — Discharge certificate page 2: MSE + investigations on one page

- Page 2 of the discharge certificate now prints a compact **INVESTIGATIONS** block under the MSE: the latest value per test from this admission's lab reports (window: admitted − 2 days … discharged + 1 day, same as the page 1 "Relevant investigations" line), grouped by panel (CBC, KFT/RFT, Electrolytes, LFT, Sugar, Lipids, Thyroid, Drug levels, Urine R/E, Others), with the report date per panel (dd Mon) and an earlier date in brackets when a test is older than its panel.
  - Abnormal results are bold + underlined with the H / L / A flag; critical results are boxed (same key as the MSE). An earlier critical or differently-flagged value is shown as "earlier … · dd Mon" when space allows.
  - No reports: "No investigations recorded in Ward Sync this admission." Death / abscond with no reports: the block is left out.
- Page 2 is always **one A4 page**: the layout is measured first and stepped down a ladder (run-in labels, two-column short MSE rows, tighter spacing, "Within normal limits: …" grouping, normal lab values packed or counted, then hidden with a "+N more normal results not shown" note, then long notes shortened with "(shortened; full note in Ward Sync)"). Fonts never go below 8 pt. Header, summary box, key and signatures are always kept. MSE not recorded: 6–20 hand-written lines, as many as fit.
- Certificate preview: the "Also printed" note now says "Page 2 (one page): MSE + investigations" with the test/report count.
- Certificate version hash now includes page-2 investigations, so a certificate already printed for a patient **with** lab reports prints as a new version next time; patients without lab reports keep their hash.
- Small fix: no more stray ". ." at the end of a short general-appearance line.
- exportPatientRecord (clinical record PDF) is separate code and unchanged.
- No database change.
