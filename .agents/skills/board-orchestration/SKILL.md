---
name: board-orchestration
description: >-
  Agent-only policy for bridging a configured project board and firstmate's existing backlog.
  Load on a session-start or heartbeat cycle when a project board is configured, before importing a board item, before reflecting a dispatch, PR, blocker, or merge onto a board, and whenever a board edit disagrees with the backlog.
user-invocable: false
metadata:
  internal: true
---

# Project board orchestration

Firstmate is the orchestrator, the board is the captain's visible statement of intent, and `data/backlog.md` remains the one execution queue.
This skill owns the policy; [`bin/fm-board.sh`](../../../bin/fm-board.sh)'s header owns every command, flag, record, and failure mode, and [`docs/configuration.md`](../../../docs/configuration.md) owns the local `config/boards` file.

## The bridge is inert until a board is configured

A home with no `config/boards` file, or an empty one, does none of this.
It performs zero board reads and zero board writes, invokes no GitHub CLI for a board, and behaves exactly as it did before the bridge existed, the same way Relay stays inert until its own opt-in.
Do not run a board command, mention a board to the captain, or offer board behavior in such a home.

Deleting or emptying that file is the whole off switch and leaves no residue, because the bridge creates no poll, watcher check, cadence file, daemon, or background process to unwind.
Say plainly what disabling does not undo: backlog items already imported stay, issues already created stay, comments already posted stay posted, and cards already moved stay where they were moved.
Never offer to reverse those as part of turning the bridge off; that is separate work and needs the captain's word.

The bridge is also strictly per project.
Only a project with its own stanza in `config/boards` is ever mapped to a board, so work on any other project never reaches any board, and a home holding several boards resolves an event against that project's stanza alone.
Never place, comment on, or move work for a project the captain did not configure a board for.

## Scope

The bridge may read the board's issues and cards, import new actionable items into the existing backlog, move a card to In Progress when a worker is dispatched, attach the working PR to the originating issue, record blockers on that issue, move the card to Done after a confirmed merge, and reconcile the backlog to cancellations and scope changes the captain makes on the board.

It may not become a second execution system.
Do not build or ask for webhook infrastructure, another daemon, another database, a second queue, continuous real-time synchronization, a separate board service, or a new orchestration layer.
Reading on the cycles firstmate already has is the whole mechanism, and it is what the captain chose knowing the latency cost.

## When the read happens

Run `bin/fm-board.sh poll` on cycles firstmate already runs: once after the session-start digest, and on heartbeat wakes as part of the fleet review that AGENTS.md section 8 already requires.
Add no wake source, no watcher check, and no timer for it.
Never poll from a lock-refused read-only session, because that session is not authorized to mutate anything.

Be honest about the resulting latency when the captain asks.
An idle fleet produces no heartbeats, so an item filed while everything is idle is picked up at the next session start rather than within minutes.

## Intake

`poll` prints a `new` line only for a card that is a real issue, sits in the configured Todo column, and carries the configured trigger.
The label is the authoritative trigger; the optional mention and assignee triggers are additional and off unless the captain configured them.
Everything else on the board is deliberately invisible to intake, including draft cards, pull requests, and untagged issues.

Import each `new` line exactly once, in this order:

1. Confirm no backlog item already names that issue URL.
2. Create the ordinary backlog item, recording the issue URL in its note, and resolve delivery mode and yolo at intake exactly as AGENTS.md section 7 requires.
3. Immediately run `bin/fm-board.sh import <project> <issue-url> <task-id>` so the linkage is durable before the turn ends.

Step 3 is what makes import idempotent, so it is never deferred to a later turn.
The record lives with the durable fleet records rather than the task's runtime state, so it outlives cleanup: an issue whose task shipped and was torn down months ago is still linked and can never be imported a second time.
Step 1 exists only for the narrow window where a turn died between steps 2 and 3.
Re-running `import` for an already-linked issue is a successful no-op, and an attempt to point a linked issue at a different task is refused rather than silently rebound; investigate a refusal instead of working around it.

## Status mapping

Todo means queued or awaiting dispatch, In Progress means a worker actively owns it, and Done means merged and verified.
There is no fourth state.
A blocked item stays visible in the column it is already in, with the blocker recorded on its issue through `bin/fm-board.sh note <task-id> "Blocked: ..."`.
A column the captain added that firstmate does not drive is recorded as the board's own and reported with its real name; leave the card there rather than forcing it into one of the three.

## The events that move a card

`mark`, `pr`, `note`, and `ack` apply only to a task imported from a board, which is the only kind of task that holds a link record.
An ordinary locally-created task has no board link, so it is never passed to any of them; they refuse it outright rather than degrading, and that refusal is a sign the wrong task id was used.

Only firstmate's own execution events move a card, and each one is a single command run at the moment the event actually happens:

- A worker is dispatched onto a board-imported task: `bin/fm-board.sh mark <task-id> in-progress`.
- The worker reports its PR: `bin/fm-board.sh pr <task-id> <pr-url>`, which attaches the PR to the originating issue.
- Work is blocked: `bin/fm-board.sh note <task-id> "Blocked: <what is needed>"`, alongside the ordinary captain escalation when the blocker needs the captain.
- A merge is confirmed: `bin/fm-board.sh mark <task-id> done`.

For a board-imported task, every one of these degrades to a stale board instead of blocking delivery, and each reports plainly whether the board took the change.
A board that did not take a change is never a reason to delay a dispatch, a PR report, a merge, or cleanup, and it is not a captain escalation on its own.
`poll` retries an outstanding card move and an outstanding PR attachment on the next cycle, reporting each as `synced` or `stale`; a blocker note is deliberately not retried, so re-run it if it matters and the captain escalation still stands either way.

## The board owns intent

This is the single most important rule here.
An `instruction` line means the captain edited, reprioritized, or moved a card, and that is an instruction to reconcile the backlog to the board.
The backlog is execution bookkeeping and never outranks the captain's visible intent.
Never move a card back to what firstmate expected, and never treat a captain's edit as drift to correct; a sync that corrects a captain's board edit is a defect, not a safeguard.

- A card moved backwards out of In Progress, or a `cancelled` line reporting a card that left the board entirely, means stop the worker.
  Stop it through `bin/fm-control.sh <task-id> interrupt` and then `exit`, exactly as any other stop, then update the backlog and run `bin/fm-board.sh ack <task-id>` so the withdrawal is not reported again.
  This never authorizes discarding unlanded work: hard rule 3 stands unchanged, so preserve the branch, report what is on it, and get an explicit captain instruction before anything is discarded.
- A card the captain moved to Done while work is unfinished is the captain closing the item.
  Stop the worker the same way, preserve the branch, and tell the captain plainly what had not landed.
- A `foreign` line means a card on the board being polled carries an issue that another configured board already owns.
  That is a configuration mistake, not an instruction, so the adapter names the owning project and touches neither the card nor the link.
  Tell the captain which board owns the issue and let them decide which board should carry it; never re-home it by hand.
- An `error` line means the board could not be read, or answered so implausibly that the adapter refused to act on it.
  Treat it as a board that is temporarily unavailable, let the next cycle reconcile, and never read it as work being withdrawn.
- A `truncated` line means the board filled the read's card ceiling, so a card past it was never seen.
  Everything that read did report still stands, but no withdrawal is reported from that board on this cycle, because absence cannot be told apart from the ceiling.
  Re-run `poll` for that board with a higher `--limit`, and if it stays truncated tell the captain the board has outgrown the default read; the same ceiling applies to the card lookup `mark` needs, so a card sitting past it cannot be moved either.
- A scope edit on a card mid-flight follows the lifecycle rule AGENTS.md section 7 already owns: route it to follow-up work unless it completely invalidates the work being validated.
  A board edit does not create a second, competing rule for that.

## Reporting to the captain

The board, the card, and the issue are the captain's own nouns and need no translation; everything else still follows AGENTS.md section 9.
Report what the board now shows and what it changed about the work, not that a poll ran or that a record was updated.
An unchanged board is not progress and is not worth a message.

## Ownership

The home whose linkage record holds an issue is the home that updates that issue and its card.
Board configuration is local to that home and is not inherited by secondmates, so never ask a secondmate or a crewmate to update a board on firstmate's behalf.
