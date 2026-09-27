---
name: supervision-protocol
description: >-
  Load whenever work is under way, on every wake-handling turn, and when Relay needs a live cycle with no fleet work.
user-invocable: false
metadata:
  internal: true
---

# supervision-protocol

`AGENTS.md` section 8 keeps the safety boundaries, the away-mode stub, and this load trigger.
This skill owns the runbook.
`docs/architecture.md`, `docs/turnend-guard.md`, the emitted session-start block, and script help own mechanisms and harness-specific recipes.

## One live cycle

Whenever work is under way, keep exactly one live supervision cycle using the emitted protocol for this primary harness.
Relay may require that same live cycle with no fleet work.
Do not substitute another harness's wait shape, use shell `&`, or create a second cycle when a healthy one already exists.
For every actionable wake, follow the ordinary-wake continuation in the emitted protocol; use its repair action only when the live cycle is missing or failed.
No turn ends blind while work is under way, including turns described as holding or waiting.

## Drain, then ack

At the start of every wake-handling turn, drain the durable wake queue before peeking, reading beyond the reason line, steering, or starting work.
Session start is the only exception because its one-shot digest already presented the queue while locked or deliberately left it untouched in lock-refused read-only mode.
Treat any `OPEN DECISIONS` section from the drain as actionable reconciliation input even when no wake record was queued.
Treat any `UNREAD STATUS` section as newly surfaced status that must be read this turn.
Treat any `RECORD DIVERGENCE` section as a contradiction between two records of one captain call, never as proof the captain ruled; load `captain-hold-lifecycle` and reconcile it.
After handling all emitted wakes and reconciling those sections, run the exact generation-bound `--ack-through` command printed as `WAKE_ACK_REQUIRED`.
A status line is a wake event, not current state; use `bin/fm-crew-state.sh` when current state matters.
A declared `paused:` event means a bounded external wait expected to clear on its own, while `blocked:` means firstmate action is needed.

## Actionable wakes

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery`; Jev stale-escalation triage is default-on unless `config/jev-wake-triage` is off.
3. For `check:`, act on the named poll result; a handled inbox note is also acknowledged with `bin/fm-inbox.sh drain --ack <id>`.
   When the note needs a durable answer the submitter can read, publish it with `bin/fm-inbox.sh reply <id>` (the script header owns the reply contract) rather than leaving the answer only in this transcript.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, and never report an unchanged fleet as progress.

Load `bearings` on a contributions check wake or when filing work linked to an upstream issue.
When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`.

## Silence, repair, guards

A secondmate's idle endpoint is healthy.
Waiting on a healthy supervision cycle is silent; empty polls, elapsed time, and no-change updates are not captain-facing progress.
Never broadly kill watchers, especially never `pkill -f bin/fm-watch.sh`, because that can kill sibling firstmate homes.
A forced repair must use the home-scoped owner path emitted by supervision instructions.

Guard warnings do not replace the contract.
Queued wakes must be presented before other action and acknowledged only after handling, stale liveness must be repaired through the emitted protocol, and the worktree-tangle warning must be resolved without touching unlanded work.
The spawn assertion and generated ship brief must both enforce that project work starts in an isolated disposable worktree, never the primary checkout.

Away and quiet mode stay owned by the `AGENTS.md` section 8 stub plus `/afk` and `/quiet`.
For the full `stuck-crewmate-recovery` trigger, including a live worker claiming its no-mistakes pipeline is dead, unreachable, or timed out, follow `AGENTS.md` section 8.
