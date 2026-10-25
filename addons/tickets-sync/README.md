# Tickets sync

Run `FM_HOME=<fleet-home> bash tickets-sync/install.sh` from merged main to register the existing watcher's poll; `--dry-run` writes nothing.
Requires Python 3.11+, gh-axi, tasks-axi, sign-off-axi and Firstmate's backlog libraries; the board comes from `config/fleet-board`.
Backlogs stay read-only: archive headings are normalized in retained copies under `state/tickets-sync/` before tasks-axi reads them.
Open work and seven days of completed work are backfilled by stable home/item hashes; lane status and linked GitHub PR state supply queued (0), building (30), review/CI (65), merging (90), and done (100) progress.
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
