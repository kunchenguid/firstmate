# Codex App backend boundary

Codex App is not a selectable Firstmate runtime backend.
Codex Desktop host tools can create and supervise visible threads and those threads can write Firstmate status files when given an authorized path, but Firstmate has no supported shell-callable bridge to those host tools.
A manual thread ledger is not a backend.

## Machine-supervised Codex workers

The opt-in app-server transport runs a local Codex worker in a Firstmate-managed tmux endpoint and isolated worktree.
It does not create a Desktop-visible thread or register a new runtime backend.
The spawn flag and installed-version/platform restrictions are owned by [`fm-spawn.sh`](../bin/fm-spawn.sh).
Interactive Codex TUI workers keep their existing unverified semantic-busy gate.

[`fm-codex-appserver.py`](../bin/fm-codex-appserver.py) owns one stdio process, thread, and turn bound to the supervisor-selected task and busy generation.
Correlated `inProgress` events publish verified busy evidence through the existing busy writer; `completed`, `failed`, and `interrupted` publish terminal evidence.
Transport death invalidates lifecycle evidence and never implies success.
A structured result becomes eligible for existing delivery reconciliation only after correlated terminal success; neither result text nor a successful turn alone establishes task completion.

Workers report through one client-owned `firstmate_report` dynamic tool accepting `type` (`progress`, `needs-decision`, or `result`) and a single-line `message` of up to 500 UTF-8 bytes, plus an optional `report` field of up to 262,144 UTF-8 bytes on scout `result` calls.
The adapter publishes scout report content to the canonical task report path only after correlated terminal success.
The adapter rejects identity/path selectors, additional fields, unknown operations, stale generations, and foreign thread/turn callbacks.
Canonical writes occur on the supervisor side under the busy generation lock.
The workspace-write sandbox grants only the worker workspace, disables network access and implicit temporary-directory write roots, and denies approval requests.
The worker has no writable fleet-state parent or access to the adapter control socket.

A `needs-decision` call opens the existing keyed status decision and remains unanswered while that same Codex turn stays in progress.
The normal current-state reader projects `parked` from the open decision, which is Firstmate's needs-user state; no separate Codex waiting record exists.
`fm-send.sh --resolve-key` hands the answer to the bound callback and closes the canonical decision through its existing answer path.
The adapter returns the answer only after that closure, resuming the same turn.
Ordinary steering uses `turn/steer` and refuses while a decision is open or after the turn ends.
Duplicate or stale answers cannot resume a callback twice or a replacement generation.
Callbacks are transient; cancellation or backend death retires them and their decision records rather than recreating a stopped turn.

For this single-turn transport, both interrupt and exit use `turn/interrupt` when active, then close app-server stdin and reap the child, retaining the task and worktree.
A bounded process-group termination fallback handles an unresponsive shutdown, without treating it as semantic success.
Relaunch, secondmates, other runtime backends, and automatic restart/resume are outside this initial transport.
The active verification and refresh commands are in [`verification/runtime-backends.md`](verification/runtime-backends.md#codex-app-server-worker-transport).

## Acceptance contract

A future Codex App backend must satisfy the same lifecycle contract as terminal-backed adapters:

1. Create a task endpoint and return a durable thread id.
2. Send the initial instructions and later operator messages to that endpoint.
3. Read enough live state or bounded transcript to supervise the task.
4. Archive, kill, or otherwise stop the exact endpoint.
5. Let the thread append Firstmate's normal lifecycle lines to `state/<id>.status`.

The status return channel is mandatory.
A visible thread that cannot report into Firstmate's normal lifecycle is not a complete backend.

## Current blocker

Firstmate backend scripts are shell entry points and can call tmux, Herdr, Zellij, Orca, and cmux directly.
Codex Desktop host tools are available to a Desktop conversation, not to arbitrary Firstmate subprocesses.
The missing component is a Codex Desktop-supported shell-callable transport, not another local ledger.

`codex app-server --stdio` exposes useful JSON-RPC pieces such as thread start, turn start, thread read, and thread archive.
A one-process probe could create and archive a thread record, but no supported bridge was found that lets Firstmate create, continue, read, and archive the same visible Desktop-owned endpoint over its full lifetime.
A raw Desktop control-socket proxy is not a supported transport.
These partial pieces do not authorize adding `codex-app` to the known or spawn-capable backend registries.

## Required bridge

Implementation can begin after Codex Desktop exposes one supported interface:

- a CLI wrapper for create, send, read, and archive host-tool operations;
- a documented JSON-RPC or MCP transport with stable framing; or
- a maintained helper that speaks the supported transport and returns plain JSON to a shell adapter.

The bridge must provide these semantics:

```text
create: task id, worktree request, initial instructions -> thread id, cwd, state
send: thread id, text -> accepted or rejected
read: thread id, bounded cursor -> transcript and live state
archive: thread id -> archived or stopped
return: thread appends state/<id>.status lifecycle lines
```

Once available, Firstmate should add a real `bin/backends/codex-app.sh`, persist `backend=codex-app` and `codex_app_thread_id=`, and route spawn, send, peek, watch, and cleanup through the shared dispatcher.

## Rollout

Ship and scout tasks come first.
Secondmate support remains out of scope until create, send, read, status return, and archive are proven through the normal backend dispatcher.
Until then, Codex App remains a blocked backend boundary with a verified host-tool capability record, not a selectable backend.

[`verification/runtime-backends.md`](verification/runtime-backends.md#codex-app-host-tools) owns the active Desktop host-tool smoke without exposing task-specific thread ids or local paths.
