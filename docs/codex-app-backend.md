# Codex App backend boundary

Codex App is not a selectable Firstmate runtime backend.
Codex Desktop host tools can create and supervise visible threads and those threads can write Firstmate status files when given an authorized path, but Firstmate has no supported shell-callable bridge to those host tools.
A manual thread ledger is not a backend.

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

## Operating a visible Desktop thread (Stand 2026-08-26)

Transferred here from the retired `firstmate-codexapp` skill; this document is now the single owner of the boundary and of the operating facts below.

Preflight, in this order:

1. Confirm the session runs inside Codex Desktop and the host tools are exposed: `create_thread`, `list_threads`, `read_thread`, `send_message_to_thread`, `archive`, and `set_thread_archived`.
2. Confirm the target repository is already saved as a Codex Desktop project.
   No host tool creates Codex App projects for an agent, so a human must add the project before a created thread reliably lands there.
3. Never create a projectless thread for repo work; ask for the project or use a normal Firstmate backend.
4. Decide whether this is a Firstmate-managed task (needs a task id, an isolated worktree or Desktop-owned cwd, a branch plan, and a writable `state/<id>.status` path) or a visible companion thread.

Create and send through the Desktop host tool, never a shell imitation.
Ask the worker to open with `pwd`, `git rev-parse --show-toplevel`, `git branch --show-current`, and `git log --oneline --max-count=3`.
Instruct it to work in the Codex-created current directory; never tell it to `cd` into the saved project checkout for edits, commits, pushes, or PR work.
Send follow-ups with `send_message_to_thread`, and treat anything the human types into the visible thread as authoritative, reconciled from `read_thread` rather than undone.

The status return channel is a verified requirement, not an assumption.
A Desktop-owned thread can append to Firstmate status files only when the prompt gives an absolute path and the Desktop permission context can write that checkout, so a Firstmate-managed task carries an explicit instruction:

```text
Append supervisor-visible status lines to <absolute-firstmate-home>/state/<task-id>.status.
Use only these prefixes for status changes: working:, needs-decision:, blocked:, paused:, done:, failed:.
Use paused: only for a deliberate known external wait that should be rechecked later, never for a blocker that needs firstmate to act.
Before doing substantive work, append "working: Codex Desktop thread started".
```

Treat the thread as supervised only after `read_thread` shows the attempted write AND the local `state/<task-id>.status` file carries the expected line.
Without that proof it stays a visible companion thread, never a complete backend.

Observe with `read_thread`; use `list_threads` only to find or recover a thread id.
Reconcile from concrete evidence - thread id and project, current Desktop-owned cwd, branch name, last meaningful thread state, latest status line, PR URL when one exists - and summarize the host-tool calls, the status result, and the archive result rather than copying transcripts.

Archive through `archive`, or `set_thread_archived(threadId=<id>, archived=true)` where that is the exposed name; archiving hides the thread from sidebar and project views without erasing the transcript or landed work.
For a companion thread, archive and report where the durable work landed; a real Firstmate task keeps its normal teardown path.

Failure signals: a missing Desktop project (ask for it, or use a normal backend); missing host tools (use a terminal backend, never shell simulation); an un-updated status file (unsupervised until proven); a worker editing the saved project checkout instead of its Desktop cwd (stop and decide about salvage); and a request for a production `codex-app` backend (answered by the acceptance contract and required bridge above, never by a local adapter).
