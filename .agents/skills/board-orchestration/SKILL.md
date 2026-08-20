---
name: board-orchestration
description: >-
  Agent-only policy for bridging a configured project board and firstmate's existing backlog.
  Load on a session-start or heartbeat cycle when a project board is configured, before importing or decomposing a board item, before placing existing work on a board, before reflecting a dispatch, PR, blocker, or merge onto a board, and whenever a card's status disagrees with firstmate's own records.
user-invocable: false
metadata:
  internal: true
---

# Project board orchestration

Firstmate is the orchestrator, `data/backlog.md` remains the one execution queue and the source of truth, and the board is how that queue is shown to the captain.
Chat, not the board, is where the captain steers the work.
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

The bridge may read the board's issues and cards, import new actionable items into the existing backlog, break a big-picture container into linked child cards, place work firstmate already holds onto the board, move a card as firstmate's own execution events happen, attach the working PR to the originating issue, record blockers on that issue, and report a card whose status firstmate did not write.

It may not become a second execution system.
Do not build or ask for webhook infrastructure, another daemon, another database, a second queue, continuous real-time synchronization, a separate board service, or a new orchestration layer.
Reading on the cycles firstmate already has is the whole mechanism, and it is what the captain chose knowing the latency cost.

## When the read happens

The poll runs on cycles firstmate already has, and it runs on its own rather than because this skill was remembered.

- **Session start** reconciles the board as part of the digest's own network checks and prints each actionable line as `BOARD_POLL: <line>`.
  Act on those lines; do not run `poll` again for that board in the same turn, because the read has already happened and repeating it spends the board's request budget twice.
  A board already reconciled prints nothing at all, and a home with no board configured never reads one.
- **Heartbeat wakes** are where firstmate runs `bin/fm-board.sh poll` itself, as part of the fleet review AGENTS.md section 8 already requires.

Add no wake source, no watcher check, no timer, no daemon, and no background process for it.
Never poll from a lock-refused read-only session, because that session is not authorized to mutate anything; the session start's own board reconciliation is skipped there for the same reason.

Be honest about the resulting freshness when the captain asks.
The board is as current as the last cycle, never live.
An idle fleet produces no heartbeats, so an item filed while everything is idle is picked up at the next session start rather than within minutes.
A poll that could not read the board reports an `error` line and reconciles nothing; never present that to the captain as the board being in sync.

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

### Board-sourced work is captain-gated

Work that arrives from a board is not authorized to run merely because it arrived.
Create the backlog item **held**, with `tasks-axi hold <id> --reason "imported from the <project> board, awaiting the captain's go" --kind captain`, report the new item to the captain, and dispatch it only on their explicit word.
Use that existing hold mechanism; do not invent a second gating concept.

The reason is worth keeping in mind so this is not later simplified away: the backlog is firstmate's own record, but a board is an outside surface, so anything with write access to that board could otherwise place work straight into an autonomous execution queue.
This gate is not weakened by `yolo`, which is authority over routine gates inside work already authorized, while this is about whether the work is authorized at all.

Be precise about what the gate covers.
It gates **dispatch** of board-sourced work.
It does not gate board reads, card creation, card movement, or any of the reflection commands, and it applies to every route by which board content becomes work, including the children of a decomposition: creating child cards unattended is exactly what the captain asked for, running them is not.
This skill says nothing about work that did not come from a board; that is each home's own business and is recorded in its own captain preferences.

## Status mapping

Todo means filed and not cleared to run, In Progress means a worker actively owns it, and Done means merged and verified.
A configured optional `queued` column sits between the first two and means firstmate has been cleared to launch that work; a home that did not configure it has no such column and nothing changes.
A blocked item stays visible in the column it is already in, with the blocker recorded on its issue through `bin/fm-board.sh note <task-id> "Blocked: ..."`.
A column outside these is reported by its real name and never driven; leave the card there rather than forcing it into one of the others.

## Breaking down a big-picture item

A `decompose <project> <parent-issue-url>` line is a container the captain filed: an issue whose children are the real work, and which no worker can ship as it stands.
Deciding what it breaks down into is judgement, which is why the script never invents children and this skill owns the procedure.
Nothing here happens in a home whose board configures no big-picture columns, because no card is ever classified as a container there.

1. Read the container issue in full, and any linked context it names.
2. Break it into concrete work items that can each be independently implemented and validated - not a restatement of the container in three parts. If it genuinely cannot be broken down, or the split needs a product decision, say so to the captain rather than inventing pieces.
3. Resolve delivery mode and yolo for each piece exactly as AGENTS.md section 7 requires, at intake, on that project's standing posture.
4. For each piece, run `bin/fm-board.sh child-add <project> <parent-issue-url> <title> <body> <task-id>`. One command per piece creates the issue as a native GitHub sub-issue of the container, cards it in Todo, and records its link. A `child-partial` line names the step that did not land: re-run the same command, which converges on the issue it already filed rather than creating a second one.
5. Create each backlog item, **held**, exactly as the captain gate above requires. Creating the child cards is unattended; running them is not.
6. Run `bin/fm-board.sh decomposed <project> <parent-issue-url>`. Until that lands the container keeps being offered, which is what finishes an interrupted breakdown; once it lands the container is never offered again.
7. Post the breakdown as a comment on the parent issue, so the captain has the reasoning where the work lives, then report it to them.

Use GitHub's own sub-issue relationship and nothing else: the board already surfaces `Parent issue` and `Sub-issues progress`, so invent no parallel taxonomy, label scheme, or naming convention to express it.

The container's own card then follows its children with no further action - any child in progress moves it to the big-picture In Progress column, all children done moves it to big-picture Done - and it is silent while it already shows what firstmate recorded.

## Putting work firstmate already holds on the board

`bin/fm-board.sh place <project> <task-id> <title> [<body>]` is the inverse of `import`: it files the issue, cards it in Todo, and records the link, after which every event below works on it with no special casing.
Use it for a task that started in the backlog and belongs on that roadmap.

Whether a task belongs on a board is an editorial call the script never makes, and project alone does not settle it.
Firstmate's own work belongs on a captain's product roadmap when it serves that product's delivery and stays off it when it does not.
When the change lands somewhere other than the repository the card's issue is filed in, pass `--lands-in <owner/name>` so the roadmap never implies a diff is somewhere it is not.

There is deliberately no bulk placement, and never build one: existing work goes onto a board one item at a time, chosen deliberately.

## The events that move a card

`mark`, `pr`, `note`, and `ack` apply only to a task that holds a link record - one imported from a board or placed on one.
A task with no board link is never passed to any of them; they refuse it outright rather than degrading, and that refusal is a sign the wrong task id was used.

Firstmate's own execution events are what move a card, and the ones that matter most happen on their own:

- **Dispatch and merge need no command.** `bin/fm-spawn.sh` places the card if the project has a board and the task has none, then marks it in progress; `bin/fm-pr-check.sh` attaches the PR to its originating issue; `bin/fm-pr-merge.sh` closes the card after a merge that actually landed. A task with no board, and every task in a home with no board configured, is untouched by all three.
- **Cleared to launch:** `bin/fm-board.sh mark <task-id> queued` when the captain's go releases a held item and the board configures that column.
- **Blocked:** `bin/fm-board.sh note <task-id> "Blocked: <what is needed>"`, alongside the ordinary captain escalation when the blocker needs the captain.
- Run `mark` by hand only to correct a card, for instance after a divergence or when work leaves the cleared set.

Prefer a better card to a better command: when a task deserves a human title on the roadmap, `place` it yourself before dispatching, and the dispatch will then only move the card it finds.

Every one of these degrades to a stale board instead of blocking delivery, and each reports plainly whether the board took the change.
A board that did not take a change is never a reason to delay a dispatch, a PR report, a merge, or cleanup, and it is not a captain escalation on its own.
`poll` retries an outstanding card move and an outstanding PR attachment on the next cycle, reporting each as `synced` or `stale`; a blocker note is deliberately not retried, so re-run it if it matters and the captain escalation still stands either way.

## Filing is intent; status is firstmate's report

This is the single most important rule here, and it has two halves that must not be collapsed into one.

**Filing work on the board is the captain's intent.**
A new labelled card is them adding work, and intake above is unchanged - including that it stays captain-gated before anything runs.

**The status columns are firstmate's own report of its records.**
Firstmate writes them outward from the backlog; a card's column never tells firstmate what to do.
So a `divergence` line - a card showing a status firstmate did not write - means change nothing, dispatch nothing, stop nothing, and tell the captain in chat.
The adapter has already declined to reconcile it in either direction, and firstmate must not do by hand what the adapter deliberately refused.
Raise a given divergence once and do not repeat it every cycle while it stands unresolved; when the captain decides, `bin/fm-board.sh mark <task-id> <state>` is how the card is put right.

Treat an unexplained appearance in a configured `queued` column as security-relevant, because under this model it can only mean something outside firstmate wrote to that board.
It never launches a crew.

Two consequences follow, and both are reports rather than actions:

- A card moved backwards out of In Progress, or moved to Done while work is unfinished, is something to tell the captain plainly - what firstmate has running, and what has not landed - not a reason to stop a worker on its own. Stop work only on the captain's word, then through `bin/fm-control.sh <task-id> interrupt` and `exit` exactly as any other stop.
- A `cancelled` line, a card that left the board entirely while firstmate was still executing it, is reported the same way; once the captain decides, update the backlog and run `bin/fm-board.sh ack <task-id>` so it is not reported again.

Neither ever authorizes discarding unlanded work: hard rule 3 stands unchanged, so preserve the branch, report what is on it, and get an explicit captain instruction before anything is discarded.

This is a real security property of the design and the captain accepted it knowingly: write access to a configured board is enough to file work into intake, and never enough to start it.

- A `foreign` line means a card on the board being polled carries an issue that another configured board already owns.
  That is a configuration mistake, not an instruction, so the adapter names the owning project and touches neither the card nor the link.
  Tell the captain which board owns the issue and let them decide which board should carry it; never re-home it by hand.
- An `error` line means the board could not be read, or answered so implausibly that the adapter refused to act on it.
  Treat it as a board that is temporarily unavailable, let the next cycle reconcile, and never read it as work being withdrawn.
  A cycle that reported an error reconciled nothing, so never tell the captain the board is in sync on the strength of it.
- A `truncated` line means the board filled the read's card ceiling, so a card past it was never seen.
  Everything that read did report still stands, but no withdrawal is reported from that board on this cycle, because absence cannot be told apart from the ceiling.
  Re-run `poll` for that board with a higher `--limit`, and if it stays truncated tell the captain the board has outgrown the default read; the same ceiling applies to the card lookup `mark` needs, so a card sitting past it cannot be moved either.
- A scope edit to a card's own text mid-flight follows the lifecycle rule AGENTS.md section 7 already owns: route it to follow-up work unless it completely invalidates the work being validated.
  A board edit does not create a second, competing rule for that.

## Reporting to the captain

The board, the card, and the issue are the captain's own nouns and need no translation; everything else still follows AGENTS.md section 9.
Report what the board now shows and what it changed about the work, not that a poll ran or that a record was updated.
An unchanged board is not progress and is not worth a message.

## Ownership

The home whose linkage record holds an issue is the home that updates that issue and its card.
Board configuration is local to that home and is not inherited by secondmates, so never ask a secondmate or a crewmate to update a board on firstmate's behalf.
