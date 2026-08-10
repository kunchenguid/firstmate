---
name: unattended-session
description: >-
  Agent-only procedure for a firstmate session that a queued trigger started rather than the captain.
  Use when the session-start digest announces an unattended session, and before taking any action in one.
  Owns what such a session may act on, what it must park, and how it ends.
user-invocable: false
metadata:
  internal: true
---

# unattended-session

The captain approved, on 2026-08-03, that firstmate may start its own session and act on the drained wake queue.
That ruling grants **execution without a live human-started session** and nothing else.
`data/loop-lc-autonomy-substrate/captain-ruling-unattended-session-2026-08-03.md` is the ruling itself; `bin/fm-unattended-session.sh`'s header owns the mechanism, the refusal tokens, and the durable records.

Load this skill when the session-start digest announces `UNATTENDED SESSION`, or when `bin/fm-unattended-session.sh session` reports `session_origin=unattended`.

## Authority is unchanged, and that is the whole point

You have exactly what a captain-started session has.
Not more because nobody is watching, and not less either.

Everything that needed the captain before still needs the captain:

- A PR merge needs the captain's explicit word, unless the project carries a standing `yolo` posture.
  This repository's posture is autonomy off.
- Teardown of unlanded work is refused; no force, no discard.
- An ask-user finding is decided under `ask-user-authority` exactly as it would be in a captain-started session, which with autonomy off means it belongs to the captain.
- A destructive, irreversible, or security-sensitive action needs the captain naming the concrete action.

When you reach one of those and the captain is not there to answer, **park**.
Record the block where it durably belongs - the backlog item, the decision hold, the task's status - and stop.
Never resolve a block by widening your own permission, and never reason that the captain "would obviously say yes": the ruling that lets you run is the same ruling that says this session approves nothing extra.

## What you may act on

Two things, and only two:

1. **The drained wake queue.** The queue is why this session exists. A trigger was queued while nobody was home, and draining it is the work.
2. **Work already registered in this home** - tasks with durable records, PRs already open, holds already filed.

Starting is not a licence to find work.
Do not survey the fleet, audit a project, sweep the backlog for improvements, or open a new line of investigation because the queue turned out to be thin.
An unattended session whose queue drains to nothing has finished; say so and stop.

Handle each drained wake under the ordinary wake contract in `AGENTS.md` section 8 - there is no separate unattended wake protocol, and inventing one would be exactly the widening this forbids.

## Records and attribution

The session's origin record and its append-only log are written by `bin/fm-unattended-session.sh`, and the digest claims the record automatically when this session holds the lock.
You do not write them by hand.

Two consequences worth knowing:

- **A lock-refused unattended session writes nothing.** It stays read-only like any other lock-refused session: no drain, no spawn, no steer, no merge, no repair. It is still announced as unattended, because announcing is a read.
- **A claimed record is what makes your actions attributable afterwards.** If the digest shows the session unattended but unclaimed while the lock is held, the record is missing or expired - report that rather than proceeding as though the run were attributable.

## Supervision

This session supervises exactly like any other: one live cycle, following the emitted harness protocol.
It never starts a second cycle beside a live one - `bin/fm-unattended-session.sh start` refuses to launch at all when a session, a healthy watcher, or away mode already owns supervision here, so if you are running, that check already passed.

## Ending

Finish the drained work, leave every block parked with its durable record, and stop.
Do not keep the session alive looking for something else to do.
The next trigger starts the next session; that is the whole design.
