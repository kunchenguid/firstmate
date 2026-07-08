# Codex App runtime backend

This document describes the `codex-app` runtime backend for making Codex Desktop the native Firstmate work surface.
Firstmate dispatches work into Codex threads, supervises those threads through Codex thread state and Firstmate status files, and archives threads when normal Firstmate teardown rules say the task is safe to remove.

Status: first-pass implementation.
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
- Do not rely on a long-running remote-control daemon in the first implementation pass.
- Do not replace Firstmate's PR, validation, landed-work, or teardown safety rules.
- Do not support secondmate launches in the first implementation pass.
- Do not auto-detect `codex-app` as the runtime backend.
- Do not depend on long transcript copies in Firstmate state files.
- Do not require Codex app-server to create git worktrees.

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
- The generated schema contains `thread/start`, `thread/resume`, `turn/start`, `turn/steer`, `thread/read`, `thread/turns/list`, `thread/list`, `thread/search`, `thread/archive`, `thread/unarchive`, `thread/name/set`, `thread/goal/set`, `turn/interrupt`, `thread/rollback`, and `thread/status/changed`.
- `ThreadStatus` has `idle`, `active`, `systemError`, and `notLoaded` variants.
- `TurnStatus` has `completed`, `interrupted`, `failed`, and `inProgress` variants.
- `ThreadStartResponse` returns a `thread` object and an effective `cwd`.
- A thread created by one direct-stdio app-server process is visible to later processes through state as `notLoaded`, but `turn/start` against that id fails with `thread not found` until the new process calls `thread/resume`.
- `thread/resume` accepts `sandbox: "danger-full-access"` as a string for this Codex version; the object-shaped sandbox used by other request paths is rejected.
- On this machine, `codex app-server daemon version` failed because `/Users/ra/.codex/app-server-control/app-server-control.sock` did not exist, so the first pass uses direct stdio and bootstrap probes `codex app-server --help` instead of depending on the daemon.
- A real Flow smoke on 2026-07-08 spawned thread `019f42e2-d486-7d93-acde-cc77270a05e4` in `/Users/ra/Documents/GitHub/firstmate/projects/.firstmate-worktrees/codex-smoke-flow-a1`, started from registered `refs/remotes/origin/dev` at `dc6bfbefb058e88c314386dfade6e16844cf1c25`, wrote the status/report artifacts, accepted a follow-up send, was readable with `fm-peek.sh fm-codex-smoke-flow-a1`, and archived/removed cleanly through teardown.

This checkout is also registered as a Codex Desktop project in the app's project list.

## Architecture

`codex-app` is a normal Firstmate runtime backend with one extra layer:

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

The bridge is implemented in Node so Firstmate can handle JSON with structured parsing instead of shell string manipulation.
Bash remains the caller, not the protocol implementation.
The first implementation uses one-shot direct stdio calls to `codex app-server --listen stdio://`.
Managed remote-control can become a later optimization after bootstrap can verify the standalone Codex install.

## Bridge contract

The bridge exposes a small CLI vocabulary.
All successful commands print one JSON object to stdout.
All failures print a short human-readable diagnostic to stderr and return non-zero.
After a thread is created, name and goal updates are best-effort metadata calls; failures are reported in the successful `start-thread` JSON instead of hiding the created thread id.

Implemented verbs:

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
bin/fm-codex-bridge start-thread --cwd <path> --name <name> --goal <text> [--model <model>]
bin/fm-codex-bridge send-turn --thread-id <id> --prompt-file <file> [--cwd <path>] [--model <model>] [--effort <effort>] [--wait-status-file <file>] [--wait-status-line <line>] [--wait-status-polls <n>] [--wait-status-sleep <seconds>] [--turn-lifecycle-polls <n>] [--turn-lifecycle-sleep <seconds>]
bin/fm-codex-bridge read-thread --thread-id <id> [--include-turns]
bin/fm-codex-bridge thread-status --thread-id <id>
bin/fm-codex-bridge turns-list --thread-id <id> --limit <n> --items-view summary|full|notLoaded
bin/fm-codex-bridge archive-thread --thread-id <id>
bin/fm-codex-bridge list-live [--cwd <path>]
```

The bridge starts by launching `codex app-server --listen stdio://` and sending schema-native newline-delimited request objects.
Every bridge process begins with `initialize` and opts into experimental APIs.
Every `send-turn` worker calls `thread/resume` before `turn/start`, because one-shot stdio processes do not share loaded thread memory.
Read-only thread listing passes `useStateDbOnly:true` to avoid rollout repair scans in the current first-pass bridge.

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
worktree_provider=git-worktree
project_id=<stable-project-id>
project_base_ref=<registry-base-ref-when-present>
```

`window=` remains populated for compatibility with existing selector helpers.
For this backend, it is the Codex thread id, not a terminal pane.

In the first implementation, Firstmate creates the isolated git worktree in the supervising shell before `thread/start`, then passes that worktree path as the Codex thread `cwd`.
This keeps worktree ownership inside Firstmate's existing safety model while Codex owns the visible thread and turn lifecycle.
Because `codex-app` has no terminal endpoint before the thread exists, it cannot rely on the tmux-style pattern of typing `treehouse get` into a newly created pane.
The first pass creates a guarded detached git worktree under `${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}/.firstmate-worktrees/<id>` and records `worktree_provider=git-worktree` so teardown uses `git worktree remove` instead of Treehouse.
When `data/projects.json` supplies a `baseRef`, that ref is the authoritative worktree base.
Otherwise the legacy path resolves the project default from `origin/HEAD`, `main`, or `master`.
The worktree deliberately starts detached so the normal Firstmate brief can create `fm/<id>` itself.
The backend must validate that `codex_cwd` matches the expected Firstmate worktree root and is not the primary project checkout.
If Codex starts a thread anywhere else, ship and scout spawns must refuse before substantive work begins.
Codex Desktop's own managed worktrees under `$CODEX_HOME/worktrees` are not adopted or removed in this backend pass.
They may be discovered for collision awareness, but task-level ownership metadata is required before Firstmate can manage an existing Codex worktree.

## Spawn flow

First pass spawn flow:

1. Resolve `backend=codex-app` only from explicit configuration or `--backend codex-app`.
2. Refuse `--secondmate`.
3. Require `harness=codex`.
4. Resolve the project through `fm-project-resolve.sh`.
5. Create an isolated detached git worktree under the effective Firstmate projects directory from the registry `baseRef` when present.
6. Build the normal Firstmate brief and status-file instructions.
7. Run `fm-codex-bridge ensure-running`.
8. Start a Codex thread through the bridge with the isolated worktree as `cwd`.
9. Set the thread name to `fm-<id>`.
10. Set the thread goal to the Firstmate task objective.
11. Validate that `codex_cwd` is the isolated worktree, not the primary checkout.
12. Start the initial prompt turn through `send-turn`, whose worker resumes the just-created thread in its own app-server process before `turn/start`.
13. Keep the app-server process alive in a detached `send-turn` worker until the return channel writes the expected status line.
14. Verify the return channel before treating the thread as supervised.
15. Record meta with `backend=codex-app`, `thread_id=`, `codex_cwd=`, `project_id=`, optional `project_base_ref=`, and `worktree_provider=git-worktree`.

The return-channel verification is load-bearing.
The worker prompt must instruct the Codex thread to append:

```text
working: Codex thread started
```

to the absolute Firstmate status file before doing substantive work.
Firstmate then waits up to 60 seconds by default for that line to appear.
The budget is controlled by `FM_CODEX_APP_RETURN_CHANNEL_POLLS` and `FM_CODEX_APP_RETURN_CHANNEL_SLEEP`, defaulting to 240 polls at 0.25 seconds.
The startup `send-turn` parent receives that same file, expected line, and timeout budget, records the status-file byte offset before `thread/resume` and `turn/start`, starts a detached worker, and waits until the worker reports that the first turn was accepted and the return channel was verified from new status output.
The worker keeps the same Codex app-server stdio process alive after that handshake while it polls the thread status until the turn leaves an active state.
The lifecycle hold is controlled by `FM_CODEX_APP_TURN_LIFECYCLE_POLLS` and `FM_CODEX_APP_TURN_LIFECYCLE_SLEEP`, defaulting to 4320 polls at 5 seconds.
If the expected line does not appear, the spawn archives the thread, removes the startup worktree only when the worktree is clean and still at the verified base commit, and fails with a diagnostic naming the thread id and the missing status file write.
If the archive attempt fails, startup cleanup stops before removing the worktree, status file, or metadata so the live thread can be recovered manually.
If the startup worktree is dirty or its git state cannot be verified, startup cleanup writes recovery metadata and preserves the worktree instead of deleting it.

## Send and steer flow

`fm-send.sh fm-<id> <text>` maps to:

```text
fm-codex-bridge send-turn --thread-id <thread_id> --prompt-file <tmp-prompt> [--cwd <path>]
```

The first implementation starts a new turn by calling `thread/resume` and then `turn/start` in a detached bridge worker.
The CLI returns after the turn is accepted, while the worker keeps the app-server alive until the thread leaves an active state.
Follow-up sends pass the recorded `codex_cwd` as `cwd`, propagate the recorded model and effort when they are not `default`, and run with the task's `GOTMPDIR` when `tasktmp=` is present in meta.
A later enhancement can offer same-turn steering, `turn/interrupt`, or interrupt-plus-new-turn behavior, but that should require an explicit design decision rather than surprising interruption.

## Peek and capture flow

`fm-peek.sh` uses `thread/turns/list` through the backend dispatcher.
For the first implementation, `capture` returns a bounded text summary assembled from recent user and agent message items.
It should not dump entire thread history.
The bridge renders fetched turns oldest-to-newest before the backend applies the requested capture line count to the returned text tail.
`FM_CODEX_APP_CAPTURE_TURN_LIMIT` controls the separate bounded `thread/turns/list` fetch size and defaults to 20 turns.

The bridge supports both summary and full item views, but the backend default uses summary.

## Watcher mapping

The watcher uses semantic Codex state through `fm_backend_busy_state` when available:

| Codex state | Firstmate interpretation |
|---|---|
| `active`, `inProgress`, `running` | busy |
| `idle` | not busy; inspect status file and latest turn |
| `systemError`, `notLoaded`, or any unknown state | unknown; fall back to status file and `thread/read` |

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
Teardown archives the Codex thread before removing the git worktree or task metadata.
If the archive call fails, teardown leaves the worktree and metadata in place.

## Configuration

Select the backend explicitly:

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

When `backend=codex-app` is selected, bootstrap requires `codex`, `codex app-server --help`, `node`, `gh`, `jq`, `no-mistakes`, `gh-axi`, `chrome-devtools-axi`, and `lavish-axi`.
It intentionally skips `tmux` and `treehouse` for this backend because Codex Desktop owns the visible thread and Firstmate uses a plain git worktree.
It also skips Treehouse compatibility probes when Treehouse is not in the selected required-tool set.

## Tests

Unit tests should use a fake bridge path injected through an environment variable, for example:

```text
FM_CODEX_BRIDGE=/tmp/fake-fm-codex-bridge
```

Implemented tests:

- Backend selection accepts `codex-app` only after it is listed as known and spawn-capable.
- `fm-spawn.sh --backend codex-app` refuses `--secondmate`.
- Spawn records `backend=codex-app`, `thread_id=`, `codex_cwd=`, `project_id=`, optional `project_base_ref=`, and `worktree_provider=git-worktree`.
- Spawn uses a registered `baseRef` as the git-worktree base when `data/projects.json` supplies one.
- Spawn refuses when the returned `codex_cwd` equals the primary checkout.
- Bridge `send-turn` resumes one-shot direct-stdio threads before `turn/start`.
- Spawn accepts a status-file return-channel write that arrives after the old five-second startup window.
- Spawn refuses when the status-file return channel is not verified.
- Spawn ignores stale return-channel status lines written before the current turn.
- Spawn preserves dirty or unverifiable failed-startup worktrees for recovery instead of deleting them.
- `fm-send.sh` routes to `send-turn`.
- `fm-send.sh` passes the recorded Codex cwd, model, effort, and per-task `GOTMPDIR` into follow-up turns.
- `fm-peek.sh` routes to recent thread turns.
- Teardown archives only after existing safety checks pass.
- Teardown archives before removing the git worktree and preserves state when archive fails.
- Bootstrap requires a Codex CLI with `app-server` support for `backend=codex-app` and does not require tmux or Treehouse.

## Implementation touch points

The existing backend dispatcher already covers the send and peek paths cleanly.
`fm-send.sh` resolves a target through `fm_backend_resolve_selector`, then calls `fm_backend_send_text_submit`.
`fm-peek.sh` resolves the same target and calls `fm_backend_capture`.
For `codex-app`, `fm-peek.sh` stays fully generic, while `fm-send.sh` adds only the small environment shim needed to pass the recorded cwd, model, effort, and task temp directory into bridge-backed turns.

The higher-risk implementation areas are:

- `bin/fm-backend.sh`: lists `codex-app` as known and spawn-capable, sources `bin/backends/codex-app.sh`, and dispatches capture, send, kill, busy state, and target existence.
- `bin/backends/codex-app.sh`: implements bridge-backed adapter functions and keeps all JSON/protocol parsing out of generic scripts.
- `bin/fm-spawn.sh`: owns the `codex-app` creation branch, skips terminal-send launch plumbing, resolves the project registry, acquires a shell-side worktree before thread creation, writes Codex-specific and project identity meta fields, and verifies the status return channel.
- `bin/fm-watch.sh`: relies on semantic `busy` and `idle` from `fm_backend_busy_state`; deeper notification integration is deferred.
- `bin/fm-crew-state.sh`: keeps using the backend dispatcher; richer Codex-specific state can be added later if needed.
- `bin/fm-teardown.sh`: relies on existing landed-work checks, then maps endpoint removal to thread archive.
- `bin/fm-bootstrap.sh`: requires a Codex CLI with `app-server` support only when `backend=codex-app` is selected.

Future call-site special cases should stay as small as the current `fm-send.sh` environment shim; protocol logic belongs in the bridge and backend adapter.

Local smoke verification should run against real Codex Desktop:

1. Spawn a scratch scout task with `--backend codex-app --harness codex`.
2. Confirm a new visible Codex thread appears.
3. Confirm the thread writes the expected status line.
4. Send a follow-up with `fm-send.sh`.
5. Read it with `fm-peek.sh`.
6. Archive it through teardown.

## Rollout sequence

1. Land the bridge with fake-protocol tests.
2. Add backend registration and adapter functions.
3. Wire spawn, send, peek, watcher busy state, and teardown.
4. Gate bootstrap on the Codex CLI for `backend=codex-app`.
5. Update README, configuration docs, and AGENTS with short pointers only.
6. Run one local Codex Desktop smoke test before marking the backend broadly supported.

## Open questions

- Should a later bridge use a long-lived process for notification subscription, or keep one-shot stdio calls?
- Should the first pass allow `turn/interrupt`, or require manual captain confirmation before interrupting active work?
- Should non-default Codex model and effort values get additional validation against `model/list` before bridge submission?
