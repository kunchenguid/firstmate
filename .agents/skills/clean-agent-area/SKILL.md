---
name: clean-agent-area
description: >-
  Use only when the captain explicitly asks to clean or free space in the agent area, or investigate low disk space there.
user-invocable: false
metadata:
  internal: true
---

# Clean agent area

## Hard rules

- Audit before any action; this skill only classifies and prescribes a process and never deletes, moves, truncates, or otherwise changes anything.
- Never remove unlanded work or remove an object before its references are understood.
- Record evidence at every step, including the paths, commands, output summaries, and verification results.
- Destructive actions require the captain's explicit authorization for the specific object and action.
- Clean only the smallest amount sufficient for the current need; do not sweep in bulk.
- Never use `--force` or forced deletion to bypass a guard.
- Pool-wide metadata inspection is allowed, but never read, copy, write, delete, move, or rename another worker's slot contents, or export sibling-slot paths or contents outside the private home.

## Trigger

- Load this skill only when the captain explicitly asks to clean or free agent-area space, or investigate an agent-area disk-space issue.

## Read-only audit

All audit commands must be read-only; do not run commands that clean, repair, reclaim, or otherwise change files or pool state.

Inventory these roots and record each candidate's path, size, owner, and most recent available use time; identify whether each timestamp is access or modification time and disclose platform limitations.

```sh
# 1. This Firstmate home's state and data. Resolve FM_HOME to the actual operational home first.
for root in "$FM_HOME/state" "$FM_HOME/data"; do
  [ -d "$root" ] || continue
  du -sh "$root"
  find "$root" -mindepth 1 -maxdepth 3 -type f -exec sh -c '
    for path do
      size=$(wc -c < "$path" | tr -d " ")
      if stat -c "%n | %s bytes | owner=%U | mtime=%y | atime=%x" "$path" 2>/dev/null; then :
      elif stat -f "%N | %z bytes | owner=%Su | mtime=%Sm | atime=%Sa" "$path" 2>/dev/null; then :
      else printf "%s | %s bytes | owner/time unavailable\n" "$path" "$size"; fi
    done
  ' sh {} +
done

# 2. Harness-owned data and caches: use only roots documented by the matching adapter references.
# Determine applicable harnesses from the current harness, explicit existing configuration,
# and installed executables documented by adapters. Inspect config/crew-harness and
# config/secondmate-harness when present; resolve the current harness with the repository's
# bin/fm-harness.sh. Read the adapter references to identify supported executable checks, then
# check those executables read-only. For each installed/configured harness, read only its
# references/harness/<name>.md and use its documented home/volatile-directory paths and
# active-session checks. pi-signed uses the pi reference. Do not infer vendor defaults or
# treat an adapter's mere presence as proof that its harness is installed.
# Inventory only documented roots, using metadata (path, size, owner, timestamps) without
# opening file contents. Include documented session records, installed plugins, and config
# snapshots. If a harness-owned directory is encountered without a matching adapter reference
# that documents its ownership/location, report it as unknown; do not guess or omit it.

# 3. Isolated-copy pool: request the supported aggregate metadata view only.
if command -v treehouse >/dev/null 2>&1; then treehouse status; fi
```

The platform-specific `stat` forms are attempted as alternatives; if neither works, the portable byte count is retained and unavailable metadata is explicitly reported.

The pool status view may expose metadata for all slots, including identifiers, paths, sizes, state, holder processes or owners, and timestamps; do not recursively inventory slot contents. Use task records and service inventories to establish ownership and references, never infer eligibility from age or a directory name alone. Metadata alone is insufficient to propose cleanup of another worker's slot; refer its disposition to the captain without exporting its path outside the private home. The metadata-only harness audit includes documented harness-owned session records, installed plugins, and configuration snapshots; sibling-slot contents remain forbidden to read, copy, write, delete, move, or rename, and sibling paths/content must not be exported outside private home.

## Three-state classification

“Unconditionally cleanable” describes only an item without references that can be regenerated; it does not authorize deletion. The captain must still explicitly authorize every destructive action.

| Object | Classification | Decision and checks | Suggested action |
| --- | --- | --- | --- |
| `state/.watch-triage.log` | Unconditionally cleanable | Firstmate's operational-home layout identifies this size-capped absorbed-wake debug log as unused and safe to delete; preserve the audit record of its observed size. | May be proposed as a minimal candidate; deletion still requires the captain's specific authorization. |
| Scratch or temporary items inside a finished task's `data/<id>/` | Conditional cleanup | Verify the task is finished and each item is scratch or temporary with no references; preserve `report.md` and investigation evidence. | Propose only individually verified items. |
| `state/.<id>.open-decisions-cursor` | Unconditionally cleanable | Deleting the cursor causes one full open-decision re-fold and loses no decision state. | May be proposed with the one-time recomputation cost disclosed; deletion still requires the captain's specific authorization. |
| Firstmate-created temporary demonstration artifacts | Conditional cleanup | Verify Firstmate ownership, temporary demonstration purpose, and absence of references. | Propose only individually verified artifacts. |
| Documented harness-owned session records, installed plugins, and configuration snapshots | Conditional cleanup | Use the matching adapter reference's active-session checks; verify the item is not needed by a live session, current harness configuration, or installed plugin, and that its purpose and references are understood. If any check cannot be established from the adapter reference and current metadata, classify it as unknown/prohibited and ask the captain. | Propose only individually verified items; never infer eligibility from age or size. |
| `state/*.status` and `state/*.meta` | Conditional cleanup | Only task teardown may remove these as part of finishing a task under `bin/fm-teardown.sh`; never manually delete active-task records, because byte-offset presentation cursors refer to them. | Leave lifecycle cleanup to teardown. |
| A complete `data/<id>/` directory | Conditional cleanup | Verify both that the task is finished and that its deliverables are archived elsewhere; otherwise do not remove the directory. | Propose only after recording the archive location. |
| A dirty isolated-copy pool slot | Conditional cleanup | Do not prescribe a destruction command. Present the evidence and let the captain decide disposition; never disturb an in-use or leased slot or another worker's sibling slot. | Escalate that specific slot's disposition to the captain. |
| Firstmate's no-mistakes data | Conditional cleanup | Evaluate only when the daemon is idle and no run is active; the daemon is managed by Firstmate and must not be bypassed. | Refer the assessment and any action to Firstmate. |
| `state/pending-replies/expired/` | Conditional cleanup | Confirm every associated task is finished; an active or unidentified task association prohibits cleanup. | Propose only entries tied to finished tasks. |
| `state/<id>.inbox/handled/` | Conditional cleanup | Confirm the associated task is finished; an active or unidentified task prohibits cleanup. | Propose only entries tied to finished tasks. |
| Watcher internals: `.hash-*`, `.count-*`, `.stale-*`, `.stale-since-*`, `.churn-since-*`, `.paused-*`, `.wedge-escalations-*`, `.dead-reported-*`, `.writing-*`, `.waiting-*`, `.seen-*`, `.hb-surfaced-*`, `.last-*`, `.heartbeat-streak`, `.secondmate-liveness-*`, `.watch.lock`, `.wake-queue*`, `.watcher-down`, and `.startup-network.*` | Prohibited | These are watcher or startup-supervision state. | Never propose cleanup. |
| Any other operational-home state entry that its layout marks “never touch” | Prohibited | This includes supervisor records, leases, session locks, and state locks not named in the rows above; the operational-home layout is authoritative for that inventory. | Never propose cleanup; see `.agents/skills/operational-home-layout/SKILL.md`. |
| `state/.branch-outcomes*` and their cursors | Prohibited | These hold durable supervision outcomes and processing position. | Never propose cleanup. |
| `state/.status-presentation-cursor` | Prohibited | It maintains fleet-wide status-presentation offsets and identity. | Never propose cleanup. |
| `state/.afk-contract` and `state/.afk` | Prohibited | These are durable away or quiet delegation records. | Never propose cleanup. |
| Leased or in-use isolated-copy slots | Prohibited | A task or lease occupies the slot. | Never propose cleanup or alter the slot. |
| Any `state/` or `data/` record belonging to an unfinished task | Prohibited | It may contain active work, deliverables, decisions, or references. | Never propose cleanup. |
| `data/captain.md`, `data/captain-shared.md`, `data/learnings.md`, `data/secondmates.md`, `data/projects.md`, and `data/backlog.md` | Prohibited | These are durable preference, knowledge, registry, or queue records. | Never propose cleanup. |

The supported task-close lifecycle is owned by `bin/fm-teardown.sh`, and the operational-home layout is documented in `.agents/skills/operational-home-layout/SKILL.md`; this skill adds a captain-authorized, cross-area triage that classifies references and retention before any action, which those owners do not provide.

## Process

1. Perform the read-only audit of the applicable roots and record each candidate's path, size, owner, latest-use evidence, and evidence source.
2. Apply the three-state table; record each required check, and treat failed or uncertain conditions as prohibited.
3. Give the captain a table with columns “path / size / owner / classification / deletion conditions / suggested action”; show only Firstmate-owned candidates and keep sibling-slot identifiers and paths within the private home.
4. Present the audit and recommendations to the captain; stop without changing anything, even when the captain authorizes a specific object and action.
5. If the captain authorizes cleanup, provide the authorized executor with the minimum backup, verification, and action procedure; the captain or designated executor performs it, not this skill.
6. Do not expand an authorization to adjacent objects or bulk cleanup.
7. Ask the captain or executor to verify before-and-after byte counts and that relevant services and processes remain alive; do not claim the result yourself without their evidence.
8. Record only the reported outcome, measured space change, untreated items, and available rollback method; distinguish unverified reports from observed evidence.

## Examples of what not to do

- Treating dirty pool slots as bulk trash can destroy another worker's unlanded work.
- Removing an unfinished task directory as a housekeeping habit can lose task records, evidence, or deliverables.
- Bypassing guards with forced deletion can destroy data or interrupt active services.
- Claiming a measured space reduction without before-and-after verification turns an estimate into a false result.
