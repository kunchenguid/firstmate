---
name: firstmate-codexapp
description: >-
  Agent-only playbook for running visible Codex Desktop tasks through Firstmate's host-managed lifecycle without pretending they are a selectable shell spawn backend.
  Use before creating, reading, steering, waiting for, archiving, debugging, or reviewing a Codex Desktop task for Firstmate work, and before responding to requests to make Codex Desktop native to Firstmate.
user-invocable: false
metadata:
  internal: true
---

# firstmate-codexapp

## Overview

Use this playbook when a Firstmate primary is itself running in Codex Desktop
and needs visible Desktop ship or scout tasks. The supported shape is:

- Desktop host tools own task create/send/read/wait/archive;
- `bin/fm-codex-app-task.sh` registers the exact task and reconciles state;
- `backend=codex-app-host` identifies that ownership split in task metadata.

This does not make `codex-app` a selectable `FM_BACKEND` or
`fm-spawn.sh --backend` value. Read `docs/codex-app-backend.md`; it owns the
acceptance contract and standalone-shell boundary.

## Preflight

1. Confirm the current session is Codex Desktop and the stable Desktop thread
   marker is present.
2. Confirm the host exposes project listing plus task create, read, wait, send,
   and archive tools. Search exact tool names rather than guessing aliases.
3. Start Firstmate once in a tracked PTY and prove the thread-bound session
   lease is live. Stay read-only if the lock is held elsewhere.
4. List saved Desktop projects. For a repository task, select the exact saved
   project and verify whether it is a Git repository.
5. Record the exactly five model-routing factors with `bin/fm-task-model-route.sh` and preserve its result before creation.
6. Select `small`, `normal`, or `research` as the session envelope and record it at registration.
7. Decide the Firstmate task id, kind, isolation strategy, and status path before creation.
Ship work gets one writer and scouts are read-only.

## Cross-project Entry

A globally discovered skill is readable context, not an additional writable
Desktop project.
Codex Desktop derives a repository task's writable scope from the project that
created the task, so a task in another repository must never test Unix mode
bits and assume the installed Firstmate project is writable.

Run `bin/fm-desktop-entry.sh` from the installed Firstmate code project before
session start.
It compares Git common-directory identity without writing either repository.

- `mode=direct` means the current task is already in the Firstmate repository
  or one of its Desktop worktrees.
  Run the reported `firstmate_code/bin/fm-session-start.sh` once with `FM_HOME`
  set to the reported `session_home`.
- `mode=coordinator` means the current task belongs to another repository.
  Do not run session start there and do not use built-in subagents for any
  project work.
  List Desktop projects, select the exact saved Git project whose path matches
  `firstmate_code`, and create one visible Firstmate coordinator using a
  Desktop worktree.
  Pass `startingState=working-tree` only when the router reports that value;
  otherwise use the project's default branch state.

The coordinator instruction must include the complete captain request, the
source Desktop thread id, the exact `source_project`, and these requirements:

1. Report `pwd`, Git top level, branch, status, and the last three commits.
2. Read the complete Firstmate instructions and required internal skills.
3. Run the coordinator worktree's own entry router and require `mode=direct`.
4. Start that worktree's session once in a tracked PTY with `FM_HOME` equal to
   its actual top level, and keep the lease live.
5. Use the Desktop host lifecycle below for all target project work.
6. Return the final project outcome to the source task without asking the
   captain to copy a continuation prompt.

Creation is asynchronous.
Wait for a real coordinator `threadId` and `hostId`, then use Desktop wait/read
for its result.
The source repository task is only a relay while the coordinator is live: it
must not edit the project, register fake Firstmate state, or perform work through
ordinary subagents.
Keep the coordinator task unarchived while its lease or retained fleet records
are still required.

If the exact repository is not saved but its exact local checkout path is
known, open that path with Codex Desktop through the normal app-open mechanism
and list projects again. This registration step belongs to the primary, not the
captain. Do not silently target a similarly named checkout. A saved parent
project may be used only when the task will operate in an already-provisioned
exact Firstmate worktree inside that parent and the prompt names that path.
Ask the captain only when the exact path is unknown or Desktop refuses the
open/permission operation; otherwise continue automatically.

## Create And Register

Use the Desktop host tool for creation, never a shell imitation. For a saved
Git project, default to a Desktop worktree. Use `startingState=working-tree`
only when the captain explicitly needs the selected checkout's current
uncommitted state applied; otherwise use the default branch state.

The first instruction must make the worker report:

```text
pwd
git rev-parse --show-toplevel
git branch --show-current
git status --short
git log --oneline --max-count=3
```

For a Desktop worktree, instruct the worker to use its created current
directory. Never tell it to edit the saved project checkout. For an explicitly
pre-provisioned Firstmate worktree under a saved parent project, name only that
exact worktree as writable scope.

Creation is asynchronous. Wait until the host returns a real `threadId` and
`hostId`; a setup-only client id is not a task endpoint. Read the task once to
obtain its actual cwd, then register it while the Firstmate lock is live:

```sh
bin/fm-codex-app-task.sh register <id> \
  --thread <thread-id> --host <host-id> \
  --project <project-checkout> --worktree <actual-worktree> \
  --kind <kind> --model <model> --effort <effort> \
  --route-record <absolute-routing-record> \
  --session-envelope <small|normal|research> \
  --mode <direct-PR|local-only> --yolo <on|off>
```

Registration must precede substantive supervision. Verify:

- one exact `state/<id>.meta` binding;
- `backend=codex-app-host`;
- the exact thread id, host id, project, and worktree;
- the project and worktree share the registered Git common-directory identity;
- the exact `direct-PR` or `local-only` mode and actual project `yolo` posture;
- the exact route record, envelope, and session generation;
- `unsupported` rather than invented values for unavailable cost, context, compaction, and output telemetry;
- a writable `state/<id>.status` return channel;
- `bin/fm-crew-state.sh <id>` reports the registered current state.

## Status And Current State

`state/<id>.status` is an append-only event/wake log. It is not current state.
`state/<id>.codex-app-current` is the exact current-state record read by
`fm-crew-state.sh`.

If the worker's Desktop permission context can write the Firstmate status path,
include this instruction:

```text
Append supervisor-visible status lines to <absolute-firstmate-home>/state/<task-id>.status.
Use only: working:, needs-decision:, blocked:, paused:, done:, failed:.
Use paused: only for a deliberate external wait, never for a blocker needing Firstmate action.
```

Direct worker status writes are useful evidence but not required for host wake:
the primary must use the Desktop wait/read tools. After reading a meaningful
transition, reconcile only what the host actually reported:

```sh
bin/fm-codex-app-task.sh reconcile <id> \
  --thread <observed-thread-id> --host <observed-host-id> \
  --generation <observed-generation> --epoch <observed-observation-epoch> \
  --state <state> --detail '<bounded host evidence>' \
  --event '<valid-prefix>: <event detail>'
```

Pass the thread, host, generation, and observation epoch attached to the observed result so a delayed result from a stopped or superseded endpoint cannot mutate the current task.
Omit `--event` for a repeated poll with no new event.
Never derive the new current state from the status log tail.

## Session Envelopes

The three envelopes are policy classes, not fabricated token counters.
`small` favors a short bounded task, `normal` is the default implementation class, and `research` allows a longer investigation or broad migration.
Codex Desktop does not currently expose reliable per-task cost, remaining-context, compaction-count, or output-token metrics to Firstmate.
Record those four signals as `unsupported` and use qualitative soft warnings based only on observed task complexity and elapsed work.
Never claim an exact threshold, hard enforcement, or savings from an unavailable signal.

When the selected envelope reaches a hard boundary by explicit worker or supervisor judgment, stage only intended changes and run:

```sh
bin/fm-codex-app-task.sh hard-stop <id> \
  --reason '<bounded reason>' \
  --handoff <absolute-path-outside-the-desktop-worktree>
```

The command creates a staged-only checkpoint commit, preserves unstaged and untracked artifacts, writes the structured external handoff, and pauses the old endpoint.
The primary then creates one fresh Desktop task targeting the exact retained worktree and registers that endpoint against the checkpoint:

```sh
bin/fm-codex-app-task.sh resume <id> \
  --thread <new-thread-id> --host <new-host-id> \
  --checkpoint <exact-sha> --handoff <same-absolute-handoff>
```

Resume refuses a reused thread, a different worktree head, a different handoff, or a task that is not paused at the recorded boundary.

## Observe, Send, And Reconcile

Use the host wait tool for bounded supervision and the read tool for transcript
truth. Use project/task listing only for recovery, not instead of reading the
task. Keep the exact returned `hostId` with the task id.

Use the Desktop send tool for follow-ups. If the captain writes directly in the
visible task, that message is authoritative; read and reconcile it rather than
trying to undo it from the primary.

Record only bounded evidence:

- task id plus host id;
- project and actual cwd;
- branch and dirty-state summary;
- current task state and last meaningful event;
- validation result and landed commit/PR only when they exist.

Do not copy long transcripts into Firstmate docs or status files. Translate
worker mechanics through `AGENTS.md` section 9 in captain-facing updates.

## Archive

Codex Desktop archive removes its app-owned worktree.
Reconcile the terminal state, then run Firstmate's archive preflight before calling the host archive tool:

```sh
bin/fm-codex-app-task.sh archive-preflight <id> \
  --report <absolute-firstmate-home>/data/<id>/report.md
```

The preflight authorizes a completed scout only when its non-empty canonical task report is retained at `data/<id>/report.md` outside the Desktop worktree.
It refuses ship tasks because archive would destroy an uncommitted or otherwise unlanded implementation artifact.
Leave a refused terminal ship task idle and unarchived until its result is independently landed or the captain explicitly authorizes discard.
Never treat archive as harmless sidebar cleanup.

After a successful scout preflight, archive the exact task with the Desktop
host tool. Generic `fm-teardown.sh` still refuses host-owned tasks and
preserves their Firstmate records; do not attempt manual cleanup.

## Failure Signals

- Missing exact project/worktree: stop; do not guess another checkout.
- Missing host tool: do not simulate it with transcript or ledger files.
- Only a setup client id returned: wait for a real task identity.
- Task cwd differs from registered worktree: stop and reconcile before writes.
- Firstmate lock absent or held elsewhere: remain read-only.
- Status file unwritable: rely on host wait/read plus primary reconciliation;
  do not claim the worker wrote an event it could not write.
- Malformed or mismatched meta/current record: treat state as unknown.
- Archive preflight refusal: retain the task/worktree; do not call the Desktop
  archive tool or substitute manual cleanup.
- Request for standalone `fm-spawn --backend codex-app`: read
  `docs/codex-app-backend.md`; the host lifecycle does not authorize inventing
  a shell adapter.
