---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, CREW_DISPATCH invalid, FLEET_SYNC, NETWORK_CHECKS, HOME_SUMMARY, BACKLOG_RECONCILE, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NUDGE_SECONDMATES, FMX, or WORKTREE_COLLISION - or reports that an interrupted backlog cleanup may have left an endpoint or local copy, or when a standalone bin/fm-bootstrap.sh or bin/fm-startup-network.sh run prints one of those lines.
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
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `HOME_SUMMARY: this home has never published state/home-summary.json` or `... has not been republished since <stamp>` - this home's structured summary publication has failed repeatedly, and the line carries the failure count and the newest recorded reason from `state/.home-summary-refresh.log`.
  Publication is deliberately best-effort, so it cannot change another session-start, spawn, teardown, or watcher-poll result, and the watcher runs it detached so a slow attempt cannot delay the liveness beacon.
  Read the named record for the recorded reasons, then reproduce with a direct `bin/fm-home-summary-refresh.sh` (no `--best-effort`, which is what keeps the failure quiet) so the refresh error reaches you.
  A recorded deadline means the complete refresh did not finish inside `FM_HOME_SUMMARY_TIMEOUT`, so inspect lock acquisition and producer completion before validation or publication, and fix the blocked phase rather than raising this load-bearing bound.

- `BOOTSTRAP_INFO: closed the backlog item for <id> after interrupted cleanup; its endpoint or local copy may remain and should be reconciled` - replay closed the item, but the durable close says physical cleanup was interrupted.
  Verify process reaping, the local-copy return, and endpoint closure, then reconcile any surviving resource.
- `BACKLOG_RECONCILE: <id>: recorded backlog close could not be replayed: <reason>` - this session start found a pending-close record but could not land it.
  A valid teardown record proves the close was authorized and recorded, but physical cleanup may be partial: verify process reaping, the local-copy return, and endpoint closure before assuming those resources are gone.
  A validation error means the record cannot be trusted, so do not assume cleanup completed or follow any path or argument stored in it.
  Read the named reason, inspect the marker as inert data when validation failed, fix the record or backlog-file problem, and rerun session start so a valid recorded close replays.
  Never hand-close the item by deleting `state/<id>.backlog-close` - that can discard a completion link the cleanup captured, and the surviving marker prevents the record sweep from starting the item meanwhile.
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
- `WORKTREE_COLLISION: live <path> claimed by <id> (<detail>, recorded <path>), ...` - two or more task records still contend for one worktree; this is the hazard the check exists for (`bin/fm-worktree-collision-lib.sh`'s header owns what each field asserts, including the local-records-only scope - read it there rather than inferring the contract from the line).
  Never edit, commit in, or tear down either claimant's worktree to resolve it - that could discard unlanded work.
  Inspect each named claimant with `bin/fm-crew-state.sh <id>` and its recorded pane before deciding which record is stale and which is real; escalate to the captain if that is not obvious.
- `WORKTREE_COLLISION: stale <path> claimed by <id> (<detail>, recorded <path>), ...` - at most one claimant is still a hazard; the rest are finished tasks whose records were never cleaned up, most often a pooled worktree recycled by a later spawn.
  The live claimant (if any) is using the path legitimately and needs no action; reconcile only the finished claimant's own bookkeeping, never the live claimant's - confirm the finished claimant with `bin/fm-crew-state.sh <id>` first.
  NEVER run ordinary teardown (`bin/fm-teardown.sh <id>`) on a claimant of a shared `worktree=` while another claimant is still live: teardown resolves the worktree from that record's own meta, so it acts on the physical SHARED copy - killing the processes in it (including the live claimant's agent), deleting the checked-out branch, and returning the checkout to the pool - and for a `scout` or `secondmate` record it skips the dirty/unpushed safety refusal entirely.
  Reconciling a stale claimant's record means removing or marking done ONLY that claimant's own state files (`state/<id>.meta` and its related `state/<id>.*` records) directly; the `live` bullet's do-not-tear-down rule applies to a `stale` line too, for exactly this reason.
- A claimant detail reading `process state unknown (...)` names what actually blocked the verdict, and each cause needs a different move: `backend=<name> reported ambiguous` means that backend answered and an unrecognised process holds the pane, so identify that process; `reported unreadable` means the read itself failed, so restore the backend endpoint; `has no recovery classifier` means firstmate cannot judge that engine at all, so verify the task by hand; `record has no endpoint` means the meta itself is incomplete, so repair the record.
  In every one of those cases the claimant counts as a hazard, not as a leftover - do not treat an unverified claimant as finished until you have resolved which cause applies.
- The path after the kind is the physically resolved copy the claimants share, and each claimant's `recorded <path>` is the `worktree=` its own `state/<id>.meta` actually contains.
  Those two differ whenever a record spelled the path through a symlink, so a claimant whose recorded spelling is not the printed one is still a real claimant of that copy - never dismiss it as a false positive on that basis, and use its own recorded spelling when you open its record.
- A line ends with one path caveat whenever the shared path is not proven safe to reclaim, on either kind.
  `still has unlanded work, do not discard` is the only caveat that reports work a probe actually saw.
  Every caveat ending `so whether work would be lost cannot be verified, do not discard` reports instead that a probe could not answer at all, and the clause before it names which one: `is not an inspectable git worktree` (the same condition `bin/fm-teardown.sh` refuses on, so escalate rather than forcing it), `whose working-tree state could not be read` (a damaged `.git/index`, most often from an agent killed mid-git-operation), `whose HEAD could not be checked against the project's default branch` (no `origin/HEAD` and no local `main`/`master`, no ref for the resolved name, or a shallow or grafted history), `whose HEAD was found reachable only from a local default branch, because the published origin/<default> either does not exist or could not answer` (most often work merged into a local `main`/`master` and pushed nowhere, which is the same copy `bin/fm-teardown.sh` refuses to discard), or `could not be examined because an ancestor directory is not searchable`.
  Resolve the named cause by hand before trusting any claim about what that copy holds; for your actions all of them mean exactly what the unlanded caveat means: reconcile records only, and never clean, reset, remove, or return the path itself to clear the line.
  `shared worktree no longer exists at that path` is the one caveat that reports the path itself is empty; the named records are still real bookkeeping to reconcile, and a claimant reported `process alive` against a vanished path is a genuine anomaly worth the captain's attention.
