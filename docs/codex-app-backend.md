# Codex App runtime backend design

This document is the design contract for making Codex Desktop the native Firstmate work surface.
The target end state is a `codex-app` runtime backend where Firstmate dispatches work into Codex threads, supervises those threads through Codex thread state and Firstmate status files, and archives threads when normal Firstmate teardown rules say the task is safe to remove.

Status: design candidate, not implemented.
Verified on 2026-07-06 against the installed `codex` CLI on the reference machine.

## Goals

- Codex Desktop is the primary interface where the captain watches and opens work.
- Firstmate can spawn ship and scout work into Codex threads without tmux.
- Firstmate can send follow-up instructions to a Codex thread.
- Firstmate can read thread state and recent transcript content without scraping a terminal.
- Firstmate can map Codex thread status into the existing watcher lifecycle.
- Firstmate can archive Codex threads during teardown without losing the transcript or landed work.
- The backend is shell-callable from Firstmate scripts, so it does not depend on model-visible host tools being present in the supervising turn.

## Non-goals

- Do not make model-visible host tools the backend API.
- Do not pretend `config/backend=codex-app` works until a shell-callable bridge exists.
- Do not replace Firstmate's PR, validation, landed-work, or teardown safety rules.
- Do not support secondmate launches in the first implementation pass.
- Do not auto-detect `codex-app` as the runtime backend.
- Do not depend on long transcript copies in Firstmate state files.
- Do not require Codex app-server to create git worktrees in the first pass.

## Current evidence

The local `codex` CLI exposes an experimental app-server protocol.

Observed commands:

```text
codex app-server --help
codex remote-control --help
codex app-server generate-json-schema --experimental --out <tmpdir>
codex app-server daemon version
```

Relevant facts from that pass:

- `codex app-server` can run over stdio, unix sockets, or websockets.
- `codex app-server proxy` proxies stdio bytes to a running app-server control socket.
- `codex remote-control start --json` starts the app-server daemon with remote control enabled.
- `codex remote-control start --json` failed on this machine because the standalone Codex install was absent at `/Users/ra/.codex/packages/standalone/current/codex`.
- The installed Homebrew `codex` binary can still run `codex app-server --listen stdio://` directly.
- The stdio transport uses one schema-native JSON object per line, without a `jsonrpc:"2.0"` wrapper and without LSP `Content-Length` framing.
- An `initialize` request returned `Codex Desktop/0.135.0`, `codexHome=/Users/ra/.codex`, `platformFamily=unix`, and `platformOs=macos`.
- `model/list`, `thread/loaded/list`, and `thread/list` work over direct stdio.
- `thread/list` with `useStateDbOnly:true` returned promptly and avoided the slow rollout repair scan that appeared with the default listing path.
- The generated schema contains `thread/start`, `turn/start`, `turn/steer`, `thread/read`, `thread/turns/list`, `thread/list`, `thread/search`, `thread/archive`, `thread/unarchive`, `thread/name/set`, `thread/goal/set`, `turn/interrupt`, `thread/rollback`, and `thread/status/changed`.
- `ThreadStatus` has `idle`, `active`, `systemError`, and `notLoaded` variants.
- `TurnStatus` has `completed`, `interrupted`, `failed`, and `inProgress` variants.
- `ThreadStartResponse` returns a `thread` object and an effective `cwd`.
- On this machine, `codex app-server daemon version` failed because `/Users/ra/.codex/app-server-control/app-server-control.sock` did not exist, so bootstrap must start or diagnose the daemon before backend use.

This checkout is also registered as a Codex Desktop project in the app's project list.

## Architecture

`codex-app` should be a normal Firstmate runtime backend with one extra layer:

```text
Firstmate scripts
  -> bin/backends/codex-app.sh
  -> bin/fm-codex-bridge
  -> codex app-server protocol
  -> Codex Desktop threads
```

`bin/fm-codex-bridge` owns the unstable Codex protocol details.
Backend scripts call stable bridge verbs and parse stable bridge JSON.
If the Codex protocol changes, the bridge changes first and the rest of Firstmate remains mostly unchanged.

The bridge should be implemented in Node or another JSON-friendly runtime already acceptable for Firstmate.
Bash remains the caller, not the protocol implementation.
The first implementation should prefer one-shot direct stdio calls to `codex app-server --listen stdio://`.
Managed remote-control can become an optimization after bootstrap can verify the standalone Codex install.

## Bridge contract

The bridge exposes a small CLI vocabulary.
All successful commands print one JSON object to stdout.
All failures print a short human-readable diagnostic to stderr and return non-zero.

Required first-pass verbs:

- `ensure-running`
- `start-thread`
- `send-turn`
- `read-thread`
- `thread-status`
- `turns-list`
- `archive-thread`
- `list-live`

Suggested command shapes:

```text
bin/fm-codex-bridge ensure-running
bin/fm-codex-bridge start-thread --cwd <path> --name <name> --goal <text> --prompt-file <file> [--model <model>] [--effort <effort>]
bin/fm-codex-bridge send-turn --thread-id <id> --prompt-file <file>
bin/fm-codex-bridge read-thread --thread-id <id> [--include-turns]
bin/fm-codex-bridge thread-status --thread-id <id>
bin/fm-codex-bridge turns-list --thread-id <id> --limit <n> --items-view summary|full
bin/fm-codex-bridge archive-thread --thread-id <id>
bin/fm-codex-bridge list-live [--cwd <path>]
```

The bridge should start by launching `codex app-server --listen stdio://` and sending schema-native newline-delimited request objects.
Every bridge process should begin with `initialize` and opt into experimental APIs.
Read-only list operations should pass `useStateDbOnly:true` unless the caller explicitly requests rollout repair.
If the future daemon path is selected, the bridge may start remote control with `codex remote-control start --json` when no daemon socket is available.
If daemon startup fails, the diagnostic must name the failed command and distinguish a missing standalone install from a missing socket or app-server error.

## Backend metadata

A `codex-app` task meta record should include:

```text
backend=codex-app
window=<thread-id>
thread_id=<thread-id>
codex_cwd=<effective-cwd-returned-by-thread-start>
worktree=<effective-cwd-returned-by-thread-start>
project=<original-project-path>
harness=codex
kind=<ship|scout>
mode=<normal|local-only|upstream-contribution>
yolo=<on|off>
tasktmp=<task-temp-path>
model=<model-or-default>
effort=<effort-or-default>
```

`window=` remains populated for compatibility with existing selector helpers.
For this backend, it is the Codex thread id, not a terminal pane.

In the first implementation, Firstmate should create or acquire the isolated git worktree in the supervising shell before `thread/start`, then pass that worktree path as the Codex thread `cwd`.
This keeps worktree ownership inside Firstmate's existing safety model while Codex owns the visible thread and turn lifecycle.
Because `codex-app` has no terminal endpoint before the thread exists, it cannot rely on the tmux-style pattern of typing `treehouse get` into a newly created pane.
The implementation should introduce a shell-side worktree acquisition helper, using Treehouse when available and a guarded `git worktree add` path when Treehouse is unavailable or unsuitable for this backend.
The backend must validate that `codex_cwd` matches the expected Firstmate worktree root and is not the primary project checkout.
If Codex starts a thread anywhere else, ship and scout spawns must refuse before substantive work begins.

## Spawn flow

First pass spawn flow:

1. Resolve `backend=codex-app` only from explicit configuration or `--backend codex-app`.
2. Refuse `--secondmate`.
3. Run `fm-codex-bridge ensure-running`.
4. Acquire an isolated git worktree through the shell-side worktree helper.
5. Build the normal Firstmate brief and status-file instructions.
6. Start a Codex thread through the bridge with the isolated worktree as `cwd`.
7. Set the thread name to `fm-<id>: <short task title>` when available.
8. Set the thread goal to the Firstmate task objective.
9. Record meta with `thread_id=`, `codex_cwd=`, and `backend=codex-app`.
10. Verify the return channel before treating the thread as supervised.

The return-channel verification is load-bearing.
The worker prompt must instruct the Codex thread to append:

```text
working: Codex thread started
```

to the absolute Firstmate status file before doing substantive work.
Firstmate then waits briefly for that line to appear.
If it does not appear, the thread is still visible in Codex Desktop but is not a supervised Firstmate task.
The spawn should fail with a diagnostic naming the thread id and the missing status file write.

## Send and steer flow

`fm-send.sh fm-<id> <text>` maps to:

```text
fm-codex-bridge send-turn --thread-id <thread_id> --prompt-file <tmp-prompt>
```

If the Codex thread is active and the protocol accepts same-turn steering, the bridge may use `turn/steer`.
If the active turn is not steerable, the bridge should return a clear non-zero diagnostic.
A later enhancement can offer `turn/interrupt` plus a new turn, but the first implementation should avoid surprising interruption.

## Peek and capture flow

`fm-peek.sh` should use `thread/read` or `thread/turns/list`.
For the first implementation, `capture` should return a bounded text summary assembled from recent user and agent message items.
It should not dump entire thread history.

The bridge should support both summary and full item views, but the backend default should use summary.

## Watcher mapping

The watcher should prefer semantic Codex state when available:

| Codex state | Firstmate interpretation |
|---|---|
| `active` | busy |
| `idle` | not busy; inspect status file and latest turn |
| `systemError` | failed or blocked, surface to captain |
| `notLoaded` | unknown; fall back to status file and `thread/read` |

Turn status provides more detail:

| Turn state | Firstmate interpretation |
|---|---|
| `inProgress` | busy |
| `completed` | turn-ended equivalent |
| `failed` | failed |
| `interrupted` | needs inspection |

The first implementation can poll through the bridge like other backends.
A later implementation can subscribe to app-server notifications and enqueue wakes directly.

## Teardown and archive

`fm-teardown.sh` must keep the existing landed-work rules.
For `codex-app`, the backend endpoint removal operation archives the thread:

```text
fm-codex-bridge archive-thread --thread-id <thread_id>
```

Archiving is not evidence that work landed.
It is only the Codex equivalent of removing the visible endpoint after Firstmate has already proved the task is safe to remove.

## Configuration

The backend should be selected explicitly:

```text
config/backend
codex-app
```

or:

```text
FM_BACKEND=codex-app
```

No runtime auto-detection in the first pass.
Running inside Codex Desktop is common for the primary supervisor, but auto-selecting the backend would surprise users who still want tmux, herdr, zellij, or cmux from inside Codex.

Bootstrap should report:

```text
CODEX_APP: available
CODEX_APP: daemon not running - run codex remote-control start --json or let spawn start it
CODEX_APP: direct stdio available; managed remote-control unavailable - standalone Codex install missing
CODEX_APP: unavailable - <diagnostic>
```

when `backend=codex-app` is selected.

## Tests

Unit tests should use a fake bridge path injected through an environment variable, for example:

```text
FM_CODEX_BRIDGE=/tmp/fake-fm-codex-bridge
```

Required tests:

- Backend selection accepts `codex-app` only after it is listed as known and spawn-capable.
- `fm-spawn.sh --backend codex-app` refuses `--secondmate`.
- Spawn records `backend=codex-app`, `thread_id=`, and `codex_cwd=`.
- Spawn refuses when the returned `codex_cwd` equals the primary checkout.
- Spawn refuses when the status-file return channel is not verified.
- `fm-send.sh` routes to `send-turn`.
- `fm-peek.sh` routes to recent thread turns.
- Teardown archives only after existing safety checks pass.

## Implementation touch points

The existing backend dispatcher already covers the send and peek paths cleanly.
`fm-send.sh` resolves a target through `fm_backend_resolve_selector`, then calls `fm_backend_send_text_submit`.
`fm-peek.sh` resolves the same target and calls `fm_backend_capture`.
For `codex-app`, those two paths should mostly need new dispatcher arms and adapter functions, not bespoke call-site branches.

The higher-risk implementation areas are:

- `bin/fm-backend.sh`: add `codex-app` to known and spawn-capable backends, source `bin/backends/codex-app.sh`, dispatch capture, send, kill, busy state, and target existence.
- `bin/backends/codex-app.sh`: implement bridge-backed adapter functions and keep all JSON/protocol parsing out of generic scripts.
- `bin/fm-spawn.sh`: add a `codex-app` creation branch, skip terminal-send launch plumbing, acquire a shell-side worktree before thread creation, write Codex-specific meta fields, and verify the status return channel.
- `bin/fm-watch.sh`: make sure semantic `busy` and `idle` from `fm_backend_busy_state` prevent stale-hash terminal heuristics from misclassifying Codex threads.
- `bin/fm-crew-state.sh`: use `fm_backend_target_exists` or `fm_backend_busy_state` for `codex-app` instead of treating capture failure as a dead pane.
- `bin/fm-teardown.sh`: rely on existing landed-work checks, then map endpoint removal to thread archive.
- `bin/fm-session-start.sh` and bootstrap helpers: report Codex app-server availability only when `backend=codex-app` is selected.

The implementation should avoid adding `codex-app` special cases to `fm-send.sh` and `fm-peek.sh` unless the generic dispatcher proves insufficient.

Local smoke verification should run against real Codex Desktop:

1. Start remote control.
2. Spawn a scratch scout task with `--backend codex-app`.
3. Confirm a new visible Codex thread appears.
4. Confirm the thread writes the expected status line.
5. Send a follow-up with `fm-send.sh`.
6. Read it with `fm-peek.sh`.
7. Archive it through teardown.

## Rollout sequence

1. Land this design doc.
2. Add the bridge with fake-protocol tests.
3. Add backend registration and adapter functions.
4. Wire spawn, send, peek, watcher busy state, and teardown.
5. Add bootstrap diagnostics.
6. Run fake bridge tests.
7. Run one local Codex Desktop smoke test.
8. Update README, configuration docs, and AGENTS with short pointers only.

## Open questions

- Should the first bridge use a long-lived process for notification subscription, or one-shot JSON-RPC calls through `codex app-server proxy`?
- Which Codex permission profile should spawned crewmates use by default?
- Should the first pass allow `turn/interrupt`, or require manual captain confirmation before interrupting active work?
- How should model and effort flags map onto Codex app-server fields when the captain selects a non-default Codex model?
