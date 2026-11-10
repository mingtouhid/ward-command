# Resident setup and original BDFT appearance

Approved on 7 November 2026 at 18:53 IST. This is the written specification for a later build. It does not change the application, the database, or the running scheduler.

Baseline is production main `d7f8d749d3f09658b03587a144e4d4439eca2c69` (R1.8). The visual reference is the sanitized static pages `generation-and-card.html`, `compact-bed-grid.html`, and `original-styles.css`. Those pages contain no credentials, no real staff, and no scripts. The department line on the published card is exactly:

Department of Psychiatry, AMCH, Dibrugarh

## What this does

An admin opens one expandable form on the existing user card in Users. The form is the only place that sets a person's account and their bed-distribution settings. There is no second roster page.

For a resident or an admin, the form has eight fields, in this order:

1. Username
2. Display name
3. Mobile number
4. Password
5. Role
6. Beds owned
7. Batch
8. Short name

Batch is exactly one of `1st year`, `2nd year`, or `3rd year`. Those three strings are the only new batch values the form can write. Beds owned opens the original compact bed grid. One Save writes the account, the role, the short name, the batch, and the bed ownership.

Interns and consultants do not get batch, short name, or beds. A consultant keeps the existing designation field and does not get a mobile number. An intern does not get a mobile number. Those omissions match the current account form and the server rule that an intern, a consultant, or a viewer cannot own a bed.

An account stored as SR is already treated as an admin by the app, so that person sees this form. An admin can open it whether or not they are signed in for the evening shift, whether or not they created the current distribution, and whether or not a distribution exists. Opening it does not allow that admin to edit a published distribution they did not create.

## What stays as it is

The server still decides the distribution. One physical bed has one owner. Available owners keep their included occupied beds. Only an unavailable owner's included occupied beds move, inside that owner's year, to the resident with the fewest occupied beds. An equal count prefers no adjacent bed, then the configured roster order. There is no random choice, rotation, acuity, or backtracking. A year with nobody available, or a bed with no owner, stays visible and unassigned. A manual move may cross years, keeps the original owner, warns on an adjacent bed, and can continue. Regenerate rebuilds from the default map and drops manual moves only after confirmation.

Generation still requires an open evening duty on the server. After publication, only the creator can edit, including after the shift ends. Replacing the board ends that permission on the old copy. Archives stay read only. Seven archives are shown and older rows are kept. Bed labels on a saved snapshot do not change when a bed is renamed. Occupancy include and exclude never write the census. An empty selection is an empty board. A later admission or transfer does not reshape a published board.

The notice, the deep link `./#/bdft/<id>`, the recipient rules, and `dispatch-bdft` stay as released. This work does not change the Vault credential, the cron job, or the clinical dispatcher.

Disabled owners stay on their beds. Those beds are flagged and are not counted as valid cover. Another resident cannot take a disabled owner's bed. Existing accounts and existing bed assignments remain. A username change updates the same resident id and does not move beds.

## Account, phone, and password

Password is never read back and never shown. On an existing account the field is empty. Leaving it blank keeps the current password. Typing a new password is an explicit replacement and still requires at least six characters. Creating an account still requires a password.

Mobile stays on the current privacy calls. The admin form does not display the stored digits. It shows only whether a number is saved. A blank mobile field on edit does not change the stored number. Removing it remains an explicit action, the existing Remove control, not a blank Save. A typed number must still be a 10-digit Indian mobile beginning 6–9 and is stored as `+91`. Consultants and interns are not given this field. The resident's own "My phone" screen is unchanged and is the only place that person sees their own number.

Username, display name, and role continue to use the current admin account calls. The signed-in admin still cannot change their own role. The resident id is the owner key. The implementation must keep that id when the username changes. If the existing account call cannot be shown to keep the id, the bed write is refused rather than copied onto a new id.

## Beds owned

Beds owned opens the original compact grid as a dialog: 560px and centered on a desktop, a bottom sheet on a phone, section labels, tiles at least 65px wide with an 8px gap, the active tile treatment, and Done. The tiles are the live beds, grouped by the ward's own sections in ward order. The sample labels in the static reference (M1, F15, and the rest) are not a second bed list and are not imported.

In this form the dialog title is Beds owned. On the generation screen the same grid is titled Occupied Beds, as in the reference. Selecting a free bed, or a bed this resident already owns, only changes the pending form. Selecting a bed owned by another active resident shows that owner's short name, or display name if there is no short name, and asks before the transfer is added to the pending form. Cancelling leaves the bed with its owner. Confirming records a pending reassignment. It is not written until Save. A disabled owner's bed is shown and cannot be selected.

## One Save

Everything visible is checked before any write. A missing username or display name, a short password, an invalid mobile number, a newly chosen batch outside the three year labels, an intern or consultant given beds, or a bed transfer that was not confirmed, blocks the Save. Nothing is written. An untouched legacy batch is not a validation error and is not sent as a change.

Account, role, short name, batch, and bed ownership are written in one database transaction where the current account call and the bed tables can be reached together. The phone number stays on `ward_set_resident_phone`, because that call is the privacy boundary: it does not return the digits to the admin screen. That call is not inside the account transaction. The screen must not say the whole Save succeeded if the phone call fails. The message names what was saved and says the phone was not. A failed account or bed write does not attempt the phone call. Leaving the form without Save drops the pending bed selection and does not change the server.

There is no distributed transaction across the phone call and the database. That limit is stated here so a later build does not invent one.

## Existing batch text

`bdft_batch` is free text today. A value that is not exactly `1st year`, `2nd year`, or `3rd year` stays stored and is shown on the form as the current label. It is not rewritten, cleared, or guessed from a year number, a role, or a nickname. Save of the other fields does not send a blank batch over that label. The year control writes one of the three labels only after the admin explicitly picks it. Until then, redistribution keeps using the stored text as that resident's group.

## Generation and the published card

The generation screen and the published card follow the sanitized reference, not the current native cards.

The screen shows BDFT with the v7.0 badge and the department line used in that reference header, Department of Psychiatry, AMCH. Tomorrow is the next calendar date in India Standard Time, computed with no daylight-saving rule, and shown as a day and a short month, for example 8 Nov. The stored date remains the full `YYYY-MM-DD`. There is no date picker. Beside it are three counts from this generation, not from the ward duty roster. On Duty is how many roster residents are not marked unavailable. Unavailable is how many are marked unavailable. Beds Assigned is how many occupied beds are included. Evening duty remains only the permission to publish. Two actions open the original selectors: Mark Occupied Beds uses the compact grid, prefilled from the live occupied beds and changing only the distribution input; Mark Unavailable uses short-name tiles grouped by the three years, with Mark Batch and Unmark Batch. People whose batch is still an unmatched legacy label are listed under that label and are not silently moved into a year. Generate for Tomorrow is the full-width primary action.

Generate for Tomorrow does not call the server and does not queue a notice. It shows a local preview from the same pure rules the server uses. Leaving the page discards the preview. There is no draft row.

Finalise & Save is the existing publish, `ward_bdft_generate`. The server recomputes the board from the occupancy and the absence list. The card is then the server result, not the preview, if the two differ. That call is the only moment a notice is queued. It still requires the evening duty and the replacement confirmation when a current board exists. It does not create an earlier push.

The published card uses 32px and 24px padding, a centered 28px heading `BDFT — 8 Nov` with that same day-and-month form, and the subtitle Department of Psychiatry, AMCH, Dibrugarh. Three year columns collapse to one column at 768px. Each year has its heading, a count of people, and remove-batch. Each person has a 44px circular short name, green for 1st year, purple for 2nd year, and blue for 3rd year, matching the reference avatar colours. An unmatched legacy batch uses the muted text colour and is not given a year colour. Then come wrapped bed tags. An original bed is teal, a redistributed bed is amber, and an adjacent conflict is red. A person with no beds shows Happy Day. That is only a display of an empty holding. It is not a new assignment rule. Beds with no holder, and beds whose owner is disabled, stay in the Orphan Beds pool and are not counted as cover. There is no legend.

Remove person and remove-batch appear only on the published card, and only for the creator. Remove person moves that person's held beds to the orphan pool through the existing manual move. The original owner is kept, an adjacent warning still applies, and undo still works. Remove-batch does the same move for every bed currently held by residents in that year. It does not change default ownership, does not mark the year absent, and does not run the algorithm again. Neither control appears on the unsaved preview, because there is no published row to move yet.

Export still omits patient names and diagnoses. It hides the bottom bar and the remove controls and paints the tag colours as solid equivalents of the reference mixes. It does not add a network font or a capture library.

The theme gallery in the reference stylesheet is not imported. The card uses the Ward Sync theme already selected in the app, with the reference avatar and tag colours expressed in that theme.

The reset icon on the original header does not clear a published board. In this app it opens the existing replace confirmation. It does not publish by itself.

## Tests to run when this is built

Use synthetic names and beds only. Do not use a real roster, a real phone number, or a patient record.

- An admin opens the form with no evening duty and with no current distribution, and can save a short name, a year, and a bed.
- An admin who did not create the current board can save setup and cannot move a bed on that board.
- Create requires a password. Edit starts with an empty password field and a blank Save keeps the old password.
- Admin mobile edit shows no digits. Blank Save keeps the number. Remove clears it. A bad number saves nothing. A phone failure after the account write says the phone was not saved.
- An intern and a consultant form have no batch, short name, or beds, and the server still rejects them as owners.
- Changing a username keeps the same resident id and the same beds.
- Choosing another resident's bed shows that owner and does nothing until confirmed. A disabled owner's bed cannot be taken.
- A stored batch of `2024` remains `2024` until the admin picks a year. Saving the display name does not clear it.
- Generate for Tomorrow shows a preview and creates no distribution and no notice. Finalise & Save creates one current distribution and one notice, and the card matches the server rows.
- The preview has no remove controls. After publish, the creator can remove one person and one year, the beds become orphans, the original owners stay, and a non-creator does not see the controls.
- Happy Day appears for a person with no held beds. A disabled owner's occupied bed appears in Orphan Beds and is not counted in a year total.
- Tomorrow across 23:30 IST and across 31 December shows the next India date, displayed as day and short month, stored as a full date.

Screenshots, synthetic only: desktop 1440 and mobile 390 of the expandable form, the bed grid with one owned bed and one confirm-transfer, the generation tiles, the preview, and the published card with one Happy Day and one orphan. No real names.

## Release note for the later build

The later build needs its own migration rollback in the existing convention if it adds a constraint or a narrower save call. It must not change `dispatch-bdft`. On the eventual release, the monthly-archive copy of the app core has to be regenerated from the new `index.html`, because that archive embeds the app and will otherwise keep the old screen. This specification does not perform that refresh.

## Self-review

No placeholder owner, phone number, or bed list is left for a builder to invent. The three year strings, the card subtitle, and the header department line are fixed from the sanitized reference.

On Duty is defined as a count of this generation, so it is not confused with the evening-duty permission. The form dialog and the occupancy dialog keep different titles so the same grid is not used for two meanings.

The form, the preview, and the published card are separated so a visual match does not add a draft or an early notice. Remove controls are defined as existing moves, so they do not add a redistribution rule.

The phone call is deliberately outside the account transaction. The spec says the screen must name that partial failure. A builder cannot honestly report one atomic Save across that privacy call.

Unmatched old batch text is preserved on purpose. The open questions from the design review are closed in the sections above.
