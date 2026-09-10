---
name: updatethecaptain
description: >-
  Keep the captain updated on every worker under way, in plain English, on a repeating ten-minute timer.
  Use when the captain invokes /updatethecaptain or asks to be kept posted on what the workers are doing.
  Every update opens with a dependency map of the whole body of work, then covers every worker with what it has finished, what it is doing now, what it still has to do, and how long it needs.
  The loop reports once immediately, repeats every ten minutes, picks up workers started since the last report, and ends by itself when no worker is left running or when the captain invokes /updatethecaptain-stop.
user-invocable: true
metadata:
  internal: true
---

# updatethecaptain

Keep the captain informed about every worker under way, on the captain's clock rather than on the fleet's.
Report once at invocation, then again every ten minutes, until the last worker stops or the captain stops the loop.

## What this skill owns, and what it does not

This skill owns exactly three contracts, stated in full below: the dependency map that opens every update, the four-part report, and the format for a worker's question.
Everything else already has an owner and is referenced here, never restated.

- `AGENTS.md` section 9 owns how to talk to the captain, including which words to use and which internal terms must never reach the captain.
  Write every line of every report through that contract.
- `AGENTS.md` section 8 owns supervision.
  This skill reports; it does not supervise.
  It never arms a second supervision cycle, never replaces wake handling, and never changes how any wake is handled.
- Reporting is read-only.
  While producing a report, do not steer a worker, answer a decision, merge, dispatch, or clean anything up.
  Those stay ordinary work under their own rules, decided outside this skill.

While this loop is running the captain has asked for the whole report on every tick, including a tick where nothing has changed.
That is a deliberate exception to section 8's rule that no-change updates are not captain-facing progress.
Equally, while this loop is running a tick is never collapsed into section 9's short acknowledgement, however quiet the ten minutes were, and the full update, map included, is always sent.
It is scoped to this loop and ends with it; it never changes what an unrequested wake surfaces.

## Procedure

1. If this session has not yet taken the helm, run `bin/fm-session-start.sh` once and read its digest before anything else.
   The timer rides the supervision cycle this home already runs, so a session that never started has nothing to keep the loop alive.

2. Build the list of workers under way from this home's own durable records with `FM_BEARINGS_GATES=200 FM_SNAPSHOT_SECONDMATE_QUEUED=200 FM_SNAPSHOT_SECONDMATE_CHILDREN=200 bin/fm-bearings-snapshot.sh --all-in-flight --all-landed`.
   That command is the single fleet-state source for this skill.
   Do not add a second reader, and do not reconstruct the fleet from conversation history.
   The same output carries what has landed and what is waiting together with the thing each waiting item waits on, which is what the dependency map is drawn from.
   The two flags and the raised bound are what the map needs, because the map claims to be the whole body of work while the default view caps how much landed work and how much waiting work it returns.
   Lift the waiting cap with `FM_BEARINGS_GATES` and never with `--all-queued`, because that flag also puts back the queued items whose bodies read as superseded, not required, or deferred, and this output carries no field that tells them apart from real waiting work.
   Raise the two secondmate bounds the same way, because they slice the queued and running work inside each registered secondmate home before it ever reaches this output, and unlike the other bounds they are not disclosed in the `omitted` array read below.
   Read the `omitted` array in that same output before drawing, and carry over only the entries saying that landed, running, or waiting work was capped or could not be read, as a plain line naming the work the captain cannot see.
   Every other entry there is machinery about surfaces the map never draws, such as task paths, watch and steer actions, or live pull request discovery, and none of it reaches the captain under `AGENTS.md` section 9.
   Where a worker's actual current step matters to part (b) or part (d) below, read it with `bin/fm-crew-state.sh <id>`, because a status line records a past event rather than current state.
   Part (d) below takes a worker's measured cost and remaining count from one place only, the last line that worker appended to its own `state/<id>.status` log in this home, and never from this output or from the reading above, neither of which carries that line whole; `bin/fm-brief.sh` owns what a worker must put on it.
   Include every worker in this home, including one only just dispatched and one waiting on something outside its control.

3. Report immediately, before arming the timer.
   The captain gets the first report out of the invocation itself and never waits ten minutes for it.

4. Arm the repeating timer with `bin/fm-captain-report-timer.sh arm`.
   Its header owns the exact commands, artifacts, and cadence bounds.

5. On each wake naming that timer, rebuild the list from step 2 and report again.
   Workers started since the last report join the list on this rebuild; nothing else is needed to pick them up.
   A worker that finished since the last report gets one closing line saying what it delivered, and then drops off the list.

6. End the loop when the rebuilt list is empty.
   Give the final report, tell the captain plainly that the updates are finished because nothing is running, and run `bin/fm-captain-report-timer.sh disarm`.
   `/updatethecaptain-stop` ends the loop the same way at any time.

The timer is durable rather than remembered, so a wake naming it can arrive in a later session that knows nothing about the loop.
Treat such a wake exactly as step 5: rebuild the list, report if anything is running, and end the loop through step 6 if nothing is.

## Why this timer and not something else

The ten-minute repeat is an authenticated check dispatched by the supervision cycle this home already runs, armed through `bin/fm-captain-report-timer.sh`.
It is not a shell background job, not a detached process, and not a second supervision cycle.
That matters for three reasons: the wake is durable, so a tick survives the captain sending messages in between and needs nothing from the captain to stay alive; the check's bytes are trust-bound, so nothing else can turn it into a different command; and it fires only while a supervision cycle is live, which is exactly the window in which there is worker progress to report.
The line lands on the first monitoring pass at or after ten minutes, never before it.

## The dependency map

Every update opens with the dependency map, above every worker's line.
The map and the four-part report are both in every update, and neither one is ever sent instead of the other.
When a worker's question is in the message, the question stays at the very top and the map follows it, still above every worker's line.

Draw a real graph rather than a list with corners on it.
Every piece of work is a node named by the job it is doing, and every dependency is an edge between two named nodes carrying the reason that edge exists.
The test is simple: if deleting every edge would leave the drawing saying the same thing, it is a list and has to be redrawn.

The map covers the whole body of work rather than only the part that is running:

- What has landed, so the captain can see what the rest is built on.
- What is running now.
- What is waiting, and the exact thing each waiting piece is waiting on.

Draw the edges between running jobs too, not only the edges into waiting work.
One of those edges is always present and is the one most often left out: landings are fast-forward only, so every landing forces each other branch to rebase and re-run its checks.
That is a real mutual dependency across everything running, and it belongs on the map as an edge over the running set rather than as a remark underneath it.

A job held back because the machine is full is not a dependency.
Show it as waiting and say that it is waiting on capacity.
A queue drawn as an edge tells the captain the chain is stuck when only the machine is busy.

## The four-part report

Report **every** worker on the list.
Never summarise the fleet in aggregate, never drop a worker for having nothing new, and never merge two workers into one entry.

Each worker's entry carries its running clock beside the name: how long that worker has been running, in minutes.
Take it from that task's durable spawn record, `state/<id>.meta`, whose `spawn_gen=` value begins with `s` followed by the epoch second at which that worker was dispatched, and report the minutes between that second and now.
That record's fields are owned by `bin/fm-spawn.sh`'s header, which is where both this field's shape and this skill's reliance on it are recorded.
The figure is elapsed wall time since the current dispatch, so it is readable from the record alone and does not depend on the worker still being alive.
Never read it from the file's modification time, because unrelated events rewrite that record after launch, and never from conversation memory or from an estimate.
A relaunch records a fresh `spawn_gen`, so the clock restarts with it.
When that same record carries a `control_relaunch_tx=` line, the worker was relaunched, and its entry says so and says that its clock runs from the relaunch rather than from the original dispatch.
Without that line the restarted clock hides the very overrun the clock exists to expose.
The clock is what exposes a worker forty minutes into a ten-minute job, which no description of the work can show.

Give each worker exactly these four parts, in this order, in plain English:

- **(a) What it has finished** - the work that is actually done, described as an outcome rather than as the steps taken.
- **(b) What it is working on now** - the one thing occupying it at this moment.
- **(c) What it still has to do** - what remains between now and the worker being finished.
- **(d) How long it needs** - a time estimate for finishing the whole job.

Three rules govern part (d):

- Always give an estimate, even when it is a guess.
  Say it is a rough guess when it is one, but never omit it and never replace it with "unclear" or "hard to say".
- Where the worker has reported what its slowest step measured and how many runs of it are left, the estimate is that measured cost multiplied by that remaining count, and the report says so in the captain's own words.
  What a worker measured is the only figure here that is not a guess, so name the step and its measured cost in the same sentence as the total, and let the arithmetic be visible rather than presenting the total alone.
  An estimate built any other way is a guess and is named as one, however confident it feels.
- When a job has already run past an estimate given in an earlier report, say that plainly in this report, then give the new estimate.
  Never quietly issue a fresh estimate as though the earlier one had not been given.

A worker that is waiting rather than working still gets all four parts: say what it is waiting for in part (b), and let part (d) reflect the wait.

## A worker's question for the captain

When a worker raises something that is the captain's to answer, put it at the very top of the message, above every status line, in this shape:

**Question from the `<name>` worker:**

followed by the question itself in plain English.
For a worker rebuilding the login page, that line reads `**Question from the login-page worker:**`.

- Name the worker by the job it is doing, never by an internal identifier.
- One question per message.
  If two workers are both waiting on the captain, ask the first and hold the rest for the next message.
- The question must stand alone.
  Someone reading only that message must be able to answer it without opening anything else first.
- Write out every link and file path in full, never a bare number or a shorthand reference.
- Ask it in the captain's own words under section 9, never by relaying the worker's wording, status line, or tool output.
- Do not answer a question that is the captain's to answer.
  `ask-user-authority` owns which decisions firstmate may settle, and that judgment is made before this skill puts anything in front of the captain.
