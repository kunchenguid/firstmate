# Recurring resume watchdog (`bin/fm-orchestrator.sh`)

`bin/fm-relaunch.sh` (`docs/relaunch-tool.md`) gives a captain a one-command way to resume a stalled firstmate session, but it registers a `launchd` job with no automatic trigger on purpose: nothing fires it but an explicit call.
That is correct for a tool whose only job is "resume when a human asks."
It is the wrong shape for the gap this tool closes: a shared account spend limit (or session usage window) can stall every in-flight worker AND the firstmate primary session at once, overnight, with no human awake to notice when it clears.
`bin/fm-orchestrator.sh` is a second, distinct `launchd` job that IS allowed a real recurring `StartInterval`, so the fleet can come back to life on its own once the limit clears - without ever becoming a blind timer that opens sessions regardless of need.

## Why this one is allowed to self-schedule and `fm-relaunch.sh` is not

`fm-relaunch.sh`'s safety property is "registered but never self-triggering" - useful for an on-demand human convenience, useless for an unattended overnight recovery.
This tool's safety property is different: every fire passes through two independent gates (below) before it is allowed to do anything, so a recurring timer can only ever open a session when a session is not already open AND there is real work for it to do.
An idle, fully-caught-up fleet with a live limit is indistinguishable from an idle, fully-caught-up fleet with no limit at all - the gates make both cases a no-op, so the timer never manufactures work or opens a session "just because it fired."

## The two gates, in order

`bin/fm-orchestrator.sh check` (the `launchd` job's program) runs both gates every time it fires, in order, and only proceeds past both:

1. **Liveness** - `fm_orch_session_alive` shells out to `bin/fm-lock.sh status` (the same session-lock mechanism `AGENTS.md` section 3 uses, not a second liveness signal) and checks for `held by live`. A live session means do nothing.
2. **Worth resuming** - `fm_orch_pending_work` is true only if at least one of:
   - the durable wake queue (`state/.wake-queue`) is non-empty;
   - a recorded ship/scout task (`state/*.meta`, excluding `kind=secondmate`) has a non-terminal last status (its `state/<id>.status` tail is not `done:`/`failed:`) and its backend endpoint is not `alive` per `fm_backend_agent_alive` (`bin/fm-backend.sh`) - a stalled/orphaned worker;
   - `data/backlog.md` has a `## Queued` item with no `blocked-by:` marker on its line.

   No pending work means do nothing, even with no live session.

Only "no live session" AND "pending work" together reach the fire step: `bin/fm-relaunch.sh run`.
That existing tool owns the actual resume mechanics (terminal, trust dialog, kickoff message) - this tool never reimplements them.

## Cooldown

After a fire attempt, `bin/fm-orchestrator.sh` writes the current epoch to `state/.orchestrator-cooldown` and refuses to fire again until `FM_ORCHESTRATOR_COOLDOWN_SECS` (default 1800) has elapsed, even if `check` runs again sooner.
The cooldown is recorded even when `bin/fm-relaunch.sh run` itself fails - a failed resume still counts against the cooldown, and `check` then propagates that failure's exit code rather than swallowing it - so a persistently broken resume cannot turn into a tight fire-loop either.
This exists because a relaunched session can itself immediately hit the same account limit and exit fast; without a cooldown, a recurring timer firing every `StartInterval` would retry in a tight loop.
The cooldown is a simple timestamp file, not a lock - convergent and idempotent the same way `fm-relaunch.sh install` converges on repeated calls.

## Never touches billing

This tool only waits for a limit to clear and then resumes normal work, exactly like a human checking back later would.
It never calls any billing/usage-credit surface and never attempts to raise or inspect a spend limit itself.

## Label and interval

The job label is `dev.firstmate.orchestrator` for the default (unoverridden) primary home, distinctly suffixed for a non-default `FM_HOME` (a secondmate home), using the same SHA-256 slug scheme as `fm-relaunch.sh` - see that tool's docs for the exact mechanism. `FM_ORCHESTRATOR_INTERVAL_SECS` (default 1800) controls the `StartInterval` written at `install` time; `launchd`'s practical polling granularity makes values much below that not meaningfully more responsive.

## Commands

See `bin/fm-orchestrator.sh --help` for the exact subcommand list; that header is the mechanics' one owner.
`status` reports whether the job is installed and loaded, its configured interval, and the last fire/cooldown state.
