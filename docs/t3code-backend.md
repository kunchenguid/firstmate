# T3 Code runtime backend

T3 Code is an experimental backend in which the T3 Code server owns the agent session while Treehouse keeps owning the task worktree.
Firstmate drives the server over its HTTP orchestration API with a CLI-issued bearer and subscribes to native thread changes over WebSocket.
Nothing is typed into a terminal.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick T3 Code when you already run the T3 Code app and want each task to be a visible T3 thread working in a Treehouse worktree, and each secondmate a visible T3 thread working in its own home.
T3 Code runs only the `claude` and `codex` harnesses; every other harness is refused at spawn.

Prerequisites:

- A running T3 Code server that passes the [version, protocol, and capability gate](#verified-version-and-protocol-gate).
- `node`, which the adapter uses to speak HTTP, and `treehouse`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select T3 Code with local `config/backend` containing `t3code`, `FM_BACKEND=t3code` for one launch, or `--backend t3code` for one task.
T3 Code is explicit-only for task dispatch; a configured server does not select this backend automatically.
An explicitly configured T3 home can identify its active supervisor by its home thread.
The shared selection rules and precedence are in [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend).

The server origin is read from `~/.t3/userdata/server-runtime.json` (`origin`); `FM_T3CODE_ORIGIN` overrides it.
The [version and protocol gate](#verified-version-and-protocol-gate) applies before spawn, control, or teardown mutations.

### Bearer token

Mint a session with the version the descriptor reports:

```sh
npx t3@<serverVersion> auth session issue --json --ttl 30d --label firstmate
```

Write the JSON `token` field to the local, gitignored `config/t3code-token` as one line with mode 0600.
The CLI-issued session is an administrative bearer that includes orchestration read and operate scopes; desktop restarts do not revoke it.
A missing token or a 401 refuses with one error that names this mint command with the live server version.
A secondmate spawned on this backend gets `config/t3code-token` as a symlink to the primary's token file, so its own daemon and crew use the same bearer without a copy of the secret, and a re-minted token reaches them.

### Provider instances and models

`config/t3code-instances` maps a harness to a T3 provider instance id, one `harness=instanceId` line each; the defaults are `claude=claudeAgent` and `codex=codex`.
The file is part of the primary's inherited local material, so every secondmate home receives the primary's mapping and its own T3 workers launch on the same provider instances; a home without the file falls back to those bare defaults, which need not name a configured account.
A task's `--model` must be a slug in T3's model catalog; an unknown slug leaves the session in `error`.
`--model default` uses the T3 project's default model only when its instance matches `config/t3code-instances`; otherwise it refuses and asks for an explicit `--model`.
`--effort` rides as a provider option, `effort` for claude (`low|medium|high|xhigh|max`) and `reasoningEffort` for codex (`low|medium|high|xhigh`); a value outside a harness's set is refused.
With `--effort default`, `--model default` preserves the project's default options, while an explicit model sends no options.

## Task shape and metadata

Each ship or scout task has one Treehouse worktree, leased durably with `treehouse get --lease --lease-holder <id>`, and one T3 thread whose `worktreePath` is that worktree.
A secondmate's T3 project is its home and its thread has no worktree of its own (`worktreePath` null), so the agent runs in the home on whatever branch the home is on.
The normal isolation and unlanded-work refusal rules still apply.

[`configuration.md`](configuration.md#task-metadata) owns the task metadata fields, and its [task-selector contract](configuration.md#task-selectors) owns routing to the recorded thread.

## Per-directory harness environment

T3 sets environment variables per provider instance, never per thread, so nothing can be typed into a pane before launch.
Each harness reads its own configuration from the thread's working directory instead, and Firstmate writes the facts a pane would have exported into that directory before the launch turn.
For `claude` that is an `env` block in the directory's `.claude/settings.local.json`, merged alongside the busy hooks a worker already carries there; for `codex` it is a `.codex/config.toml` holding a `[shell_environment_policy]` `set` table.
Firstmate-created untracked environment files are git-excluded and removed at teardown.
An existing untracked `.codex/config.toml` without Firstmate's marker is preserved and refused.
For a tracked `.codex/config.toml`, Firstmate preserves the project bytes and appends its policy only if the file does not already define `shell_environment_policy`, including through dotted or quoted keys.
`bin/fm-t3code-codex-env.sh` owns the tracked overlay, its private worktree Git journal, and its `skip-worktree` protection against ordinary staging and commits.
Teardown restores the original bytes and prior Git flag before returning the slot; unexpected file or index edits refuse cleanup and retain the journal for recovery.
The tracked path requires Python 3.11 or newer for TOML parsing; the script uses the first of `python3`, `python3.14`, `python3.13`, `python3.12`, or `python3.11` on `PATH` that imports `tomllib`, and refuses before any mutation when none does.
Codex's [configuration layers](https://learn.chatgpt.com/docs/config-file/config-basic#configuration-precedence) provide no separate per-directory fragment for a thread launched at the repository root, and T3 cannot select a different CLI override or profile per thread.
Every kind receives `GOTMPDIR`, `COMPACT_ADVISER_DISABLE=1`, and `FM_TASK_INBOX`, plus `LAVISH_AXI_HOST` when `config/lavish-axi-host` is set; ship and scout workers also receive `FM_TASK_ID`; `TRACEPARENT` rides only when trace context is on, and only once its `traceparent=` line is recorded.
A secondmate additionally receives the launch prefix every other backend types (`FM_ROOT_OVERRIDE`, `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` empty, `FM_PUBLIC_FOLLOWUP_PRIMARY_HOME`, `FM_HOME`, `FM_TRACE_CONTEXT`, `FM_SUPERVISION_MODEL`) plus `FM_SUPERVISOR_BACKEND=t3code` and its own thread id as `FM_SUPERVISOR_TARGET`, so its away daemon resolves its target exactly.
A `claude` ship or scout worker also receives the task-worker channel statement that a pane launch appends to the system prompt, written as a `CLAUDE.local.md` in its worktree because T3 owns the system prompt; a secondmate does not, as on every backend.
Without it a Claude worker can refuse the launch brief as prompt injection, which happened live.
The statement also tells the worker not to call T3's `link_pull_request`, `list_thread_pull_requests`, or `unlink_pull_request` tools even when host instructions request it, because those calls crash Claude's session and Firstmate already records the PR from the worker's `done: PR <url>` status line.
A `claude` task checks the leased worktree and refuses a tracked, existing, or symlinked `CLAUDE.local.md`, because that file is the backend's channel and teardown removes it.

## Current lifecycle and safety

Spawn matches the project (the home, for a secondmate) by real path against the T3 projects' `workspaceRoot`, creating one titled `fm-<directory name>` with `project.create` when absent, leases the worktree for a worker, creates the thread with `thread.create` (branch, worktree path or null, `full-access` runtime mode, the model selection), disables automatic settlement for that thread with `thread.auto-settle.set`, installs the harness hooks and the per-directory environment, records metadata, and then starts the launch turn with `thread.turn.start` carrying the encoded brief (the charter, for a secondmate).
Exact command payloads are owned by `bin/backends/t3code.sh`.

`fm-peek.sh` renders `[role] text` for the recent messages followed by a `t3code: session=<status> turn=<state>` line.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and its doorbell is a `thread.turn.start` on the thread.
Sent while a turn runs, both Claude and Codex answer it inside the live turn.
Escape and Ctrl-C are both a `thread.turn.interrupt`; Enter is a no-op and Ctrl-U is unsupported.

The control plane ([`agent-control.md`](agent-control.md)) reads the same status table.
`interrupt` is a `thread.turn.interrupt` proven by the session still reading alive afterwards.
`exit` is a `thread.session.stop`, since a thread has no composer to type an exit command into, proven by the session reading `stopped`; the thread and its transcript stay, and a later turn restarts the same agent with that transcript.
`relaunch` is refused before anything is stopped: a T3 thread is bound to the driver that first ran it, and a turn on a stopped thread continues the same agent, so no replacement agent can be launched into the endpoint.

The watcher and `fm-crew-state.sh` use the adapter's [shared thread classification](#restart-and-liveness-behavior) ahead of harness gates and hook records (source `t3code-native`), so a codex crew settles from T3's status even though codex has no verified hook writer.
Native uncertainty stays unknown instead of falling through to a hook record or rendered fallback.
A thread's capture stays byte-identical through a long tool call, so before reporting a possible wedge the watcher rechecks the [shared thread classification](#restart-and-liveness-behavior) and resets its stale timer only for the `running` word, including live `working` background jobs.
`wedge_defer_t3code_running` in `bin/fm-watch.sh` owns that consult; all other classified words keep the ordinary escalation ladder, including its declared-wait, worktree-write, and dead-record checks.
T3 launches Claude with the `user,project,local` setting sources, so the worktree `.claude/settings.local.json` busy hooks fire as on every other backend.
T3 starts every agent with the T3 server's own environment, not a login shell's.
Codex runs each command through `/bin/zsh -lc` in that environment, so the Firstmate toolchain must survive the login shell's startup files, and a startup file that rebuilds `PATH` when a marker variable is missing hides it from every Codex worker; Claude's shell tool restores its own login-shell snapshot and is unaffected.
A remote secondmate is unaffected by this backend: it always runs on the remote host's Herdr, and `--backend t3code` on one is refused.

Cleanup keeps all shared Firstmate safety checks.
Before the slot returns to the pool, or before a secondmate home is removed, teardown stops the session and archives the thread (`thread.session.stop`, then `thread.archive`), because a live thread whose worktree path disappears re-creates that worktree on its next turn.
If spawn aborts after creating the thread, cleanup uses the same order and keeps the lease when stop or archive fails, then prints the manual archive and `treehouse return --force` steps.
Two lost `thread.create` transport responses leave ownership uncertain, so cleanup keeps the lease even when an immediate thread lookup returns 404; verify the thread before returning that slot.
The kill is idempotent, so an already archived or deleted thread is the end state, and an unreachable server refuses the teardown rather than returning a slot a live thread still points at.
Archiving keeps the transcript visible in T3 Code.
The `fm-` project of a torn-down secondmate home stays in T3 Code pointing at the removed directory until the operator deletes it there: `project.delete` refuses while the archived thread exists, and forcing it would delete that thread's transcript, which is the only record once the home is gone.
T3 renames a thread's branch on the first turn only when it matches `t3code/<8hex>` or `t3code/<uuid>`, so Treehouse branches are left alone.

## Restart and liveness behavior

The T3 thread id, transcript, provider binding, and Treehouse worktree outlive a server connection.
A server restart can interrupt the provider process even though the thread still exists.
T3 owns continuation: an eligible running turn with a saved resume cursor may resume under its existing provider when restart continuation is enabled or prepared by a server update.
If T3 cannot continue an orphaned provider session, its session projection becomes `error` and reports that a new message is needed.
Thread persistence alone does not prove a live agent.

While HTTP is unavailable, Firstmate reads `unknown unreadable` and does not treat the outage as proof that a replacement agent is safe.
After reconnection, `starting` and `running` read busy/alive; `ready`, `idle`, and `interrupted` read idle/alive; `stopped` and `error` read dead; a settled thread whose session was stopped by T3 reads idle/alive; an archived thread or HTTP 404 reads missing.
If detail reports a live `ready`, `idle`, or `interrupted` session but the shell snapshot fails, the thread reads unknown/alive and busy guards defer until idle is proven.
Background work follows T3's own classification.
Background jobs never revive a stopped or failed session; the settled-stopped exception above still reads idle/alive.
On a live session, a shell row reporting `working` background work, such as a terminal job that outlived its turn, reads busy/alive.
`monitoring` adds no activity verdict, so an otherwise idle live session stays idle/alive.
The stream reader and the HTTP probe share that rule in `bin/backends/t3code-thread-status.cjs`, and the status table in `bin/backends/t3code.sh` owns these mappings for the watcher and recovery callers.
Inspect a failed worker's thread error before sending a new turn through its normal steer path.
A new turn continues the same driver and transcript; `fm-control.sh relaunch` remains refused.
Teardown still requires a successful stop and archive before returning the worktree.

## Push events and polling fallback

The watcher opens one bounded shell subscription for this home's T3 worker threads using the configured bearer to obtain a short-lived WebSocket ticket.
T3 buffers live changes before emitting the initial snapshot, so every connection reconciles current levels before consuming subsequent thread updates.
Only selected thread ids contribute records; secondmate endpoints remain excluded from immediate escalation.
Pending approvals or user-input requests on a live session normalize to `blocked`, active sessions to `working`, settled live sessions to `idle`, and unreadable or dead sessions to `unknown`.
The adapter feeds these records into the shared transition shape and policy in `bin/fm-transition-lib.sh`.

A fresh blocked transition uses the existing durable wake path, including its declared-wait exemptions and deduplication after successful enqueue.
A working transition clears the thread's dedupe marker; idle transitions keep the ordinary completion and stale checks.
The shared transition policy remains the only owner of escalation decisions.

Polling still runs every cycle at the existing cadence.
Missing built-in Node WebSocket support, rejected tickets, unavailable sockets, malformed subscriptions, and dropped connections all fall back to polling.
Repeated failures disable push for the current watcher process; its successor probes again.
The reader runs as a bounded child of the existing watcher.

<a id="away-mode"></a>

## Away-mode supervisor support

The away daemon can supervise a captain that runs inside a T3 thread.
[`configuration.md`](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns discovery precedence and the explicit-selection, origin, and bearer prerequisites.
T3 puts nothing about the thread into the agent's environment, so eligible discovery matches this home's real path to a project's `workspaceRoot` and selects its one unarchived thread with `worktreePath` null and a session status of `starting` or `running`.
Multiple matching threads print an ambiguity diagnostic naming their ids and fall through to the legacy tmux fallback, as do no matches or an unreachable server.
Resolve ambiguity by explicitly setting both `FM_SUPERVISOR_BACKEND=t3code` and `FM_SUPERVISOR_TARGET` to the intended thread id.
Busy uses the [shared thread classification](#restart-and-liveness-behavior), injection is a `thread.turn.start`, and escalations defer exactly as on every other backend.
An unknown native busy verdict defers new-turn delivery but does not prove that work resumed.
Away housekeeping keeps an overdue stale alert pending and buffers one possible-wedge report while the verdict remains unknown, including an errored session or a transient thread-detail failure.
Delivered warnings stay suppressed while the same unknown condition persists.
If a fresh daemon entry discards a queued, undelivered warning, it clears that warning's reported marker and preserves its stale timer, so the next housekeeping pass queues exactly one replacement.
Refreshing a live daemon preserves the queue; a failed start restores the previous queue and reported markers.
Confirmed busy activity or a missing thread (archived or HTTP 404) clears the stale and reported markers, so a later unknown condition can report again.
Declared external-wait rechecks also survive native uncertainty; the worker's declaration still controls their cadence.
`stale_window_is_busy` and `housekeeping` in `bin/fm-supervise-daemon.sh` own stale tracking; `fm_afk_clear_stale_artifacts` in `bin/fm-afk-start.sh` and the launcher in `bin/fm-afk-launch.sh` own queue discard and startup rollback.
`tests/fm-backend-t3code.test.sh` covers retention, deduplication, and re-arming across native restart.
Only `bin/fm-afk-launch.sh start-native` launches the daemon here, as the captain's own tracked background job; `start` refuses because T3 hosts no terminal to create.
A secondmate spawned on this backend carries its supervisor identity in its environment, so its own daemon needs no discovery.

## Switching back to Herdr

Write `herdr` to `config/backend` and every new spawn uses the Herdr backend again.
In-flight tasks keep the backend recorded in their own `state/<id>.meta`, so they are supervised and torn down through T3 Code until they finish.

## Verified version and protocol gate

The verified source pin and minimum server version are stable `v0.0.44`.
The adapter compares the complete semantic version, including prerelease identifiers; versions below the stable floor and malformed versions fail with the installed version and required floor in the error.
For example, `0.0.44-nightly.1` is below the floor, while `0.0.45-nightly.1` passes the version check and must still satisfy the protocol and capability checks.
Build metadata does not affect ordering.
The descriptor must advertise `threadAutoSettleOptOut` and report `orchestrationProtocolVersion` as absent or `1`, and the configured bearer must authorize a shell read.
Orchestrator V2 removes the HTTP dispatch path and renames commands, so this adapter refuses it before spawn, control, or teardown mutations.
There is no override.
A task still in flight when T3 Code upgrades to V2 cannot be torn down through Firstmate, so release it by hand:

1. Archive the task's thread in T3 Code.
2. For a worker, undo the per-worktree environment with `bin/fm-t3code-codex-env.sh cleanup <worktree>`, then remove `CLAUDE.local.md` and `.claude/settings.local.json` from the worktree.
   Skipping this hands the next holder of the slot a hidden `.codex/config.toml` overlay carrying the dead task's environment, and refuses the next T3 Codex spawn there.
   For a secondmate, release its own tasks in this same order, then run `bin/fm-t3code-codex-env.sh cleanup <home>` and remove its `.claude/settings.local.json` before releasing the home.
3. For a worker, return its slot with `treehouse return --force <worktree>` from its project.
   A secondmate has no separate task worktree, but its home may itself be leased: preserve its durable records and unlanded work, then return a pooled home with `treehouse return --force <home>` from the Firstmate code root, or remove a standalone home by hand.
   Remove its line from the parent's `data/secondmates.md`.
4. Remove the task record, `state/<id>.meta`, and its other `state/<id>.*` files.

The live guard below refreshes version and protocol evidence after an upgrade.

## Active limits

- T3 Code remains experimental and runs only `claude` and `codex`.
- T3 starts the agent at `full-access` with its provider instance's account and environment, so a spawn refuses `config/claude-permission-mode=auto` for `claude`, `config/launch-env-allowlist`, and a worker account pin; select the account through `config/t3code-instances` instead.
- T3 owns the Claude provider command, so Firstmate cannot add its command-line prompt-suggestion, feedback-draft, or attribution controls; configure equivalent provider-instance settings in T3 when those policies are required.
  Unless `config/keep-ai-trailers` is present, the per-worktree environment selects Firstmate's Git commit hook to strip known AI trailers, including on T3 workers.
- `fm-control.sh relaunch` is refused because a thread is bound to its existing driver.
- A tracked `.codex/config.toml` that already defines `[shell_environment_policy]` is refused by file and table name before a slot is leased.
- While a tracked Codex overlay is installed, do not edit that file or clear its `skip-worktree` flag; configuration changes require cleanup first.
- Shell typing and Ctrl-U are unsupported; runtime Escape and Ctrl-C still interrupt the turn.
- A Codex supervisor has no away mode on this backend because it has no tracked background tool for `start-native`, and T3 has no terminal for `start` to create.
- Push requires Node's built-in WebSocket support; HTTP polling remains available without it.
- The live guard does not restart the server shared with other threads.

## Regression entry points

```sh
bin/fm-test-run.sh tests/fm-backend-t3code.test.sh tests/fm-backend-t3code-events.test.sh
bin/fm-test-run.sh tests/fm-backend.test.sh tests/fm-supervision-events.test.sh tests/fm-daemon.test.sh tests/fm-control.test.sh
FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-live-e2e.test.sh
```

The live guard runs the token-free lifecycle and WebSocket checks by default when T3 and its tools are available, against one fresh temporary project that it deletes afterwards.
Set `FM_T3CODE_LIVE_E2E=0` to disable it or `FM_T3CODE_LIVE_E2E=1` to require it and fail on missing tools.
The prompt subtest stays opt-in with `FM_T3CODE_PROMPT_LIVE=1`; the shared `FM_LIVE` override also applies.
[`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code) records the dated live results.
