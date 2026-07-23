# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations.
Secondmate handoffs are separate and unconditional: `fm-backlog-handoff.sh` keeps only its own fleet-level validation and always delegates the item move to `tasks-axi mv`, the single owner of the backlog format.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer, `tasks-axi update --help` exposes `--archive-body`, and `tasks-axi mv --help` exposes `[<id>...]` for the atomic multi-ID move introduced in 0.2.2 and required by handoff delegation.
That sentence is the single owner of the tasks-axi compatibility definition; every other document points here instead of restating the version gates.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and `TASKS_AXI: available` behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress `TASKS_AXI: available`, not missing-tool reporting.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

## Runtime backend (config/backend / FM_BACKEND)

The runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend (see [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, and `cmux` are experimental new-task spawn backends, while `orca` is retained only for eligible pre-cutover task recovery (see [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md), and [`docs/cmux-backend.md`](cmux-backend.md)).
Treehouse remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; eligible legacy Orca recoveries use Orca for both the task worktree and terminal endpoint.
New spawns choose the backend in this order: an explicit `--backend` flag firstmate passes when it spawns a task, then `FM_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-auto-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.
Auto-detected herdr or cmux prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Zellij is never auto-detected; select it through local `config/backend`, `FM_BACKEND=zellij`, or an explicit request.
Orca is also never auto-detected and may be selected only under the [`docs/orca-backend.md`](orca-backend.md#eligibility) eligibility contract.
Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`fm-spawn.sh` accepts `tmux`, `herdr`, `zellij`, and `cmux` for new ship and scout tasks; `backend=cmux` still refuses `--secondmate` until its secondmate launch semantics are designed.
Every new task refuses `backend=orca` before any owned mutation, and Orca also refuses `--secondmate`; the Orca guide owns the rationale and exact legacy eligibility rule.
`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.
The session-start secondmate liveness sweep uses a deeper `fm_backend_agent_alive` probe where verified.
Today that probe can classify tmux and herdr secondmate endpoints as `alive`, `dead`, or `unknown`; zellij, Orca, and cmux report `unknown` until their own agent-process classifiers are verified.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires the Herdr tool delta owned by "Toolchain" below, refusing loudly on an incompatible or missing installation.
A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.
A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.
A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
An eligible legacy Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=fm-<id>` kept as the shared firstmate alias.
A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and uses the same recorded backend target fields after loading `state/<id>.meta`.
Herdr workspaces are derived from `FM_HOME`: the primary home uses `firstmate`, and a secondmate home marked by `.fm-secondmate-home` uses `2ndmate-<secondmate-id>`.
Spawn, list-live, and recovery paths read that label from the active home, so a secondmate's own crewmates stay inside that secondmate home's herdr space.
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
For normal zellij operations, `FM_ZELLIJ_SESSION` selects the named session and defaults to `firstmate`.
Zellij has no per-home workspace split: primary and secondmate tasks share that one session, and visible tab titles are scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.
cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `fm-<id>`, but the actual cmux workspace title is scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Test cleanup must use the guarded path described in [`docs/cmux-backend.md`](cmux-backend.md)'s "Test safety" section, never enumerate-and-close every workspace.
The `config/backend` file is not inherited by secondmate homes.

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

These settings apply only to the terminal-backed compatibility path used by a harness without a native tracked-background completion notification.
Native tracked delivery completes the away daemon task and does not resolve or inspect a supervisor pane.
The compatibility path injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned and currently supports only `tmux` and `herdr` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux|herdr` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `firstmate:0` tmux fallback with a warning.
Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses compatibility delivery at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When terminal-backed compatibility injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged compatibility delivery is never silent, and it fires at most once per max-defer window after a genuine wedge.
Native tracked delivery does not use these channels because a due batch completes the task directly without a pane-dependent defer condition.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the channel reference and macOS verification evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` keeps test evidence outside the repo and defines `commands.test` so no-mistakes runs firstmate's bash behavior suite directly.
That evidence policy is specific to the firstmate repo: target projects may legitimately commit `.no-mistakes/evidence/` from their own no-mistakes pipeline, but firstmate keeps `.no-mistakes/` local and CI rejects tracked entries under that path.
That command requires `tmux` on `PATH`, prints `tmux -V`, runs every `tests/*.test.sh` with `bash`, and fails if any script exits non-zero.
It intentionally mirrors the behavior-test baseline in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) instead of delegating the test step to an agent.

## Captain preferences (data/captain.md)

Personal preferences for one captain's fleet live locally in `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and rewrite or prune the matching bullet in place; add a new bullet only for a genuinely new durable preference.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed right after `data/captain.md` in the session-start context digest.
The file is created lazily on first learning and follows the same dated, evidence-backed, curated style as `data/captain.md`: inspect the current file first, then rewrite or prune stale entries instead of appending forever.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
Each line records the secondmate id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh firstmate worktree for the secondmate home.
Use the deliberate `--no-projects` signal only for a firstmate-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog queued items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent and refuses In flight, Done, or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.
Each seed writes an `.fm-secondmate-home` identity marker at the home root.
The tracked root `.gitignore` ignores that marker, so validation can read it without making a freshly seeded home appear dirty to porcelain-based safety checks.
This does not relax protection for any other untracked file.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatefirstmate`'s origin refresh instead.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
For the herdr backend, `FM_HOME` also determines the workspace label used by the adapter.
For the zellij backend, `FM_HOME` does not split containers, but it determines the readable home prefix embedded in visible tab titles; use `FM_ZELLIJ_SESSION` when a separate zellij session is needed.
The full zellij home label also includes a short hash of the resolved `FM_ROOT` path.
For the cmux backend, `FM_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read from, while `FM_HOME` determines the default config path and readable home prefix embedded in workspace titles.
The full cmux home label also includes a short hash of the resolved `FM_ROOT` path, and there is no per-home container split.

## Harness support

claude, codex, opencode, pi, and grok are all empirically verified; new harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - busy signatures, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
Primary-session turn-end guard integrations for verified harnesses are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude and Grok use background-notify cycles, Codex uses bounded foreground checkpoints, Pi uses its two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`fm-harness.sh secondmate-model` and `fm-harness.sh secondmate-effort` expose only the optional tokens from `config/secondmate-harness`; `config/crew-harness` remains a bare adapter-name file.
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
The primary propagates `config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`, and `config/account-routing-mode` into secondmate homes at secondmate spawn, during the locked session-start bootstrap secondmate sweep, and during explicit `bin/fm-config-push.sh` runs, so a secondmate's own crewmates use the primary dispatch and routing policy.
`config/secondmate-harness` and `config/secondmate-account-pool` are not inherited because they are primary-owned knobs for launching secondmate agents.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Pi secondmate launches, `fm-spawn.sh` starts Pi with `-e` pointed at the secondmate home's own tracked `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts`, both already present from the secondmate home's git worktree.

## Agent Fleet account routing

Firstmate routes new observe and enforce Claude and Codex ship/scout launches directly through account profile directories.
The exact discovery, fresh-usage, health, fallback, and Herdr-hook mechanics are owned by `bin/fm-account-directory.sh`'s header and help output.
The selected provider command receives `CLAUDE_CONFIG_DIR=<home>` or `CODEX_HOME=<home>`, and task metadata records the non-secret `account_home=<home>` for observability.
New ship/scout launches never ask Agent Fleet to enable a profile, establish identity, install a bundle, or acquire a lease.
They invoke Herdr's own integration installer against the selected profile directory and verify its per-profile hook file before launching.
Account credentials remain captain-owned and read-only to Firstmate; selection never authenticates, logs in, or invokes a model.

Codex health and usage are genuinely readable per account.
Every selection performs a fresh per-account quota read instead of trusting a prior cache, and a Codex directory with no fresh general usage window is skipped.
This means an account re-authenticated immediately before spawn is eligible on that spawn.
Claude's config-directory-specific macOS Keychain credential is not currently distinguishable through non-interactive quota reads.
Claude therefore treats missing quota as unreadable rather than unhealthy, chooses the first real profile directory in stable sort order, and prints a loud `CLAUDE USAGE UNREADABLE` note explaining that keychain/quota-read gap.

Account routing remains default-off.
An unchanged installation does not select an account directory, does not alter the provider launch, and adds no account field to task metadata.
The production mode resolves in this order: explicit `--account-pool` or `--account-profile` enforces routing for that spawn, emergency `--no-account-routing` disables it for that spawn, the single value in local `config/account-routing-mode`, then `off`.
The emergency bypass is printed loudly and persisted as `account_routing_emergency_bypass=1` in task metadata.
Ambient `FM_ACCOUNT_ROUTING=off` cannot override the authoritative config.
The valid modes are `off`, `observe`, and `enforce`.
Bootstrap reports an `ACCOUNT_ROUTING` diagnostic when the configured policy is unreadable, contains multiple values, or names any other mode.
`observe` and `enforce` both activate direct account-directory selection for a new Claude or Codex ship/scout launch on any supported runtime backend.
Neither mode invokes Agent Fleet selection or leases for a new ship/scout launch.
The existing `--account-pool`, `--account-profile`, and dispatch-profile fields remain compatibility activation inputs for those crewmates while the inactive-code removal is handled separately.
Their legacy aliases do not constrain the new usage-based account choice.
Secondmate integration is deferred: secondmate launches retain their pre-cutover Agent Fleet selection and lease behavior, including `config/secondmate-account-pool`.
Firstmate's spawn flags and `config/secondmate-account-pool` continue to accept aliases made only of letters, digits, dot, underscore, and dash, excluding values that begin with dot or dash; `config/crew-dispatch.json` deliberately narrows those fields to an alphanumeric first character.
Account email addresses and filesystem paths are invalid in every input surface.
Direct ship/scout task metadata records only `account_home=` from this account mechanism.
It never creates `account_pool=`, `account_profile=`, `account_task=`, `account_attempt=`, or `provider_session_id=`.

Existing ship/scout tasks that already carry `account_profile=` metadata remain legacy Agent Fleet managed generations.
That compatibility path is recovery-only for ordinary crewmates and is not used for any new ship/scout task.
Secondmate launches continue to create and recover legacy Agent Fleet managed generations until their dedicated direct-account integration is designed.
Bootstrap requires Agent Fleet for enforced secondmate routing and when legacy `account_profile=` or pending rollback metadata exists, while new direct ship/scout routing requires `jq`, `quota-axi`, and Herdr's integration installer instead.
Same-profile recovery is sticky and fail-closed: `bin/fm-spawn.sh <id> --resume-account` validates existing task metadata and Agent Fleet's session mapping, uses `lease recover` rather than new-task quota selection, resumes the recorded provider session without replaying the brief as a new prompt, and requires a higher monotonic `session_event_seq` from a SessionStart accepted after its local launch gate before committing the recovered lease.
Wall-clock `updated_at` remains diagnostic only and never decides launch freshness.
Schema-1 mappings remain readable as virtual sequence zero; the next same-binding SessionStart atomically migrates them to schema 2 / sequence 1, while a changed binding is rejected without modifying the legacy record.
The per-task lifecycle lock serializes concurrent managed recovery attempts, and a waiter re-reads the committed metadata generation after acquiring ownership before it acts.
When native resume is unavailable or a different Claude/Codex profile must take over, `bin/fm-spawn.sh <id> --continue-account` builds and validates the provider-neutral task packet owned by `bin/fm-account-continuation.sh`, launches a fresh generation from that packet, and releases the predecessor only after the new SessionStart mapping is bound.
Continuation verifies a bounded repository identity before replacement and fails closed when the file, byte, enumeration, or time limit cannot cover the repository; the environment-variable table below owns those tuning defaults.
Continuation inherits the predecessor pool only when the provider is unchanged; a provider change with no explicit pool or profile resolves the target provider's standard pool.
If predecessor lease or session cleanup fails after that binding, the replacement stays committed with retry metadata, and rerunning the same `--continue-account` command completes cleanup without creating another endpoint or account attempt.
If pre-bind rollback cleanup fails, metadata records `account_rollback_cleanup=pending` plus an exact predecessor backup when applicable, and recovery or teardown retries that failed attempt before restoring or recycling task state.
Bootstrap uses the managed recovery path for a confidently dead secondmate carrying `account_profile=` and deliberately defers an unmanaged generation until an operator makes the explicit routing decision owned by the `secondmate-provisioning` skill's "Recovery" section.
Teardown kills the recorded endpoint and releases the Agent Fleet lease and session mapping only after the backend confirms absence; a live or unknown endpoint state retains metadata and storage for retry.
Off and observe mode support the tmux, Herdr, zellij, and cmux session backends.
`config/secondmate-account-pool` selects the Agent Fleet pool for secondmate launches when routing is already enabled; it does not activate routing by itself and is deliberately not inherited into the secondmate home.
An explicit per-spawn account pool or profile overrides that secondmate pool.
`config/account-routing-mode` is inherited, so a secondmate can apply the same off/observe/enforce policy to its own crewmates while resolving its own pools from dispatch profiles or the standard provider defaults.
The legacy secondmate and recovery implementation resolves Agent Fleet through its sealed production front door and keeps its environment overrides behind `FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1`.
Its remaining crew-dispatch pool-summary branch and isolated new-crewmate fixture path are deferred to follow-up task `remove-fleet-routing-deadcode`; neither is a real new ship/scout launch path.
The direct account-directory module has a separate unmistakable `FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1` opt-in for deterministic filesystem, quota, and installer fixtures.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best matching rule with judgment, resolves that rule directly or through a supported selector, and passes the concrete harness, model, effort, account pool, and account profile axes to `fm-spawn.sh` when present.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Secondmate spawns are exempt and still resolve through `config/secondmate-harness` and its optional model and effort tokens.
This section is the single owner of the canonical schema and its per-field semantics; `AGENTS.md` section 4 keeps only the dispatch procedure and points here.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>", "account_pool": "<optional compatibility activation alias>", "account_profile": "<optional compatibility activation alias>" }
      ],
      "select": "<optional strategy>",
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>", "account_pool": "<optional compatibility activation alias>", "account_profile": "<optional compatibility activation alias>" }
}
```

Per rule, `when` and `use` are required.
`use` may be a single profile object or an ordered array of profile objects; the single-object form stays fully backward-compatible, and every profile needs `harness`.
`use.model`, `use.effort`, `use.account_pool`, `use.account_profile`, and `why` are optional.
Account pool and profile fields are valid only for `claude` and `codex`, and selecting either field activates direct account-directory routing even when the global mode is off or observe.
`select` is optional and currently supports `quota-balanced`.
Absent `select` means use the first array element, or the only object in the single-object form; the first array element is the deterministic tie-break and the ultimate fallback.
`default` is optional.
An omitted model or effort means the selected harness uses its own default for that axis.
If a selected profile carries an effort value the chosen harness does not accept, `fm-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `CREW_DISPATCH` diagnostic when it is visible in the file.
`quota-balanced` selection is deterministic and implemented by `bin/fm-dispatch-select.sh`, whose header owns the general-window rules, the 20 point stale-clear freshness margin, vendor-availability handling, and the degrade-to-first-element fallbacks; quota trouble never blocks dispatch.
Any quota-balanced candidate carrying `account_profile` remains invalid for compatibility, and pool-aware candidates must all carry `account_pool`.
The winning profile's account field activates the later per-account direct selection; its legacy alias does not pin an account directory.
When account routing is `enforce`, every quota-balanced candidate must carry `account_pool`; `off` and `observe` retain the legacy poolless `quota-axi` compatibility path.
That pool-aware path never falls through to `quota-axi` default-account data, preventing one quota source from choosing a provider while a different account source chooses the concrete profile.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files produce a `CREW_DISPATCH: active config/crew-dispatch.json` block that lists each rule and prints `default:` when present.
Malformed JSON, an unverified harness, malformed or unsupported account fields, a malformed array profile, an unknown `select`, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
If no dispatch rule fits, firstmate uses the dispatch profile `default` when present, then falls back to `config/crew-harness`.
Because the spawn backstop is gated by file presence, any fallback path after a missing match, validation error, or missing `jq` still passes a resolved harness explicitly until the file is fixed or removed.
Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## Checkout refresh

`bin/fm-checkout-refresh.sh` keeps worktree seed checkouts current independently of Firstmate's own PR lifecycle.
Its header owns the exact discovery, configuration-file, cadence, state, and command contracts.
The default covered set is every clone under the active home's `projects/`, every backing checkout referenced by a Treehouse pool under `~/.treehouse`, and every top-level clone under `$HOME` whose `origin` URL matches one of those tracked checkouts.
Matching by origin discovers parallel clones such as `~/relvino` without embedding a captain-specific path in shared code.
Optional `path` and shallow `scan` directives in the gitignored `config/checkout-refresh` file extend that set.
Every declared checkout and matching-origin scan result must resolve to its exact canonical Git worktree root, so nested directories can never redirect refresh to an enclosing repository.

Each `FM_HOME` owns a distinct background identity and state directory, so primary and secondmate homes can cover their own projects without displacing one another.
Checkout-level owner locks are held by the shared `fm-fleet-sync.sh` mutation path, Treehouse acquisition, and every authorized Treehouse return, so home-scoped services, spawn, secondmate seeding, teardown, and merged-PR wake handling serialize overlapping checkouts safely.
Each Treehouse return is process-tree bounded by `FM_TREEHOUSE_RETURN_TIMEOUT`, which defaults to 60 seconds, and the common checkout lock is released only after that process tree is gone.
Each background owner probes every covered checkout's remote default-branch tip every 60 seconds.
Any upstream-tip change triggers `fm-fleet-sync.sh` immediately, regardless of who pushed or merged it.
Every `fm-fleet-sync.sh` invocation repeats the live upstream-default probe after fetching and proves that the fetched ref matches the live tip instead of trusting a checkout's possibly stale `origin/HEAD`.
Each shared checkout mutation is process-tree bounded by `FM_CHECKOUT_REFRESH_SYNC_TIMEOUT`, including direct teardown and merged-PR wake calls.
Teardown holds that same checkout lock while its landed-content fallback probes, fetches, re-probes, and compares the live default, and it retains the worktree unless both live branch identity and tip remain unchanged.
If the upstream default branch changes, a checkout still on the old branch is reported as `STUCK:` and left unchanged under the fast-forward-only posture.
A full safe refresh runs at least every 15 minutes even when no change signal is observed, so transient network failures, a missed probe, or lost local state cannot create unbounded drift.
Every probe also inventories non-ignored untracked files in covered seed checkouts and Treehouse pool worktrees under `.agents/skills`, `.claude/skills`, `.codex/skills`, and `skills`.
Gitignored files are intentional local material and remain outside this collision guard.
A new or growing inventory produces a durable `HYGIENE:` alert immediately, while forced session-start and spawn-preflight checks repeat any unresolved alert for an operator.
An inventory read failure preserves the prior hygiene alert and marks the latest coverage result unhealthy until a complete scan succeeds.
Unreadable active-home project directories, unreadable or malformed Treehouse state, or a covered checkout that becomes uninspectable during either refresh pass surface an actionable diagnostic and mark the latest coverage result unhealthy.
The ordinary safe-refresh warning separately quantifies every non-ignored untracked file and the subset under those skill directories, so other untracked accumulation is bounded by the same 15-minute backstop.
These checks inspect paths only and never delete, move, stash, reset, or edit a draft.
The signal interval and backstop are configurable through `FM_CHECKOUT_REFRESH_INTERVAL` and `FM_CHECKOUT_REFRESH_BACKSTOP`.
Every cadence and spawn-preflight refresh disables gone-branch pruning and retains `fm-fleet-sync.sh`'s fail-safe behavior: a dirty, diverged, or non-default checkout is left untouched and recorded as an alert.
The forced session-start mode preserves the existing gone-branch pruning pass.

Treehouse v2.0 already excludes dirty pool entries, fetches `origin`, and resets only an available clean detached worktree to the freshest default ref.
Firstmate surfaces matching dirty pool entries, acquires the selected path with `treehouse get --lease`, and verifies the durable lease before creating its endpoint.
That synchronous acquisition holds the common-Git-directory mutation lock and is process-tree bounded by `FM_TREEHOUSE_ACQUIRE_TIMEOUT`, which defaults to 60 seconds.
The accepted lease must be clean, belong to the requested repository, have the same origin identity, and match the live upstream default-branch tip.
Remote-free `local-only` acquisitions use the same repository and cleanliness proof, with the requested checkout's local `main` or `master` tip as their freshness authority.
Treehouse-acquired secondmate homes receive the same proof before seeding.
They use the same locked, bounded acquisition entrypoint as ordinary task worktrees.
A stale, dirty, or uninspectable acquisition remains durably leased without forced return and is surfaced for manual recovery.
If an unmanaged spawn fails after publishing metadata or task artifacts, it restores the prior task generation before returning only a worktree whose repository identity, cleanliness, and expected detached tip are re-proven.
That makes the acquisition proof explicit even if the background owner was offline.
Orca is an explicit legacy-recovery-only exception because this change creates no new Orca tasks or acquisitions.

### Limitations / deferred

- A checkout without `origin` still uses the local default-tip proof without first proving that its registered project mode is explicitly `local-only`.
- Home-scoped refresh owners still enumerate the shared user-level Treehouse root without filtering pool entries by owning `FM_HOME`.
- Secondmate home acquisition still relies on Treehouse's dirty-entry skip and does not run Firstmate's `pool-preflight` before requesting its durable lease.
- The rare SIGKILL lock-to-guard handoff race, exact wrapped-exit-code fidelity, and setup-failure diagnostic precision remain deferred under `clone-refresh-followup-edges`; current fail-safe behavior may retain or refuse work or require retry, but must not claim healthy coverage or discard unlanded work.

The consolidated `clone-refresh-followup-edges` follow-up should tighten explicit local-only mode proof, add home-filtered pool ownership, apply pool preflight to secondmate acquisition, and close the three process-ownership edges above.
These are bounded completeness limitations: coverage health fails closed when Treehouse enumeration cannot be proved, and rollback retains any worktree whose repository identity and expected detached tip cannot be re-proven, so the deferred formalization does not create a false healthy-coverage signal or a destructive data-loss path.

On macOS, bootstrap reports `MISSING: checkout-refresh` until that home's per-user LaunchAgent is installed.
After the captain approves the background owner, install it with:

```sh
bin/fm-bootstrap.sh install checkout-refresh
```

The locked session-start sweep still runs the same broad discovery and a forced refresh, so the service has an operator-visible backstop.
The LaunchAgent is intentionally independent of the Firstmate watcher and continues polling when no fleet task or Firstmate session is active.
Only the LaunchAgent's scheduled invocation advances its heartbeat, while foreground session and manual runs update coverage health without refreshing scheduler liveness.
The heartbeat proves scheduler liveness only, while `ensure` independently requires the latest coverage result to be healthy.
Its definition persists the configured Treehouse root, refresh interval, and backstop, and health validation rejects any installed value that no longer matches the current configuration.
macOS launchd is the primary fleet scheduler in this release.
Scheduler installation and health checks dispatch through an adapter seam, while a future Linux cron or systemd adapter remains explicit follow-up work rather than silently claiming coverage today.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The universal toolchain is node, python3, git, gh with GitHub auth via `gh auth login`, Perl, no-mistakes v1.31.2 or newer, gh-axi, chrome-devtools-axi, lavish-axi, compatible tasks-axi per "Backlog backend" above, and quota-axi.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, no-mistakes runs the validation pipeline, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi plus quota-axi back backlog mutations and quota-balanced dispatch.
The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
That delta is owned in code by `fm_backend_required_tools` in `bin/fm-backend.sh`: the resolved backend's own session-provider CLI (`tmux`, `herdr`, `zellij`, `orca`, or `cmux`), `jq` for the JSON-emitting experimental adapters (`herdr`, `zellij`, `cmux`) whose spawn and liveness paths parse the backend's JSON output, `nohup` for Herdr's portable detached `setsid` server launcher, and the `treehouse` worktree provider for every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`).
Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
For an eligible pre-cutover task, Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, or cmux home is therefore never told `tmux` is missing, and the `treehouse` durable-lease upgrade check runs only for the backends that actually use treehouse.
Bootstrap reports missing `jq`, fixed system Perl, or Herdr whenever local routing mode, dispatch configuration, or existing ship/scout `account_home=` metadata can activate direct account-directory launches.
It reports missing Agent Fleet when enforced secondmate routing is configured or legacy task metadata still carries `account_profile=` or pending rollback cleanup and may need managed recovery.
Observe and enforce modes both use direct account-directory routing for new ship/scout launches; off mode leaves them on the provider's default identity while still allowing recorded direct generations to recover through fresh selection.
When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
When X mode is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
`tasks-axi` and `quota-axi` are required bootstrap tools in every profile, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)`; when `config/backlog-backend` is not `manual` and compatible `tasks-axi` is on `PATH`, bootstrap also prints `TASKS_AXI: available` and firstmate uses its verbs for routine backlog mutations, otherwise it hand-edits `data/backlog.md` until installation is approved and completed.
An absent `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)`; `bin/fm-dispatch-select.sh` still degrades to the first profile at runtime when quota data is unavailable.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
The locked session-start bootstrap step also runs a best-effort covered-checkout refresh through `fm-checkout-refresh.sh`, which delegates individual safe updates to `fm-fleet-sync.sh`.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Checkout discovery and configuration diagnostics use the same relay so an omitted configured clone cannot remain silent.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed checkout-refresh output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The locked session-start bootstrap step also runs the guarded local secondmate sync for recorded live secondmate homes, then propagates declared inheritable local config into each validated live home.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason or config inheritance failed, and `NUDGE_SECONDMATES:` only when a running home advanced and its instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed.
`NUDGE_SECONDMATES:` lists stable `fm-<id>` task selectors; the `bootstrap-diagnostics` skill owns the send procedure.
The same bootstrap run also emits `SECONDMATE_LIVENESS:` outcomes for live secondmate endpoints; the `bootstrap-diagnostics` skill owns the response to handled, deferred, skipped, and failed outcomes.
For a mid-session inherited config edit where tracked-file sync and reread nudges are not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each live home's `crew-dispatch.json`, `crew-harness`, `backlog-backend`, and `account-routing-mode` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero only for real propagation errors.
That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

### Portable process-control prerequisites

Bootstrap requires `perl` on every backend because checkout refresh and account control use it to bound and reap complete process trees.
Herdr additionally requires `nohup`, while its production adapter executes only the fixed system binaries documented in [herdr-backend.md](herdr-backend.md#control-plane-and-filesystem-hardening).
Both commands ship with macOS and are commonly supplied by the platform's coreutils and Perl packages on other Unix-like systems.
If bootstrap reports either command missing, restore or install the corresponding platform package, confirm it with `command -v nohup` or `command -v perl`, and rerun bootstrap.
Bootstrap treats these as manual prerequisites because package names and command exposure differ across supported platforms.

## X mode (.env)

X mode lets a firstmate instance answer public `@myfirstmate` mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while parent-thread context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a check shim that runs `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.
This section is the single owner of the X-mode cadence contract: an X instance polls every 30 seconds instead of the default 300, only an X instance speeds up because a non-X home has no `config/x-mode.env`, and the session-start supervision operating block includes the cadence instruction when that file exists.
The active primary-harness supervision protocol owns how that sourced cadence reaches the watcher process.
Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a watcher is already running, or opt-out - is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap deliberately never restarts the watcher itself.
While away mode is active the daemon owns the watcher and its default cadence applies; away-mode X cadence is a deferred follow-up.
When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.
X mode is purely additive: no edit is made to `bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, `bin/fm-wake-lib.sh`, or the afk daemon (`bin/fm-supervise-daemon.sh` and the `afk` skill).
It lives entirely in X-specific `bin/` scripts, the `fmx-respond` skill, and the generated local artifacts above.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate with `x-mention <request_id>`.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
At the same time the poll records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) from the same authoritative relay payload, best-effort and keyed by `request_id` so concurrent requests never overwrite each other; it survives the inbox cleanup that follows the acknowledgement, so a delayed follow-up can recover the original platform and split budget even with no task link.
`recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
The [`operating-fundamentals`](../.agents/skills/operating-fundamentals/SKILL.md) skill owns the intake and orchestration contract for actionable requests; this section owns only the X-mode transport and generated-state mechanics.
Fleet-state questions are answered in that turn.
For an actionable request, firstmate posts an acknowledgement through the normal answer endpoint, links the tracked task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, always finishing with a `--final` one when the task reaches a terminal state.
That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.
Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` owns the source order: the durable per-request registry is consulted first, then the still-present inbox payload, then - for a follow-up posted live by request_id - an authoritative relay lookup via `POST /connector/request-context` (`{request_id}` in, `{platform, reply_max_chars}` back).
This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.
`bin/fm-x-link.sh` follows the same ordering when recording a fresh link's context and requires `jq`; its request-context lookup is best-effort: no token or `curl`; a non-2xx response; an unresolved response; or a relay version without that endpoint leaves the context unknown.
In that case the link is still recorded but `bin/fm-x-link.sh` prints a loud warning; when neither a follow-up's platform nor a valid explicit budget of at least 50 characters can be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses it (fail-safe exit 8) rather than posting with a local default - firstmate holds and retries it once either value is recoverable.
Requiring only one resolvable axis is a deliberate divergence from upstream #520, which refused a follow-up unless both an authoritative platform and a valid explicit budget were resolvable.
Future upstream syncs must preserve this either-axis-sufficient behavior.
Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it also clears that request's durable per-request context, since a dismissed mention never gets a follow-up.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.
A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
`fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: both platform and explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once either value can be recovered; a known platform uses its documented default budget.
Past-window relay rejections are only guaranteed while the expired binding row still exists on the relay side; after its cleanup sweep, a very-late follow-up call may instead see a benign no-op 200, which is why the local window and cap pruning remains the primary guard.
Reply splitting is platform-aware: an explicit relay platform field (`reply_platform`, `platform`, `target_platform`, `source_platform`, or `provider`) wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric `tweet_id` selects X.
An explicit relay limit field (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit`, or `max_chars`) wins over the platform defaults.
If the reply exceeds the selected budget, the client splits it into a numbered thread on fenced-code, paragraph, line, and word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener message and later chunks stay text-only.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_DISCORD_REPLY_MAX_CHARS` defaults to 1900, clamps to a minimum of 50, and resets values above Discord's 2000-character limit back to 1900.
`FMX_X_THREAD_MAX` defaults to 25 and caps oversized reply threads for every platform, marking the last retained message with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 604800 (7 days) and controls the local completion follow-up window; `FMX_FOLLOWUP_MAX_COUNT` defaults to 3 and controls the local follow-up cap.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target, and zellij/cmux home-title hash; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_BACKEND=             # optional runtime backend override; tmux/herdr/zellij/cmux support new ship/scout spawns, Orca is legacy-recovery-only, and codex-app is not accepted
FM_ACCOUNT_ROUTING=off  # test/lab-only mode override; production config/account-routing-mode is authoritative
FM_AGENT_FLEET_BIN=agent-fleet  # test/lab-only Agent Fleet executable override
FM_ACCOUNT_ROUTING_TEST_LAB=firstmate-account-routing-test-lab-v1  # unmistakable opt-in required for either override; never set in production
FM_ACCOUNT_CONTROL_TIMEOUT=10  # seconds allowed per ordinary Agent Fleet control-plane command; an explicit value also remains the legacy selection override when the next variable is unset
FM_ACCOUNT_SELECTION_TIMEOUT=120  # seconds allowed per choose/acquire/recover command; unset falls back to an explicit legacy FM_ACCOUNT_CONTROL_TIMEOUT, then 120
FM_ACCOUNT_SESSION_WAIT_SECONDS=10  # seconds a managed spawn waits for its required SessionStart mapping
FM_ACCOUNT_SESSION_QUERY_TIMEOUT=5  # seconds allowed per Agent Fleet session-status query
FM_ACCOUNT_SESSION_SYNC_INTERVAL=60  # watcher cadence for reconciling missing managed provider-session mappings
FM_ACCOUNT_SESSION_SYNC_TIMEOUT=5  # seconds allowed for each watcher reconciliation command
FM_ACCOUNT_SESSION_SYNC_TOTAL_TIMEOUT=8  # seconds allowed per rotating watcher reconciliation worker
FM_ACCOUNT_SESSION_MAX_PARALLEL=4  # maximum managed mappings attempted in one rotating watcher batch
FM_ACCOUNT_NATIVE_READY_WAIT_SECONDS=5  # seconds sticky recovery waits for its native provider wrapper launch gate
FM_ACCOUNT_CONTINUATION_STATUS_TIMEOUT=5  # seconds allowed for the no-mistakes status snapshot in a provider-neutral continuation packet
FM_ACCOUNT_CONTINUATION_FINGERPRINT_FILES=100000  # maximum repository entries verified for a provider-neutral continuation
FM_ACCOUNT_CONTINUATION_FINGERPRINT_BYTES=268435456  # maximum repository content bytes verified for a provider-neutral continuation
FM_ACCOUNT_CONTINUATION_ENUMERATION_BYTES=33554432  # maximum bytes used to enumerate repository identity inputs
FM_ACCOUNT_CONTINUATION_FINGERPRINT_SECONDS=30  # seconds allowed to verify the continuation repository identity
FM_DISPATCH_AGENT_FLEET_TIMEOUT=120  # optional positive seconds per live-proof pool summary; unset uses FM_ACCOUNT_SELECTION_TIMEOUT, an explicit legacy FM_ACCOUNT_CONTROL_TIMEOUT, then 120
FM_REPORT_STACK_ROOT=  # machine-global completion-report store override; unset uses $XDG_DATA_HOME/firstmate/report-stack or ~/.local/share/firstmate/report-stack
FM_REPORT_RETENTION_INTERVAL=  # optional shared cadence: owner/policy default 300s, opportunistic watcher default 86400s; constrained by docs/report-stack.md
FM_REPORT_RETENTION_COHORT_MS=300000  # retention cohort width; this plus the owner interval may not exceed 15 days
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_COMPOSER_LINES=20  # herdr-only: tail lines scanned by composer-state guard/fallback paths; idle-baseline submit confirmation uses agent-state
FM_BACKEND_HERDR_IDLE_RE='^Type a message\.\.\.$'  # herdr-only: empty-composer placeholder regex after shared ghost extraction plus border and prompt stripping
FM_BACKEND_HERDR_BARE_PROMPT_RE='^[❯›]'  # herdr-only: verified agent glyphs recognized as an UNBORDERED (bare) composer row, e.g. claude's ❯ or codex's ›; shell glyphs remain unknown rather than empty, and de-emphasised ghost/placeholder text (dim or dark-truecolor) after an agent prompt reads empty via the shared fm_composer_strip_ghost (docs/herdr-backend.md "Incident (2026-07-08)", "Incident (2026-07-10)")
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Native agent-state submit confirmation")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_BACKEND_ORCA_COMPOSER_LINES=200  # orca-only: terminal-read lines scanned to locate the composer row for submit verification
FM_BACKEND_ORCA_IDLE_RE='^Type a message\.\.\.$'  # orca-only: empty-composer placeholder regex after border/prompt stripping
FM_ZELLIJ_SESSION=firstmate  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
FM_BACKEND_CMUX_COMPOSER_LINES=20  # cmux-only: tail lines scanned to locate the composer row for submit verification
FM_BACKEND_CMUX_IDLE_RE='^Type a message\.\.\.$'  # cmux-only: empty-composer placeholder regex after border/prompt stripping
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merge polls or the X-mode poll shim)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes runs rows scanned when cross-branch attribution falls back from axi status
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage
FMX_PAIRING_TOKEN=      # X mode pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional X relay override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct X client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews X replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting X-mode completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on X-mode completion follow-ups per linked mention
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # status regex that makes watcher and daemon signal/stale/scan output captain-relevant
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates; stale panes whose crew is not provably working surface immediately unless they declare the pause verb
FM_PERMISSION_STALL_ESCALATE_SECS=900 # busy seconds without meaningful pane/status/turn-end progress before a possible macOS permission/system-dialog block surfaces; timeout heuristic, not direct OS detection
FM_PAUSE_RESURFACE_SECS=3600       # seconds before an idle declared external wait re-surfaces for a recheck in the watcher or away-mode daemon
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive unchanged wedge or permission-stall escalations before demand-deep-inspection is added
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_CHECKOUT_REFRESH_INTERVAL=60       # seconds between background upstream-tip probes
FM_CHECKOUT_REFRESH_BACKSTOP=900      # maximum seconds between full safe refresh attempts
FM_CHECKOUT_REFRESH_PROBE_TIMEOUT=15  # seconds allowed for one upstream-tip probe
FM_CHECKOUT_REFRESH_SYNC_TIMEOUT=60   # seconds allowed for one checkout refresh
FM_TREEHOUSE_ACQUIRE_TIMEOUT=60       # seconds allowed for one durable task-worktree acquisition
FM_TREEHOUSE_RETURN_TIMEOUT=60        # seconds allowed for one Treehouse worktree return
FM_TREEHOUSE_ROOT=                    # optional Treehouse state root override; defaults to ~/.treehouse
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'   # busy-pane signatures, shared by watcher, fm-crew-state pane fallback, and tmux helper
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after ghost and border stripping
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, shared by the tmux and herdr composer readers)
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful text submit; 0 disables
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # terminal-backed compatibility only: optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
FM_SUPERVISOR_TARGET=              # terminal-backed compatibility only: optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # terminal-backed compatibility only: max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # terminal-backed compatibility only: override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|command:<cmd>; absent = auto (macOS -> an OS notification)
FM_WEDGE_ALARM_EXEC=              # terminal-backed compatibility only: notifier seam routing every channel through `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; sourced tests default to "discard" (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # terminal-backed compatibility only: maximum seconds per notifier before its watchdog terminates it and continues; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # terminal-backed compatibility only: seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # terminal-backed compatibility only: Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # terminal-backed compatibility only: seconds between submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```

[`permission-stall-detection.md`](permission-stall-detection.md) records why the watcher uses direct harness-prompt matching but a timeout heuristic for macOS system dialogs.

`fm-teardown.sh` retries only Git's `Unable to create '...index.lock': File exists` return failure up to `FM_TREEHOUSE_RETURN_LOCK_RETRIES` times.
`FM_TREEHOUSE_RETURN_LOCK_RETRIES` accepts a nonnegative integer, and an unset, blank, or invalid value uses the default of 3.
`FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` accepts nonnegative whole or fractional seconds between attempts.
When it is unset or blank, `FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS` remains a compatible fallback, and a blank fallback uses the 1-second default.
An invalid nonblank wait falls back to 1 second rather than interrupting teardown.
Teardown never removes a lock during the retry window, and after that window it attempts stale-lock cleanup only for a still-present lock that passes the configured age and live-holder checks.

`fm-fleet-sync.sh` applies the same shape to an orphaned `.git/packed-refs.lock`: it retries only Git's `Unable to create '...packed-refs.lock': File exists` fetch failure up to `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES` times (nonnegative integer; unset, blank, or invalid uses the default of 3), waiting `FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` seconds (nonnegative whole or fractional; invalid falls back to 1 second) before each.
Only after those retries exhaust does it remove the lock, and only when it is provably stale - still present, mtime age at least `FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS` (default 30), and no `lsof` holder of the lock file or of the clone worktree itself (a live `git` keeps that as its cwd even in the window after it closes the lock and before it exits).
A live lock, a missing `lsof`, any failed check, or any other fetch failure keeps today's behavior.
Every wait, retry, and removal is printed to stderr, and a successful recovery also prints one `recovered:` summary line to stdout so a session-start refresh - which discards fleet-sync stderr and relays only stdout - still surfaces it.
The shared staleness proof lives in `bin/fm-lock-lib.sh`, which both `fm-teardown.sh` and `fm-fleet-sync.sh` use.
