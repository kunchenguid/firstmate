---
name: bootstrap-diagnostics
description: >-
  Agent-only handling playbook for session-start bootstrap diagnostics.
  Use whenever the session-start digest's bootstrap or network-checks section prints an actionable diagnostic line - MISSING, MISSING_MANUAL, BACKEND_INVALID, NEEDS_GH_AUTH, TANGLE, STARTUP_MEMORY_BUDGET, BACKLOG_ORPHAN, PROJECT_POOL, CREW_DISPATCH invalid, HARNESS_OVERRIDES invalid, FLEET_SYNC, NETWORK_CHECKS, PR_CHECK_MIGRATION, SECONDMATE_SYNC, SECONDMATE_LIVENESS, SECONDMATE_HANDOFF, NM_INCOMPATIBLE, NM_ORPHAN, NM_UNWATCHED, NUDGE_SECONDMATES, FMX, or RELAY - or when a standalone bin/fm-bootstrap.sh or bin/fm-startup-network.sh run prints one of those lines.
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
  For `no-mistakes`, `MISSING` means its command is absent; an installed SemVer build older than 1.46.0, an unclassifiable build, or a build missing required capabilities reports `NM_INCOMPATIBLE` instead.
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
- `BACKLOG_ORPHAN: <id> is In flight in data/backlog.md but has no state/<id>.meta ...` - the task's runtime record is gone but its row was never closed, so this is finished work that firstmate would keep re-reporting to the captain as still open (exactly how four merged tasks were re-reported as awaiting approval days after landing).
  `bin/fm-teardown.sh` closes the row itself, so an orphan means that write failed or the task ended outside teardown; resolve it before dispatching, and never just re-report the row as in-flight work.
  Establish how the task actually ended first - a merged PR/MR, a local merge, or a scout report - then close the row with `tasks-axi done <id>` plus the right link flag (`--pr` for a GitHub pull URL, `--note <url>` for a Codebase MR, `--report <path>` for a scout), or hand-edit `data/backlog.md` when the backlog backend is `manual`.
  If the task turns out to be genuinely unfinished (its worktree and meta were cleaned up while the work was not landed), tell the captain and re-dispatch it rather than closing the row.
- `PROJECT_POOL: <clone> ...` - that project clone still draws task worktrees from the machine-wide worktree pool that every firstmate home holding the same repo shares, so a worktree belonging to another home's clone can be handed to this one; `bin/fm-spawn.sh` refuses to launch on such a worktree, which makes the work undispatchable until the pool is split.
  For a clone with no config or a config naming the wrong home, `bin/fm-spawn.sh` repairs it automatically on the next spawn, so this line only means the clone has not been used yet; run the printed `bin/fm-project-pool.sh apply <clone>` to close it now, or `bin/fm-project-pool.sh backfill --all` to sweep every home on this machine.
  A `commits its own treehouse.toml` or `firstmate did not write` line is different: firstmate will not overwrite it, the repair command will refuse, and closing that one is a captain decision about the project's own configuration.
  Nothing here prunes, destroys, or returns a worktree; worktrees already checked out of the shared pool stay where they are and stay returnable.
- `CREW_HARNESS_OVERRIDE: <name>` - record and use the override silently; surface a harness fact only if it actually blocks work or the captain asks.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; continue with the normal fallback chain, resolve and pass the chosen fallback harness explicitly while the file remains present, fix the malformed schema, unverified harness name, unknown selector, or invalid harness/effort pair when convenient, and do not select a bad profile.
- `CREW_DISPATCH: active config/crew-dispatch.json` - bootstrap validated the optional dispatch profile file and printed its active rules and `default:` when present.
  Keep this block top-of-mind during intake; it is the reminder that every crewmate or scout dispatch must consult the rules before spawning (`AGENTS.md` section 4).
- `HARNESS_OVERRIDES: invalid config/harness-overrides.json - <reason>` - the optional per-harness launch override file exists but failed low-cost bootstrap structural validation; spawns keep launching harnesses with their built-in defaults, so this never blocks work, but the captain's intended override is not being applied - fix the malformed JSON or field type when convenient.
- `STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>` - the visible startup-memory budget is not a safe one-line positive decimal file; do not infer the default or propagate it.
  Correct the local primary file, then rerun session start so the normal convergence path can deliver the validated value to secondmate homes.
- `CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>` - the optional dispatch profile file exists but failed low-cost bootstrap validation; stop profile-based dispatch, report the actionable error, and require correction of the malformed schema, unverified harness name, or invalid harness/effort pair rather than falling back around it or selecting a bad profile.
- `FLEET_SYNC: <repo>: skipped: <reason>` - a benign one-off skip (offline, no origin, local-only); bootstrap continued, investigate only if it blocks work.
  A skip can also report the bounded fleet-refresh timeout (`FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT`, or a fleet-size-aware default with a 20 second floor); a timeout never blocks startup.
- `FLEET_SYNC: <repo>: recovered: <detail>` - the clone had drifted onto a clean detached HEAD holding no unique commits and the sync self-healed it (re-attached the default branch and fast-forwarded); no action needed, it is reported only so the self-heal is visible.
- `FLEET_SYNC: <repo>: STUCK: on <state>, N commits behind <base> - needs attention` - the clone is dirty, on a non-default branch, detached with unique commits, or diverged, so the sync left it untouched (never forcing or discarding); it will keep falling behind until you look.
  A loud STUCK, especially a growing N across bootstraps, means that clone needs hands-on attention; dispatch a crewmate or resolve it before it strands work.
- `NM_INCOMPATIBLE: no-mistakes <reason> (upgrade: no-mistakes update)` - the no-mistakes binary is present, but its SemVer is below 1.46.0, its version cannot be safely classified, or a recognized commit-hash build failed a bounded read-only probe for `watch --pr` or `axi run --intent`.
  This is a detect-only diagnostic; bootstrap never upgrades the tool.
  Tell the captain the exact failed contract named by the line and, on explicit consent, upgrade it with the printed `no-mistakes update`, then rerun session start to confirm the line is gone.
  Never auto-upgrade, and note that no-mistakes is a shared single-instance daemon: an upgrade is a captain-authorized action, not a routine bootstrap install.
- `NM_ORPHAN: no-mistakes ... run parked ... - no live task in this home owns it ...` - a no-mistakes watch run THIS home armed (via `bin/fm-nm-watch.sh`, recorded in `data/nm-armed-runs`) is parked, but the task that armed it is gone (cancelled or torn down), so the reminder cascade re-sends into silence with nobody to answer.
  The line names the run id, the branch, and the gate; it is scoped by this home's own ledger, so a run this home never armed - the captain's own no-mistakes work or another firstmate home's task - never appears here.
  Escalate it to the captain as a stuck review that needs a call: answer the run with `no-mistakes axi respond --run <id>` (approve/skip only - an externally opened PR refuses `fix`) or cancel the run; do not merge a red PR to clear it.
- `NM_UNWATCHED: <id>: <pr-url> has no CI monitoring - <reason> ...` - this task has a recorded PR and `bin/fm-nm-watch.sh` could not put a watch on it, so nothing is polling that PR's checks, review threads, or mergeability.
  The line exists because the refusal itself prints once, mid-run, and reads like a note; it is a coverage hole, and it repeats every session start until it is closed.
  Treat any PR carrying this line as unverified regardless of what the worker reported: read its CI conclusion from the provider yourself (`gh-axi` for GitHub, `bytedcli` for Codebase) before relaying or merging it.
  Then fix the cause the reason names - most often an uninitialized project clone, which the `project-management` skill's Initialize section owns - and re-arm with the printed `bin/fm-nm-watch.sh <id> <pr-url>`, which clears the line only when the run's own record confirms it is watching.
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
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - the secondmate sweep fast-forwarded a running secondmate home and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local X-mode poll artifacts (`docs/configuration.md` "X mode (.env)").
- `RELAY: <host>: <problem>` - a registered remote task host cannot be dispatched to, or is carrying a full-access authorization.
  Repair with `bin/fm-relay-conn.sh up <host>`, which re-pairs and re-tightens transactionally.
  A full-access line is not cosmetic: that host is currently accepting arbitrary commands from anyone holding its key, and the wording is universal because a second `bifrost remote conn up` ADDS such a grant while leaving the tightened one in place looking correct.
  A host whose authorization "could not be audited from here" has no usable SSH route from this machine; audit it on that machine with `bin/fm-relay-conn.sh tighten-local`.
  A host that did not answer has already had the automatic reconnect tried, so this line means it could not be restored from here: read what it says is missing and act on the machine it names, rather than re-running the pairing command it just refused.
  A line naming a desktop host session is that machine's own one-time action and needs its operator; nothing on this side can start it (`docs/relay-gui-host.md`).
  `RELAY:` lines can also come from fleet task adoption on a machine that holds the helm - "could not ask `<machine>` what it is running", an id collision, or a `bin/fm-pr-check.sh` re-arm instruction for adopted work carrying an open change - and each is handled as `docs/helm.md` describes rather than by re-running adoption blind.
  `docs/relay-host.md` owns the mechanism and the evidence.
- `SECONDMATE_HANDOFF: secondmate <id>: pending delivery: <n> item(s)` - queued work has already left the main dispatchable backlog and remains safe in the named remote route's backlog-format outbox, pending backlog receipt or receiver-wake confirmation.
  Preserve that outbox and rerun `bin/fm-backlog-handoff.sh --resume-pending` after the route or endpoint problem is resolved; never re-add or dispatch the items from the main backlog.
  An unsafe-outbox variant requires path and file-type inspection before any retry.
- `NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>` - secondmate convergence changed a running home's loaded instructions or inherited config, but the deterministic `fm-send.sh fm-<id>` re-read nudge failed.
  Inspect the reason, keep the pending marker under `state/.secondmate-nudge-pending/` intact, and rerun session start after the endpoint or metadata issue is fixed so bootstrap can retry the exact same marked send on the same local or remote route.
- `FMX: X mode on ...` / `FMX: X mode off ...` - bootstrap confirmed or removed the local Relay poll artifacts (`docs/configuration.md` "Relay (.env)"); the emitted line still carries Relay's former `X mode` wording.
  Only when a running watcher needs the cadence transition applied immediately, restart the home-scoped watcher through the emitted harness supervision protocol; bootstrap deliberately never restarts the watcher itself.
