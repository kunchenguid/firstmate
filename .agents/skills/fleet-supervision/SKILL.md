---
name: fleet-supervision
description: >-
  Agent-only procedure for live fleet supervision and notification handling.
  Load whenever work is under way or X mode requires monitoring, before starting or repairing supervision and at the start of every notification-handling turn.
user-invocable: false
metadata:
  internal: true
---

# fleet-supervision

This skill is the single owner of harness-neutral notification handling after the always-loaded one-cycle, no-blind-turn, and away-mode ownership boundaries in `AGENTS.md` section 8.
The supervision block emitted by `bin/fm-session-start.sh` is the sole owner of the active primary runtime's wait, continuation, and repair commands.

## Establish supervision

Whenever project work is under way, keep exactly one live supervision cycle in the shape emitted at session start.
Keep the same cycle for an X-only home that has no project work but still requires mention polling.
Do not substitute another runtime's wait shape, use shell `&`, or create a second cycle beside a healthy one.
For an ordinary actionable notification, follow the emitted ordinary-continuation path.
Use its repair action only when the live cycle is explicitly missing, failed, or unhealthy.
Never broadly kill monitoring processes, especially never use `pkill -f bin/fm-watch.sh`, because sibling Firstmate homes may match.
A forced repair uses only the home-scoped owner path in the emitted instructions.

Waiting on a healthy cycle is silent.
Empty polls, elapsed time, automatic retries, and unchanged observations are not captain-facing progress.
No turn ends blind while supervision is required, and turn-end guards are structural backstops rather than replacements for the live cycle.
While `state/.afk` exists, `/afk` owns supervision and this ordinary procedure must not start another cycle.

## Start every notification turn

At the start of every notification-handling turn, run `bin/fm-wake-drain.sh` before peeking, reading beyond the supplied reason line, steering, or starting new work.
Session start is the only exception because its one-shot digest already drained while locked or deliberately left the queue untouched in read-only mode.
Treat each `state/<id>.status` line as a notification event rather than current task truth.
Use `bin/fm-crew-state.sh <id>` before action depends on the worker's current state, especially before repeating an old decision, blocker, pause, or validation instruction.

A `paused:` event declares a bounded external wait expected to clear without firstmate action.
A `blocked:` event declares that firstmate action is needed.
Do not reclassify one as the other merely to silence monitoring.

## Handle notification types

For `signal:`, read the listed event lines first and reconcile current state only where the next action depends on it.
Translate a terminal event into the appropriate validation, report, landing, failure, or captain-decision procedure rather than trusting the status wording as proof.

For `stale:`, inspect only the recorded task endpoint and load `stuck-crewmate-recovery` for a stopped, looping, confused, or unresponsive ordinary worker.
A deep-inspection reason also requires current-state and validation-log inspection.
Load `secondmate-provisioning` instead when the affected direct report is a persistent secondmate.

For `check:`, act on the named authenticated result, including a merged PR, registered custom check, or X event.
On `x-mention <request_id>` and `x-mode-error ...`, load `fmx-respond` before handling the event.

For `heartbeat:`, review the whole fleet from the structured fleet view, reconcile suspicious tasks and PR state, update the backlog, and re-evaluate ready queued work.
Never describe an unchanged fleet as progress.

## Cross-cutting completion actions

When a notification reports a merged PR for a project cloned in this home, refresh that clone through the guarded fleet-sync path.
When X-linked work reaches a genuine milestone or terminal result, load `fmx-respond` and post the appropriate follow-up.
Before terminal cleanup, always post the final follow-up so the link clears even when earlier follow-ups used the available count.

Treat a persistent secondmate's idle endpoint as healthy.
Parent supervision relies on its routed status or referenced document rather than treating a quiet secondmate as stale or reconstructing its child tree.

Guard warnings never replace this procedure.
Queued notifications still drain before other work, waiting-too-long workers still use their recovery owner, and a local-copy tangle must be resolved without touching unlanded work.
The spawn assertion and generated ship instructions both continue to enforce an isolated disposable project worktree rather than firstmate's primary clone.
