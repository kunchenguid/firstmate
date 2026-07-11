---
name: firstmate-codexapp
description: >-
  Agent-only playbook for coordinating visible Codex Desktop threads alongside Firstmate without pretending they are a selectable shell backend.
  Use before creating, reading, steering, archiving, debugging, or reviewing a Codex App visible thread for Firstmate work, and before responding to requests to make Codex App native to Firstmate.
user-invocable: false
metadata:
  internal: true
---

# firstmate-codexapp

## Overview

Use this playbook when Firstmate work needs a visible Codex Desktop thread.
The current supported shape is Desktop host-tool choreography plus an explicit status-file return-channel check, not a `codex-app` value in `FM_BACKEND`.

## Boundary

Codex Desktop visible threads are companion host-tool workflows, not a selectable Firstmate backend.
Read `docs/codex-app-backend.md` when it exists in this checkout; that document owns the acceptance contract, bridge requirement, status-return requirement, and staged rollout.

If local helper scripts exist for Codex App work, use only helpers explicitly provided by the operator or maintained by Firstmate.
For helpers outside `bin/`, inspect the source or header before running `--help`.

## Preflight

1. Confirm this session is running inside Codex Desktop and that the host tools are exposed.
   Search exact names when needed: `create_thread`, `list_threads`, `read_thread`, `send_message_to_thread`, `archive`, and `set_thread_archived`.
2. Confirm the target repository is already saved as a Codex Desktop project.
   No host tool currently creates Codex App projects for an agent, so the human must add the project in Desktop before a created thread can reliably land there.
3. Do not create projectless threads for repo work.
   If the project is absent, stop and ask for the project to be added or use a normal Firstmate backend instead.
4. Decide whether this is a real Firstmate-managed task or a visible companion thread.
   A real task needs a task id, an isolated worktree or Desktop-owned cwd, a branch plan, and a writable `state/<id>.status` path.

## Create And Send

When creating a visible thread, use the Desktop host tool, not shell imitation.
Target the saved project and ask the worker to start by reporting:

```text
pwd
git rev-parse --show-toplevel
git branch --show-current
git log --oneline --max-count=3
```

For writable repo work, instruct the worker to use the Codex-created current directory.
Do not tell it to `cd` into the saved project checkout for edits, commits, no-mistakes, pushes, or PR work.

When sending follow-up instructions, use `send_message_to_thread`.
If the user types directly into the visible thread, treat that as authoritative and reconcile from `read_thread` instead of undoing it.

## Status Return Channel

A Desktop-owned Codex thread can append to Firstmate status files only when the prompt gives an absolute path and the Desktop permission context can write that checkout.
That makes status writes a verified return-channel requirement, not a fact to assume.

For a Firstmate-managed task, include an explicit status instruction:

```text
Append supervisor-visible status lines to <absolute-firstmate-home>/state/<task-id>.status.
Use only these prefixes for status changes: working:, needs-decision:, blocked:, paused:, done:, failed:.
Use paused: only for a deliberate known external wait that should be rechecked later, never for a blocker that needs firstmate to act.
Before doing substantive work, append "working: Codex Desktop thread started".
```

Verify the return channel before treating the thread as supervised:

- `read_thread` shows the worker attempted the status write.
- The local `state/<task-id>.status` file contains the expected line.
- If available, the transcript includes a file-change entry for that status file.

If the thread cannot write the status file, keep it as a visible companion thread only.
Do not claim it is a complete Firstmate backend.

## Observe And Reconcile

Use `read_thread` for thread truth.
Use `list_threads` only to find or recover a visible thread id, not as a replacement for reading the transcript.

For Firstmate reconciliation, prefer concrete evidence:

- thread id and project
- current Desktop-owned cwd
- branch name
- last meaningful thread state
- latest status file line
- PR URL when one exists

Avoid repeating long transcripts into Firstmate docs or PR bodies.
Summarize only the host-tool calls, the status-file result, and the archive result.

## Archive

Archive through the Desktop host tool: `archive` when that is the exposed primitive, or `set_thread_archived(threadId=<id>, archived=true)` when that is the exposed tool name.
Archiving can remove the thread from normal sidebar/project views, but it should not erase the transcript or landed work.

For companion threads, archive the thread and report where the durable work landed.
If there is a real Firstmate task record, leave teardown decisions to the normal Firstmate task flow instead of this skill.

## Failure Signals

- Missing Desktop project: ask the human to add the target project in Codex Desktop, or use a normal backend.
- Missing host tools: do not simulate them with shell files; use a terminal backend instead.
- Status file not updated: treat the thread as unsupervised until the return channel is proven.
- Worker editing the saved project checkout instead of its Desktop cwd: stop and decide whether to salvage the branch before continuing.
- Production `codex-app` backend request: read `docs/codex-app-backend.md` and do not invent a local adapter.
