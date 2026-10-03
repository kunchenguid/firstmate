---
name: session-cache
description: Agent-only procedure for keeping worker sessions cheap to continue. Load on a `check: session-cost` wake, and before steering a ship or scout whose fleet-view Session Cost row advises `fresh`. Relevant only when config/session-cache exists.
user-invocable: false
metadata:
  internal: true
---

# Session cache cost

Every turn of a worker re-reads its whole context, so a turn costs more as the context grows.
A turn after the prompt cache expired also re-writes that whole context at full price.
A fresh worker in the same local copy, started from a short written handoff note, avoids both.
Context size is the larger cost; idle time only matters for a large context.

`bin/fm-session-cost.sh` owns the measurement, the thresholds, the config format, and the once-per-crossing notice.
This skill owns what firstmate does with a notice.

## On a notice

1. Read `bin/fm-session-cost.sh show <task>` and `bin/fm-crew-state.sh <task>`.
   Act on current numbers, not the wake text.
2. Act only at a phase boundary: the worker's turn has ended and it waits, for example `paused`, `parked`, `blocked`, a pre-validation `done`, or a PR that still needs worker turns.
   If it is mid-stage, do nothing now; re-run step 1 at its next status event.
3. Leave the worker as it is when no further worker turns are expected (a green PR that only waits for a merge), when the captain is working in its pane, or when the remaining work is one short step.
4. Get a handoff note at `data/<task>/handoff.md`: branch, PR URL, what is done, what is left, every open decision or blocker key, and the exact next step.
   - Cache `warm` (reason `size`): ask the worker through `bin/fm-send.sh` to write that note and stop; one turn on a warm cache is cheap.
   - Cache `cold` (reason `cold`): write the note yourself from the brief, the status log, the PR, and the no-mistakes run, so the cold context is never woken.
5. Run `bin/fm-control.sh <task> relaunch --note-file data/<task>/handoff.md`.
   It keeps the local copy, the branch, and the recorded harness, model, and effort.
6. If relaunch refuses, leave the worker running, note the refusal in the backlog item, and continue normal supervision; do not retry in a loop.

This is routine supervision: do not report notices or relaunches to the captain.
