# T3 Code runtime backend

T3 Code is an experimental backend in which the T3 Code server owns the agent session while Treehouse keeps owning the task worktree.
Firstmate drives the server only through its Orchestrator V2 `/mcp` endpoint, signed in as an OAuth `mcp-client`, and nothing is typed into a terminal.
[`bin/fm-t3-mcp.mjs`](../bin/fm-t3-mcp.mjs) owns that transport, the credential, and the capability gate; [`bin/backends/t3code.sh`](../bin/backends/t3code.sh) owns the backend primitives built on it.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick T3 Code when you already run the T3 Code app and want each task to be a visible T3 thread working in a Treehouse worktree, and each secondmate a visible T3 thread working in its own home.
T3 Code runs only the `claude` and `codex` harnesses; every other harness is refused at spawn.

Prerequisites:

- A running T3 Code server that passes the [capability gate](#capability-gate).
  T3 stable 0.0.45 lacks the Orchestrator V2 thread tools, so it is refused; the verified version is recorded in [`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code).
- `node`, which the adapter uses to speak MCP, and `treehouse`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain).

Run the server that hosts Firstmate workers with T3's product telemetry off, so worker turns are not counted:

```sh
T3CODE_TELEMETRY_ENABLED=false t3 serve --host 127.0.0.1 --port <port> --no-browser
```

Every spawn and control action checks the server's telemetry state and warns unless the listening loopback server's own process proves it off.

Select T3 Code with local `config/backend` containing `t3code`, `FM_BACKEND=t3code` for one launch, or `--backend t3code` for one task.
T3 Code is explicit-only for task dispatch; a configured server does not select this backend automatically.
An explicitly configured T3 home can identify its active supervisor by its home thread.
The shared selection rules and precedence are in [`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend).
The [capability gate](#capability-gate) applies before spawn, control, or teardown mutations.

### Sign-in

Issuing a full-access agent credential is the captain's decision, so the captain runs the sign-in and Firstmate never does:

```sh
bin/fm-t3-mcp.mjs login --access full-access
```

The server origin defaults to `FM_T3CODE_ORIGIN`, else the `origin` in `~/.t3/userdata/server-runtime.json`; `--url <origin>` names it explicitly.
Add `--t3 <path>` when `t3` is not on `PATH`, and `--base-dir <dir>` when the server runs with a non-default T3 base directory.
The sign-in mints a two-minute one-time pairing code with the operator's own `t3 auth pairing create`, scoped to `orchestration:read` and `orchestration:operate`, and spends it to approve Firstmate as an OAuth `mcp-client` at the full-access ceiling.
No browser is involved, and the token and pairing code are never printed.

Full access is required because a worker writes its status lines outside its worktree.
Under T3's narrower modes Codex's sandbox blocks that write and Claude parks on an approval that an MCP client cannot grant.
The credential is much narrower than T3's administrative bearer from `t3 auth session issue`, which this backend no longer uses; T3 accepts an `mcp-client` session only on `/mcp`.

The credential, the server's origin, its environment id, and its version are written to the local, gitignored `config/t3code-token`, mode 0600.
A missing, expired, revoked, or over-readable credential refuses with one error that names the sign-in command.
A secondmate spawned on this backend gets `config/t3code-token` as a symlink to the primary's credential file, so its own daemon and crew use the same credential without a copy of the secret, and a fresh sign-in reaches them.

### Expiry and revocation

T3 issues the credential for 30 days with no refresh token.
Every call warns within five days of expiry and refuses once it has expired; the captain then signs in again.
The credential appears in `t3 auth session list` as subject `mcp-client` with label `firstmate`.
Revoke it with `t3 auth session revoke <id>` and delete `config/t3code-token` when retiring the backend.

### Provider instances and models

`config/t3code-instances` maps a harness to a T3 provider instance id, one `harness=instanceId` line each; the defaults are `claude=claudeAgent` and `codex=codex`.
Spawn resolves the selection against T3's own catalog (`orchestrator_capabilities`) before anything is leased: the instance must exist, be usable, and run the harness's driver (`claudeAgent` for claude, `codex` for codex), so a mapping onto another driver's instance is refused.
The file is part of the primary's inherited local material, so every secondmate home receives the primary's mapping and its own T3 workers launch on the same provider instances; a home without the file falls back to those bare defaults, which need not name a configured account.
A task's `--model` must be a model that instance lists in T3's catalog.
`--model default` uses the T3 project's default model only when its instance matches `config/t3code-instances`; otherwise it refuses and asks for an explicit `--model`.
`--effort` rides as the driver's reasoning option, `effort` for claude and `reasoningEffort` for codex, and must be one of the values the catalog lists for that model.
An effort replaces only that option: `--model default` keeps every other project default option, such as Codex's service tier or Claude's fast mode, while an explicit model sends only the effort.
Every selected option is checked against the model's catalog descriptors.

### Capability gate

Every call first runs `tools/list` and refuses unless T3 offers every tool in `REQUIRED_TOOLS` in `bin/fm-t3-mcp.mjs` (the thread, project, configuration, pending-request, and catalog tools) and `t3_environment_read`.
It then refuses unless `t3_environment_read` reports the environment id recorded at sign-in, so a different T3 server behind the same address is never driven with this credential.
A refusal names the missing tool or both environment ids, and spawn, control, and teardown stop before their first mutation.
This gate replaces the HTTP dispatch probe and version floor of the pre-V2 transport, which T3 0.0.46 removed.

## Task shape and metadata

Each ship or scout task has one Treehouse worktree, leased durably with `treehouse get --lease --lease-holder <id>`, and one T3 thread launched with the `existing_worktree` workspace strategy on that worktree.
A secondmate's T3 project is its home and its thread is launched with the `root` workspace strategy, so the agent runs in the home on whatever branch the home is on.
T3 assigns the thread id at launch (`mcp:<uuid>`), and the task records it as `t3_thread_id`.
The normal isolation and unlanded-work refusal rules still apply.

[`configuration.md`](configuration.md#task-metadata) owns the task metadata fields, and its [task-selector contract](configuration.md#task-selectors) owns routing to the recorded thread.

## Per-directory harness environment

T3 sets environment variables per provider instance, never per thread, so nothing can be typed into a pane before launch.
Each harness reads its own configuration from the thread's working directory instead, and Firstmate writes the facts a pane would have exported into that directory before the launch turn.
For `claude` that is an `env` block in the directory's `.claude/settings.local.json`, merged alongside the busy hooks a worker already carries there; for `codex` it is a `.codex/config.toml` holding a `[shell_environment_policy]` `set` table.
Firstmate-created untracked environment files are git-excluded and removed at teardown.
An existing untracked `.codex/config.toml` without Firstmate's marker is preserved and refused.
A symlinked `.codex` directory, config file, or tracked-overlay journal is refused.
For a tracked `.codex/config.toml`, Firstmate preserves the project bytes and appends its policy only if the file does not already define `shell_environment_policy`, including through dotted or quoted keys.
`bin/fm-t3code-codex-env.sh` owns the tracked overlay, its private worktree Git journal, and its `skip-worktree` protection against ordinary staging and commits.
Teardown restores the original bytes and prior Git flag before returning the slot; unexpected file or index edits refuse cleanup and retain the journal for recovery.
The tracked path requires Python 3.11 or newer for TOML parsing; the script uses the first of `python3`, `python3.14`, `python3.13`, `python3.12`, or `python3.11` on `PATH` that imports `tomllib`, and refuses before any mutation when none does.
Codex's [configuration layers](https://learn.chatgpt.com/docs/config-file/config-basic#configuration-precedence) provide no separate per-directory fragment for a thread launched at the repository root, and T3 cannot select a different CLI override or profile per thread.
Every kind receives `GOTMPDIR`, `COMPACT_ADVISER_DISABLE=1`, and `FM_TASK_INBOX`, plus `LAVISH_AXI_HOST` when `config/lavish-axi-host` is set; ship and scout workers also receive `FM_TASK_ID`; `TRACEPARENT` rides only when trace context is on, and only once its `traceparent=` line is recorded.
A secondmate additionally receives the launch prefix every other backend types (`FM_ROOT_OVERRIDE`, `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` empty, `FM_PUBLIC_FOLLOWUP_PRIMARY_HOME`, `FM_HOME`, `FM_TRACE_CONTEXT`, `FM_SUPERVISION_MODEL`) plus `FM_SUPERVISOR_BACKEND=t3code` and its own thread id as `FM_SUPERVISOR_TARGET`, so its away daemon resolves its target exactly.
A `claude` ship or scout worker also receives the task-worker channel statement that a pane launch appends to the system prompt, written as a `CLAUDE.local.md` in its worktree because T3 owns the system prompt; a secondmate does not, as on every backend.
Without it a Claude worker can refuse the launch brief as prompt injection, which happened live.
The statement's pull-request-tool workaround follows the [verified version boundary](verification/runtime-backends.md#claude-pull-request-tools); an older or unreadable server keeps the clause, while a server at or past the verified build gets none.
Firstmate records the PR from the worker's `done: PR <url>` status line either way.
A `claude` task checks the leased worktree and refuses a tracked, existing, or symlinked `CLAUDE.local.md`, because that file is the backend's channel and teardown removes it.

## Current lifecycle and safety

Spawn matches the project (the home, for a secondmate) by real path against T3's live projects, creating one titled `fm-<directory name>` with `t3_project_create` when absent, and leases the worktree for a worker.
It then launches an idle thread with `t3_thread_launch` (the workspace strategy and branch, `full-access` runtime mode, the model selection) and reads the thread and its `t3_thread_configuration` back; a thread T3 bound to another workspace, runtime mode, instance, model, or option value is archived and the spawn refuses.
It installs the harness hooks, records metadata, installs the [per-directory harness environment](#per-directory-harness-environment), and sends the encoded brief (the charter, for a secondmate) as the thread's first message with `t3_thread_send`.
Exact call payloads are owned by `bin/fm-t3-mcp.mjs` and `bin/backends/t3code.sh`.

`fm-peek.sh` renders the newest items of the thread's activity view as `[type/status] text` lines followed by a `t3code: status=<status> run=<active run>` line.
T3 pages that view oldest first, so the helper starts from the thread's visible item count to read the tail.
An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and its doorbell is a `t3_thread_send` in `auto` mode, which starts an idle thread's next turn or steers the running one.
T3 derives the message id from the client request id and commits a send before it replies, so retries must reuse that id to reach the message T3 already committed.
For ordinary sends and doorbells, the adapter reuses the id stored in a record keyed by thread and text for up to 60 minutes from creation, ending that delivery earlier on confirmation or a typed send refusal.
After that window, identical text starts a new delivery, so verify an older unconfirmed send in T3 Code before resending it.
An accepted delivery's outcome (its request id, `messageId`, `runId`, and `delivery`) is kept for a day as `state/t3code-sends/<request-id>.accepted`, so it can be reconciled against T3's own message and run.
The submit primitive reports `empty` when T3 accepts the message, `unconfirmed` when its reply was lost, and `send-failed` only for proven non-delivery.
The direct-submit plane of `fm-send.sh` reports `unconfirmed` as exit 3 with any reply expectation kept armed; an inbox steer's exit status still follows the [durable-record contract](../bin/fm-send.sh).
After `unconfirmed`, an unmarked send can reuse its request id by resending identical text within that window; a marked secondmate request is not resent, because a rerun mints a new reply correlation and so a new message.
While the logical delivery still holds its id, a retry that fails for any reason other than T3 refusing the send, including an unreachable server, stays `unconfirmed` and keeps that id.
The away daemon mints a request id for each T3 digest.
It freezes an unconfirmed digest and retries its exact text under that id, with no expiry, until T3 accepts or refuses it, while events that arrive meanwhile wait for the next digest.
Task completion remains a separate worker status event.
Escape and Ctrl-C are both a `t3_thread_interrupt`; Enter is a no-op and Ctrl-U is unsupported.

The control plane ([`agent-control.md`](agent-control.md)) reads the same status table.
`interrupt` is a `t3_thread_interrupt` proven by the thread still reading alive afterwards.
T3 stops its latest active run asynchronously and names it, so the `cancel=` verdict waits on exactly that run: `confirmed` when it reached a terminal status, `not-running` when there was no active run, else `unconfirmed`, even when a later queued run is already terminal or has started meanwhile.
`exit` is refused before anything is sent: the V2 `/mcp` tools have no session stop, and an interrupt leaves the thread idle and alive, so no stop could be proven.
`relaunch` is refused before anything is stopped: a T3 thread keeps its conversation, so a new turn continues the same agent, and a provider or model change through `t3_thread_configure` is a context handoff on that same thread rather than the fresh agent a relaunch promises.

The watcher and `fm-crew-state.sh` use the adapter's [thread status table](#restart-and-liveness-behavior) ahead of harness gates and hook records (source `t3code-native`), so a codex crew settles from T3's status even though codex has no verified hook writer.
Native uncertainty stays unknown instead of falling through to a hook record or rendered fallback.
Watcher re-rings for ordinary records treat that uncertainty like busy, so a due doorbell waits and spends the same busy-deferral budget [`bin/fm-task-inbox-lib.sh`](../bin/fm-task-inbox-lib.sh) owns before a stuck-busy escalation.
The initial `fm-send.sh` doorbell follows that library's best-effort ring contract instead.
A thread's capture stays byte-identical through a long tool call, so before reporting a possible wedge the watcher rechecks the [thread status table](#restart-and-liveness-behavior) and resets its stale timer only for the `running` word.
That deferral is itself bounded by `FM_BUSY_TURN_MAX_SECS`, measured from the latest run boundary T3 records (completion, or start while the run is still active), so a hung run still reaches the possible-wedge alert, and a missing run timestamp never defers.
`wedge_defer_t3code_running` in `bin/fm-watch.sh` owns that consult; all other classified words keep the ordinary escalation ladder, including its declared-wait, worktree-write, and dead-record checks.
T3 launches Claude with the `user,project,local` setting sources, so the worktree `.claude/settings.local.json` busy hooks fire as on every other backend.
T3 starts every agent with the T3 server's own environment, not a login shell's.
Codex runs each command through `/bin/zsh -lc` in that environment, so the Firstmate toolchain must survive the login shell's startup files, and a startup file that rebuilds `PATH` when a marker variable is missing hides it from every Codex worker; Claude's shell tool restores its own login-shell snapshot and is unaffected.
A remote secondmate is unaffected by this backend: it always runs on the remote host's Herdr, and `--backend t3code` on one is refused.

Cleanup keeps all shared Firstmate safety checks.
Before the slot returns to the pool, or before a secondmate home is removed, teardown interrupts any active run, archives the thread with `t3_thread_organize`, and requires T3 to read back `archived:true` with no active run, so no live thread can act in a slot another task may lease.
T3 detaches the provider session as a separate effect after that read-back, so its Claude or Codex process can briefly outlive it: a worker's slot is cleared by teardown's worktree-process reaper, and a secondmate home, pooled or standalone, goes through the same reaper before it is returned or removed, keeping the home and its records when the process scan cannot complete.
Secondmate retirement requires `lsof` to prove the home is quiet; without it, teardown preserves the home and records for retry.
If spawn aborts after launching the thread, cleanup uses the same proven close and keeps the lease when it fails, then prints the manual archive and `treehouse return --force` steps.
`t3_thread_launch` has no idempotency key, so a lost launch reply or a failed binding read-back leaves ownership uncertain: spawn keeps the lease and never retries.
When the thread id is known, the helper attempts to archive it and reports its id, but even an accepted archive request leaves the lease held until the archive is verified.
A lost reply to the launch brief means the brief may already be running, so spawn keeps the task record, lease, and thread, never resends the brief itself, and exits nonzero with the thread to inspect.
An identical brief resend follows the [ordinary-send retention window above](#current-lifecycle-and-safety); verify delivery in T3 Code before resending after that window.
Before returning a retained slot by hand, prove both the archive with no active run and the end of its provider and worktree-owned processes, as teardown does above.
The kill is idempotent, so an already archived thread, or one the verified server no longer has, is the end state, and an unreachable or gate-refused server refuses the teardown rather than returning a slot a live thread still points at.
Archiving keeps the transcript visible in T3 Code; this backend never deletes a thread.
The `fm-` project of a torn-down secondmate home stays in T3 Code pointing at the removed directory until the operator deletes it there, because deleting a nonempty project takes the archived thread's transcript with it.

## Restart and liveness behavior

The T3 thread id, transcript, provider binding, and Treehouse worktree outlive a server connection.
A server restart cancels in-flight runs even though the thread still exists, so a worker whose turn ended without a terminal status line needs a steer.
Thread persistence alone does not prove a live agent.

`bin/backends/t3code.sh` owns one status table over the thread's V2 status, read with `t3_thread_read`:

- A thread with a pending runtime request (`pendingRequestCount`, a question or a permission approval) reads `blocked`, idle/alive, so a wait on a human is never taken for progress.
- `preparing`, `queued`, `starting`, `running`, and `waiting` (the run's post-turn drain) read busy/alive.
- `idle`, `completed`, `interrupted`, `cancelled`, and `rolled_back` read idle/alive.
- `failed` reads unknown/dead.
- An archived thread with no active run, or one the verified server does not have, reads missing.
- An archived thread whose run is still draining is not proven closed, so it reads `unknown unreadable` until the run ends.
- An unreachable server, a refused gate, or a failed read reads `unknown unreadable`, which is never treated as proof that a replacement agent is safe.

Inspect a failed worker's thread error before sending a new turn through its normal steer path.
A new turn continues the same driver and transcript; `fm-control.sh relaunch` remains refused.
Automatic secondmate recovery treats a failed run the same way: the thread is still readable, so recovery resumes it in place with one recovery turn instead of archiving it and launching a second thread, and the relaunch ledger bounds repeats.
A secondmate thread that reads missing is closed again through the idempotent archive before a replacement thread is launched, and when that close cannot be proven the thread and its record stay as recorded and nothing is spawned; other backends keep their existing best-effort close ([`bin/fm-secondmate-liveness-lib.sh`](../bin/fm-secondmate-liveness-lib.sh)).
Teardown still requires a proven archive before returning the worktree.

## Push events and polling fallback

T3 accepts an `mcp-client` session only on `/mcp`, so its WebSocket event stream is not available to this credential.
`t3_thread_wait` is itself event-driven on T3's stored run updates, so the watcher's push splice uses it instead: each cycle makes one bounded `fm-t3-mcp.mjs watch` call across the recorded T3 workers.
A new or changed set of pending requests is escalated at once, once per set, as a `blocked` wake that names the question ids and any permission approvals.
Otherwise the call waits on each thread's exact active run and returns as soon as one turns terminal, so the poll loop reconciles that turn without waiting out its interval; with no active run it sleeps the interval instead of re-arming.
The poll loop, its wedge timer, and the `FM_BUSY_TURN_MAX_SECS` bound on a running thread remain the backstop, and a server the call cannot read drops the cycle to plain polling.
Secondmate threads stay off the splice, as on Herdr.
In a home that also records Herdr workers, Herdr keeps the push wait and the T3 workers stay on the poll loop, so adding a T3 task never slows Herdr escalation.

Read and answer a worker's pending questions with [`bin/fm-t3-answer.sh`](../bin/fm-t3-answer.sh), which uses T3's `t3_pending_request_*` tools.
Those tools cannot see or approve a permission request, so an approval is surfaced as a count and answered only in T3 Code itself.

<a id="away-mode"></a>

## Away-mode supervisor support

The away daemon can supervise a captain that runs inside a T3 thread.
[`configuration.md`](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns discovery precedence and the explicit-selection and credential prerequisites.
T3 puts nothing about the thread into the agent's environment, so eligible discovery matches this home's real path to a live project's `workspaceRoot`, lists its threads with an active run through every `t3_thread_list` page, and selects the one unarchived thread with no worktree of its own.
A forked conversation counts; a delegated subagent does not.
Multiple matching threads print an ambiguity diagnostic naming their ids and fall through to the legacy tmux fallback, as do no matches or an unreachable server.
Resolve ambiguity by explicitly setting both `FM_SUPERVISOR_BACKEND=t3code` and `FM_SUPERVISOR_TARGET` to the intended thread id.
Busy uses the [thread status table](#restart-and-liveness-behavior), injection is a `t3_thread_send`, and escalations defer exactly as on every other backend.
An unknown native busy verdict defers new-turn delivery but does not prove that work resumed.
Away housekeeping keeps an overdue stale alert pending and buffers one possible-wedge report while the verdict remains unknown, including a failed run or a transient thread-read failure.
Delivered warnings stay suppressed while the same unknown condition persists.
If a fresh daemon entry discards a queued, undelivered warning, it clears that warning's reported marker and preserves its stale timer, so the next housekeeping pass queues exactly one replacement.
Refreshing a live daemon preserves the queue; a failed start restores the previous queue and reported markers.
Confirmed busy activity or a missing thread clears the stale and reported markers, so a later unknown condition can report again.
Declared external-wait rechecks also survive native uncertainty; the worker's declaration still controls their cadence.
`stale_window_is_busy` and `housekeeping` in `bin/fm-supervise-daemon.sh` own stale tracking; `fm_afk_clear_stale_artifacts` in `bin/fm-afk-start.sh` and the launcher in `bin/fm-afk-launch.sh` own queue discard and startup rollback.
`tests/fm-backend-t3code.test.sh` covers retention, deduplication, and re-arming across native restart.
Only `bin/fm-afk-launch.sh start-native` launches the daemon here, as the captain's own tracked background job; `start` refuses because T3 hosts no terminal to create.
A secondmate spawned on this backend carries its supervisor identity in its environment, so its own daemon needs no discovery.

## Switching back to Herdr

Write `herdr` to `config/backend` and every new spawn uses the Herdr backend again.
In-flight tasks keep the backend recorded in their own `state/<id>.meta`, so they are supervised and torn down through T3 Code until they finish.

## Moving a task from the pre-V2 transport

A home that used the earlier HTTP dispatch transport needs the `/mcp` credential first: run the [sign-in](#sign-in), which replaces the old bearer in `config/t3code-token`.
Keep each task's recorded thread id and use normal steering and teardown after sign-in; [`verification/runtime-backends.md`](verification/runtime-backends.md#adapter-wiring-on-linux) records the pre-V2 thread-read evidence.
If a task's thread no longer reads back, release the task by hand:

1. Archive the task's thread in T3 Code and satisfy the [cleanup proof above](#current-lifecycle-and-safety) before releasing its worktree or home.
2. For a worker, undo the per-worktree environment with `bin/fm-t3code-codex-env.sh cleanup <worktree>`, then remove `CLAUDE.local.md` and `.claude/settings.local.json` from the worktree.
   Skipping this hands the next holder of the slot a hidden `.codex/config.toml` overlay carrying the dead task's environment, and refuses the next T3 Codex spawn there.
   For a secondmate, release its own tasks in this same order, then run `bin/fm-t3code-codex-env.sh cleanup <home>` and remove its `.claude/settings.local.json` before releasing the home.
3. For a worker, return its slot with `treehouse return --force <worktree>` from its project.
   A secondmate has no separate task worktree, but its home may itself be leased: preserve its durable records and unlanded work, then return a pooled home with `treehouse return --force <home>` from the Firstmate code root, or remove a standalone home by hand.
   Remove its line from the parent's `data/secondmates.md`.
4. Remove the task record, `state/<id>.meta`, and its other `state/<id>.*` files.

## Active limits

- T3 Code remains experimental and runs only `claude` and `codex`.
- T3 starts the agent at `full-access` with its provider instance's account and environment, so a spawn refuses `config/claude-permission-mode=auto` for `claude`, `config/launch-env-allowlist`, and a worker account pin; select the account through `config/t3code-instances` instead.
- T3 owns the Claude provider command, so Firstmate cannot add its command-line prompt-suggestion, feedback-draft, or attribution controls; configure equivalent provider-instance settings in T3 when those policies are required.
  Unless `config/keep-ai-trailers` is present, the per-worktree environment selects Firstmate's Git commit hook to strip known AI trailers, including on T3 workers.
- T3 also owns the Codex provider command, so Firstmate cannot apply the pane-backed worker's hook-disable or turn-end notify options.
  Firstmate's pane-backed hook-trust workaround therefore does not apply; supervision uses T3's [thread status table](#restart-and-liveness-behavior).
- `fm-control.sh exit` is refused because the V2 `/mcp` tools have no session stop, and `relaunch` is refused because a thread keeps its conversation, so no fresh agent can replace it.
- The WebSocket event stream is not available to an `mcp-client` credential; the [run wait](#push-events-and-polling-fallback) stands in for it.
- A permission approval cannot be answered through `/mcp`; it waits for T3 Code itself.
- A tracked `.codex/config.toml` that already defines `[shell_environment_policy]` is refused by file and table name before a slot is leased.
- While a tracked Codex overlay is installed, do not edit that file or clear its `skip-worktree` flag; configuration changes require cleanup first.
- Shell typing and Ctrl-U are unsupported; runtime Escape and Ctrl-C still interrupt the turn.
- A Codex supervisor has no away mode on this backend because it has no tracked background tool for `start-native`, and T3 has no terminal for `start` to create.
- T3 checkpoints each turn as hidden refs under `refs/t3/orchestration-v2/checkpoints/` in the project clone; they are never pushed and do not affect the landed-work test.

## Regression entry points

```sh
bin/fm-test-run.sh tests/fm-t3-mcp.test.sh tests/fm-backend-t3code.test.sh
bin/fm-test-run.sh tests/fm-backend.test.sh tests/fm-daemon.test.sh tests/fm-control.test.sh
FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-live-e2e.test.sh
FM_T3CODE_PR_TOOLS_LIVE=1 FM_CONFIG_OVERRIDE=<home>/config bin/fm-test-run.sh tests/fm-backend-t3code-pr-tools-live-e2e.test.sh
```

The portable entry points cover the T3 adapter against a [fake `/mcp` server](../tests/t3-fake-server.mjs) and fake Treehouse, plus the shared backend, daemon, and control behavior.
The live guard spends no model tokens and changes nothing on the server: it checks the gate, the project catalog, and a typed missing-thread read against the server the configured credential names, and skips cleanly without one.
Set `FM_T3CODE_LIVE_E2E=0` to disable it or `FM_T3CODE_LIVE_E2E=1` to require it; the shared `FM_LIVE` override also applies.
The pull-request-tool guard is opt-in because it spends model tokens: it launches one scratch Claude thread that links, lists, and unlinks an old merged PR, and archives that thread afterwards.
[`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code) records the dated live results.
