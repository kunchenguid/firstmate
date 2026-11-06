---
name: bearings
description: >-
  Generate a "pick up where I left off" fleet digest.
  Use when the captain invokes /bearings (plain, file, or lavish) or asks for a bearings report, morning brief, status report, catch-up, "where did I leave off", or "what's in the works".
  Also use on a contributions check wake, when filing work linked to an upstream issue, and on a procevent lavish wake whose source id is the bearings board's.
user-invocable: true
metadata:
  internal: true
---

# bearings

Generate a complete current snapshot from the fleet's current state, so the captain can resume in one read after a break, a night, or a context reset.
Plain `/bearings` returns only the concise four-section chat digest.
Only `/bearings file` writes the dated markdown report artifact and then returns the concise four-section chat digest linked to that report.
Only `/bearings lavish` builds the interactive fleet board beside that digest, through `bin/fm-bearings-board.sh` (its header owns every board mechanic and the fm-bearings-board.v1 payload contract).
A digest/build invocation is operationally read-only apart from observational remote-ledger cache refreshes, durable per-target reconcile-notify requests when the captured state needs them, plus the explicit per-mode artifacts: the dated report in file mode, and in lavish mode the board file plus the answer binding and source registration that `bin/fm-bearings-board.sh build` records through their own owners.
During that invocation it never tears down a task, merges a PR, dispatches new work, steers a worker, answers a decision, cleans up work, or mutates backlog or task state.
Board answers are acted on later under the normal authority rules; `references/lavish-board.md` owns the guarded routing at that time.

## Invocation modes

- Plain `/bearings` gathers a fresh bounded snapshot and renders the four-section chat digest without creating, deleting, reading, or replacing `data/status-report-<YYYY-MM-DD>.md`.
- `/bearings file` gathers a fresh bounded snapshot, replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch, and renders the four-section chat digest with a link or path to that report.
- `/bearings lavish` gathers a fresh bounded snapshot, rebuilds and arms the interactive fleet board, and renders the four-section chat digest with the board's URL inside it.
- Treat `file` and `lavish` only as explicit invocation options in the slash command.
- Do not treat natural-language requests such as "write a report", "save this", "persist it", "make a file", or "make a board" as file or lavish mode unless the invocation explicitly includes the standalone option.
- When the captain asks to include PRs, pass the snapshot command's live-PR opt-in.
- `/bearings include PRs` remains chat-only and makes the live-PR opt-in.
- `/bearings file include PRs` and `/bearings lavish include PRs` compose the same way.

## References

Load a reference with `cat` through Bash (for example `cat .agents/skills/bearings/references/digest.md`); shell output is not re-attached after compaction, so read each one at the moment it applies.

| Reference | Read it when |
| --- | --- |
| `references/digest.md` | Every `/bearings` invocation: the gather command, the secondmate reconcile request, composing the digest, and the file-mode report. |
| `references/chat-contract.md` | Every `/bearings` invocation, before writing the reply: the four sections, empty-states, rules, and report tone. |
| `references/lavish-board.md` | `/bearings lavish`, or a `procevent lavish` wake whose source id is the bearings board's: payload rules, board wake routing, the merge-click ruling. |
| `references/contributions.md` | A `check: contributions` wake, or filing work linked to an upstream issue. |

A contribution wake or linked-issue filing goes directly to `references/contributions.md`; the digest procedure applies to Bearings invocations only.

## Supervision discipline

During a digest/build invocation, this skill changes no fleet state beyond observational remote-ledger cache refreshes, durable local per-target reconcile-notify requests, explicit report or board artifacts, binding, and source registration.
Do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, clean up work, or mutate any other `state/` or `data/` file during that invocation.
If the state gathered for the digest suggests an action, name it in its section and leave it to the normal lifecycle and configured authority.
On a later board wake, this read-only invocation rule yields to the board-wake section of `references/lavish-board.md` and its guarded authority for captain-selected dispatches and merges.
