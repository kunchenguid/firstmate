---
name: executor-dispatch
description: >-
  Agent-only judgment for the executor task kind: a cheap one-shot headless worker that closes one scoped GitHub issue and opens a pull request that firstmate reviews by the real diff.
  Load when classifying a deliverable as executor at intake, before writing the issue it will close, before launching more than one executor, on an executor-ready, executor-failed, or executor-stale check wake, and before merging, bouncing, or escalating an executor's pull request.
user-invocable: false
metadata:
  internal: true
---

# executor-dispatch

This skill is the single owner of the judgment around the executor task kind.
The scripts own the mechanics and their headers own the exact flags: `bin/fm-brief.sh --executor`, `bin/fm-spawn.sh --executor`, `bin/fm-executor-poll.sh`, `bin/fm-executor-lib.sh`, `bin/fm-crew-state.sh`, `bin/fm-control.sh`, `bin/fm-pr-check.sh`, `bin/fm-review-diff.sh`, `bin/fm-pr-merge.sh`, and `bin/fm-teardown.sh`.
Nothing here restates them.

## When to choose executor over ship

Ship stays the default.
Executor is an explicit intake choice, recorded in the backlog item note together with the resolved verify command, and it fits only when every condition holds:

- The work is already fully specifiable as one GitHub issue with observable acceptance criteria and an exact verify command.
- The work is bounded: one issue, one pull request, no design left to make.
- The work touches no danger zone that needs a frontier model's judgment while implementing.
- A dispatch rule for executor work exists in `config/crew-dispatch.json`.

When any condition fails, dispatch a ship task, or a scout when the intake and authority contract in `AGENTS.md` section 7 warrants separate research.

## Off-machine boundary

A profile whose runtime sends code to a third-party API may run only against projects the captain has explicitly permitted for it.
The captain records that permission in the dispatch rule's own `when` or `why` text.
Never infer it from a project name, path, or visibility, never route work to such a profile without having been told it is permitted, and ask the captain once when unsure.

## The issue scoping contract

The issue is the executor's whole specification, so it must remove all inference.
Write it through `gh-axi` against the project repository with `-R <owner>/<name>`, and verify every file pointer in the local clone before writing it.
Show the captain the issue draft as part of intake unless the captain already authorized that exact scope.

Required fields:

- An imperative title.
- Context: what exists today and why the change is wanted.
- A checklist of observable acceptance criteria.
- Verified file pointers.
- How to verify: one exact command.
- Constraints: `preserve`, `do not touch`, and `match` items.
- Danger zones for review to aim at, chosen from concurrency, validation and edge cases, error paths, ordering and retry, build wiring, security or data integrity, and GUI teardown and modal dialogs.
- Out of scope: what the executor must leave alone.

Right-size it: an issue that needs more than one pull request, more than one verify command, or a decision the executor cannot make from the text is two issues or a ship task.

## Intake mechanics

File the backlog item with `bin/fm-tasks-axi.sh add <id> "<title>" --kind executor`, then scaffold with `bin/fm-brief.sh <id> <repo> --executor --issue <N> --verify "<command>"`, resolving the project's CI-equivalent gate yourself; the scaffold never guesses it.
Resolve the profile through `config/crew-dispatch.json` and `quota-array-dispatch` exactly as for a crewmate, then spawn with `bin/fm-spawn.sh <id> <project-dir> --executor --issue <N> --yolo <on|off> --harness <adapter> [--model <name>] [--effort <level>]`.
The spawn refuses an adapter without a verified headless form; `bin/fm-spawn.sh --help` names the accepted set and the raw-command escape hatch.

## Canary rule

When more than one executor is about to launch, launch exactly one first.
After roughly ninety seconds read its endpoint with `bin/fm-peek.sh <id>` and require positive signs of work: a tool call, a file read, a test run.
A live process is not evidence.
An empty log, or an authentication, model-not-found, or usage-limit line, means a launch-environment failure that would take the whole wave down: abort, investigate, and do not retry blind.
Launch the rest only after the canary shows real work.

## Handling the wakes

The three executor outcomes arrive as `check:` wakes carrying the poll's line; `bin/fm-crew-state.sh <id>` reads the same facts on demand.

- `executor-ready: PR <url> <draft|ready>`: run `bin/fm-pr-check.sh <id> <url>` with the exact URL from the line, then review under the rubric below.
- `executor-failed: ...`: read the endpoint's final output with `bin/fm-peek.sh <id>`, then choose between re-scoping the issue and relaunching, relaunching on a stronger profile with `bin/fm-control.sh <id> relaunch --harness <adapter> [--model <name>] [--effort <level>]`, or the captain.
- `executor-stale: running <N>m past the bound`: inspect the endpoint, then stop it with `bin/fm-control.sh <id> exit` or let it run when the output shows real progress.

An executor reads no steering inbox; changing what it does means re-scoping the issue and relaunching.

## Review rubric

Firstmate is the last reviewer, so the review reads the real diff through `bin/fm-review-diff.sh <id>`, never the description alone.
Green means checks ran and passed; when the repository has no checks, run the issue's verify command yourself in the task worktree.
Confirm by reading that every acceptance criterion is met, every constraint respected, no test weakened, and no scope added.
Exercise each danger zone rather than reading past it.
A draft is a non-merge until reviewed.

Verdicts:

- MERGE through `bin/fm-pr-merge.sh` under the task's `yolo` posture or the captain's explicit word.
- BOUNCE by closing the pull request with a precise, actionable comment through `gh-axi`, keeping the remote branch, re-scoping the issue, and relaunching or re-dispatching.
- ESCALATE to the captain only for a genuine intent question, and for a second failure of the same issue.

Uncertain equals bounce.
Never hand-fix an executor's pull request; re-scope and re-run instead.
Never relay the executor's own summary to the captain as evidence.

## Cleanup

After landing or a final bounce, `bin/fm-teardown.sh <id>` as for any ship task; the pushed branch counts as landed work whether the pull request merged or was bounced with its branch kept.
