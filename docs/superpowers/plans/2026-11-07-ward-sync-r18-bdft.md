# R1.8 bed distribution plan

## Self-review

The approved rules are specific enough to implement without the original file. One owner per bed is a primary key, not a per-batch owner. The admin and the creator are different permissions and must stay that way. Empty occupancy is empty. Notices are queued, not sent. No roster is seeded.

## Build order

1. Put the date, adjacency, build, and manual-move rules in the app and test them outside the repository.
2. Add `migrations/r18_bdft.sql` and `migrations/r18_bdft.rollback.sql`. The compute function follows the same rules. Generation, move, undo, regenerate, read, and roster setup are privileged functions with a fixed search path and the session as the actor.
3. Add the More tile, the Home card, the distribution screen, and the Users link. Draw the board with text nodes. Desktop uses drag and drop. A select remains for keyboard and narrow screens.
4. Bump the app and the service worker to R1.8 together.
5. Run the migration forward, roll it back, and apply it again on a disposable database with synthetic rows. Exercise the permission and race cases there.
6. Capture synthetic screens. Copy the app and service worker hashes into the run artifacts. Do not merge or deploy.

## Notification limit

`bdft_queue_notice` inserts one `notification_events` row with dedupe key `bdft:<id>`. A duplicate key returns the existing row. A failure is caught and the distribution remains saved. Nothing in this repository calls the dispatch function. Push delivery stays blocked until a later, separately authorised deploy creates the missing anon key and the edge function is present.

## Rollback

The rollback drops the new tables, columns, and functions, deletes queued `bdft` notice rows, restores the previous event-type check, and restores the previous inbox function. It does not touch the census.
