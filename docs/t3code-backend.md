# T3 Code runtime backend

T3 Code is an experimental backend in which the T3 Code server owns the agent session while Treehouse keeps owning the task worktree.
Firstmate drives the server over its HTTP orchestration API with a CLI-issued bearer and subscribes to native thread changes over WebSocket.
Nothing is typed into a terminal.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick T3 Code when you already run the T3 Code app and want each task to be a visible T3 thread working in a Treehouse worktree, and each secondmate a visible T3 thread working in its own home.
T3 Code runs only the `claude` and `codex` harnesses; every other harness is refused at spawn.

Prerequisites:

- A running T3 Code server, version 0.0.41-nightly.20260914.1707 or newer, whose `GET /.well-known/t3/environment` descriptor reports the `threadSettlement` capability.
- `node`, which the adapter uses to speak HTTP, and `treehouse`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Select T3 Code with local `config/backend` containing `t3code`, `FM_BACKEND=t3code` for one launch, or `--backend t3code` for one task.
Without an explicit selection, a configured server can identify the active supervisor by its home thread.
The shared selection rules and precedence are in [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend).

The server origin is read from `~/.t3/userdata/server-runtime.json` (`origin`); `FM_T3CODE_ORIGIN` overrides it.
Before any spawn mutates repository state, Firstmate requires the descriptor to pass the version floor and capability check and requires an authorized read of `GET /api/orchestration/shell`.

### Bearer token

Mint a session with the version the descriptor reports:

```sh
npx t3@<serverVersion> auth session issue --json --ttl 30d --label firstmate
```

Write the JSON `token` field to the local, gitignored `config/t3code-token` as one line with mode 0600.
The session carries the `orchestration:read` and `orchestration:operate` scopes, and desktop restarts do not revoke it.
A missing token or a 401 refuses with one error that names this mint command with the live server version.
A secondmate spawned on this backend gets `config/t3code-token` as a symlink to the primary's token file, so its own daemon and crew use the same bearer without a copy of the secret, and a re-minted token reaches them.

### Provider instances and models

`config/t3code-instances` maps a harness to a T3 provider instance id, one `harness=instanceId` line each; the defaults are `claude=claudeAgent` and `codex=codex`.
The file is part of the primary's inherited local material, so every secondmate home receives the primary's mapping and its own T3 workers launch on the same provider instances; a home without the file falls back to those bare defaults, which need not name a configured account.
A task's `--model` must be a slug in T3's model catalog; an unknown slug leaves the session in `error`.
`--model default` uses the T3 project's default model selection and refuses when the project has none.
`--effort` rides as a provider option, `effort` for claude (`low|medium|high|xhigh|max`) and `reasoningEffort` for codex (`low|medium|high|xhigh`); `default` sends no option, and a value outside a harness's set is refused.

## Task shape and metadata

Each ship or scout task has one Treehouse worktree, leased durably with `treehouse get --lease --lease-holder <id>`, and one T3 thread whose `worktreePath` is that worktree.
A secondmate's T3 project is its home and its thread has no worktree of its own (`worktreePath` null), so the agent runs in the home on whatever branch the home is on.
The normal isolation and unlanded-work refusal rules still apply.

```text
backend=t3code
window=fm-<id>
t3_thread_id=<uuid>
t3_project_id=<uuid>
worktree=<absolute Treehouse slot path>
```

`window=` remains the caller-facing Firstmate alias.
`t3_thread_id=` is the backend authority used by every operation and cleanup path.
A secondmate record carries the ordinary `home=` and `projects=` lines as on every backend.

## Per-directory harness environment

T3 sets environment variables per provider instance, never per thread, so nothing can be typed into a pane before launch.
Each harness reads its own configuration from the thread's working directory instead, and Firstmate writes the facts a pane would have exported into that directory before the launch turn.
For `claude` that is an `env` block in the directory's `.claude/settings.local.json`, merged alongside the busy hooks a worker already carries there; for `codex` it is a `.codex/config.toml` holding a `[shell_environment_policy]` `set` table.
Untracked environment files are git-excluded and removed at teardown.
For a tracked `.codex/config.toml`, Firstmate preserves the project bytes and appends its policy only if the file does not already define `shell_environment_policy`, including through dotted or quoted keys.
`bin/fm-t3code-codex-env.sh` owns the tracked overlay, its private worktree Git journal, and its `skip-worktree` protection against ordinary staging and commits.
Teardown restores the original bytes and prior Git flag before returning the slot; unexpected file or index edits refuse cleanup and retain the journal for recovery.
The tracked path requires Python 3.11 or newer for TOML parsing; the script uses the first of `python3`, `python3.14`, `python3.13`, `python3.12`, or `python3.11` on `PATH` that imports `tomllib`, and refuses before any mutation when none does.
Codex's [configuration layers](https://learn.chatgpt.com/docs/config-file/config-basic#configuration-precedence) provide no separate per-directory fragment for a thread launched at the repository root, and T3 cannot select a different CLI override or profile per thread.
Every kind receives `GOTMPDIR` and `COMPACT_ADVISER_DISABLE=1`, plus `LAVISH_AXI_HOST` when `config/lavish-axi-host` is set; ship and scout workers also receive `FM_TASK_ID`; `TRACEPARENT` rides only when trace context is on, and only once its `traceparent=` line is recorded.
A secondmate additionally receives the launch prefix every other backend types (`FM_ROOT_OVERRIDE`, `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` empty, `FM_PUBLIC_FOLLOWUP_PRIMARY_HOME`, `FM_HOME`, `FM_TRACE_CONTEXT`, `FM_SUPERVISION_MODEL`) plus `FM_SUPERVISOR_BACKEND=t3code` and its own thread id as `FM_SUPERVISOR_TARGET`, so its away daemon resolves its target exactly.
A `claude` ship or scout worker also receives the task-worker channel statement that a pane launch appends to the system prompt, written as a `CLAUDE.local.md` in its worktree because T3 owns the system prompt; a secondmate does not, as on every backend.
Without it a Claude worker can refuse the launch brief as prompt injection, which happened live.
The statement also tells the worker not to call T3's `link_pull_request`, `list_thread_pull_requests`, or `unlink_pull_request` tools even when host instructions request it, because those calls crash Claude's session and Firstmate already records the PR from the worker's `done: PR <url>` status line.
A `claude` task refuses a project that tracks `CLAUDE.local.md`, because that file is the backend's channel and teardown removes it.

## Current lifecycle and safety

Spawn matches the project (the home, for a secondmate) by real path against the T3 projects' `workspaceRoot`, creating one titled `fm-<directory name>` with `project.create` when absent, leases the worktree for a worker, creates the thread with `thread.create` (branch, worktree path or null, `full-access` runtime mode, the model selection), installs the harness hooks and the per-directory environment, records metadata, and then starts the launch turn with `thread.turn.start` carrying the encoded brief (the charter, for a secondmate).
Exact command payloads are owned by `bin/backends/t3code.sh`.

`fm-peek.sh` renders `[role] text` for the recent messages followed by a `t3code: session=<status> turn=<state>` line.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and its doorbell is a `thread.turn.start` on the thread.
Sent while a turn runs, both Claude and Codex answer it inside the live turn.
Escape and Ctrl-C are both a `thread.turn.interrupt`; Enter is a no-op and Ctrl-U is unsupported.

The control plane ([`agent-control.md`](agent-control.md)) reads the same status table.
`interrupt` is a `thread.turn.interrupt` proven by the session still reading alive afterwards.
`exit` is a `thread.session.stop`, since a thread has no composer to type an exit command into, proven by the session reading `stopped`; the thread and its transcript stay, and a later turn restarts the same agent with that transcript.
`relaunch` is refused before anything is stopped: a T3 thread is bound to the driver that first ran it, and a turn on a stopped thread continues the same agent, so no replacement agent can be launched into the endpoint.

The watcher and `fm-crew-state.sh` read the server's own session status through one table in the adapter, and both native verdicts are trusted ahead of every harness gate and hook record (source `t3code-native`), so a codex crew settles from T3's status even though codex has no verified hook writer; only an unreadable server falls through to the ordinary contract.
A thread's capture stays byte-identical through a long tool call, so before the watcher reports an unchanged transcript as a possible wedge it reads the session status once more and resets its stale timer while the server still reports `running`; `wedge_defer_t3code_running` in `bin/fm-watch.sh` owns that consult, and every other session status keeps the ordinary escalation ladder, including its declared-wait and worktree-write deferrals; a `stopped` or `error` session reads dead and is reported once by the watcher's shared dead-record probe, as a dead pane is on tmux or Herdr.
T3 launches Claude with the `user,project,local` setting sources, so the worktree `.claude/settings.local.json` busy hooks fire as on every other backend.
T3 starts every agent with the T3 server's own environment, not a login shell's.
Codex runs each command through `/bin/zsh -lc` in that environment, so the Firstmate toolchain must survive the login shell's startup files, and a startup file that rebuilds `PATH` when a marker variable is missing hides it from every Codex worker; Claude's shell tool restores its own login-shell snapshot and is unaffected.
A remote secondmate is unaffected by this backend: it always runs on the remote host's Herdr, and `--backend t3code` on one is refused.

Cleanup keeps all shared Firstmate safety checks.
Before the slot returns to the pool, or before a secondmate home is removed, teardown stops the session and archives the thread (`thread.session.stop`, then `thread.archive`), because a live thread whose worktree path disappears re-creates that worktree on its next turn.
If spawn aborts after creating the thread, cleanup uses the same order and keeps the lease when stop or archive fails, then prints the manual archive and `treehouse return --force` steps.
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
After reconnection, `starting` and `running` read busy/alive; `ready`, `idle`, and `interrupted` read idle/alive; `stopped` and `error` read dead; an archived thread or HTTP 404 reads missing.
The status table in `bin/backends/t3code.sh` owns these mappings for the watcher and recovery callers.
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
T3 puts nothing about the thread into the agent's environment, so after the explicit `FM_SUPERVISOR_TARGET`/`FM_SUPERVISOR_BACKEND` overrides and the tmux and Herdr markers, the daemon asks the server for the one live thread with no worktree of its own on the project whose `workspaceRoot` is this home; that rule runs only when a server origin and a bearer are configured.
Two live threads in one home is an error naming both ids, resolved by setting `FM_SUPERVISOR_TARGET`; none, or an unreachable server, falls through to the ordinary tmux default.
Busy is the server's session status alone, injection is a `thread.turn.start`, and escalations defer exactly as on every other backend.
Only `bin/fm-afk-launch.sh start-native` launches the daemon here, as the captain's own tracked background job; `start` refuses because T3 hosts no terminal to create.
A secondmate spawned on this backend carries its supervisor identity in its environment, so its own daemon needs no discovery.

## Switching back to Herdr

Write `herdr` to `config/backend` and every new spawn uses the Herdr backend again.
In-flight tasks keep the backend recorded in their own `state/<id>.meta`, so they are supervised and torn down through T3 Code until they finish.
The branch can be left with `git switch main`.

## Version floor

The minimum server version is `0.0.41-nightly.20260914.1707`, the verified nightly used as this adapter's floor.
The adapter compares the complete semantic version, including prerelease identifiers; earlier nightlies and malformed versions fail with the installed version and required floor in the error.
Build metadata does not affect ordering, and the stable `0.0.41` release sorts after its prereleases.
The descriptor must also advertise `threadSettlement`, and the configured bearer must authorize a shell read before spawn mutates anything.
The live guard below refreshes version and protocol evidence after an upgrade.

## Active limits

- T3 Code remains experimental and runs only `claude` and `codex`.
- T3 starts the agent at `full-access` with its provider instance's account and environment, so a spawn refuses `config/claude-permission-mode=auto` for `claude`, `config/launch-env-allowlist`, and a worker account pin; select the account through `config/t3code-instances` instead.
- T3 owns the Claude provider command, so Firstmate cannot add its command-line prompt-suggestion, feedback-draft, or attribution controls; configure equivalent provider-instance settings in T3 when those policies are required.
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
