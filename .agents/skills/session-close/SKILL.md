---
name: session-close
description: >-
  End a firstmate session deliberately, with an explicit handoff when work is under way.
  Use when the captain says they are closing or ending the session, shutting down for the day, or asks what must happen before this session can be closed.
  Distinct from /afk, which keeps supervision live during an absence; closing ends this session's supervision until the next session starts.
user-invocable: true
metadata:
  internal: true
---

# session-close

Closing is the mirror of session start: `AGENTS.md` sections 3 and 5 make a restart a non-event, but only when the durable records match reality at the moment this session ends.
This skill owns the decision of which close applies and the handoff steps that make the second case safe.

## Choose the branch first

Check whether work is under way in this home: any `state/<id>.meta` for an ordinary task exists, an X-mode relay poll is armed, or a captain decision from this session is still unanswered.
A `kind=secondmate` meta record is a permanent registration of a direct report rather than work under way, so an idle registered secondmate never by itself forces the handoff branch.
No work under way means branch 1; anything under way means branch 2.
Away mode is a separate check that applies on either branch: read "Away mode at close" below before treating the session as closable.

## Branch 1 - fleet empty: straight close

No handoff is needed.
If this session produced durable knowledge that so far exists only in this conversation, run the `/stow` sweep first so it lands on disk.
Confirm to the captain that nothing is under way and the session can close cleanly, then stop.
A numeric lock owner needs no action from anyone on this branch.
The codex-thread case in the lock section below applies on this branch too: on a Codex-hosted session, ask the captain to actually close the old Codex window, and tell them the next session may ask them to confirm that window is closed.
An active `state/.afk` also applies on this branch: an empty fleet does not make an away daemon self-clearing, so handle it through the away-mode section below before closing.

## Branch 2 - work under way: handoff before close

Work under way must be handed to the durable records, because after this session closes nothing responds until the next session opens.
Complete every step below before treating the session as closable.

1. **Reconcile the durable records with reality.**
   Update the backlog for every in-flight and queued item so its recorded state matches what the work is actually doing (`AGENTS.md` section 10).
   An unanswered decision that came from an investigation or a visual review is already owned by `.agents/skills/decision-hold-lifecycle/SKILL.md` and registered through `bin/fm-decision-hold.sh`; leave it under that owner rather than filing it again here.
   File every other unanswered captain decision from a main-side thread as its own captain-gated work item with `tasks-axi hold <id> --reason "<reason>" --kind captain`, so it survives as a tracked item rather than only as chat history.
   Relay any finished result or finding that has not yet reached the captain, in the outcome language of `AGENTS.md` section 9.
2. **Run the `/stow` sweep.**
   It owns routing conversation-only knowledge to disk; do not re-derive its routing here.
3. **Leave running work and its monitoring alone.**
   Workers continue in their own endpoints and their delivery pipelines keep running; never stop, tear down, or discard work because the session is ending, and never kill the monitoring (`AGENTS.md` sections 1 and 8).
   Events the monitoring captures wait in the durable wake queue, and the next session start reads every task's records directly, so a lapsed monitoring chain loses signal freshness but not the work.
   This session's own away daemon is not covered by that rule, because it supervises a pane that is about to disappear; the away-mode section below is where it is wound down.
4. **Give the captain a closing summary.**
   State what is still under way and its current state (use `bin/fm-crew-state.sh <id>` where the live state matters), what awaits their decision, and that while no session is open the work keeps running but nothing responds to its reports or questions.
   State where it resumes: opening the next session replays the queued events and reconciles all running work automatically, and `/bearings` gives a readable catch-up at any point after that.

Do not invent a separate handoff file or checkpoint document; the backlog, task metadata, status history, wake queue, and `data/` briefs and reports are already the complete handoff surface that session start consumes.

## Session lock at close

There is deliberately no manual release step and no unconditional clear command; never hand-delete `state/.lock` (`bin/fm-lock.sh` header owns the mechanics).
A numeric owner becomes provably stale when this session's harness process exits, and the next session start proves that and atomically reclaims the lock on its own.
A codex-thread owner cannot be proven dead from the process table: ask the captain to actually close the old Codex window, and tell them the next session may ask them to confirm that window is closed before it can take over.

## Away mode at close

Check for an active `state/.afk` before closing: its presence means an away daemon is supervising this session, and closing leaves it pointed at a pane that is about to disappear.
That daemon does not recover on its own from a gone target: it backs off and retries against it indefinitely, and it keeps holding the identity-backed daemon lock, so the next session's `/afk` re-entry reports the daemon as already running instead of starting a fresh one.
Exit away mode through `bin/fm-afk-launch.sh stop`, which keeps `state/.afk` present through the daemon's shutdown flush and clears it last.
If the captain wants away mode left set anyway, say in the closing summary that it stays set and name `bin/fm-afk-launch.sh stop` as the command that ends it.
Winding the away daemon down ends this session's own supervision, which is exactly what closing means; it never stops, tears down, or unmonitors a worker's own running work.

## Close versus /afk

`/afk` keeps this session and its supervision live while the captain is away: the away daemon handles routine events and escalates what matters.
Closing ends this session's supervision entirely until the next session starts: work continues, but decisions and reports wait unanswered.
If the captain is stepping away and wants the fleet actively supervised meanwhile, offer `/afk` instead of closing; close only when they genuinely want this session ended.
