---
name: bounded-child-agents
description: Agent-only contract for an ordinary Herdr-backed ship or scout worker to create and manage up to three same-tab child agent panes with explicit disjoint path ownership. Use only when the worker is already processing its task and wants bounded parallel help inside the same writable working copy.
user-invocable: false
metadata:
  internal: true
---

# Bounded child agents

Use this skill only from the live parent pane of an ordinary Herdr-backed ship or scout worker.
This is an optional concurrency tool for genuinely independent subproblems, not a default delegation layer.
Do not use it from FirstMate, a second mate, a child agent, an unsupported runtime backend, or a primary project copy.
Do not use it when the paths or design decisions overlap, when one result semantically depends on another, or when shared mutable state makes concurrent edits unsafe.

`bin/fm-child.sh` is the single lifecycle owner.
Never use raw Herdr commands for child creation, inspection, stopping, or cleanup.
The helper binds the caller to one exact parent task, pane, workspace, tab, registered worker, and isolated working copy before acting.

## Prepare one child

Choose a short unique name using letters, digits, dots, underscores, or dashes.
Write the child's task instructions to a regular private file outside the repository, preferably below `/tmp/fm-<parent-task>/`.
Keep the instructions self-contained, narrow, and explicit about acceptance criteria and checks.
Do not put coordination files, child reports, or task instructions in the repository.

Assign every writable path explicitly relative to the repository root.
Assign the narrowest practical file or directory paths.
Paths for concurrent children must be disjoint, including ancestor and descendant overlap.
Do not assign `.git`, `.no-mistakes`, symlinks, glob patterns, or ambiguous traversal paths.
Use ASCII ownership paths on a case-insensitive working copy because the helper refuses Unicode specifications it cannot compare with exact portable filesystem semantics.
The parent retains every unassigned path.

Create the child from anywhere inside the parent's recorded working copy:

```sh
/path/to/firstmate/bin/fm-child.sh create <name> \
  --instructions /tmp/fm-<parent-task>/<name>.md \
  --path path/owned/by/child \
  [--path another/disjoint/path]
```

The helper allows at most three concurrently live direct children.
The returned pane stays in the parent's recorded Herdr tab and uses the same working copy.
The child inherits the parent's recorded harness, model, and effort profile through the existing harness launch rules.
The helper does not offer a backend, provider, model, effort, worktree, tab, or window override.

## Child authority

A child may edit only its assigned paths in the shared working copy.
The child's edits are concurrent shared edits, not an isolated branch or worktree.
The parent must avoid editing a child's owned paths until that child has stopped.

The parent is the sole owner of Git mutations, branch state, commits, validation runs, push, publication, and PR operations.
Children may use the generated read-only Git guard for inspection.
Children must not stage, commit, switch, rebase, merge, reset, restore, clean, push, invoke no-mistakes, or perform PR operations.
Children must not call FirstMate lifecycle or status helpers, address the captain, create public status updates, or recursively delegate.
Children must not bypass the generated command guards.
A child explicitly assigned to test this lifecycle may invoke a generated guarded interface solely to prove it refuses, but may never bypass the guard or perform the prohibited action.

The complete generated contract stays in the private `launch.md`, and the verified Herdr composer path submits only one short operational pointer telling the child to read that absolute file.
The generated startup instructions and private environment provide the exact path ownership, report path, and completion command.
The child writes a self-contained report listing changed paths, checks, results, and parent review needs.
The child then invokes its exact generated completion command and stops work.
No child completion is authority to ship, publish, or expand the accepted parent task.
A scout parent's child remains knowledge-only and inherits every scout publication restriction.

## Supervise and reconcile

List all child records and current live states:

```sh
/path/to/firstmate/bin/fm-child.sh list
```

Inspect one child's owned paths, completion result, report location, and bounded recent pane output:

```sh
/path/to/firstmate/bin/fm-child.sh inspect <name>
```

If a child pane disappears, `list` and `inspect` report it as dead while preserving its private record and any shared edits.
Inspect the assigned paths and private report before deciding whether the parent should finish, revert, or leave that work.
Do not silently recreate a dead child under a new name or overwrite its path ownership.

Stop one exact child pane without touching siblings or shared edits:

```sh
/path/to/firstmate/bin/fm-child.sh stop <name>
```

Stopping is idempotent for an already absent exact pane.
The helper refuses an ambiguous pane, another tab, another parent, malformed private records, and primary-pane targeting.

## Parent completion boundary

Inspect every completed child report and review every assigned path before accepting the work.
Stop every child pane after its report is complete.
Run the readiness assertion before the parent stages, commits, switches branch state, invokes no-mistakes, performs final validation, pushes, or opens a PR:

```sh
/path/to/firstmate/bin/fm-child.sh ready
```

Readiness succeeds only when every recorded child has a non-empty private report, a completion result, and no live pane.
It never validates the code or replace parent review.
The parent owns integration, conflict resolution, tests, documentation, exact-head validation, and final delivery.

The parent may remove stopped private child records after reports have been consumed:

```sh
/path/to/firstmate/bin/fm-child.sh cleanup
```

Normal FirstMate cleanup also quiesces exact recorded child panes before safety inspection and removes their private records before returning the parent's working copy.
A refused cleanup preserves the shared working copy and reports.
Child cleanup never resets, restores, or discards shared edits.
