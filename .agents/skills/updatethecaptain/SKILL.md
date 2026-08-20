---
name: updatethecaptain
description: >-
  Keep the captain updated on every worker under way, in plain English, on a repeating ten-minute timer.
  Use when the captain invokes /updatethecaptain or asks to be kept posted on what the workers are doing.
  Every report covers every worker with what it has finished, what it is doing now, what it still has to do, and how long it needs.
  The loop reports once immediately, repeats every ten minutes, picks up workers started since the last report, and ends by itself when no worker is left running or when the captain invokes /updatethecaptain-stop.
user-invocable: true
metadata:
  internal: true
---

# updatethecaptain

Keep the captain informed about every worker under way, on the captain's clock rather than on the fleet's.
Report once at invocation, then again every ten minutes, until the last worker stops or the captain stops the loop.

## What this skill owns, and what it does not

This skill owns exactly two contracts, stated in full below: the four-part report, and the format for a worker's question.
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
It is scoped to this loop and ends with it; it never changes what an unrequested wake surfaces.

## Procedure

1. If this session has not yet taken the helm, run `bin/fm-session-start.sh` once and read its digest before anything else.
   The timer rides the supervision cycle this home already runs, so a session that never started has nothing to keep the loop alive.

2. Build the list of workers under way from this home's own durable records with `bin/fm-bearings-snapshot.sh --all-in-flight`.
   That command is the single fleet-state source for this skill.
   Do not add a second reader, and do not reconstruct the fleet from conversation history.
   Where a worker's actual current step matters to part (b) or part (d) below, read it with `bin/fm-crew-state.sh <id>`, because a status line records a past event rather than current state.
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

## The four-part report

Report **every** worker on the list.
Never summarise the fleet in aggregate, never drop a worker for having nothing new, and never merge two workers into one entry.

Give each worker exactly these four parts, in this order, in plain English:

- **(a) What it has finished** - the work that is actually done, described as an outcome rather than as the steps taken.
- **(b) What it is working on now** - the one thing occupying it at this moment.
- **(c) What it still has to do** - what remains between now and the worker being finished.
- **(d) How long it needs** - a time estimate for finishing the whole job.

Two rules govern part (d):

- Always give an estimate, even when it is a guess.
  Say it is a rough guess when it is one, but never omit it and never replace it with "unclear" or "hard to say".
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
