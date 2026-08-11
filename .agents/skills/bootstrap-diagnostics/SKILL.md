---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, MAIN_DIVERGED, SELF_UPDATE, SELF_UPDATE_BLOCKED, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, PR_CHECK_MIGRATION, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, MISSION_CONTROL_STALE, or FMX - or when a standalone bin/fm-bootstrap.sh run prints one of those lines, or when bin/fm-pr-merge.sh prints a SELF_UPDATE or SELF_UPDATE_BLOCKED line right after a firstmate-repo merge.
  A silent bootstrap section, or a BOOTSTRAP_INFO fact, means no skill load.
user-invocable: false
metadata:
  internal: true
---

# bootstrap-diagnostics

Handle each printed line as below, before dispatching work that depends on it.
The line formats themselves are owned by `bin/fm-bootstrap.sh`'s header; this playbook owns the response to actionable lines.
The inline rules in `AGENTS.md` section 3 still bind: detect, then consent, then install - never install anything the captain has not approved in this session - and no work is dispatched until the tools it needs are present and GitHub auth is good.
When any diagnostic needs captain attention, report the plain consequence and requested action using `AGENTS.md` section 9's captain-facing translation contract; do not name the diagnostic label unless the captain needs to paste it into a command or issue.

- `MISSING: <tool> (install: <command>)` - list the missing tools to the captain with a one-line purpose each plus the printed install commands, wait for consent (one approval may cover the list), then run `bin/fm-bootstrap.sh install <approved tools...>`.
  For `treehouse`, this also covers an installed version whose `treehouse get` lacks `--lease`; treat it as an upgrade request.
  For `no-mistakes`, this also covers an installed version older than 1.31.2, because crewmate validation briefs delegate gate mechanics to no-mistakes' version-matched guidance.
  For any axi-family tool - `gh-axi`, `lavish-axi`, `tasks-axi`, `quota-axi` - an installed version below its floor is a plain upgrade request; [`bin/fm-bootstrap.sh`](../../../bin/fm-bootstrap.sh) owns the floor policy, and never argue the floor down to whatever the home happens to have installed.
  For `tasks-axi`, this additionally covers an installed build that fails the separate feature probe (`bin/fm-tasks-axi-lib.sh` owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because firstmate reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated change to which branch the primary has checked out, and it is a non-destructive branch switch that strands nothing; the fetch-and-fast-forward writes `/updatefirstmate` already makes to the primary, and the `git -C <root> fetch origin` printed by the `MAIN_DIVERGED` bullet below, are separately sanctioned.
- `MAIN_DIVERGED: <remediation>` - the primary checkout's local default branch carries commits `origin/<default>` does not, so neither the automatic primary fast-forward nor `/updatefirstmate` can reconcile it and both decline to advance it.
  This session-start diagnostic owns the report for divergence already visible before the automatic fetch; the automatic fast-forward stays silent for that case to avoid reporting the same problem twice.
  This usually means a shared fix landed directly on the local default branch instead of through the normal PR path.
  The check function never fetches, so it compares against a possibly stale `origin/<default>`; run the printed `git -C <root> fetch origin` first, because a refreshed ref alone can clear the report when the local-only commits are in fact already upstream.
  If the divergence survives that fetch, inspect the printed `git log origin/<default>..<default>` command to see what only exists locally, then reconcile manually - rebase or merge the local default branch onto `origin/<default>`, or open a PR to land the local-only commits upstream - before rerunning `/updatefirstmate`.
  This is a report only; do not attempt an automatic fix, and do not force-push, reset, or discard the locally-diverged commits without the captain's explicit authorization per `AGENTS.md`'s destructive-action boundary.
  In a read-only session that did not get the fleet lock, the same line is advisory and omits the `git fetch origin` instruction, leaving refresh and reconciliation to the session holding the fleet lock.
- `SELF_UPDATE: <ff_target detail>; re-read AGENTS.md now` - the primary checkout was already fast-forwarded to origin (a merged firstmate PR), and that fast-forward changed `AGENTS.md`, `bin/`, or `.agents/skills/`. Printed either by bootstrap's own cadence sweep, or by `bin/fm-pr-merge.sh` immediately after it merged that same firstmate-repo PR - same function, same meaning either way.
  Re-read `AGENTS.md` now, in this session, before relying on it further; this is the same "did the running firstmate's instructions change" signal `/updatefirstmate` reports as `reread-firstmate: yes`, just delivered automatically instead of by hand.
  No captain action is needed - report only if the changed instructions materially affect work already under way.
- `SELF_UPDATE_BLOCKED: <ff_target detail>; <consequence>` - the automatic fast-forward could not advance the primary checkout (dirty working tree, a divergence this fetch just revealed, a missing base, or a failed merge), so a merged firstmate PR has not reached this home yet, and anything it locally serves - including a Mission Control board - may still be running stale code. Printed either by bootstrap's own cadence sweep, or by `bin/fm-pr-merge.sh` right after it merged that same firstmate-repo PR - same function, same meaning either way, and the merge itself is never affected by the report.
  Report the plain consequence to the captain per `AGENTS.md` section 9, then resolve the named reason (commit or stash the local change, or reconcile a divergence per the `MAIN_DIVERGED` bullet above) and rerun session start to confirm it clears.
  Do not force, stash, or reset to clear it without the captain's explicit authorization.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home` - the non-executing migration rebuilt canonical task polls from validated metadata, and those polls are already armed.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: validated replacement polls armed; resume supervision for this home` - a retry proved canonical publication provenance, metadata identity binding, and single-link integrity for a replacement poll resolving an earlier ambiguous migration outcome.
  Independently verify the private per-task outcome record, then resume the emitted supervision protocol after finishing the session-start wake handling.
- `PR_CHECK_MIGRATION: quarantined polls remain unarmed; review state/.pr-check-migration.log before rearming` - one or more ambiguous or invalid task polls were quarantined without execution and remain unarmed.
  Read the private mode-`0600` per-task outcome record, verify the task's recorded PR independently, and rearm only through `bin/fm-pr-check.sh` with canonical inputs.
- `PR_CHECK_MIGRATION: migration completed safely; resume supervision for this home` - migration crossed the update boundary without rebuilding or quarantining a task poll after pausing the prior watcher.
  Resume the emitted supervision protocol after finishing the session-start wake handling.
- Any other `PR_CHECK_MIGRATION:` refusal means migration did not complete safely, whether because watcher exclusion, a private path, a diagnostic, quarantine validation, or marker publication could not be proved.
  Keep each affected poll unavailable, inspect the named private state path, and do not bypass the migration or execute a quarantined artifact; a completed safe-scan marker allows unrelated authenticated polls to continue while private repair remains pending.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - secondmate convergence left a live home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing its placement-specific target commit, unreachable, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>` - the session-start liveness sweep could not guarantee that the registered secondmate is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox.
  Preserve that outbox and rerun `bin/fm-backlog-handoff.sh --resume-pending` after same-host connectivity returns; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - secondmate convergence changed a running home's loaded instructions or inherited config, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `MISSION_CONTROL_STALE: board last rendered <timestamp> (age <seconds>s, threshold <seconds>s); refresh its local generator` - the captain opted in to monitoring a local Mission Control board, and its proved render timestamp is older than the configured threshold.
  Refresh or restore the local generator that owns that board, then rerun session start to confirm it has become current.
  Do not treat an absent diagnostic as proof that the board is healthy: this convenience check stays intentionally silent for unreadable, malformed, future-dated, or otherwise unprovable targets.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts (`docs/configuration.md` "X mode (.env)").
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
