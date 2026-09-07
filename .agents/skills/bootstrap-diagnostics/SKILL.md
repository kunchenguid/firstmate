---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH, FLEET_SYNC, NETWORK_CHECKS, HOME_SUMMARY, BACKLOG_RECONCILE, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, or FMX - or reports that an interrupted backlog cleanup may have left an endpoint or local copy, or when a standalone bin/fm-bootstrap.sh or bin/fm-startup-network.sh run prints one of those lines.
  A silent bootstrap section, or any other BOOTSTRAP_INFO fact, means no skill load.
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
  For `no-mistakes`, this also covers an installed version older than 1.46.0, because this repo's PR gate requires structured pipeline attestation that older builds do not write.
  For any axi-family tool - `gh-axi`, `lavish-axi`, `tasks-axi`, `quota-axi` - an installed version below its floor is a plain upgrade request; [`bin/fm-bootstrap.sh`](../../../bin/fm-bootstrap.sh) owns the floor policy, and never argue the floor down to whatever the home happens to have installed.
  For `tasks-axi`, this additionally covers an installed build that fails the separate feature probe (`bin/fm-tasks-axi-lib.sh` owns the definition); `config/backlog-backend=manual` only suppresses the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not this missing-tool report.
  For `quota-axi`, bootstrap requires it because firstmate reads its current output directly before resolving every crew-dispatch profile array; without it, report the missing requirement and do not choose around an unexamined candidate.
- `MISSING_MANUAL: <tool> (instructions: <url>)` - tell the captain why the tool is required and give them the printed instructions URL, but do not pass the tool to `bin/fm-bootstrap.sh install`; wait for the captain to complete the manual installation, then rerun session start to confirm the dependency is present.
- `BACKEND_INVALID: <name> (known: <names>)` - the resolved runtime backend has no verified dependency or lifecycle contract, so do not dispatch work until the invalid `FM_BACKEND` or `config/backend` value is corrected to one of the listed backends.
- `NEEDS_GH_AUTH` - ask the captain to run `! gh auth login` (interactive; you cannot run it for them).
  This probe now arrives from the deferred network stage, so it is also how an unreachable network shows up: `gh` cannot validate its token offline and reports the same failure. Confirm reachability before asking the captain to re-authenticate a credential that may be fine.
- `NETWORK_CHECKS: <what did not complete>; rerun <command>` - the deferred network stage itself could not finish, so the checks it names are simply unknown, not failed.
  Rerun the printed command; it is idempotent and re-derives every finding.
  A `hit the ...s bound` line means one of those checks is slow or unreachable - most often a remote secondmate host - and the stage stopped rather than letting it wedge; a `lock was no longer held` line means the session that asked for the sweeps no longer owns them, so leave them to the session that does.
- `TANGLE: <remediation>` - the primary checkout is stranded on a feature branch instead of its default branch; `AGENTS.md` section 8 explains why this guard exists and what it protects.
  The work is safe on that branch ref; restore the primary to its default branch with the printed `git -C <root> checkout <default>`, then re-validate that branch in a proper worktree.
  This is the only sanctioned firstmate-initiated git write to the primary, and it is a non-destructive branch switch that strands nothing.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, invalid harness/effort pair, or malformed Codex home rather than falling back around it or selecting a bad profile.
- `CREW_DISPATCH: codex home unavailable: <path> - <reason>` - the file is valid and only that one Codex home is unusable on this machine (never created, or logged out).
  This is per-candidate eligibility evidence, not file-wide invalidity: treat every candidate naming that home as ineligible and keep dispatching every other profile, including the other Codex account's candidates and rules that name no home.
  Restore the account with the printed `CODEX_HOME=<path> codex login`, or drop that candidate from `config/crew-dispatch.json` if the account is gone for good.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `HOME_SUMMARY: this home has never published state/home-summary.json` or `... has not been republished since <stamp>` - this home's structured summary publication has failed repeatedly, and the line carries the failure count and the newest recorded reason from `state/.home-summary-refresh.log`.
  Publication is deliberately best-effort, so it cannot change another session-start, spawn, teardown, or watcher-poll result, and the watcher runs it detached so a slow attempt cannot delay the liveness beacon.
  Read the named record for the recorded reasons, then reproduce with a direct `bin/fm-home-summary-refresh.sh` (no `--best-effort`, which is what keeps the failure quiet) so the refresh error reaches you.
  A recorded deadline means the complete refresh did not finish inside `FM_HOME_SUMMARY_TIMEOUT`, so inspect lock acquisition and producer completion before validation or publication, and fix the blocked phase rather than raising this load-bearing bound.

- `BOOTSTRAP_INFO: closed the backlog item for <id> after interrupted cleanup; its endpoint or local copy may remain and should be reconciled` - replay closed the item, but the durable transition says physical cleanup was interrupted.
  Verify process reaping, the local-copy return, and endpoint closure, then reconcile any surviving resource.
- `BOOTSTRAP_INFO: kept the captain call for <id> open with its deliverable recorded after interrupted cleanup; its endpoint or local copy may remain and should be reconciled` - replay retained the captain-held item, but physical cleanup was interrupted.
  Verify process reaping, the local-copy return, and endpoint closure without closing or lifting the captain's call, then reconcile any surviving resource.
- `BACKLOG_RECONCILE: <id>: recorded backlog close could not be replayed: <reason>` - this session start found a pending-close record carrying a close or retention transition but could not land it.
  A valid teardown record proves the transition was authorized and recorded, but physical cleanup may be partial: verify process reaping, the local-copy return, and endpoint closure before assuming those resources are gone.
  A validation error means the record cannot be trusted, so do not assume cleanup completed or follow any path or argument stored in it.
  Read the named reason, inspect the marker as inert data when validation failed, fix the record or backlog-file problem, and rerun session start so the valid recorded transition replays.
  Never delete `state/<id>.backlog-close` by hand - that can discard a completion link or captain-call retention the cleanup captured, and the surviving marker prevents the record sweep from starting the item meanwhile.
- `BACKLOG_RECONCILE: <id>: worker record exists but its backlog item could not be read: <reason>` - this home could not determine whether the item matches its worker record.
  Resolve the named backlog read problem and rerun session start; never guess by starting or closing an unreadable item.
- `BACKLOG_RECONCILE: <id>: worker record exists but its backlog item could not be moved to In flight: <reason>` - this home owns a worker whose backlog item is still queued, and the reconciliation could not correct it.
  Until it is corrected, the fleet view reads that worker as work no backlog item owns; resolve the named backlog problem and rerun session start.
- `SECONDMATE_SYNC: secondmate <id>: skipped: <reason>` - secondmate convergence left a live home on its existing checkout because the home was dirty, diverged, unsafe, on the wrong branch, missing its placement-specific target commit, unreachable, or otherwise not fast-forwardable, or because inherited local-material propagation failed; bootstrap continued, but inspect the reason because the secondmate's tracked instructions, inherited settings, or shared captain preferences may be stale after a primary update.
- `SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>` - the session-start liveness sweep could not guarantee that the registered secondmate is running a real agent process.
  Investigate the reason because that secondmate is not guaranteed live.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox, pending backlog receipt or receiver-wake confirmation.
  Preserve that outbox and rerun `bin/fm-backlog-handoff.sh --resume-pending` after the route or endpoint problem is resolved; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - secondmate convergence changed a running home's loaded instructions or inherited config, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local Relay poll artifacts (`docs/configuration.md` "Relay (.env)"); the emitted line still carries Relay's former `X mode` wording.
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
