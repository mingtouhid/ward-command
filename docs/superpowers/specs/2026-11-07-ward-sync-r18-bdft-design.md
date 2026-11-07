# Ward Sync R1.8 bed distribution

Approved product for the native bed-distribution module. This is the behaviour to build. It keeps the reviewed distribution rules and changes only occupancy, permissions, the roster, and the Ward Sync interface.

## What stays the same

The physical bed is the unit. One resident owns each physical bed across every batch. A batch only groups owners for redistribution. Available owners keep the occupied beds already assigned to them. Only an unavailable owner's included occupied beds move, and they move inside that owner's batch, to the resident who currently holds the fewest occupied beds. An equal count prefers a resident who would not then hold an adjacent bed. Adjacency is the same label prefix and a number one higher or one lower. The remaining tie uses the configured roster order. There is no random choice, rotation, acuity, or backtracking.

If every resident in the batch is unavailable, or the bed has no owner, the bed stays visible and unassigned. It is never given to another batch by the algorithm. A person can move a bed across batches by hand. That move keeps the original owner. An adjacent move warns and can continue. Regenerating rebuilds from the default map, drops manual moves and undo, and asks first. There are no pinned assignments.

The current board stays until someone replaces it. It does not expire at midnight. Archives are read only. Seven archives are shown. Older rows stay in the database. A renamed bed does not rewrite a saved snapshot.

Tomorrow defaults to the next calendar date in India Standard Time, written as YYYY-MM-DD. India has no daylight-saving change, so the date does not depend on a device timezone rule.

## What is different

Occupancy is read from Ward Sync. Include and exclude change only the distribution input. They never change the patient or the bed census. A selection with no beds is an empty board. A blank or failed read is not treated as every bed. Offline and unknown snapshots cannot be published. Later admissions, discharges, and transfers do not reshape a published board. The screen shows that the census changed and offers an explicit regenerate.

Generation is allowed only while the signed-in resident has an open evening duty. The server reads that duty. The browser flag is not trusted. After publication, only the creator can edit, including after the evening shift has ended. Replacing the board ends that permission on the old version. An admin does not gain an edit bypass by being an admin. An admin can edit only when that admin is the authenticated creator. Roster setup stays an admin setting. Being the creator does not grant it.

Accounts, batch, short name, and the default bed owner live in the existing Users area. The module does not keep a second roster and does not infer a batch from senior, junior, or admin. No real roster or default ownership is imported. Disabled owners stay on the map and the affected beds are flagged.

Publishing is one action. There is no approval stage. Replacing the current board asks for confirmation. One current board exists. Saves carry a version. A stale edit or undo is rejected.

A successful generation queues one notice for residents and admins. Interns and consultants do not receive it. Ordinary edits do not. The distribution is still saved when the notice cannot be queued. This build does not send a push and does not create `ward_dispatch_anon_key`.

## Server checks

Every mutation uses the session token. The creator id cannot be supplied by the client. Included bed ids must be occupied beds in the catalogue. The server rebuilds the board from the default map, the absence list, and the included beds. It does not accept a finished board from the browser. The census tables are not written.
