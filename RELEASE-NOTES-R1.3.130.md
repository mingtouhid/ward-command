# Ward Sync R1.3.130 — date-only investigations form + no long-press selection

App-only release (index.html + sw.js). No database change. It builds on R1.3.128 and the R1.3.129 save fix, which are already live.

## Add investigations form
- The Pathology/Biochemistry toggle, the "Collected" date/time and "Sample no." have been removed.
- The only header field is "Report date as printed" (required, date only, no time). It sits above the panel chips and cannot be set in the future.
- The date is stored in reported_at as 00:00 IST of that day (no DB change). All date maths uses IST, so the day never shifts to the previous or next day on any device.
- Every report, including older ones saved with a time, now shows the date only: list, timeline, critical-alert text, record PDF, certificate line and the latest-investigations card.
- Reports on the same date are ordered by when they were saved.
- New reports leave out department, sample_no and collected_at. The DB stores department = 'other' (the column default) and nulls for the other two.
- Older reports still show their Pathology/Biochemistry and sample details in the list, timeline, PDF and critical-alert text.
- Editing an older report keeps those hidden values unchanged, so no spurious edit diff is recorded.
- The duplicate check now matches on the same report date plus overlapping panels. It warns with "Save anyway" and never blocks.
- Editing an older timed report without changing its date keeps the original timestamp, so no "report time" diff is logged.
- Drafts saved by R1.3.128 load cleanly. Their dept, collected and sample fields are dropped; the date part of the report time and the values are kept.

## Long press / text selection
- Selection and the long-press callout are off app-wide (html, body, every element, ::before and ::after), including modals and other content that renders later.
- Only real editable fields allow selection: text-type inputs, textarea and contenteditable.
- The old `user-select:auto` override on open sheets was removed.
- JS safety net: selectstart and contextmenu are cancelled outside editable fields, and any stray selection is cleared on selectionchange.
- Typing, caret placement, paste and in-field selection still work.
