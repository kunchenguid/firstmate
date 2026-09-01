---
name: workstreams
description: >-
  Build and arm the captain-facing workstream board: backlog tasks grouped into workstreams against intended outcomes, dependency edges drawn, live agents pinned on the tasks they are working, and captain decisions answerable from the board.
  Use when the captain invokes /workstreams or asks for the workstream board, and also load this skill's board-wake handling when a procevent lavish wake's source id matches the canonical source id of the stable workstream board path.
  A sibling of /bearings, not an extension of it: bearings is the whole-fleet digest, this board is the grouped per-outcome view of the main home's backlog.
user-invocable: true
metadata:
  internal: true
---

# workstreams

Build the interactive workstream board so the captain sees every task grouped by intended outcome, what each live agent is doing right now, and answers pending decisions directly on the board.
`bin/fm-workstream-board.sh` owns every board mechanic - the stable board path, fm-workstream-board.v1 payload validation, template injection, Lavish session establishment, the answer binding, and arm-if-absent registration - so the per-invocation work is composing the payload and running its `build`.
The board is a sibling of the bearings board and shares its build mechanics through `bin/fm-board-lib.sh`; it never replaces the four-section `/bearings` digest.

## What it does

1. **Gather live grouped state with one deterministic command.**
   Run `snapshot=$(bin/fm-workstream-snapshot.sh --json)` at invocation time and read that compact output.
   It is the single bounded, deterministic source for this board; do not create a second fleet-state reader, status-tail interpretation, or ad-hoc `gh`/`gh-axi` query.
   The command's header owns the workstream-derivation convention (umbrella tasks with `kind: program`, id prefixes, blocked-by edges, the unassigned lane), the task-state precedence, the divergence rules, and the bounds with their `omitted[]` disclosure.
   The projection is always local-only and main-home only.

2. **Compose the fm-workstream-board.v1 payload from that snapshot.**
   The gather step is deterministic; your judgment is scoped to captain-facing copy - workstream outcome lines, task row wording, agent chip labels, and decision cards.
   Board rules:
   - A waiting item's `key` is the captain-held TASK ID from the snapshot's `decisions[]`, so the bound keyed-answer intake closes or releases that task at answer time; never invent a key that names no captain-held task.
   - Compose exactly one waiting item per captain-held task id; when one task carries multiple questions, consolidate them into that item (`captain-hold-lifecycle` owns this rule).
   - Set `close: "release"` when the answer should free a captain-gated WORK item to proceed; question-shaped items omit it.
   - Pass the snapshot's workstreams through, including the explicit `unassigned` lane, and keep each lane's `more` count as the payload's `more_tasks`.
   - Carry each lane's whole-lane state tallies through as its `counts` object (`done`, `review`, `active`, `held`, `decision`, `queued`), so the progress bar reports the lane rather than the rows the cap left visible.
   - Pass the snapshot's `edges` and `divergence` rows through; the divergence callout is how the captain learns the backlog and the live fleet disagree.
   - Map each agent's state to a chip tone: `working` for a working agent, `decision` for one waiting on the captain, `paused` otherwise.

3. **Run `build` once after composing the payload.**
   Its serve-first sequence publishes the board, establishes or resumes its Lavish session, and only then binds and arms the polling source; use the session URL it prints in the chat reply.
   Never run `lavish-axi poll` for the board yourself: the armed source's supervised runner owns the blocking poll.

4. **Reply in chat with the board URL and a one-line summary** of what needs the captain (decisions waiting, divergence callouts), following `AGENTS.md` section 9.

## Starting or reshaping a workstream

The backlog has no workstream field; the grouping is the umbrella-task convention the snapshot header owns.
When the captain asks to group work, create one umbrella task per workstream (`tasks-axi add <slug> "<workstream name>" --kind program`) with the intended-outcome line as its body, give member tasks the umbrella's id prefix or a real `blocked-by` edge, and let the next `/workstreams` run pick the grouping up.
Record real dependencies only; the graph draws what the backlog actually says.

## Handling a board wake

A board answer arrives as an ordinary `procevent lavish <source-id> <sequence>` check wake.
Identify it by comparing the wake source id with `bin/fm-procevent-lavish.sh source-id "$(bin/fm-workstream-board.sh path)"`, then load `process-event-sources` and follow its contract for the result read, adapter classification, and the handled acknowledgement.
Decision answers need no routing from you: the runner feeds the board's binding into `bin/fm-captain-hold.sh`'s one keyed-answer intake, which closes or releases each answered captain-held task at answer time.
Reconcile any `skipped:` key yourself with a direct `answer`, and when the captain's answer is "later", record it as a deferral with `tasks-axi hold <id> ... --until <date>` instead of a closure.
After handling, rebuild the board from a fresh snapshot so answered items leave the waiting rail, and echo every action taken in chat so the board and chat never diverge silently.

## Supervision discipline

A board build changes no fleet state beyond the board artifact, its answer binding, and its source registration.
During the invocation, do not tear down a task, merge a PR, dispatch queued work, steer a worker, answer a queued decision, or mutate any other `state/` or `data/` file.
If the snapshot suggests an action - a divergence to repair, a stale worker - name it in chat and leave it to the normal lifecycle and configured authority.
On a later board wake, this read-only rule yields to "Handling a board wake" and the normal authority rules.
