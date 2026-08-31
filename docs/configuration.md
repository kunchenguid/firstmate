# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Operational home layout and state

This section is the single owner of the top-level operational-home layout; producer script headers and their help own exact child-file fields and mutation contracts.
The tracked code root contains the shared instruction, skill, documentation, workflow, and `bin/` surfaces, while each effective `FM_HOME` contains private operational directories.
`data/` holds durable private fleet records such as the project and secondmate registries, captain preferences, optional shared captain preferences, learnings, backlog, briefs, scout reports, and explicitly installed content-addressed extension packages under `data/extensions/packages/`.
`state/` holds runtime records such as task metadata, append-only status events, endpoint signals, watcher and wake-queue coordination, inactive terminal-outcome receipts under `state/terminal-outcomes/`, enabled extension working namespaces under `state/extensions/`, away-mode state, generated Relay artifacts, parent-side remote ledger copies under `state/secondmate-summary-cache/`, one-shot Bearings reconcile requests under `state/reconcile-notify/`, private secondmate config-reread generations with their retry and quarantine state, per-task steering-inbox records under `state/<id>.inbox/` (`bin/fm-task-inbox-lib.sh`), and parent-owned secondmate pending-reply records under `state/pending-replies/` (`bin/fm-pending-reply-lib.sh`).
`config/` holds local gitignored operating choices, including explicit extension bindings under `config/extensions.d/`, and `projects/` holds the local project clones that Firstmate reads but changes only through the narrow guarded and concrete captain-approved exceptions in `AGENTS.md`.
Untracked files and directories whose names begin with `scratchpad` are also gitignored, so temporary scratch does not make porcelain-based secondmate sync guards treat a home as dirty.

`bin/fm-spawn.sh` owns the base task-metadata fields it emits, while the runtime-backend section below owns backend-specific fields and selector interpretation.
The producing PR and Relay helpers own the fields they append, `bin/fm-classify-lib.sh` owns status-event vocabulary, and `bin/fm-crew-state.sh` owns current-state reconciliation.
Wake, watcher, away-mode, and Relay-specific state mechanics remain with their named scripts and reference sections rather than being duplicated into one exhaustive state tree here.

`bin/fm-session-start.sh`'s header is the single owner of session-start ordering, composed commands, digest contents, and the digest's startup mechanism.
`bin/fm-startup-network.sh`'s header owns the deferred startup stage that keeps every external-network call and the potentially slow inactive-outcome scan off that digest's blocking path, including its state files and the safety argument for running them later.
`docs/sessionstart-nudge.md` owns the native session-open adapter tiers that run or nudge the digest command, and the source routing between them.
`AGENTS.md` retains the run-once and read-once operator rules, lock-refusal safety, installation consent, and direct-report recovery boundaries because those facts apply at every session start.
Ordinary dead-direct-report recovery is owned by `stuck-crewmate-recovery`, while persistent-secondmate recovery is owned by `secondmate-provisioning`.

## Pi Calm preference (config/calm)

The Pi Calm extension stores the captain's home-local presentation choice in gitignored `config/calm` under the effective Firstmate home, resolved from `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `FM_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
The values it writes are `on` and `off`, each followed by one newline; an absent, unreadable, or unrecognized value defaults to off.
`max` is the legacy value written by a removed third presentation level whose behavior is now ordinary Calm, and it is still read as `on`, so a home upgraded from it keeps Calm on rather than dropping to off.
The `/calm` command replaces the file atomically before changing live presentation, so a failed write leaves the current choice unchanged rather than claiming persistence.
The extension reloads this preference on every Pi `session_start`, including startup, new, resume, fork, and reload reasons.
This preference is local to each Firstmate home and is not part of secondmate inherited configuration.

## Pi supervision branch

On a Pi primary, an in-process supervision branch handles eligible task-local wake rows and selected heartbeat reviews while keeping main-only rows on the captain-facing path; [docs/pi-supervision-branch.md](pi-supervision-branch.md) owns its conversation lifecycle, row eligibility, mixed-queue dispatch, heartbeat routing, and pre-drain recheck.
Supervision is default-on: once a Pi primary session owns this home's fleet lock, the branch is eligible for every task with no captain grant file required.
A genuinely no-op heartbeat is absorbed in bash and never reaches Pi, and every watcher-failure alarm stays on the captain-facing main path.
Away mode still declines every wake offer, and a broken branch still falls back to today's wake-to-main path.
The branch's role stays bounded exactly as the captain-approved architecture set it: it cannot merge a PR, land local work, or freshly spawn, and every existing captain gate remains unchanged.
Homes on any other primary harness never load this feature and are entirely unaffected.
`AGENTS.md`'s `state/` inventory routes the branch's runtime files to their format and lifecycle owners.
A captain-facing (verdict `captain`) branch outcome persists as one exact, sequence-keyed visible transcript entry and then opens one sequence-keyed processing turn on main, which stays open until main acknowledges that sequence through its `fm_branch_processed` tool.
The branch prompt's "Verdict: routine or captain" section owns the distinction between captain-facing, unsolicited routine, and unchanged-review outcomes.
The generated [Pi supervision protocol](supervision-protocols/pi.md) owns main's event ownership, acknowledgement duty, and conversational treatment for merged outcomes, while the persisted entry itself owns captain visibility.
A no-change heartbeat outcome explicitly reported with `task=fleet` and `silent=true` is delivered silently with no rendered note, while every other routine outcome still appends a rendered, sailboat-prefixed note.

## Pi supervision branch model and effort (config/supervision-branch-model, config/supervision-branch-effort)

Supervision is an easier job than the captain's own conversation, so the branch can run on a cheaper model than main.
It is also an easier job than the captain's own conversation needs reasoning for, so the branch can run at a shallower effort than main as well.
The Pi `/supervision-model` command settles both in one flow: it opens a selector over the models that Pi reports with configured credentials and that this home's stored credentials let the isolated supervision branch resolve, plus a first "Follow main" entry, and then a second picker for the branch's reasoning effort.
In Pi's terminal TUI, the model step uses Pi's bounded scrolling list with its input and fuzzy filtering primitives, the same list primitive Pi's `/model` picker scrolls: typing filters the entries, "Follow main" stays the first entry whenever it still matches, and a long catalog scrolls inside the dialog instead of running off the terminal.
The non-TUI RPC, JSON, and print modes have no custom-component surface and keep Pi's generic selector without search, where terminal overflow does not apply.
The effort list is a handful of levels and stays on Pi's plain selector dialog.
Both picks change the supervision branch alone and never the captain's own conversation model or effort.
It persists the model pick in gitignored `config/supervision-branch-model` and the effort pick in gitignored `config/supervision-branch-effort`, both under the effective Firstmate home, resolved from `FM_HOME`, then `FM_ROOT_OVERRIDE`, then the tracked code root derived from the extension path, or under `FM_CONFIG_OVERRIDE` when that test and specialized-setup override is present.
Firstmate keeps no model catalog of its own; the list is the intersection of what Pi reports when the picker opens and what a fresh isolated branch runtime can run.
A provider that exists only because an extension registered it inside the captain's session is not offered, while stored OAuth and API-key credentials retain their native credential type because Firstmate never copies, converts, installs, or overwrites credentials for the branch runtime.
The file holds one `<provider>/<model-id>` line followed by one newline, split at the first `/` so a provider-qualified model id such as `openrouter/anthropic/claude-sonnet-4-5` survives intact.
An absent, unreadable, or unparseable file means no pin, and the branch then follows main's own current model, applied explicitly and live whenever main changes models mid-session.
A valid pin wins over main and remains unaffected by main's model changes.
Picking "Follow main" removes the file, and the command writes a pin at mode `0600` and replaces it atomically so a failed write leaves the current choice unchanged rather than claiming persistence.
The file's current state decides the branch model on every branch build - the new conversation each main session start opens and the reopen after a model or effort change inside one session - and it overrides Pi's restore of whatever model a reopened branch session recorded, so the choice survives all of them.
That override is what keeps "Follow main" honest: a branch conversation that ran under an earlier pin still records that model, so clearing the file explicitly applies main's model rather than letting the reopened session restore the old one.
Only when main's own model is unknown, or this home's stored credentials cannot run it in the isolated branch runtime, does an unpinned build fall back to passing no override at all, which is the behavior from before this file existed; the wake is never lost over model choice, and the command says plainly when main's model could not be applied instead of reporting a change that did not take effect.
A pin naming a model Pi cannot hand back, because the model is unknown or has no configured credentials, is never silently downgraded onto main's model: the branch refuses to build and rejects the accepted wake to the watcher's captain-facing main path, exactly as any other unreachable branch does.
Picking also releases the live branch so the next wake reopens this session's own branch conversation under the new model without waiting for a session replacement.

The effort file holds one Pi thinking level followed by one newline, and the two pins are independent: a captain may pin a model, an effort, both, or neither.
The effort step runs after the model step because the effective branch model decides which levels exist: its menu is Pi's own supported-level list, so a model that maps no extended levels simply does not offer them and a non-reasoning model offers only `off`.
The picker keeps no effort catalog of its own; when main's model cannot be resolved, it first resolves the model recorded by the most recent branch conversation and uses Pi's supported levels for that effective model.
If neither model can be resolved, the picker invents no levels and the command says that the branch's effective effort cannot be determined.
An absent, unreadable, or unrecognized file means no effort pin, and the branch then follows main's own current effort, applied explicitly and live whenever main changes effort mid-session.
A valid pin wins over main and remains unaffected by main's effort changes.
Picking "Follow main" removes the file, and the command writes an effort pin at mode `0600` and replaces it atomically, exactly as it writes a model pin.
The effort file's current state decides the branch effort on every branch build, on the same create-and-reopen contract as the model pin and for the same reason: a reopened branch conversation records the effort it last ran under, so only an explicit override keeps "Follow main" honest.
Only when main's own effort cannot be read either does an unpinned build fall back to passing no effort override at all, which is the behavior from before this file existed.
Pi owns the clamp, so a pinned level the branch's model cannot run becomes that model's nearest supported level rather than a refusal; the branch is never refused over effort, the captain's raw pick is kept so it applies again on a model that supports it, and the command reports the level the branch will really run at rather than the raw pin.
An effort token Pi would not recognize at all is treated as no pin rather than passed to that clamp, which would otherwise collapse a typo into the model's lowest level.

Cancelling the model picker cancels the whole command and changes neither choice.
Cancelling only the effort picker keeps the standing effort choice and still applies the model pick made in the same run, and the command's one closing message reports both choices as they will actually take effect.
Both choices are local to each Firstmate home and are not part of secondmate inherited configuration, the same as the Pi Calm preference; a secondmate home pins its own supervision model and effort with its own `/supervision-model`.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations.
When the automatic transition gate applies, dispatch and completion are not separate operator actions: each moves its work item inside the same run that creates or removes the task's record, so the ordinary successful path cannot leave the backlog and live task set out of sync ([`bin/fm-backlog-transition-lib.sh`](../bin/fm-backlog-transition-lib.sh)).
Under that gate, dispatch accepts only an unheld, unblocked Queued or In flight item in this home; a missing, Done, held, or dependency-blocked item is refused before any endpoint or local copy is created.
Completion refuses to report success until the item is closed, and session start reconciles this home's own books after an interrupted run.
Automatic transition mutations address the configured `<data>/backlog.md` explicitly from the data directory's parent, keeping relocated backlog configuration, archives, and relative scout-report links together.
The gate does not apply to persistent secondmates, manual-backend homes, or homes without a backlog file, preserving their existing persistent-agent, manual, or ad-hoc lifecycle behavior.
On an automatic-backend home with a backlog, missing or incompatible `tasks-axi`, an unresolvable configured data directory, or one containing a control byte fails lifecycle work before mutation.
Secondmate handoffs bypass that routine-backend choice: `fm-backlog-handoff.sh` keeps only its own fleet-level validation, delegates the item move to `tasks-axi mv`, and requires a verified receiver wake after a new move becomes durable.
It moves in-scope `## Queued` items only and refuses `## In flight` and historical `## Done` records, which stay with their home for pruning or archiving.
Handoff item bodies must use at least two leading spaces, and the helper refuses a selected item with a single-space or tab-indented continuation rather than risk orphaning it.
Because bootstrap requires `tasks-axi` on `PATH` on every profile, that delegation works fleet-wide, and the `config/backlog-backend=manual` knob governs firstmate's own hand-editing of its backlog, not this validated helper.
Compatible means the installed build passes the shared version and feature probe owned by [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh), including the atomic multi-ID move required by handoff delegation.
Bootstrap requires compatible `tasks-axi` on every profile; see "Toolchain" below for missing-tool reporting and silent default-backend behavior.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact, not missing-tool reporting.
A `manual` home owns its backlog file outright: the lifecycle transitions above are skipped there, dispatch and completion never fail over the file's contents, and a completed teardown prints the hand edit that is owed instead.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` sections.

## Runtime backend (config/backend / FM_BACKEND)

For spawn-capable adapters, the runtime session-provider backend controls where task windows/endpoints are created, captured, sent to, watched, and killed.
`tmux` is the verified reference backend (see [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, `orca`, and `cmux` are experimental spawn backends (see [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md), and [`docs/cmux-backend.md`](cmux-backend.md)).
Treehouse remains the worktree provider for tmux, herdr, zellij, and cmux, since herdr, zellij, and cmux are session providers only; Orca provides both the task worktree and terminal endpoint.
New spawns choose the backend in this order: an explicit `--backend` flag that current authority for that exact task alone has authorized (a present captain instruction or the task's own accepted brief; never later-task precedent by analogy), then `FM_BACKEND`, then the first non-empty line of local gitignored `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
If more than one runtime marker is present, detection resolves innermost-first: `$TMUX` is checked before `HERDR_ENV=1`, which is checked before cmux's primary `CMUX_WORKSPACE_ID` marker and its documented fallback signals - tmux or herdr started from inside a cmux terminal is the innermost, currently-executing layer, while cmux itself (a terminal application, not a nestable multiplexer) is always checked last.
See [`docs/cmux-backend.md`](cmux-backend.md#runtime-detection) for why cmux can be selected when `CMUX_WORKSPACE_ID` is absent.
Auto-detected herdr or cmux prints a stderr notice naming `config/backend` and `--backend tmux` as opt-outs; auto-detected tmux stays silent to preserve existing default behavior.
Zellij and Orca are never auto-detected; select them by putting the name in a local `config/backend` file, by exporting `FM_BACKEND=<name>`, or by telling the first mate in chat.
Any value other than `tmux`, `herdr`, `zellij`, `orca`, or `cmux` is rejected until another adapter is implemented and verified.
`fm-spawn.sh` accepts `tmux`, `herdr`, `zellij`, `orca`, and `cmux` for ship and scout tasks; `backend=orca` and `backend=cmux` both still refuse `--secondmate` until secondmate launch semantics are designed for each.
`codex-app` is not an accepted runtime backend yet; [`docs/codex-app-backend.md`](codex-app-backend.md) owns the Codex App boundary.
The session-start secondmate liveness sweep uses the recovery-grade `fm_backend_agent_state` classifier where verified.
The comment above that function in `bin/fm-backend.sh` is the single owner of its detailed state contract and recovery authorization.
The compatibility helper `fm_backend_agent_alive` continues to collapse those detailed results to `alive`, `dead`, or `unknown` for older callers.
A herdr spawn additionally version-gates against the installed `herdr` binary's protocol and requires `jq`, refusing loudly on an incompatible or missing installation.
A zellij spawn additionally version-gates against the installed `zellij` binary's version and requires `jq`, refusing loudly when either is missing or the version is older than 0.44.
A cmux spawn additionally version-gates against the installed `cmux` binary's version, requires `jq`, and requires the control socket to be reachable and accessible (see [`docs/cmux-backend.md`](cmux-backend.md) "Setup" for the one-time socket-access configuration this needs; Automation mode is the recommended socket control mode, with Password mode supported via `config/cmux-socket-password`), refusing loudly and non-retryably on a `cmuxOnly`/unauthenticated socket.
A backend spawn refusal from a missing dependency, version gate, or unauthenticated socket is terminal for that selected backend; firstmate surfaces it as a blocker instead of silently retrying another backend.
Task meta records `backend=` only for a non-default backend; an absent `backend=` means `tmux`, preserving existing default-path meta files.
Every new task records `endpoint_task_id=` as the cleanup binding between the metadata filename and its opaque runtime endpoint.
A herdr task additionally records `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`.
A zellij task additionally records `zellij_session=`, `zellij_tab_id=`, and `zellij_pane_id=`.
An Orca task additionally records `orca_worktree_id=` and `terminal=`, with `window=fm-<id>` kept as the shared firstmate alias.
A cmux task additionally records `cmux_workspace_id=` and `cmux_surface_id=`.
Task selectors for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh` resolve centrally through `fm_backend_resolve_selector`.
A selector containing `:` is passed through as an explicit backend endpoint escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that themselves start with `fm-` route to their own metadata instead of being stripped.
A metadata-routed selector returns the recorded backend target (`terminal=` for Orca, otherwise `window=`), and matching explicit targets can still recover the recorded backend when metadata contains the same endpoint.
Only metadata-routed task selectors carry secondmate-marker and Codex-harness context; explicit endpoint escape hatches do not.
These five sentences are the single owner of the task-selector vocabulary; backend guides and other documents point here instead of restating the resolution order.
`fm-teardown.sh <id>` takes a task id directly and validates the complete metadata-only endpoint identity before any runtime dispatch or cleanup mutation.
Missing, empty, duplicate, malformed, backend-inconsistent, or task-mismatched endpoint records are preserved and refused.
Legacy tmux metadata remains cleanup-compatible when its exact window name is `fm-<id>`; opaque non-tmux endpoints require their recorded `endpoint_task_id=` binding.
`FM_HOME` determines Herdr's home label: the primary home uses `firstmate`, and a secondmate home marked by `.fm-secondmate-home` uses `2ndmate-<secondmate-id>`.
[`herdr-backend.md`](herdr-backend.md#watching-and-task-containers) owns launcher-bound workspace placement, the label-only fallback, collision handling, and recovery behavior.
The local `config/herdr-presentation-spaces` file instead opts a home out of, or explicitly in to, Herdr's default-on disposable single-task visual projection; [Presentation spaces](herdr-backend.md#presentation-spaces) owns its accepted values, default, Herdr version floor, migration, behavior, safety limits, recovery contract, and narrow locked session-start cleanup of exact restored idle-shell children.
The setting is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
For normal herdr operations, `HERDR_SESSION` selects the named session, but destructive test cleanup must not rely on `HERDR_SESSION` alone.
Use the explicit guarded cleanup path described in [`docs/herdr-backend.md`](herdr-backend.md) instead of `herdr server stop`.
For normal zellij operations, `FM_ZELLIJ_SESSION` selects the named session and defaults to `firstmate`.
Zellij has no per-home workspace split: primary and secondmate tasks share that one session, and visible tab titles are scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Use the guarded cleanup path described in [`docs/zellij-backend.md`](zellij-backend.md) instead of `kill-all-sessions` or `delete-all-sessions`.
cmux has no session layer at all - one workspace per task, in whatever cmux window is open - and its socket password (when configured) is read from local, gitignored `config/cmux-socket-password` under the effective config directory, never committed.
The caller-facing label remains `fm-<id>`, but the actual cmux workspace title is scoped by the active `FM_HOME` readable label plus a short hash of the resolved `FM_ROOT` path as `fm-<home-label>-<id>`.
Test cleanup must use the guarded path in [`docs/cmux-backend.md`](cmux-backend.md#current-operation-and-safety), never enumerate-and-close every workspace.
`config/backend` is inherited into secondmate homes under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor injects escalation digests into firstmate's own pane independently of where new task endpoints are spawned.
It currently supports only `tmux` and `herdr` supervisor panes.
Set `FM_SUPERVISOR_BACKEND=tmux|herdr` and `FM_SUPERVISOR_TARGET=<target>` to override both axes explicitly; for herdr the target is `"<session>:<pane-id>"`.
Without overrides, backend detection uses `$TMUX_PANE` first, then `HERDR_ENV=1` with `HERDR_PANE_ID`, then falls back to `tmux`.
That keeps a tmux pane nested inside herdr on the tmux transport, matching the runtime backend's innermost-first rule.
Target detection uses `FM_SUPERVISOR_TARGET`, then `$TMUX_PANE`, then `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` under herdr, then the legacy `firstmate:0` tmux fallback with a warning.
Selecting any other supervisor backend, including `zellij`, `orca`, or `cmux`, refuses at daemon startup instead of trying tmux injection primitives against a non-tmux pane.

## Away-mode wedge alarm channels (config/wedge-alarm)

When away-mode injection wedges past `FM_MAX_DEFER_SECS`, the sub-supervisor raises a loud, rate-limited alarm.
Beyond the durable `state/.subsuper-inject-wedged` marker and the tmux status-line flash, it attempts a configured backend-independent active alert that can reach the captain even when every pane and its backend status-line is unreadable.
`config/wedge-alarm` (local, gitignored) lists channel directives, one per non-empty, non-comment line; every listed non-`off` channel fires, best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with a single directive.
Directives are `off` (a position-independent kill switch that disables every active alert), `auto`/`default`, `osascript` (macOS Notification Center banner), `herdr` (herdr UI notification), and `command:<cmd>` (run `<cmd>` via `sh -c`, summary on `$1` and stdin).
An absent file means `auto`, i.e. default-on on macOS: the alarm exists precisely so a wedged away-mode primary is never silent, and it fires at most once per max-defer window after a genuine wedge.
A missing or failing channel logs and falls through to the next, never crashing the daemon.
See [`wedge-alarm.md`](wedge-alarm.md) for the current channel reference, [`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) for active evidence, and [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Trace context propagation (config/trace-context / FM_TRACE_CONTEXT)

The optional local, gitignored `config/trace-context` presence flag enables default-off native W3C trace-context propagation.
`FM_TRACE_CONTEXT` overrides the file: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked home session resolves those inputs once, and all spawns from that home use the frozen decision until a new session starts.
When launching a Secondmate, the primary copies the presence flag into its home and passes the primary session's frozen decision as a non-empty `FM_TRACE_CONTEXT=on|off` override for the Secondmate's own session start.
A Secondmate on a remote route is covered the same way: the primary resolves and records that task's carrier, and the configured host exports it and receives the same enablement snapshot.
The presence flag is session-scoped enablement, so it transfers at launch and is left unchanged by live convergence into a running home.
See [`trace-context.md`](trace-context.md) for carrier semantics, supported routes, the manual fleet-restart requirement, the session boundary, and safety limits; `bin/fm-trace-context-lib.sh`'s header owns the exact mechanics, and [`verification/trace-context.md`](verification/trace-context.md) records repeatable evidence.

## Turn-end pane-churn absorb (config/turnend-churn-absorb)

The optional local, gitignored `config/turnend-churn-absorb` presence flag opts this home into a default-off third form of positive work evidence in watcher triage.
With it present, every referenced task must independently show positive work evidence, and an eligible bare turn-ended task that lacks authoritative proof may satisfy that requirement when its pane content changed since the previous poll.
It stays opt-in because the other two proofs read a verdict the harness itself vouches for while this one infers execution from rendered bytes; with the flag absent triage behaves exactly as it did before.
`FM_TURNEND_CHURN_ABSORB_SECS` is a positive integer number of seconds, defaults to `900`, and bounds how long one endpoint's turn-ends may ride that evidence before surfacing anyway.
An invalid value fails closed and surfaces the wake.
The bound is required rather than cosmetic because churn and pane staleness read the same pane.
The flag is a home-local supervision-noise preference and is not inherited by secondmate homes, which run their own crew mix.
[`architecture.md`](architecture.md) owns the triage contract and `bin/fm-watch.sh`'s `signal_turnend_panes_churned` owns the exact evidence and fail-closed boundaries.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` sets `test.evidence.store_in_repo: true`, pins `commands.lint` to `bin/fm-lint.sh` so local lint matches CI, and pins `commands.test` to `bin/fm-test-run.sh --changed --exclude-family real-herdr-gated` so the gate's test baseline runs through the repository's own runner instead of a hand-chained walk of `bash tests/*.test.sh`.
Storing evidence in the repo publishes each run's test artifacts to the orphan `no-mistakes/evidence` branch and links them from the PR body, instead of keeping them on local disk under the no-mistakes home.
That branch shares no history with code branches, so evidence never enters a pushed feature branch or the default branch; the worktree's `.no-mistakes/` stays local and CI rejects tracked entries under that path.
`commands.test` stays changed-file-scoped and must never become a complete `tests/*.test.sh` walk: `--changed` selects only the families the branch's changed files map to, runs concurrency-admitted scripts with bounded concurrency, keeps every unproven stateful script serial, and applies its own generous per-script bound.
The runner's `--help` output owns the exact selection, scheduling, and timeout rules.
It excludes `real-herdr-gated` on the same grounds the portable CI lanes do, because those scripts drive a live Herdr lab and the dedicated required Herdr lane owns that coverage.
Because firstmate always supplies `--intent`, that command is a baseline and the Test step still runs its intent-targeted evidence agent on top of it.
`commands.test` executes code, so no-mistakes honors it only from the default-branch copy of `.no-mistakes.yaml`; a pushed branch cannot change what the gate runs.
See [CONTRIBUTING.md](../CONTRIBUTING.md) for the firstmate-specific local test policy and entry points.
Portable shard evidence and coverage rules are in [fm-test-portable-shards.md](fm-test-portable-shards.md); [herdr-backend.md](herdr-backend.md#destructive-lab-safety) owns the real-Herdr lane's isolation boundary, and [runtime-backends.md](verification/runtime-backends.md#herdr) owns active evidence.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Domain-local preferences for one captain's fleet live locally in each home's `data/captain.md`; it is gitignored and printed in the session-start context digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the current file and curate the matching bullet in place under the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) tiering and archive contract; add a new bullet only for a genuinely new durable preference.
Shared captain preferences that apply across secondmate domains live only in the primary home's optional `data/captain-shared.md`.
`secondmate-provisioning` owns its propagation contract, including the required header, read-only secondmate copies, quarantine diagnostics, and the rollout rule that existing homes trim `data/captain.md` by hand after first propagation rather than deleting private content automatically.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and printed after the captain-preference files in the session-start context digest.
The file is created lazily on first learning and follows the internal [`stow` skill's](../.agents/skills/stow/SKILL.md) aging-tier and cold-archive contract: inspect the current file first and curate it instead of appending forever.
There is no shared learnings file by captain decision.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-home allowance for the startup prompt-memory surface: `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` together.
The locked mutable bootstrap path materializes its visible default of `7500` estimated tokens in a primary home when the file is absent.
To select another allowance, replace the primary home's file with one valid positive value in the exact format below; the next locked bootstrap convergence or `bin/fm-config-push.sh` propagates it to registered secondmates.
A secondmate does not create an independent default and instead receives the primary value through the inherited-local-material contract in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).
The file must be one positive base-10 integer followed by exactly one newline in a regular, single-linked file beneath a non-symlinked `config/` directory.
Malformed, multi-line, symlinked, hardlinked, special, or otherwise unsafe values are rejected rather than treated as a default.
Use `bin/fm-startup-memory-budget.sh read` to validate and print the effective value, or `bin/fm-startup-memory-budget.sh report` to account for the three files.
The stable local estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation rather than a provider-exact tokenizer.
An inherited `data/captain-shared.md` counts in a secondmate's total but remains primary-owned and read-only there.
The internal [`/stow` skill](../.agents/skills/stow/SKILL.md) owns curation and its automatic secondmate cascade, which accounts every home against this same per-home allowance separately rather than against a fleet total.
The helper's header owns exact parsing, publication, and report output mechanics.

## Stow pass horizon (config/stow-pass-horizon)

`config/stow-pass-horizon` is an optional local, gitignored presence flag that opts this home in to the pass-count decay horizon in the internal [`/stow` skill](../.agents/skills/stow/SKILL.md).
Without it a `/stow` pass decays memory entries on their wall-clock horizons alone - 30 days for `aging`, 7 days for `perishable` - which is the default and unchanged behavior.
With it, an entry is also stale after 10 passes (`aging`) or 3 passes (`perishable`) that evaluated it without reinforcing it, whichever horizon it reaches first.
Opt in for a home that stows often enough that entries never sit unreinforced for a wall-clock horizon, so memory only grows against the startup-memory budget above; a home that stows rarely already exceeds its date horizon on a single pass and gains nothing.
The flag is per home and is not inherited by secondmate homes, because stow cadence is a property of the home doing the stowing.
Only the file's presence is read, so its contents are ignored; remove it to return to the default contract on the next pass.
The skill text owns the marker spelling, the tick order, and the reinforcement rule.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
The concise single-line route contract is owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table), including the parser-compatible fields, one-sentence summary requirement, `home:` pointer to the seeded charter, and limit on extra registry prose.
A remote route adds `host:` and `root:` before the existing fields and places the whole secondmate home on that SSH host; it does not make ordinary workers remotely placeable.
[`remote-secondmates.md`](remote-secondmates.md) owns current remote setup, operation, and safety behavior.
Use `fm-home-seed.sh validate` to check the complete operational registry contract documented by the command itself.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
Use `fm-home-seed.sh <id> - {<project>...|--no-projects}` to lease a fresh local firstmate worktree for the secondmate home.
For remote provisioning, including supplied project origins, follow [Remote second mates](remote-secondmates.md#provision-a-route).
Use the deliberate `--no-projects` signal only for a firstmate-repo domain that needs no separate project clones.
It cannot be combined with a project list, and omitting both still fails loudly.
A project-less seed requires no existing project clones or `data/projects.md` entries in the home, so it refuses a populated-home conversion without changing that home.
A preexisting project-bearing charter is also refused until it is re-scaffolded with `--no-projects` or removed.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog queued items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it refuses In flight, Done, or non-secondmate homes, and a new move succeeds only after waking the recorded receiver.
If the wake is known to have failed, the moved item remains durable and rerunning the same handoff retries it idempotently; an unresolved delivery is reported and never blindly resent.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.
The seeded home's `data/charter.md` owns the standard secondmate lifecycle and escalation contract; the route file points to it through the existing `home:` field instead of adding another pointer.
Each seed writes an `.fm-secondmate-home` identity marker at the home root, alongside a durable `.fm-secondmate-parent` record of the home's route to its parent (see "Provision a route" in [`docs/remote-secondmates.md`](remote-secondmates.md)).
The tracked root `.gitignore` ignores both markers, so validation can read them without making a freshly seeded home appear dirty to porcelain-based safety checks.
This does not relax protection for any other untracked file.
An existing linked-worktree home that predates this rule advances through its marker-only state during its next bootstrap or spawn local sync, after which Git ignores the marker normally.
A local standalone-clone home cannot receive a primary-local commit through that no-fetch sync, so it receives the rule through `/updatefirstmate`'s origin refresh instead.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, most scripts use the repo root as the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`bin/fm-send.sh` is intentionally stricter than that general fallback: it requires `FM_HOME` to be set before resolving a target, so operator steers cannot silently resolve against the wrong home.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.
Before `fm-brief.sh`, `fm-spawn.sh`, or `fm-afk-launch.sh` persists a path or passes it to another process, it resolves each applicable relative `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` directory against the caller's working directory, preserves accepted absolute spellings unchanged, and rejects an unresolvable relative directory with the offending variable named.
`fm-spawn.sh` additionally rejects control bytes in those raw directory inputs before shell or filesystem normalization can change which path the backlog gate checks.
Lifecycle access to a backlog, task record, or pending-close record must resolve within its configured data or state root, and a final-component symlink is refused even when its target remains within that root.
Bootstrap applies the same relative `FM_HOME` resolution only when embedding that home in the generated Relay poll shim; other transient consumers retain their existing shell-relative behavior.
For the herdr backend, `FM_HOME` also determines the workspace label used by the adapter.
For the zellij backend, `FM_HOME` does not split containers, but it determines the readable home prefix embedded in visible tab titles; use `FM_ZELLIJ_SESSION` when a separate zellij session is needed.
The full zellij home label also includes a short hash of the resolved `FM_ROOT` path.
For the cmux backend, `FM_CONFIG_OVERRIDE` overrides where `config/cmux-socket-password` is read from, while `FM_HOME` determines the default config path and readable home prefix embedded in workspace titles.
The full cmux home label also includes a short hash of the resolved `FM_ROOT` path, and there is no per-home container split.

## Harness support

claude, codex, opencode, pi, pi-signed, grok, kimi, and cursor are empirically verified for crewmate and secondmate launches; gemini is verified for crewmate and scout launches only, and [README requirements](../README.md#requirements) own the set supported for the primary session.
A cursor secondmate or primary runs the tracked project-scope `.cursor/hooks.json` in its own home and must be launched with `--trust`, or no project hook loads; [`docs/supervision-protocols/cursor.md`](supervision-protocols/cursor.md) owns its supervision protocol.
Cursor typed-submit confirmation is verified on tmux and Herdr only.
On Zellij, cmux, and Orca a typed-plane Cursor send (a harness-native invocation or an explicit backend target; ordinary text steers ride the durable inbox and exit 0 at enqueue) lands, but `fm-send` reports delivery unconfirmed and exits non-zero because their shared submit core does not consult the busy footer; [runtime backend verification](verification/runtime-backends.md#cursor-agent-cli) owns the evidence and transcript-state boundary.
muse is verified for crewmate and scout launches ONLY, and `fm-spawn.sh` refuses it for a secondmate, because muse ships no usable hook surface for a primary session's turn-end supervision; [`docs/verification/muse.md`](verification/muse.md) owns that evidence.
cursor is refused for every ordinary UNATTENDED launch, ship, scout, and secondmate alike, because it runs under `--auto-review --sandbox enabled` and that classifier prompts for any call it does not deem safe, leaving a pane parked on a dialog no one answers while the `cursor-transcript` fold still reads it as working.
Set `config/crew-harness` or `config/secondmate-harness` to codex or claude for unattended work, since a cursor value there now fails at spawn time.
cursor remains permitted when a person is in the pane or a separately proven outer isolation envelope governs the worker, and each case requires passing `--cursor-exemption attended` or `--cursor-exemption envelope:<name>` on the spawn itself.
That grant is per invocation and is recorded as `cursor_exemption=` in the task's meta, so it cannot leak to a later spawn in the same shell and an audit can tell the two grounds apart.
An envelope name is whitelisted to letters, digits, `.`, `_`, and `-` starting on a letter or digit, so a grant can neither be unauditable nor carry a line break into the record that would displace another recorded field.
A grant is refused outright on a non-cursor harness, on the local and remote spawn routes alike, rather than recorded where a later relaunch onto cursor could read it back as authority nobody granted.
Across a relaunch an `envelope:<name>` grant is inherited because it describes a durable property that still governs the replacement agent, while an `attended` grant is never inherited because the person who attested may be gone.
`fm_control_harness_supports_kind` in [`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh) owns that rule for both the launch owner and the control plane, so a relaunch onto cursor is refused before the running agent is stopped.
muse also needs a worker-reachable credential before spawning, and the portable fleet path is the `<config>/muse/auth.json` credential stored by `muse login`, because a caller-only `META_API_KEY` does not cross a long-lived backend daemon.
gemini is likewise refused for secondmates because it has no primary supervision protocol; [its adapter reference](../.agents/skills/harness-adapters/references/harness/gemini.md) owns the credential precondition, canonical-launch wiring, and raw-launch limitations.
New harnesses get verified through a supervised trial task before joining the set.
The verified adapter evidence - each harness's busy-state source, interrupt and exit behavior, skill-invocation syntax, and per-harness quirks - lives in the skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
The executable interrupt and exit mechanics live in [`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh), and [`docs/agent-control.md`](agent-control.md) owns their lifecycle-control architecture.
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
Pi-family launches adapt the regular-TUI safeguard to the installed CLI's capabilities; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns the exact version-safe launch mechanics.
Enabled primary-session turn-end guard integrations are tracked as repo-level hook files and documented in [`docs/turnend-guard.md`](turnend-guard.md).
Kimi remains outside the primary turn-end guard integrations; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) owns its separate captain-approved crew wake hook.
Primary-session watcher wake protocols are rendered at session start by [`bin/fm-supervision-instructions.sh`](../bin/fm-supervision-instructions.sh) from [`docs/supervision-protocols/`](supervision-protocols/).
Claude's Stop `asyncRewake` hook owns tokenless re-arm cycles, Cursor's stop hook parks on the watcher, Grok uses background-notify cycles, Codex uses bounded foreground checkpoints, Pi and pi-signed use the same two tracked primary extensions, and OpenCode uses its TUI plugin.
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When pi-signed is selected, Firstmate preserves `FM_PI_HARNESS=pi-signed` and refuses the launch if the selected executable is unavailable rather than falling back to pi; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns executable resolution and launch mechanics.
Plain Pi launches set `FM_PI_HARNESS=pi`, so a signed primary's environment cannot relabel a plain Pi worker.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents, optionally followed by model and effort tokens on the same line.
The first non-empty, non-comment line is parsed as `<harness> [<model>] [<effort>]`.
A bare `<harness>` preserves the previous behavior: harness only, with no model or effort launch flag.
When the harness token is absent or `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, and no model or effort is read from that file.
`fm-harness.sh secondmate-model` and `fm-harness.sh secondmate-effort` expose only the optional tokens from `config/secondmate-harness`; `config/crew-harness` remains a bare adapter-name file.
Changing this pin affects the next secondmate spawn or control-plane relaunch; the relaunch profile rules are owned by [`docs/agent-control.md`](agent-control.md#transactional-relaunch).
An explicit harness argument to `fm-spawn.sh` still overrides either config file for that spawn only.
An explicit `--model` or `--effort` overrides the matching token from `config/secondmate-harness`; for a local route, an explicit harness or raw launch command starts with clean model and effort defaults unless those flags are also passed.
Remote secondmate routes accept verified harness adapters only and reject raw launch commands.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
The inherited-local-material contract is owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); its harness-relevant consequence is that a secondmate's own crewmates use the primary's dispatch profiles and static harness value.
Those inherited values are defaults and rules only; `fm-spawn` still permits a consciously chosen explicit runtime outside the config.
`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.
For Kimi crews, `fm-spawn.sh` runs `fm-kimi-turnend-hook.sh install`, drops a per-task `.fm-kimi-turnend` pointer in the worktree, and records the matching private registry token for teardown.
Kimi continues to use the captain's normal Kimi home, including the existing config, skills, and memory; Firstmate does not create an isolated Kimi home.
The Kimi installer requires an existing regular non-symlink `~/.kimi-code/config.toml`, `python3` with `tomllib`, and `jq`; it validates but never serializes the captain's TOML and refuses before writing when the config is missing, malformed, or surprising or when either tool requirement is unavailable.
Its `remove` action excises only the marker-delimited Firstmate region and removes Firstmate's hook files.
For Pi and pi-signed secondmate launches, `fm-spawn.sh` starts the selected executable with `-e` pointed at the secondmate home's own tracked `.pi/extensions/fm-primary-pi-watch.ts` and `.pi/extensions/fm-primary-turnend-guard.ts`, both already present from the secondmate home's git worktree.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best matching rule with judgment, resolves its profile object or array under the operating contract in `AGENTS.md` section 4 and `quota-array-dispatch`, and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Secondmate spawns are exempt and still resolve through `config/secondmate-harness` and its optional model and effort tokens.
This section is the single owner of the canonical schema and its per-field semantics.
`AGENTS.md` section 4 owns the always-loaded dispatch intake boundary, and `quota-array-dispatch` owns the completion-aware profile-array selection procedure.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "<adapter>", "model": "<optional model>", "effort": "<low|medium|high|xhigh|max, optional>" }
      ],
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "<adapter>", "model": "<optional model>", "effort": "<optional effort>" }
  ]
}
```

Per rule, `when` and `use` are required.
Both `use` and the optional top-level `default` accept either one profile object or a non-empty array of profile objects.
The single-object form stays fully backward-compatible, and every profile needs `harness`.
Profile `model` and `effort` fields and rule `why` are optional.
An omitted model or effort means the selected harness uses its own default for that axis.
Every profile array is an implicit quota-aware choice resolved through `quota-array-dispatch`.
If no dispatch rule fits, firstmate resolves `default` through the same object-or-array path before falling back to `config/crew-harness`.
If a selected profile carries an effort value the chosen harness does not accept, `fm-spawn.sh` records the requested `effort=` in task meta for traceability but omits the launch flag, and bootstrap reports the invalid harness/effort pair as a `CREW_DISPATCH` diagnostic when it is visible in the file.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
When the file exists, bootstrap validates it with `jq`.
Valid files stay silent by default; with `FM_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emits `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, one `BOOTSTRAP_INFO:` fact per rule, and one fact for the optional default profile set.
Malformed JSON, an empty or malformed rule/default array, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
While the file remains present, no crewmate or scout spawn may proceed without an explicit resolved harness; malformed configuration must be reported and corrected rather than selected around.
Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## Toolchain

On session start the first mate detects what its required toolchain is missing or too old and lists each problem with either an exact install command or manual instructions.
It installs automatically supported tools only after you say go; manual-only tools remain for you to install from the printed instructions.
Required tools come in two parts: a universal toolchain every home needs regardless of backend, and a per-backend delta that follows the runtime backend actually resolved for this home.
The universal toolchain is node, git, gh with GitHub auth via `gh auth login`, no-mistakes v1.46.0 or newer, compatible gh-axi, chrome-devtools-axi, compatible lavish-axi, compatible tasks-axi per "Backlog backend" above, and compatible quota-axi.
[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns the axi-family floor policy and the gh-axi and lavish-axi floors, while [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) and [`bin/fm-quota-axi-lib.sh`](../bin/fm-quota-axi-lib.sh) hold their own tools' floor constants.
This section is the single owner of that universal toolchain list; backend guides' prerequisites point here and add only their backend-specific tools.
In that list, no-mistakes runs the validation pipeline, gh-axi, chrome-devtools-axi, and lavish-axi cover GitHub, browser, and rich-review operations, and tasks-axi plus quota-axi back backlog mutations and quota-aware array dispatch.
The per-backend delta is required only for the backend resolved from `FM_BACKEND`, then `config/backend`, then runtime auto-detection, then default `tmux`, so a home is never told to install a tool an inactive backend or feature would need.
That delta is owned in code by `fm_backend_required_tools` in `bin/fm-backend.sh`: the resolved backend's own session-provider CLI (`tmux`, `herdr`, `zellij`, `orca`, or `cmux`), `jq` for the JSON-emitting experimental adapters (`herdr`, `zellij`, `cmux`) whose spawn and liveness paths parse the backend's JSON output, and the `treehouse` worktree provider for every session-provider-only backend (`tmux`, `herdr`, `zellij`, `cmux`).
Backend tool availability uses the adapter's own executable resolver, so bootstrap and spawn agree on supported non-`PATH` locations such as cmux's bundled CLI.
An unknown resolved backend emits `BACKEND_INVALID` and blocks dispatch instead of silently dropping its dependency delta or falling back to tmux.
Orca provides both the task worktree and terminal endpoint (see "Runtime backend" above), so `backend=orca` requires only `orca` on top of the universal toolchain and skips both `treehouse` and every other backend's session CLI.
A herdr, zellij, or cmux home is therefore never told `tmux` is missing, and the `treehouse` durable-lease upgrade check runs only for the backends that actually use treehouse.
When `config/crew-dispatch.json` exists, bootstrap also requires `jq` for dispatch profile validation.
When Relay is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
`tasks-axi` and `quota-axi` are required bootstrap tools in every profile, the same class as `lavish-axi`.
An absent or incompatible `tasks-axi` reports `MISSING: tasks-axi (install: npm install -g tasks-axi)`; when `config/backlog-backend` is not `manual`, a home with a backlog refuses lifecycle mutation until compatible `tasks-axi` is on `PATH`, while a manual-backend home keeps its backlog hand-edited.
An absent or incompatible `gh-axi` reports `MISSING: gh-axi (install: npm install -g gh-axi && gh-axi setup hooks)`.
An absent or incompatible `lavish-axi` reports `MISSING: lavish-axi (install: npm install -g lavish-axi && lavish-axi setup hooks)`.
An absent or too-old `quota-axi` reports `MISSING: quota-axi (install: npm install -g quota-axi)`; firstmate cannot resolve a profile array without a compatible binary.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
In a read-only session that did not get the fleet lock, the same line is advisory and omits the checkout command.
The locked session-start deferred network stage runs bootstrap's best-effort project clone refresh through `fm-fleet-sync.sh`; [`fm-bootstrap.sh`'s header](../bin/fm-bootstrap.sh) owns the exact clone-refresh overlap, liveness-before-convergence, per-mate concurrency, ordered diagnostic replay, and sequential-fallback contract.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms.
Normal completed runs keep local-only and no-origin skips silent.
If bootstrap kills a timed-out refresh, it replays any completed `fm-fleet-sync.sh` output before the aggregate timeout skip so no finished result is lost.
A killed refresh (or a teardown process kill) can leave an orphaned `.git/packed-refs.lock` in a clone, which makes the next refresh's fetch fail with Git's `Unable to create '...packed-refs.lock': File exists`.
On that signature only, `fm-fleet-sync.sh` retries the fetch with a bounded wait for the lock to self-clear, then removes the lock and retries once more only when it can prove the lock stale, exactly like the `fm-teardown.sh` `index.lock` recovery.
It never removes a live lock, leaves any other failure shape untouched, and prints every wait, retry, and removal to stderr plus a one-line `recovered:` summary to stdout on success so that this session-start relay still surfaces the recovery.
The same deferred network stage performs guarded tracked-file sync and propagates declared inherited local material into each validated live home under that sequencing contract.
Local routes use direct guarded filesystem operations, while remote routes delegate sync and allowlisted transfer through their configured SSH host without probing any unconfigured fleet.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
When a running home advances and its loaded instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself through the stable `fm-<id>` selector and reports the exact completed send as `BOOTSTRAP_INFO:`.
If that send fails, bootstrap keeps an idempotent retry marker and emits `NUDGE_SECONDMATES:` with the failure reason.
The same bootstrap run emits `SECONDMATE_LIVENESS:` only when a registered secondmate is skipped or its relaunch fails; already-live and successfully relaunched secondmates are handled silently.
For a mid-session inherited local-material edit where tracked-file sync is not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each live home's `crew-dispatch.json`, `crew-harness`, `backlog-backend`, `backend`, `herdr-presentation-spaces`, `startup-memory-budget`, `trace-context`, and `data/captain-shared.md` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero for real propagation errors or config-reread send failures.
When an allowlisted config item changes for an already-running local home, it sends the literal-content reread pointer described in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md); unchanged allowlisted config sends no pointer unless a previous delivery is pending.
A changed remote home instead receives one durably recorded marked re-read instruction after the allowlisted bytes have transferred because primary-local generation paths are not meaningful on another host.
The locked bootstrap inheritance pass uses the same placement-specific behavior; see `secondmate-provisioning` for the single contract owner.
That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## Watched tool updates (config/watched-tools.json)

`config/watched-tools.json` is an optional local, gitignored list of the tools this home depends on.
When it is present and the check is armed, [`bin/fm-tool-update-check.sh`](../bin/fm-tool-update-check.sh) reports two conditions, and keeps them deliberately distinct:

- `<tool> update available` means a newer version exists at the tool's update source.
- `<tool> update not in effect` means a newer copy is already installed on this host, but `PATH` still resolves an older one.

The second condition is the reason the check exists.
An update can install correctly and stay inert because an earlier `PATH` entry still holds an older copy, and a check that only asks whether a newer version is published reports that host as up to date.
The script therefore runs every copy of a watched command found on `PATH` and asks it for its own version, rather than trusting one lookup or reading a version out of a directory name.
It only reports; it never installs, updates, fetches, or changes `PATH`, a version manager, or any installed tool.

This section is the single owner of the canonical schema.
`bin/fm-tool-update-check.sh` owns probe mechanics, cadence, and the report record.

```json
{
  "tools": [
    {
      "name": "<label used in the report>",
      "command": "<optional bare executable name to find on PATH>",
      "version_args": ["<optional args that make it print its version, default --version>"],
      "announce_pattern": "<optional extended regex matching the tool's own update announcement>",
      "announce_args": ["<optional args for the command that carries that announcement, default version_args>"],
      "git": {
        "repo": "<optional absolute path to a local clone>",
        "remote": "<optional remote name, default origin>",
        "branch": "<optional branch, default the remote's own default branch>"
      }
    }
  ]
}
```

Each entry needs a `name` and at least one of `command` or `git`; an entry may carry both.
A `command` entry gives the `PATH` comparison above, and adding `announce_pattern` also reports the tool's own update announcement, which is how a tool that already reports its own updates is read rather than reimplemented.
A tool does not always announce a new release on the command that prints its version: `no-mistakes --version` prints only the version, while its other commands carry the announcement.
`announce_args` names the command to search for the announcement in that case, and it is asked only of the copy `PATH` resolves; without it the version probe's own output is searched.
An `announce_pattern` that is not a usable extended regular expression stops `arm`, and during a sweep it is reported as that one tool's own check failure so one broken pattern never stops the other watched tools from being checked.
A `git` entry reports how many commits the local clone is behind its remote branch, and stays silent when the clone is current or ahead.
An omitted `branch` uses the remote's default branch, taken from the clone's own record of it and otherwise asked of the remote directly, so a `--single-branch` clone still resolves.
Both probe kinds are read-only and bounded, and a probe that cannot answer is reported as a check failure rather than assumed current.
See [`docs/examples/watched-tools.json`](examples/watched-tools.json) for a starting point to copy into local `config/watched-tools.json`.

Arm the check once per home with `bin/fm-tool-update-check.sh arm`.
That writes `state/tool-updates.check.sh` and binds its bytes with `bin/fm-check-register.sh`, so the existing watcher polls it on its normal cadence and turns its one line into a `check:` wake; no separate schedule is involved.
The armed check runs whenever that home has a watcher running, and arming alone does not make watcher supervision required, so a home with no in-flight work and no other reason to watch does not start a watcher just for this check.
`bin/fm-tool-update-check.sh disarm` removes the shim, its trust binding, and the report record.
The check prints nothing when everything is current, and `state/.tool-updates` records the findings the last report was made from so the same pending update is reported once instead of on every poll.
A changed or returning condition is reported again.
Adding, removing, or changing a watched tool is an edit to this file and needs no code change or re-arming.
This file is not inherited by secondmate homes, so each home watches the tools it actually depends on.

`FM_TOOL_UPDATE_INTERVAL` (default 900 seconds, `0` to probe on every run) sets how often probes actually run, `FM_TOOL_UPDATE_PROBE_SECS` (default 5) bounds one probe, and `FM_TOOL_UPDATE_BUDGET_SECS` (default 20) bounds a whole sweep.
A sweep that runs out of budget says which tool it did not reach rather than reporting the rest as current.
The sweep must finish inside `FM_CHECK_TIMEOUT` (default 30), because a run the watcher kills prints nothing and records nothing and would then repeat that silence on every poll.
So a budget larger than that timeout allows is cut down to what fits instead of being refused, and the cut is reported in the report line.
A budget that is not a whole number from 1 to 120 is still refused outright.

## Relay (.env)

Relay lets a firstmate instance answer public mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It covers both public surfaces the relay supports: `@myfirstmate` mentions on X, and mentions of the myfirstmate bot in a Discord server where it is installed.
Both surfaces are the same opt-in and the same machinery - one pairing token, one relay poll, and one reply path - so everything below applies to Discord mentions unless a line names a platform explicitly.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while its surrounding conversation context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

To turn it on:

1. Sign in at [myfirstmate.io](https://myfirstmate.io) with X or Discord.
2. For the Discord surface, use the dashboard's install link to add the myfirstmate bot to a server you administer; the X surface needs no install step.
3. Copy the pairing token from the dashboard into this firstmate home's gitignored `.env` as `FMX_PAIRING_TOKEN=<token>`.
4. Start a new firstmate session so bootstrap picks the token up, then mention `@myfirstmate` on X or mention the bot in a server where it is installed.

The dashboard owns account creation, identity linking, bot installation, and token issuance; this document owns only what the local firstmate home does with the token once it is in `.env`.

The locked session-start bootstrap step turns the token into local generated state.
It writes `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.
The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section is the single owner of the Relay cadence contract: a Relay instance polls every 30 seconds instead of the default 300, only a Relay instance speeds up because a non-Relay home has no `config/x-mode.env`, and the session-start supervision operating block includes the cadence instruction when that file exists.
The active primary-harness supervision protocol owns how that sourced cadence reaches the watcher process.
Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence transition - opt-in while a watcher is already running, or opt-out - is applied by restarting the home-scoped watcher through the emitted harness protocol; bootstrap deliberately never restarts the watcher itself.
While away mode is active the daemon owns the watcher and its default cadence applies; away-mode Relay cadence is a deferred follow-up.
When the token is removed or empty, the next locked session-start bootstrap step removes those artifacts.
Steady-state off is silent and writes nothing.
Relay remains additive to non-Relay lifecycle behavior: homes without the generated artifacts keep the default watcher cadence and do not run the Relay poll.
Its request handling remains in Relay-specific `bin/` scripts and the `fmx-respond` skill, while the watcher owns authenticated dispatch from the generated local identity shim.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A newly offered pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before emitting that wake, and subsequent offers of the same request stay silent even after the inbox is drained following an answer or dismiss.
Offer markers share the context registry's bounded seven-day retention, so losing or expiring the local marker lets a relay offer wake firstmate again.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
The preserved object may also carry `in_reply_to_chain`, an optional oldest-first transcript of the surrounding conversation: entries shaped `{author_handle, text, unavailable, images, attachments}` plus an optional `kind` of `reply` (a reply ancestor), `thread_starter` (the message a thread grew from), or `history` (a recent nearby message), where an absent `kind` means a legacy reply-ancestor or thread-starter entry.
The chain is untrusted third-party public input and is often absent today (the relay currently sends it only for Discord reply chains and thread starters), so consumers treat it as strictly optional, tolerate unknown or missing fields, and read an entry with `unavailable: true` as a gap rather than content; the `fmx-respond` skill owns how firstmate reads it for referent resolution.
The mention and its chain entries may also carry attached media as image or file URLs, in fields such as `images` and `attachments`, either as bare URL strings or as objects with a `url`; a mention whose own media is empty can still have screenshots on its `thread_starter` entry.
The poll preserves those URLs in the stashed object and never downloads them, so nothing is fetched on the polling path: the responding agent retrieves and views the media with its own tools when it handles the mention.
The `fmx-respond` skill owns which hosts that fetch is restricted to and the untrusted-content handling that applies to whatever comes back.
At the same time the poll records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) from the same authoritative relay payload, best-effort and keyed by `request_id` so concurrent requests never overwrite each other; it survives the inbox cleanup that follows the acknowledgement, so a delayed follow-up can recover the original platform and split budget even with no task link.
`recorded_at` begins as the locally observed first-seen Unix epoch and remains unchanged when the same request is polled again.
A successful live initial answer refreshes it to the time that the relay establishes the follow-up binding; dry-runs, failed answers, and follow-ups do not refresh it.
Configured polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records fall back to their file modification time so they cannot remain indefinitely.
The record is written only when a platform or explicit budget is actually known, so an unknown-platform mention leaves no useless entry.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts up to three completion follow-ups on genuine milestones, finishing with a `--final` one for ordinary Relay-linked work. When a typed promised-final commitment is registered, `bin/fm-public-followup.sh` owns the terminal reply and clears the legacy link after its receipt is validated.
That link stores optional reply-platform context so Discord-originated follow-ups keep Discord's larger message budget after the inbox file has been drained.
Platform/budget resolution is layered and independent of the task link: a per-axis `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override (how `bin/fm-x-followup.sh` passes a recorded link's context) wins.
For either axis without an override, `bin/fm-x-lib.sh:fmx_resolve_reply_context` owns the source order: the durable per-request registry is consulted first, then the still-present inbox payload, then - for a follow-up posted live by request_id - an authoritative relay lookup via `POST /connector/request-context` (`{request_id}` in, `{platform, reply_max_chars}` back).
This is what keeps a delayed request-id follow-up on the original platform's budget even after the inbox is drained and with no task link surviving; the relay step is confined to the live follow-up path so the answer path and every dry-run stay network-free.
The link is home-local by construction, because it lives in that home's own `state/<task-id>.meta`: work routed to a secondmate has no record here, so `bin/fm-x-link.sh` refuses it, names the registered secondmate home the task was found in when it can, and points at the promised-final path (`bin/fm-public-followup.sh register ... --work-home secondmate:<id>`), which is the only follow-up mechanism that binds work in another home.
`bin/fm-x-link.sh` follows the same ordering when recording a fresh link's context and requires `jq`; its request-context lookup is best-effort: no token or `curl`; a non-2xx response; an unresolved response; or a relay version without that endpoint leaves the context unknown.
In that case the link is still recorded but `bin/fm-x-link.sh` prints a loud warning; and when either a follow-up's platform or explicit budget cannot be authoritatively resolved from any source, `bin/fm-x-reply.sh` refuses it (fail-safe exit 8) rather than posting with a local default - firstmate holds and retries it once both values are recoverable.
Fresh links start with `x_followups=0` and the current timestamp; when relinking the same relay request onto a successor task, pass paired `--carry-count <n> --carry-ts <epoch>` flags plus any prior `x_platform=` and `x_reply_max_chars=` as `--carry-platform <x|discord> --carry-max <n>` so the successor preserves the already-consumed follow-up count, original 7-day window, and reply split budget.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply; on success it clears that request's durable reply-context record, while the separate offer marker remains for its bounded retention so a brief relay re-offer stays silent.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
A failed durable offer claim is likewise reported once as `x-mode-error cannot record mention offer` and remains deduplicated through quiet no-pending polls until a later offer confirms an existing valid marker or claims a new one.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-message replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`, up to three times per link within the window.
Add `--image <path>` there too when a completion follow-up should carry an image.
A successful post increments the local `x_followups=` counter and keeps the link, unless `--final` was passed or the new count reaches the cap, in which case the link is cleared instead; a failed post leaves the link and counter untouched so it can be retried.
The relay itself rejects a follow-up past its own cap or window with HTTP 409 and may include `{"error":"followup_unavailable"}` in the response body; the client surfaces any follow-up 409 as a distinguishable exit code and uses the body marker only for a sharper diagnostic.
`fm-x-followup.sh` treats that exit exactly like a locally-detected expiry - clearing the link and skipping quietly rather than retrying - so an older single-follow-up relay or an already-exhausted binding degrades gracefully.
It treats `fm-x-reply.sh`'s fail-safe refusal (exit 8: platform or explicit budget unresolved) differently: that is a retryable hold, so the link is KEPT and the follow-up is retried once both values can be recovered, never posted with a local default.
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

### Promised public replies (state/public-followup)

A relay request that spawns real work can leave firstmate owing a specific public reply in a specific thread.
That promise is a typed `kind=public-followup` obligation whose state machine is owned entirely by `tasks-axi public-followup`, while the full private conversation context stays only in `state/x-context/`.
Firstmate's bounded registration retains the obligation's public-safe request binding so a delivered loop can be rechained without the original inbox.
`bin/fm-public-followup.sh` is firstmate's side: it registers a commitment, reconciles typed terminal work results into it, posts the final reply through `bin/fm-x-reply.sh --followup`, and explicitly rechains or retires the retained loop.
Run `bin/fm-public-followup.sh --help` for the exact subcommands and flags.

Registration is what creates this home's private transport under `state/public-followup/` (mode 0700): `registry/` for the bounded private binding of each open public loop (the record survives delivery, stamped `state=delivered`, and is removed only by `retire`), `events/` for typed terminal results awaiting reconciliation, `consumed/` for the accepted-event ledger, `rejected/` for refusals kept with a one-line reason, `retired/` for the mode-0600 reason-and-time receipt written before removal, and `surfaced` for the poll's last-surfaced signature.
A work home that reports across a machine boundary also gets `outbox/`, described below.
The home that owns the commitment also owns the outward post, because only it holds the relay consent, the request context, and the opaque thread binding.
Work routed elsewhere reports a typed terminal result with `bin/fm-public-followup-emit.sh` and never looks for the thread; when writing directly into the owning home, that emitter refuses a home with no registration for the named obligation.
When that work lives in a REMOTE secondmate home, delivery clears its bound legacy link after validating the public receipt, while retirement clears the link before closing the loop, and both clears run over that route's SSH transport.
Readable remote state that proves no link exists succeeds without a write, while a present link is cleared only when its Relay request identity matches the registration and the state is writable; an identity mismatch, unreadable or unsafe state, an unavailable write or lock, an older remote copy, or a host that never confirms the clear leaves the loop retained for reconciliation.
A terminal event's id is derived from its identity tuple, so a duplicate report, a retry, or a replay after restart resolves to the same event and changes nothing.

Work bound to a REMOTE secondmate home reports across a machine boundary, where no local path reaches the owning home.
`bin/fm-public-followup.sh brief` therefore prints that worker the route's own code root and home with `--stage-in`, so the typed result is staged in `outbox/` in the home where the work actually runs rather than written to a path that only exists on the owning machine.
The owning home collects staged results for open registrations over the same SSH route it reaches that secondmate on, because that transport only runs in the outbound direction: `consume` pulls them into its own `events/` and then reconciles them exactly as it reconciles a local report.
Non-open registrations owe no result, so `consume` skips them without contacting their routes; an open registration whose reachable route has nothing staged remains pending without an error.
Collection is non-destructive until the result is durably held, and the staged copy is retired only afterwards, so a dropped connection can never lose a terminal result.
For an open registration, a work home that cannot be reached is named in `consume`'s output and keeps the promise open; it is never reported as an empty inbox.
Run `bin/fm-public-followup-collect.sh --help` for the staged-result commands the owning home runs over that route.

Activation is the same `.env` `FMX_PAIRING_TOKEN` contract as the rest of Relay, with no second flag.
A home without that token runs one file test and stops: no `tasks-axi` call, no backlog or request-context scan, and no `state/public-followup/` directory.
Ordinary startup, polling, cleanup, and silent read-side subcommands also produce no output; commands that require an active relay report that configuration error after the same gate.
A relay-enabled home with no registered commitment stops at an O(1) directory presence check, so the empty state costs no CLI call and adds no periodic scan.
Unreconciled terminal results ride the existing 30-second relay poll rather than a new process or timer: `bin/fm-x-poll.sh` compares the pending-event signature against `surfaced` and wakes firstmate once per new result set.
The session-start digest separately prints a "Public commitments" subsection from disk when, and only when, this home is relay-active and still holds an open public loop (a reply still owed, or a delivered loop with nothing owed), so compaction and restart are non-events.
`bin/fm-teardown.sh` refuses to clean up a task while this home still owes a public reply for exactly that work, unless `--force` carries explicit discard approval.
`FM_PF_RETRY_BACKOFF_SECS` (default 900) sets the next-attempt time recorded with a retryable delivery error.
See [verification/public-followup.md](verification/public-followup.md) for the current maintainer evidence behind restart recovery, retained-loop disposition, and the relay-disabled zero-overhead guarantee.

## Trusted external process-event adapters (config/extensions.d)

A home can explicitly enable a trusted external `process-event-adapter/1` package without adding package code to Firstmate.
This is one narrow extension type, not a general plugin or hook system.
[`extension-bindings.md`](extension-bindings.md) owns the manifest, binding, trust, handshake, invocation-envelope, capability, version-compatibility, and authority-boundary contracts.
`bin/fm-extension.sh --help` and `bin/fm-procevent.sh --help` own exact command mechanics.

Discovery reads only mode-`0600` bindings under this home's mode-`0700` `config/extensions.d/` directory.
The current directory, projects, task copies, worker text, environment payloads, and Pi packages are never searched for extensions.
When the directory is absent, ordinary process-event commands perform only a bounded absence check, create no package or extension state, and preserve every built-in adapter path.

Binding separates the package's own manifest from this home's explicit enablement.
`bind` validates the source package, computes every digest, copies the complete tree into the read-only content-addressed `data/extensions/packages/` store, performs the live handshake, and atomically publishes the enabled adapter-name subset.
The operator supplies trust and required consent facts, not hashes.
`state/extensions/<extension-id>/` is created when binding performs its initial handshake and is that package's home-local working namespace for later verification and invocation.
`state/extension-invocations/` contains private host-owned exact process-group cleanup records only while an enabled package invocation is starting or running; retirement and reconciliation retain their existing owners until those records prove the group extinct.
This integrity boundary does not sandbox trusted same-user code, so bind only a package trusted to run with the operator's operating-system access.

The shipped `file-signal` package is a complete neutral example.
Copy it to a persistent directory outside every Git project or task copy, then bind and verify it:

```sh
mkdir -p "$HOME/.local/share/firstmate-packages"
cp -R docs/examples/process-event-extension \
  "$HOME/.local/share/firstmate-packages/file-signal"
bin/fm-extension.sh bind \
  "$HOME/.local/share/firstmate-packages/file-signal" \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
bin/fm-extension.sh list
bin/fm-extension.sh inspect org.firstmate.example.file-signal
bin/fm-extension.sh verify org.firstmate.example.file-signal
```

Use an absent destination for the copy so the source identity remains inspectable and reproducible.
For a non-default home, set `FM_HOME=<that-home>` on every command; local and remote secondmate homes bind the package independently, and bindings are not inherited.
For a configured remote secondmate, keep the package at the controller and transfer it through the authenticated `fm-on` route:

```sh
bin/fm-extension.sh remote-bind <secondmate-id> \
  /absolute/controller/path/to/file-signal \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
```

The command serializes only the validated extension package, stages it below the addressed remote home's fixed extension staging root, binds it there, and prints transfer and binding digests.
Registration uses `bin/fm-on.sh <secondmate-id> fm-procevent.sh ...`.
After retiring every registration with its printed owner token and handling every captured result, retire the enabled remote binding and its exact staged transfer together with `bin/fm-on.sh <secondmate-id> fm-extension.sh retire-transfer <extension-id> --if-transfer-digest <transfer-digest> --if-binding-digest <binding-digest>`.
For a direct local binding, use `bin/fm-extension.sh retire-binding <extension-id> --if-binding-digest <binding-digest>` after the same process-event retirement and handling steps.
Both commands retain the retired identity reversibly and leave unrelated bindings and content-addressed installed packages unchanged.

Register one file completion source with a path-safe source id and an explicit non-secret source configuration reference.
Credential values never belong in that reference, command argv, or a process-event result:

```sh
bin/fm-procevent.sh register-extension file-signal build-complete \
  --config-ref "file:/absolute/path/to/build-result.txt"
bin/fm-procevent.sh reconcile
```

`register-extension` prints the new registration's owner token and exact owner-matched retirement command.
The source waits outside the conversational turn, and its completed result arrives through the existing process-event `check` path.
Classify the captured result through its immutable package identity with `bin/fm-procevent.sh classify <result-file>`, acknowledge it with the existing `handled` command only after it is handled, and use the printed `retire --if-owner` command when explicit retirement is needed.
Never run the registered blocking source command directly in a conversational turn.

## Process-to-event sources (state/procevent)

A long-polling external process is registered as a *source* through its adapter, whose header and `--help` own the commands and flags.
`bin/fm-procevent.sh` owns the generic contract; built-in adapters retain their tracked `bin/fm-procevent-<adapter>.sh` commands, while an explicitly bound external adapter routes through the trusted host contract above.
`bin/fm-procevent-lavish.sh` is the first built-in adapter and wraps only the currently published `lavish-axi poll` interface.
That adapter, and only that adapter, retries the one exact transient response a cut-short listener returns while its marks remain available (`error: Lavish Editor poll response was interrupted` with `code: SERVER_ERROR`), up to 12 times at 5 second intervals, so an internal retry never reaches the runner as a captured result.
Real feedback, ended and missing sessions, any other `SERVER_ERROR`, and that same interruption still standing once the bound is spent are all captured and announced normally; `FM_LAVISH_POLL_RETRY_DELAY` is a bounded 0 to 60 second test override for the interval only, and the runner itself stays adapter-agnostic.
An already-armed Lavish source keeps its registered listener command until it is retired and armed again, so re-arm a live board once to adopt this retry policy.

The `when` adapter (`bin/fm-procevent-when.sh`) turns this channel into a condition->action primitive: it registers a deterministic condition and a deterministic action once, its blocking child polls the condition without waking firstmate, and a stable true fires the action at most once before one terminal outcome is durably captured and published as a wake that remains eligible for re-announcement until handled.
The (condition, action) spec is stored privately under `state/when/` and hash-bound by a trust record the same way `bin/fm-check-register.sh` binds a custom check, while the spec separately binds the resolved action executable's bytes; a mutated or unregistered spec or a changed action executable is refused before the action runs.
Every failure path - a mutated spec or action executable, a condition error past its budget, an expired deadline, a failed action, or an earlier fire whose outcome was never captured - produces a terminal captured outcome that wakes firstmate rather than a silent retry, and a durable single-fire marker claimed before the action makes restarts and re-polls unable to fire it twice.
The adapter automates only the exact deterministic subset: anything needing judgment, and anything destructive, irreversible, or security-sensitive, keeps the ordinary check-fires-then-firstmate-decides flow, and the adapter's header and `--help` own its commands, flags, and outcome document.

This section is the single owner of the runner's operating contract.
Process-event commands resolve the state root to its physical directory before validating it and deriving paths, so a home reached through a symlinked ancestor behaves like its physical spelling while an unsafe target directory remains refused.
Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before any announcement or event can reference it.
By default, results are published as ordinary `check` wakes carrying the source id and committed result sequence through the existing durable wake queue, so the runner adds no second notification control plane.
The self-announcing adapter exception and its fail-safe ordering are defined below.
The watcher delivers a queued result on its ordinary cycle by reporting it as an actionable `check` wake, so a default or fallback publication reaches firstmate through the same rewake path every other wake uses and never waits for a manual drain.
A queued `check` delivery is reported at most once per captured source and sequence while any records for that key remain queued.
A durable handled acknowledgement stops future source re-announcement, while a record already queued remains under the durable queue's authority until the ordinary drain's sequence-bound post-handling acknowledgement consumes it.

Discovery is never a timer.
Each registered source has its own child process blocking on that source, and the watcher's per-cycle `reconcile` republishes every captured result with no durable handled acknowledgement yet - regardless of any earlier publication - restarts a source whose owner is gone, and stops this home's runner when reconciliation runs after its registration disappeared unexpectedly.
In supported steady state, a home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

Whether a captured result is a routine no-op is adapter knowledge too, and the runner names no adapter-specific condition for it either.
Before publishing, the runner asks the immutable captured owner through the built-in `silent` command or external `result.silent` operation and treats exit 0 as the only silence verdict: the result is recorded as durably handled and never announced, so it neither wakes a handler now nor returns on a later reconcile.
A missing command, an error, any other exit, or a silence the runner cannot durably record all publish the `check` wake exactly as before, so an adapter with no notion of a no-op needs no change and an unknown or degraded result always reaches its handler.
For built-ins, silence remains independent of the keyed-answer feed below: suppressing an announcement never suppresses the captain's own answer.
For Lavish that verdict covers exactly one shape - a session the adapter classifies `ended` that carries no queued content block at all, which is a review surface closed with nothing said.
Any recognized top-level `prompts` or `feedback` block counts as content regardless of its declared count, and a malformed header makes the result indeterminate rather than empty.
A `Send & End` close carrying the captain's answer arrives as `status: feedback` with `session_ended`, so it classifies `feedback` and is announced unchanged, as is any `ended` result that still carries content, and every `waiting`, `missing`, `unknown`, or unreadable result.

Whether a captured result ends its source is adapter knowledge, never the runner's.
After capture - and after initial `check` publication for the default ordering - the runner asks the immutable captured owner through the built-in `terminal` command or external `result.terminal` operation and retires the registration on exit 0 alone, dropping only the exact registration generation captured by its claim and releasing that claim only after removal succeeds under one source boundary; a missing command, an error, or any other exit keeps the source armed, so an adapter with no notion of ending needs no change.
A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives and becomes independently runnable after the old claim releases.
Any registration refuses to replace an external registration while its prior runner claim is live, uncertain, orphaned, or terminal-pending; replacement becomes eligible only after that generation is proved gone or its terminal retirement completes.
A source that has ended therefore captures at most one terminal result, is never restarted, and leaves no recurring poll work, while explicit `retire` stays the supported and idempotent path afterwards.
For Lavish that verdict covers an ended session, a missing session, and the final feedback of a `Send & End` review, which the published poll marks with `session_ended` before it returns only empty ended sessions.

Applying a captured result through code is a built-in adapter seam, and some built-in results carry no judgement at all: they must simply be applied idempotently to this home's own durable state.
Leaving that to a handler means it can silently not happen, so immediately after the terminal check above the runner calls `bin/fm-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` and lets the built-in adapter apply and acknowledge its own result.
That call runs strictly after terminal retirement, because a handling adapter re-arms its own next source and retiring afterwards would drop that fresh registration and leave the source silently dead.
Exit 0 means the adapter fully applied and acknowledged the result; a missing command, an error, or any other exit is not a capture failure but leaves the result unacknowledged and therefore still eligible for re-announcement, so a handler receives it exactly as before and an adapter with no such command needs no change.
Announcement ordering is adapter-declared through `bin/fm-procevent-<adapter>.sh self-announcing`: an adapter that answers exit 0 declares that every result its autohandle fully applies is announced through a durable downstream channel of its own, so the runner applies first and publishes a `check` wake only for what remains unhandled afterwards; every other adapter keeps the strict publish-before-apply order, and its autohandle runs only when this capture's own wake was successfully appended to the durable queue.
The remote-secondmate reply adapter declares itself self-announcing: a captured reply reaches its local status mirror and settles its correlated pending-reply expectation without any handler step, the mirrored status bytes are the single wake for one remote note through the same signal classification a local secondmate's append gets, a byte-identical replayed capture adds no bytes and stays quiet, and only a capture the adapter could not fully apply is published as a `check` wake, whose adapter handling remains idempotent.

Keyed captain answers from built-in adapters use one more seam of the same kind, and the runner still decides nothing about them.
Some built-in sources carry the captain's answer to a captain-held task, and what such an answer means is owned once by `bin/fm-captain-hold.sh`'s keyed-answer intake rather than by any channel.
A built-in source bound with `bin/fm-captain-hold.sh bind` therefore has each captured result passed to `bin/fm-procevent-<adapter>.sh answers <result-file>`, and whatever that prints is piped straight into that intake.
A binding can select one decision origin or the script's cross-origin mode; the command header owns the exact forms and key interpretation.
The built-in adapter reports only what the captain chose; the intake owns every rule about what happens next, so the runner names no adapter, parses no result, and carries no decision rule, and a future built-in source needs nothing here beyond an `answers` command and a binding.
Feeding is independent of handling: it never acknowledges a result and never suppresses a wake, because recording the answer is transcription while acting on it is firstmate's judgement.
An unbound built-in source, a built-in adapter with no `answers` command, and a failure on either side all leave the capture untouched and still announced.
External binding responses never enter this authority-bearing intake.

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.
Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`).
Each claim binds its caller-reported home and runner PID to a process identity, unique claim generation, exact registration-file generation, and resolved state-root identity.
Registration, acquisition, replacement, retirement, and generation-bound release are serialized at one machine-wide boundary per source.
A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.
Retirement and orphan reconciliation signal a runner process group only while its recorded process identity still matches, or when the recorded leader is gone and only its own owned group survives.
A runner leads its own process group, so a claim counts as reclaimable only when that whole generation is gone: a crashed leader whose group still has members is not stale, and reconcile stops that surviving group and releases its generation before starting any replacement.
If identity cannot be established for a live PID, or a surviving owned group cannot be proved stopped, the operation preserves the registration and claim for safe retry rather than adding a second owner.
A live PID whose identity no longer matches is a reused PID, so it is treated as stale and its process group is never signalled.

Supported secondmate retirement preflights each target home's bounded `sweep-home` command before destructive teardown, snapshots its registrations outside the target, then runs the sweep at that home's final deletion or return boundary.
If deletion or return fails, teardown restores those registrations and reconciles them before returning the refusal.
If restoration or rearming also fails, teardown returns a distinct status and reports the retained registration backup path for manual recovery instead of hiding the retired waits.
The sweep retires local registrations and machine-wide claims whose recorded state-root identity matches that home's resolved state root through the same identity-checked, generation-bound retirement path, and leaves foreign-home claims untouched.
Teardown refuses with the home, lease, routing evidence, registrations, claims, and runners retained when identity is uncertain, ownership is unreadable or unreleased, or relevant state exists without a sweep-capable child script.
Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.

`FM_PROCEVENT_MAX_OUTPUT_BYTES` (default 1048576) bounds a single captured result while the source runs; oversized output is drained but truncated with a stderr notice rather than staged or published whole or dropped.

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no durable handled acknowledgement remains eligible for bounded re-announcement across any number of drains and restarts, not only the crash window right after capture.
`bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement: a generation-keyed, private, path-safe, durable, and idempotent acknowledgement that atomically checks and deduplicates by the exact source and sequence, so a paired effect gated on its first-time-vs-repeat report is never authorized twice.
Default and fallback `check` publication is still best-effort, so the same source and sequence can repeat even before any restart; handlers deduplicate that identity rather than assuming a wake is unique.
The runner proves nothing about the source side, and the handled acknowledgement proves nothing about a paired external effect performed before it: a crash between that effect and the acknowledgement call can still repeat the effect on replay, so this is never a generic exactly-once guarantee.
The published `lavish-axi poll` clears feedback destructively before returning it, so a result lost between that clearing and the runner reading process output is unrecoverable.
Never describe this path as at-least-once, no-loss, or lossless.
`docs/verification/process-event-sources.md` holds the measurements and `.agents/skills/process-event-sources/SKILL.md` owns the handling procedure.

## Spoken interface and captain inbox (config/voice-*, config/inbox-*)

The spoken interface in [`docs/voice-relay.md`](voice-relay.md) and the model-backed subcommands of `bin/fm-inbox.sh` reach a paid API in a named account, so no region, model id or AWS profile is shipped as a tracked default.
Each is one line in a local, gitignored `config/` file, with an environment variable that overrides it for a single run, and a missing required value refuses with the path to write rather than falling back to a value that belongs to another home.
That configuration is the whole opt-in: an unconfigured home cannot start the relay and cannot run `fm-inbox.sh say` or `ask`, while `note`, `status`, `list` and `drain` need no configuration at all because they make no model call.
The voice handover depends on `note`, so it keeps working in a home that has configured nothing.

| File | Environment | Holds |
| --- | --- | --- |
| `config/voice-region` | `FM_VOICE_REGION` | Bedrock region for the relay's bidirectional session, required by `bin/fm-voice-relay.py`. |
| `config/voice-model` | `FM_VOICE_MODEL` | Speech-to-speech model id, required by `bin/fm-voice-relay.py`. |
| `config/voice-profile` | `FM_VOICE_PROFILE` | AWS profile the relay exports credentials from; absent, or an explicitly empty variable, means it uses only credentials already in its environment. |
| `config/voice-id` | `FM_VOICE_ID` | Output voice id, optional, `matthew` when unset. |
| `config/voice-read-scope` | none | `counts` (the default, and what an absent file means) or `full`; see [`docs/voice-relay.md`](voice-relay.md) for what each scope may say. |
| `config/voice-read-deny` | none | One plain case-insensitive substring per line; a matching open item is withheld from every list and reduced to a count. |
| `config/inbox-region` | `FM_INBOX_REGION` | AWS region for `fm-inbox.sh say` and `ask`. |
| `config/inbox-stt-model` | `FM_INBOX_STT_MODEL` | Speech-to-text model id, required by `fm-inbox.sh say`. |
| `config/inbox-ask-model` | `FM_INBOX_ASK_MODEL` | Side-question model id, required by `fm-inbox.sh ask`. |
| `config/inbox-profile` | `FM_INBOX_PROFILE` | AWS profile for those two calls; absent, or an explicitly empty variable, means whatever credentials are already in the environment. |

Each account, model and voice file above is read as its first line that is not blank and not a `#` comment, so a comment above the value is fine.
The two read files are parsed differently: `config/voice-read-scope` must hold the bare word and nothing but blank space around it, so a comment header there refuses instead of being skipped, while every line of `config/voice-read-deny` that is not blank and not a `#` comment is one more substring.
`FM_VOICE_RELAY` and `FM_VOICE_PYTHON` belong to the laptop rather than to a home, so they have no config file: `bin/fm-voice-client.py` requires the relay path as a flag or that variable and carries no default path.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home for most scripts, unset means this repo root; fm-send requires it explicitly
FM_ROOT_OVERRIDE=        # override firstmate repo root, tangle-guard target, and zellij/cmux home-title hash; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity reads in fm-wake-lib.sh and fm-teardown.sh, mainly for tests
FM_BACKEND=             # optional runtime backend override for new spawns; tmux/herdr/zellij/orca/cmux support ship/scout spawns, codex-app is not accepted
FM_TRACE_CONTEXT=       # optional trace-context override; see "Trace context propagation"
HERDR_SESSION=default  # herdr-only: named session for normal backend ops; not enough for destructive cleanup (docs/herdr-backend.md)
FM_BACKEND_HERDR_SUBMIT_POLLS=6  # herdr-only: agent-state samples spread across each Enter attempt's budget when confirming a submit (docs/herdr-backend.md "Current transport behavior")
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # herdr-only: minimum per-Enter confirmation budget before polling agent-state after an idle baseline
FM_ZELLIJ_SESSION=firstmate  # zellij-only: named session for normal backend ops and test isolation (docs/zellij-backend.md)
CMUX_SOCKET_PASSWORD=   # cmux-only: socket password fallback when config/cmux-socket-password is absent (docs/cmux-backend.md)
FM_SESSION_START_STATUS_TAIL=5   # state/*.status lines printed per task in the session-start digest; each line is capped by bin/fm-line-cap-lib.sh
FM_SESSION_START_QUEUED_LIMIT=20   # plain queued backlog rows in the session-start digest; in-flight, held, and blocked rows are never bounded and done rows are never listed
FM_BOOTSTRAP_DETECT_ONLY=0   # internal/read-only session-start mode: skip bootstrap's mutating sweeps and print advisory TANGLE wording
FM_BOOTSTRAP_NETWORK=all   # internal session-start phase split: all, skip (local steps only), or only (network steps only); see bin/fm-bootstrap.sh
FM_STARTUP_NETWORK_TIMEOUT=120   # seconds bounding the deferred inactive-outcome scan plus network checks; hitting it prints an actionable NETWORK_CHECKS line
FM_TASKS_AXI_COMPATIBLE=   # internal one-hop handoff of an already-computed tasks-axi compatibility verdict (0 or 1); consumed when bin/fm-tasks-axi-lib.sh is sourced
FM_GUARD_READ_ONLY=0    # internal/read-only guard mode: keep alarms but suppress drain, supervision repair, and checkout repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line; fm-send.sh overrides it to name the requested message specifically
FM_POLL=15              # seconds between watcher poll cycles
FM_HOME_SUMMARY_INTERVAL=300   # seconds before a live watcher refreshes this home's state/home-summary.json even without a status signal; invalid or zero values use 300
FM_HOME_SUMMARY_TIMEOUT=60     # seconds bounding the complete best-effort home-summary refresh, including lock acquisition, validation, atomic publication, and worker-side failure logging; invalid or zero values use 60
FM_HOME_SUMMARY_ERROR_LOG_MAX_BYTES=65536   # approximate size cap for state/.home-summary-refresh.log before it is trimmed to the newest 200 lines; invalid or zero values use 65536
FM_HOME_SUMMARY_FAILURE_REPORT=2   # recorded publication failures since the ledger's own last publication before session start reports a HOME_SUMMARY line; invalid or zero values use 2
FM_SNAPSHOT_CREW_STATE_TIMEOUT=10   # seconds bounding each local per-task current-state read inside bin/fm-fleet-snapshot.sh; remote endpoint liveness is not probed on the snapshot path
FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8   # maximum local tasks whose current-state and endpoint observations are collected concurrently during snapshot composition
FM_SNAPSHOT_BUDGET=5                # one total seconds budget for all concurrent remote home-ledger reads
FM_SNAPSHOT_CACHE_DIR=$FM_HOME/state/secondmate-summary-cache   # private parent-side cache of successfully fetched remote home ledgers
FM_RECONCILE_REQUEST_MAX_BYTES=1048576   # maximum captured Bearings or fleet snapshot accepted for durable reconcile-notify request publication
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_INACTIVE_RECONCILE_SECS=900  # 60..1800-second watcher cadence and inactivity threshold; locked session start also requests an immediate scan in the deferred worker
FM_INACTIVE_RECONCILE_BUDGET_SECS=10  # 1..30-second scan deadline; wedged-scan kill backstop follows one second later
FM_CHECK_INTERVAL=300   # seconds between slow checks (authenticated merge polls, custom checks, or Relay dispatch)
FM_TASK_INBOX_GRACE_SECS=90   # seconds an unhandled steering-inbox message may sit before the watcher attempts doorbell delivery on an idle pane; also the minimum spacing between attempts
FM_TASK_INBOX_RING_MAX=3      # watcher delivery attempts without an acknowledgement before the task surfaces as a stale wake for recovery
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_TOOL_UPDATE_INTERVAL=900   # seconds between watched-tool probe sweeps; 0 probes on every run, other values must be 60..86400
FM_TOOL_UPDATE_PROBE_SECS=5   # 1..30 seconds allowed for one version or git probe
FM_TOOL_UPDATE_BUDGET_SECS=20   # 1..120 seconds allowed for a whole watched-tool sweep; cut to fit FM_CHECK_TIMEOUT, and the cut is reported
FM_TOOL_UPDATE_NOW=     # test override for the watched-tool sweep clock; the sweep budget still uses real time
FM_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # bound on one captured process-to-event result
FM_PROCEVENT_CLAIM_ROOT=                # machine-wide source claim root; default $XDG_STATE_HOME/firstmate/procevent-claims
FM_WHEN_OUTPUT_TAIL_BYTES=8192          # bound on the command-output tail inside one condition->action outcome document
FM_CODEX_WATCH_CHECKPOINT=180   # seconds per foreground watcher checkpoint in Codex primary supervision
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_TEARDOWN_NM_TIMEOUT=10    # seconds allowed per no-mistakes query or abort inside fm-teardown.sh
FM_CREW_STATE_RUNS_LIMIT=200  # recent no-mistakes run rows scanned when axi status cannot be attributed directly
FM_TEARDOWN_NM_RUNS_LIMIT=200  # recent no-mistakes run rows scanned to prove an unresolved-head parked run belongs to teardown's task
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by working/paused watcher triage
FMX_PAIRING_TOKEN=      # Relay pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional Relay endpoint override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct Relay client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews Relay replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-message split budget; values below 50 clamp to 50
FMX_DISCORD_REPLY_MAX_CHARS=1900   # Discord reply per-message split budget; values below 50 clamp to 50, values above 2000 reset to 1900
FMX_X_THREAD_MAX=25     # maximum messages in one auto-split reply thread
FMX_FOLLOWUP_MAX_AGE_SECS=604800   # local window for posting Relay completion follow-ups (7 days)
FMX_FOLLOWUP_MAX_COUNT=3   # local cap on Relay completion follow-ups per linked mention
FM_PF_RETRY_BACKOFF_SECS=900   # seconds before the next attempt after a retryable promised-public-reply delivery error
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings, arm health checks, and the primary turn-end guard treat a watcher beacon as stale
FM_CLAUDE_AUTOARM_ATTEMPTS=2   # bounded Stop-owned arm attempts per Claude auto-arm cycle; accepted values are 1, 2, or 3
FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milliseconds the --claude turn-end guard waits for watcher health, an open Stop auto-arm generation claim, or a fresh epoch before deciding recovery ownership or failure progression
FM_CLAUDE_AUTOARM_EPOCH_FRESH=15   # seconds a recorded auto-arm outcome remains eligible for the current event epoch's recovery or failure decision
FM_CLAUDE_TURNEND_BLOCK_BUDGET=3   # consecutive --claude guard re-blocks before the verified one-time attended fail-open; safely below Claude Code's 8-block override
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED; default 30 on Git Bash/MSYS
FM_ARM_ATTACH_POLL=0.5  # seconds between checks while fm-watch-arm is attached to an existing healthy watcher cycle
FM_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milliseconds the OpenCode primary watcher plugin waits for an arm attempt to report started, healthy, wake, or failure; default 35000 on Windows to stay above the MSYS confirm budget
FM_PI_ARM_READY_TIMEOUT_MS=12000   # milliseconds the Pi watcher extension waits for a successor arm to report started or attached; default 35000 on Windows to stay above the MSYS confirm budget
FM_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milliseconds Pi/OpenCode wait for an unready successor arm to exit before abandoning retries
FM_WATCH_REARM_RETRY_BASE_MS=250   # Pi/OpenCode adapter base delay for continuity restoration retries
FM_WATCH_REARM_RETRY_MAX_MS=4000   # Pi/OpenCode adapter cap for exponential continuity retry delay
FM_WATCH_REARM_RETRY_LIMIT=5   # Pi/OpenCode adapter launch-failure retries before surfacing restoration failure
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # size cap for the arm-owned watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000   # newest complete lifecycle rows considered when the ledger is capped
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_TURNEND_CHURN_ABSORB_SECS=900   # longest one endpoint's bare turn-ends may be deferred on pane-churn evidence alone; only consulted when config/turnend-churn-absorb is present
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex; nonterminal progress verbs remain excluded even when their prose matches
FM_CLASSIFY_PAUSED_VERB=paused     # leading status verb for a declared external wait; excluded from FM_CAPTAIN_RE and distinct from blocked
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working stale pane escalates; stale panes whose crew is not provably working surface immediately unless admitted directly to the declared-wait cadence, while a live idle declared wait still surfaces once before that cadence bounds repeats
FM_BUSY_TURN_MAX_SECS=3600         # maximum age of a busy pane's latest state/<id>.turn-ended marker, or its state/<id>.meta spawn record before any turn completes, before the same wedge escalation used for a provably-working non-busy stale takes over; inspection-only, never an automatic interrupt or restart; a declared external wait or verified captain-held transfer takes the FM_PAUSE_RESURFACE_SECS recheck below instead
FM_PAUSE_RESURFACE_SECS=3600       # seconds between bounded rechecks of a declared external wait or verified captain-held transfer, including a live idle pane after its first inconclusive stale wake and a live busy pane past FM_BUSY_TURN_MAX_SECS; the away-mode daemon uses the same setting, ageing its window against the crew's own latest status line rather than pane busy state
FM_SECONDMATE_WAKE_STALL_SECS=60   # minimum age of the oldest valid foreign wake-queue row before an endpoint-recorded local secondmate produces one durable parent wake-loop-stall notification; zero or invalid values use 60
FM_WEDGE_DEMAND_INSPECT_COUNT=3    # consecutive provably-working stale escalations on the same unchanged pane before demand-deep-inspection is added
FM_WORKTREE_WRITE_PRUNE='.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'   # directory names the wedge detector's task-worktree write probe skips; the default keeps .git out so a supervisor's own read-only git command can never look like crew progress; set it to the empty string to prune nothing, which widens the probe to the whole depth-bounded tree rather than disabling it
FM_WORKTREE_WRITE_MAXDEPTH=6       # depth that same probe walks below the recorded worktree; it runs only at the moment a wedge escalation would otherwise fire, never on every poll; no probe knob applies to a secondmate, whose recorded worktree is a provisioned home the probe skips entirely
FM_WORKTREE_WRITE_TIMEOUT=10       # wall-clock seconds that one walk may take, so a worktree on a hung mount cannot stall the watcher poll that started it; hitting the bound reads as no write evidence, which leaves the escalation schedule exactly as it was; a value that is not a positive integer falls back to the default
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=     # optional seconds allowed for bootstrap's best-effort clone refresh; unset/blank defaults to max(20, 5 + 3 * origin-backed-project-count)
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_STALE_WORKTREE_LOCK_AGE_SECS=30       # min mtime age before fm-teardown.sh treats a leftover worktree git index.lock as provably stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3        # retries after a treehouse return fails on the transient git index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1 # seconds fm-teardown.sh waits before each retry after that signature
FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # legacy alias for FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS when the new variable is unset
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3        # fetch retries after fm-fleet-sync.sh hits the orphaned .git/packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # seconds fm-fleet-sync.sh waits before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # min mtime age before fm-fleet-sync.sh treats a leftover packed-refs.lock as provably stale
FM_BUSY_REGEX=          # optional override for rendered delivery guards and Grok's isolated task-state fallback; converted worker state ignores it
FM_COMPOSER_IDLE_RE=    # optional fleet-wide idle-placeholder regex override (bin/fm-composer-lib.sh); a match alone does not prove emptiness because shape-specific position and ANSI de-emphasis safety gates still apply
FM_COMPOSER_CAPTURE_LINES=20   # fleet-wide bound for tail-capture composer reads; tmux instead supplies its bounded visible pane, while the other adapters use this small window so stale scrollback banners stay out of the candidate set
FM_COMPOSER_PI_MAX_LINES=8     # fleet-wide: maximum rows admitted between Pi's identity-corroborated separator pair; taller or ambiguous candidates stay unknown
FM_COMPOSER_GHOST_LUMA_MAX=128   # fleet-wide: max perceived luminance (0.299R+0.587G+0.114B, 0-255) for a TRUECOLOR foreground to count as de-emphasised ghost/placeholder text and be stripped; dim/faint (SGR 2) is stripped regardless. Assumes a dark terminal theme (bin/fm-composer-lib.sh's fm_composer_strip_ghost, used by styled tmux, herdr, and Zellij reads)
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send typed-plane Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send typed-plane submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful typed-plane submit; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # seconds after marked-request delivery before a completed turn without a correlated parent report is eligible for its one recovery repost
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_BACKEND=             # optional supervisor pane backend override; tmux/herdr only, otherwise detects $TMUX_PANE then HERDR_ENV/HERDR_PANE_ID before tmux fallback
FM_SUPERVISOR_TARGET=              # optional supervisor pane target override; tmux target or herdr <session>:<pane-id>, otherwise auto-detected
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=            # override config/wedge-alarm with one active-alert directive for the wedge alarm; off|auto|osascript|herdr|command:<cmd>; absent = auto (macOS -> an OS notification)
FM_WEDGE_ALARM_EXEC=              # notifier seam: route every channel (osascript, herdr, command:) through this command as `<cmd> <channel> <summary>`; "discard" fires nothing; unset in production; the daemon defaults it to "discard" when sourced so no test posts a real notification (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10    # maximum seconds for each osascript, herdr, override, or command: notifier before its watchdog terminates it and continues to the next channel; invalid or zero values use 10
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale/pause-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
# spoken interface and captain inbox; see "Spoken interface and captain inbox" above
FM_VOICE_REGION=        # overrides config/voice-region for one relay run
FM_VOICE_MODEL=         # overrides config/voice-model for one relay run
FM_VOICE_PROFILE=       # overrides config/voice-profile; explicitly empty forces ambient credentials
FM_VOICE_ID=            # overrides config/voice-id; matthew when neither is set
FM_VOICE_RELAY=         # laptop-side path to bin/fm-voice-relay.py on the desktop; required by fm-voice-client.py unless --relay is passed
FM_VOICE_PYTHON=python3 # laptop-side interpreter used to start the relay over ssh
FM_INBOX_REGION=        # overrides config/inbox-region for fm-inbox.sh say and ask
FM_INBOX_STT_MODEL=     # overrides config/inbox-stt-model for fm-inbox.sh say
FM_INBOX_ASK_MODEL=     # overrides config/inbox-ask-model for fm-inbox.sh ask
FM_INBOX_PROFILE=       # overrides config/inbox-profile; explicitly empty forces ambient credentials
```

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
