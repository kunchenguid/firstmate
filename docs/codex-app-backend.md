# Codex App backend contract

Status: blocked for Firstmate as a selectable shell backend. The Codex Desktop host-tool loop works, including status-file writes, but Firstmate does not yet have a supported shell-callable bridge to those host tools.

This document replaces the earlier passive visible-thread ledger shape. A manual ledger is not a backend.

## Backend acceptance contract

A Codex App backend must satisfy the same lifecycle contract as the terminal-backed adapters:

1. Firstmate creates the task endpoint and receives a durable thread id.
2. Firstmate sends the initial prompt and later operator messages to that endpoint.
3. Firstmate observes enough live thread state or transcript to supervise the task.
4. Firstmate can archive, kill, or otherwise stop supervising the endpoint.
5. The Codex thread can report back through Firstmate's normal `state/<id>.status` lifecycle.

The final point is mandatory. If a Desktop-owned thread cannot write Firstmate status files, the backend cannot be treated as complete.

## Verified Desktop host-tool smoke

Smoke date: 2026-07-03.

Environment: Codex Desktop, against a local Firstmate checkout on branch `fm/codex-app-real-backend`.

Thread id: `019f2947-f75e-78b2-aebc-f57ef1b5b399`.

Transcript, trimmed to the backend-relevant facts:

```text
create_thread:
  Created Codex Desktop thread 019f2947-f75e-78b2-aebc-f57ef1b5b399.
  Prompt asked the thread to write:
    state/codex-app-host-smoke-j3.status
    data/codex-app-host-smoke-j3/report.md

read_thread:
  Observed the thread while active.
  Later observed it completed and idle.
  Transcript included fileChange entries for both files.

status file after create:
  working: host thread wrote status

report file:
  cwd=<Desktop-owned thread worktree>
  status_file_write=ok
  sentinel=FM_CODEX_APP_HOST_TOOL_SMOKE_OK

send_message_to_thread:
  Sent a follow-up asking the same thread to append a completion status.

status file after follow-up:
  working: host thread wrote status
  done: follow-up delivered

archive:
  Archived the thread through the Desktop host archive tool.
  A later read still returned the transcript and showed the thread not loaded.
```

Result: a Desktop-owned Codex thread can write Firstmate status files when the prompt gives it the absolute status path and the Desktop permission context can write that checkout. The return channel is real at the Codex Desktop host-tool layer.

## Shell-backend blocker

Firstmate's backend scripts are Bash entry points. They can call `tmux`, `herdr`, `zellij`, and primitive Orca CLI surfaces directly. The Codex Desktop host tools verified above are available to the Codex Desktop conversation, not to arbitrary Firstmate subprocesses.

The shell bridge check found useful pieces but not a supported backend transport:

- `codex app-server --stdio` exposes JSON-RPC methods such as `thread/start`, `turn/start`, `thread/read`, and `thread/archive`.
- A one-shot stdio probe could create a thread record, and `thread/archive` worked through that same stdio process.
- The managed daemon path was unavailable in this Desktop install.
- A raw proxy attempt against the Desktop control socket did not accept plain JSON-RPC framing.

That is not enough to add `codex-app` to `FM_BACKEND_KNOWN` or `FM_BACKEND_SPAWN`. A Firstmate backend must be able to create a thread, start or continue turns, read live state while turns run, and archive/stop the same endpoint through a stable shell-callable API. Shipping a local ledger would only record intentions; it would not supervise the actual Desktop thread.

## Required bridge before implementation

A future Codex App adapter should be implemented only after one of these exists:

- A supported CLI wrapper around the Desktop host tools: create thread, send message, read transcript/state, archive thread.
- A documented JSON-RPC or MCP transport that Firstmate can call from Bash with stable request/response framing.
- A small maintained helper binary/script that speaks the supported transport and returns plain JSON to `bin/backends/codex-app.sh`.

Minimum command semantics:

```text
create:
  input: task id, cwd/worktree request, initial prompt
  output: thread id, Desktop-owned cwd if different, initial status

send:
  input: thread id, text
  output: accepted/rejected delivery result

capture/read:
  input: thread id, bounded transcript or status cursor
  output: enough text/state for fm-peek.sh, fm-watch.sh, and fm-crew-state.sh

archive/kill:
  input: thread id
  output: archived/stopped result

status return channel:
  the thread must be able to append Firstmate status lines to state/<id>.status
```

Once that bridge exists, the implementation should add a real `bin/backends/codex-app.sh`, persist `backend=codex-app` and `codex_app_thread_id=` in `state/<id>.meta`, and wire spawn/send/peek/watch/teardown through the same dispatcher paths used by the existing adapters.

Until then, Codex App support remains a verified host-tool smoke plus this blocked backend contract, not a selectable backend.
