# T3 Code runtime backend

T3 Code is an experimental, explicit-only backend in which each task runs as its own thread in the [T3 Code](https://github.com/pingdotgg/t3code) GUI, inside the T3 project that owns the task's repository.
Treehouse still provides the isolated worktree, and the thread is bound to that worktree, never to the project root.
Firstmate keeps every supervision primitive it has on a terminal backend: spawn, steer, peek, busy state, turn-end wakes, interrupt, exit, relaunch, and cleanup all go through T3's own HTTP API.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared selection and metadata semantics.

## Setup

Pick T3 Code when you already run your primary session or your day in T3 Code and want each worker visible as a thread in the repository's T3 project rather than in a terminal multiplexer.

Prerequisites:

- T3 Code v0.0.42, the one version this backend is verified against (see [Version pin](#version-pin)), with its server running as the same user: `t3 serve`, or `t3 service install` for the background service.
- The `t3` CLI on `PATH`, `curl`, and `jq`.
- Claude Code installed and authenticated for T3's `claudeAgent` provider; the worker harness must be `claude`.
- The universal harness and toolchain requirements in [`configuration.md`](configuration.md#toolchain), including Treehouse.

Select it with local `config/backend` containing `t3`, `FM_BACKEND=t3` for one launch, `--backend t3` on one spawn under that task's own authority, or an explicit request to Firstmate.
It is never auto-detected, even when Firstmate itself runs inside a T3 Code thread.

A spawn stops before anything is leased or created when a required tool is missing, when the server's runtime file `~/.t3/userdata/server-runtime.json` (or `$T3CODE_HOME/userdata/server-runtime.json`) names no reachable origin, when the harness is not `claude`, when `config/claude-account` declares a Claude account pin, when a raw launch command is given, or when `--secondmate` is requested.
`FM_T3_ORIGIN` overrides server discovery for verification against another server; `T3CODE_HOME` selects another T3 home for discovery, the model manifest, and the `t3` CLI alike.

Verify setup by spawning a small task and confirming metadata contains `backend=t3`, `t3_thread_id=`, and `t3_project_id=`, then opening the thread in T3 Code under the repository's project.
Routine supervision does not require the GUI: `bin/fm-peek.sh <id>` renders the thread's transcript tail, and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` steers it.

## Version pin

This backend is verified against T3 Code v0.0.42 only, and it claims no newer release.
T3's pending Orchestrator V2 rewrite ([pingdotgg/t3code#2829](https://github.com/pingdotgg/t3code/pull/2829)) removes `POST /api/orchestration/dispatch`, the only write path this backend has, and renames the thread commands it sends, while keeping the shell and thread reads, so a server carrying V2 cannot run this backend even though it still answers reads.
Before a spawn, relaunch, interrupt, exit, or teardown does any real work, Firstmate probes that endpoint and refuses a server that no longer exposes it, with a message naming the verified version and the V2 removal, rather than failing partway through the action.
A write that still reaches a server without the endpoint fails with the same message and changes nothing; only the best-effort inbox doorbell drops that message, because it discards its error output by design and leaves the retry to the watcher.
Once V2 ships a supported script-callable write path, the transport is expected to move onto it.

## Projects, threads, and the worktree binding

Every task's thread lands in the T3 project for its repository.
A project whose workspace root is Firstmate's project clone is used first.
Otherwise Firstmate uses the project T3 already has for the same repository, such as one the captain registered from their own checkout: the same repository means the same `origin` URL as the project clone, never an `upstream` remote.
Each project's `origin` is read from its workspace root; only when that directory is unreadable does Firstmate fall back to the project's `repositoryIdentity`, and then only when its locator names the `origin` remote, because T3 builds that identity from `upstream` first and its `canonicalKey` is not an origin.
Remotes compare the way T3 normalizes them, so `git@github.com:owner/repo.git`, `ssh://git@github.com/owner/repo`, and `https://github.com/owner/repo` name one repository.
When several projects match, the one titled after the repository wins, then the oldest; the spawn prints a notice naming the chosen project's title and workspace root, and `t3_project_id=` records it.
Only when T3 has no project for the repository does the first task register one rooted at the project clone, exactly as `t3 project add` would.
No manual project registration is required.

Each task leases its Treehouse worktree first, non-interactively, then creates a T3 thread with `worktreePath` set to that worktree and `branch` set to its current branch when it has one.
T3 launches the provider process in the worktree; a thread created without that binding would run in the project root, which is why Firstmate never creates one that way.
The thread's title is the task label `fm-<id>`, its model comes from the spawn's `--model` and `--effort`, then the T3 project's default model, then T3's own default for the claude provider, and its runtime mode follows `config/claude-permission-mode`: the default bypass posture maps to T3's full-access mode and `auto` maps to T3's auto mode.
T3 starts the provider under the thread's own runtime mode and treats the mode a turn carries as informational, so a relaunch whose resolved posture differs from the thread's switches the thread with `thread.runtime-mode.set` and reads it back before the brief turn, refusing the relaunch when the change does not stick.

```text
backend=t3
window=<thread id>
t3_thread_id=<thread id>
t3_project_id=<project id>
```

`window=` stays the shared Firstmate alias every reader uses; `t3_thread_id=` repeats it as the exact binding cleanup validation requires.

## Tokens

Every request carries a short-lived bearer session that Firstmate mints with `t3 auth session issue`, cached per home under `state/.t3-session` and `state/.t3-session.header` with mode 0600.
`FM_T3_TOKEN_TTL` sets its lifetime (default one hour); the session is refreshed inside its last five minutes, re-minted once when the server rejects it, and revoked with `t3 auth session revoke` when the home's last T3 task is torn down.
The token travels to `curl` only through the header file, so it never appears in a command line, a task record, a status line, or Firstmate's output.
`t3 auth session list` shows the live session labeled `firstmate:<home>`.

## What T3 launches, and what Firstmate still controls

T3 owns the provider command line, so nothing Firstmate normally puts on a launch line rides it.
Each piece has a verified replacement:

- The claude busy-state and turn-end hooks live in the worktree's `.claude/settings.local.json`, which T3's claude launch loads; a T3 worker therefore reports busy and idle, and wakes the watcher at turn end, exactly like a terminal worker.
- The launch environment a terminal worker receives through pane exports (`GOTMPDIR`, `FM_TASK_ID`, `COMPACT_ADVISER_DISABLE`, the Lavish host, the trace carrier, claude's suggestion and feedback switches, and the `GIT_CONFIG_COUNT`, `GIT_CONFIG_KEY_0=core.hooksPath`, and `GIT_CONFIG_VALUE_0=<hooks dir>` override that points git at the AI-trailer strip hooks) is written into that settings file's `env` map.
- The attribution-off and feedback-draft policies are settings keys in the same file.
- The launch brief is the thread's first turn, encoded exactly as a terminal launch encodes it, so the worker role contract and the steering-inbox path reach the worker unchanged.

An ordinary metadata-routed `fm-send.sh` text steer becomes a durable steering-inbox record, and its doorbell is one more turn on the thread.
T3 accepts a turn while another is running and hands it to the provider as a queued user message, so a busy worker receives the doorbell without any composer.
A steer, a doorbell, or a relaunch also wakes a worker whose provider session T3 has stopped: T3 starts the provider again on the next turn and resumes the same conversation.

## Lifecycle and control

`fm-peek.sh` renders the thread's messages and tool activity in time order, bounded to the requested lines, followed by one footer line with T3's session and turn state.

`fm-control.sh <id> interrupt` sends T3's turn interrupt.
T3 then stops the provider session itself a moment later and starts it again on the next message, so the interrupt's postcondition is the thread still existing, and the interrupted turn's own claude hooks close its busy record.
`fm-control.sh <id> exit` sends T3's session stop and requires T3 to report no live provider before it claims the stop; an already-stopped session is idempotent success, and a thread T3 no longer knows reports `endpoint-gone`.
`fm-control.sh <id> relaunch` stops the agent and delivers the brief again as a new turn on the same thread.
T3 resumes the provider's own conversation, so unlike a terminal relaunch the replacement keeps the previous context; a thread that has been archived or deleted cannot be re-created and refuses instead.
A relaunch onto a non-`claude` harness refuses before the running agent is stopped.
`--model` and `--effort` on a relaunch ride that brief turn as its model selection, so the replacement runs on the model the record names.
A relaunch whose brief turn never starts stops the session again but keeps the thread, the record, and the worktree, so the task can be relaunched once the cause is fixed.
A fresh spawn that fails before its task record is published archives the thread when its close can be proven, and returns a clean slot's lease only after that proven close, under the Treehouse project lock it still holds.
There, an unproven close keeps both the lease and this task's slot claim, so no stale owner's teardown recycles a slot an open thread is still bound to, while a proven close on a dirty or unreadable slot keeps the lease and drops only this task's own claim, so the slot's previous owner keeps its teardown protection.
A launch-delivery failure after the record exists keeps both the lease and the claim unless the close was proven, the slot is clean, and the Treehouse project lock was taken within a bounded wait.
Whatever either path leaves in place, it names in a warning.

Cleanup keeps every shared Firstmate safety check: a scout still requires its report and completed decision inventory, and a ship still refuses dirty or unlanded work.
Before its first destructive step it runs the version pin's endpoint probe, even under `--force`, so a server without the dispatch endpoint, or one it cannot reach, refuses the cleanup before the backlog is marked, a parked no-mistakes run is concluded, or any process, lease, or record is touched.
It then stops the provider session when one is live, waits for T3 to report it stopped, archives the thread, and re-reads it: only T3's own not-found proves the close.
Stopping first is deliberate, because a stop sent after the archive is ignored and would leave the provider process running.
Only after that proven close does teardown return the leased worktree through Treehouse and release the task's slot claim, because a returned slot keeps the thread's `worktreePath` and T3 would start the provider there for the slot's next holder.
A close that cannot be proven stops the cleanup before that return, even under `--force`, keeping the task's records and the leased slot so the thread can still be reconciled.
Archived threads stay in T3's archive list; Firstmate never deletes a thread.

## Active limits

- T3 Code is experimental and explicit-only, and supports the `claude` harness family only, because only claude's settings-file wiring is verified to load through T3's launch.
- Only T3 Code v0.0.42 is supported; a server without the pre-V2 dispatch endpoint is refused (see [Version pin](#version-pin)).
- Secondmate spawns are unsupported.
- The claude system-prompt trust statement a terminal launch adds cannot be delivered, because no settings key carries it and T3 sets the command line; the brief's own worker-role section still establishes the task identity.
- The provider runs with the credentials T3's server holds; `CLAUDE_CONFIG_DIR` and the launch-environment allowlist do not reach it.
- A Claude worker account pin (`config/claude-account`) cannot be honored, because T3 launches the provider with its server's own login; a spawn or relaunch on `t3` refuses while one is declared rather than record a pin that did not apply.
- A relaunch resumes the thread's conversation rather than starting a fresh one, and cannot re-create an archived or deleted thread.
- Settling or archiving a worker's thread in the T3 GUI stops or hides its provider; Firstmate reads the first as an idle worker it can wake and the second as a gone endpoint.
- T3 hides archived threads from its detail endpoint, so Firstmate cannot distinguish an archived thread from a deleted one; both read as gone.
- Supervision is polling over HTTP; T3 exposes no push event Firstmate consumes yet.

## Regression entry points

```sh
tests/fm-backend-t3.test.sh
tests/fm-backend.test.sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-control.test.sh
```

The portable suite drives the adapter, the spawn, peek, control, and teardown paths against `tests/t3-fake-server.py`, a fake server speaking the observed response shapes plus two defensive models of shapes v0.0.42 was never seen to send: a dispatch 404 that names a resource, and an accepted turn that a readable thread's transcript does not show yet.
[`verification/runtime-backends.md`](verification/runtime-backends.md#t3-code) records the live evidence against a real T3 Code server, including what survives a T3-launched worker.
