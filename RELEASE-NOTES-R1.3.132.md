# R1.3.132 — Certificate: no countersign on page 2, no medication tags

- Discharge certificate page 2 (MSE + investigations) now has only **Signature of examining doctor** on the left; the right-hand signature line and "Countersigned by VP/VS/Registrar" are removed.
- Page 1 is unchanged: "Countersigned by VP/VS/Registrar" / "Case note prepared by" and the N.B. countersign footer stay.
- The page 2 one-page fit is unchanged (the signature row stays at the same height, so no extra vertical space is freed).
- The certificate version hash is unchanged, so certificates already printed keep their version number on re-print.
- Discharge certificate medications table: the "(new)" / "(changed)" tags after the medicine name are removed (no other status tags existed on the certificate). The tags stay in the clinical record / timeline ("Medications on discharge" list and its text copy), which is separate code. The certificate preview never showed them.
- Removing the tags does not change the certificate version hash.
- No database change.
