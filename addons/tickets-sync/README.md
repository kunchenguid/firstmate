# Tickets sync

Run `FM_HOME=<fleet-home> bash tickets-sync/install.sh` from merged main to register the existing watcher's poll; `--dry-run` writes nothing.
Requires Python 3.11+, gh-axi, tasks-axi, sign-off-axi 0.6.9+ and Firstmate's backlog libraries; the board comes from `config/fleet-board`.
Backlogs stay read-only: archive headings are normalized in retained copies under `state/tickets-sync/` before tasks-axi reads them.
Open work and seven days of completed work are backfilled by stable home/item hashes; lane status and linked GitHub PR state supply queued (0), building (30), review/CI (65), merging (90), and done (100) progress, plus the matching `--stage` word and `--last-event-at` from the newest status `[at=]` stamp or backlog created/closed day (omitted when unknown).
Parked homes and held items stay On hold; completion clears hold.
Confirmed `parent: <item id>` wins even for captain-tagged work.
Unparented captain asks are roots, titled with their stored quote or plain recorded title; other work joins a unique same-project ask sharing a specific brief phrase, or the single fleet-wide `Not from your asks (fleet upkeep)` root.
Legacy placeholder records move under that root as earlier grouping history; internal home names are cleared from project fields.
Each poll uses a field-hash ledger and a 20-second cursor budget; mid-pass continue notes go to `state/tickets-sync/progress.log` (check stdout wakes Main). A finished pass with changes prints one summary; failures print on stderr. `sync.py --audit` runs the full ticket list separately.
Public titles cap at 160 characters and omit bookkeeping tags, priority prefixes and URLs; release and delivery PR use their own ticket fields.
Full request context is cached by source-file revision so truncated list bodies cannot hide a confirmed parent; the watcher budget also covers filling this cache.
Each real project name gets the dashboard's own local image (`fleet-dashboard/fm-dashboard/icons`) through `sign-off-axi project --icon`, only when it passes `identify` or the XML parser and the registry hash differs; missing or broken images are recorded in `state/tickets-sync/icons-skipped.json` without printing (check stdout wakes Main). Internal homes (`main`, `firstmate`, `herdr`, …) never become ticket projects.
Backlog completion, merged delivery PRs, and explicit `status: superseded|cancelled` notes or terminal lane events close tickets; URLs in free-form notes do not imply completion.
Use `sync.py --reconcile` to finish every registered home without the watcher budget; GitHub failures name their cause and stop the sync, and open PR state is refreshed after five minutes.
For an authorized board-only cancellation or supersession, use `sync.py --close HOME/ITEM --reason superseded|cancelled --reconcile`; the decision is retained in the sync state's `closures.json`, without editing the source backlog.
Explicit board completion survives a sync-state reset so a stale backlog cannot reopen cancelled work.
Grouping records publish zero raw progress; sign-off still derives their roll-up from children and owns hiding group percentages, collapsed placement, stage words and stale-event age.

## Writing a ticket at the moment it changes

The poll is a backstop, not the only writer. Firstmate's lifecycle calls `bin/fm-ticket.sh <task-id> [--stage W] [--state W] [--pr URL] [--release TEXT]` at dispatch (`building`), merge (`done` plus the delivered PR), cleanup (the retained PR) and a release cut; the fork-side shim validates the task, then hands `ticket.py` this home so the writer reads the same `config/fleet-board` the poll does.

`ticket.py` corrects an existing ticket in place: it writes only the fields that differ, so a repeated step appends nothing; `--state done` also sets 100%; it deliberately leaves `last-event-at` to the poll, which derives it from the real status stamps. It never creates a ticket — the poll owns titles, parents and the ask a ticket answers — so writing for a task with no published ticket, an absent writer, or a home with no fleet board is a silent no-op that exits 0. A real failure names its cause on stderr and exits 1, and every caller guards the call, so a board problem never fails a merge, a dispatch or a cleanup.

To cut a release, call the same shim with `--release <name>` for each ticket the release ships.

## The checks

`state/tickets-sync.check.sh` runs the poll; `state/tickets-stale.check.sh` runs `sync.py --check`. The second one reads every registered home and prints one line for each ticket whose state contradicts its own work — the board still says queued or in progress while the backlog item is closed and its PR merged, or the reverse — and for each `fm-` ticket left on the board that no home's work accounts for. It writes nothing, and silence means the board is true. Both are registered as Firstmate checks, so a disagreement wakes Main instead of waiting for someone to notice the count.
