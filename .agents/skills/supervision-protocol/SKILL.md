---
name: supervision-protocol
description: >-
  Agent-only procedure for handling Firstmate supervision wakes and guard warnings.
  Use when handling a signal, stale, check, or heartbeat wake, when reviewing the whole fleet on a heartbeat, when a merged PR needs a clone refresh, and when a supervision guard warning must be resolved.
  AGENTS.md section 8 owns the always-loaded live-cycle, wake-drain, acknowledgement, and away-mode rules that apply with this skill unloaded.
user-invocable: false
metadata:
  internal: true
---

# supervision-protocol

`AGENTS.md` section 8 is the always-loaded owner of the rules that must hold before this skill loads: keep exactly one live supervision cycle whenever work is under way, never end a turn blind, drain the durable wake queue before acting, never acknowledge before handling, treat a status line as a wake event rather than current state, and honor the away-mode stub.
`docs/architecture.md`, `docs/turnend-guard.md`, the emitted session-start block, and script help own the mechanisms and harness-specific recipes.
This skill owns per-wake handling and the guard-warning contract.

## The live cycle

Use the emitted protocol for this primary harness; `bin/fm-supervision-instructions.sh` renders it at session start from `docs/supervision-protocols/`.
Do not substitute another harness's wait shape, use shell `&`, or create a second cycle when a healthy one already exists.
For every actionable wake, follow the ordinary-wake continuation in the emitted protocol; use its repair action only when the live cycle is missing or failed.
Relay may require that same live cycle with no fleet work at all.

## Draining before acting

At the start of every wake-handling turn, drain the durable wake queue before peeking, reading beyond the reason line, steering, or starting work.
Session start is the only exception, because its one-shot digest already presented the queue while locked, or deliberately left it untouched in lock-refused read-only mode.

Treat any `OPEN DECISIONS` section from the drain as actionable reconciliation input even when no wake record was queued.
Treat any `UNREAD STATUS` section as newly surfaced status that must be read this turn, because those lines are not re-printed after this presentation.
Treat any `RECORD DIVERGENCE` section as a contradiction between two records of one captain call, never as proof the captain ruled; load `captain-hold-lifecycle` and reconcile it in whichever direction the evidence supports.

After handling all emitted wakes and reconciling the OPEN DECISIONS and UNREAD STATUS sections, run the exact generation-bound `--ack-through` command printed as `WAKE_ACK_REQUIRED`.
Interruption before that acknowledgement deliberately leaves the work durable for idempotent re-handling.

## Handling each wake type

A status line is a wake event, not current state; use `bin/fm-crew-state.sh` when current state matters, especially before re-escalating an old decision, blocker, or pause.
A declared `paused:` event means a bounded external wait expected to clear on its own, while `blocked:` means firstmate action is needed.

1. For `signal:`, read the listed event lines first, then reconcile current state only where action depends on it.
2. For `stale:`, inspect the recorded endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive worker.
   A deep-inspection reason also requires current-state and validation-log inspection.
3. For `check:`, act on the named poll result, including merges, Relay events, process-to-event source results, and captain inbox notes.
   A handled inbox note is also acknowledged with `bin/fm-inbox.sh drain --ack <id>`, or it stays counted as still waiting for firstmate.
4. For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, and never report an unchanged fleet as progress.

When any wake reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When Relay-linked work reaches a milestone or terminal state, load `fmx-respond`; before terminal teardown, use its promised-final reconciliation when a typed public commitment exists, otherwise post the final completion follow-up so the link clears even if earlier follow-ups were spent.

## Quiet is not progress

A secondmate's idle endpoint is healthy, and parent supervision relies on its routed status rather than treating a quiet pane as stale.
Waiting on a healthy supervision cycle is silent; empty polls, elapsed time, and no-change updates are not captain-facing progress.

## Guard warnings

Guard warnings do not replace the contract.
Queued wakes must be presented before other action and acknowledged only after handling, stale liveness must be repaired through the emitted protocol, and the worktree-tangle warning must be resolved without touching unlanded work.
The spawn assertion and generated ship brief must both enforce that project work starts in an isolated disposable worktree, never the primary checkout.
Harness-aware turn-end guards are structural backstops, not permission to omit the live cycle.

Never broadly kill watchers, and especially never `pkill -f bin/fm-watch.sh`, because that can kill sibling firstmate homes.
A forced repair must use the home-scoped owner path emitted by supervision instructions.
