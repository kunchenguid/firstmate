---
name: artifact-comment-loop
description: >-
  Agent-only procedure for keeping the captain's artifact comment loop alive across firstmate restarts.
  Load before publishing or updating an artifact the captain will comment on, on the session-start "Live artifacts" listing, when `bin/fm-artifact.sh due` names an artifact on a heartbeat wake, and before retiring a finished review surface.
user-invocable: false
metadata:
  internal: true
---

# Artifact comment loop

An artifact watch is session-local.
It is armed by a tool call inside one firstmate session and dies with that session, so after a restart nothing is subscribed: the captain leaves a comment, no notification arrives, and the review loop stops with nobody noticing.
That failure is silent on both sides, which is what makes it worth durable machinery rather than attention.

Two mechanisms answer it, and they are not the same mechanism.
Re-arming restores the subscription at every session start.
The backstop re-reads comment threads on a slow clock, because a watch can also drop mid-session with no error anyone sees.

`bin/fm-artifact.sh` is the single owner of the live-artifact registry, the handled-comment ledger, and the backstop clock; read its header for exact flags and record formats.
It never reaches the network: reading and answering comments is always your tool call, and the script is only what makes those calls agree with each other across restarts.

## Register an artifact the captain will comment on

Publish first, then register the URL the publish returned:

```
bin/fm-artifact.sh register <url> --title "<short name>" [--note "<what it is for>"]
```

Register only surfaces the captain is expected to comment on.
A one-off page nobody will annotate is not a review surface and does not belong in the registry.
Re-registering the same URL replaces that record rather than adding a second one, so pass `--note` again when the note still applies.

Registration is not the watch.
Arm the watch in the same turn, then record the outcome exactly as the re-arm procedure below does.

## Re-arm at session start

The session-start digest prints a "Live artifacts" listing whenever this home has any.
For each artifact in it, in the same turn:

1. Arm a watch on that URL.
2. Record what happened: `bin/fm-artifact.sh rearm <url> ok`, or `bin/fm-artifact.sh rearm <url> failed "<what went wrong>"`.

Record the failure before moving to the next artifact.
An unrecorded failure is the silent failure this whole mechanism exists to prevent: the next digest would show a healthy-looking artifact that nothing is subscribed to.
A recorded failure reappears as a `!` line in every later digest until a re-arm succeeds, so it cannot quietly decay.

A watch that fails to restore is a real blocker under `AGENTS.md` section 9: tell the captain the review page is no longer watched and that comments on it will only be picked up on the slow re-read, and say what blocked it.
Do not retire an artifact to clear a failing re-arm.

A session that did not acquire the fleet lock re-arms nothing and records nothing; the digest says so.

## The heartbeat backstop

On a heartbeat wake, after the ordinary fleet review, run:

```
bin/fm-artifact.sh due
```

It prints nothing until an artifact's poll interval has elapsed, so an ordinary heartbeat costs one shell call and stops there.
Only when it names an artifact do you spend tool calls, and only on the artifacts it names.

For each named artifact:

1. Read its comment threads.
2. Feed the script one `<thread-id> <mark>` line per thread on stdin, where the mark is a stable identity for how far that thread has been read - the thread's comment count, or its last comment id:

```
printf '%s\n' "<thread-id> <mark>" ... | bin/fm-artifact.sh new <url>
```

3. It prints only the threads that have moved since you last handled them, and stays silent when nothing has.
   Silence ends the backstop for that artifact: say nothing to the captain, and do not report the empty poll as progress.

Handle whatever it prints as ordinary comment feedback.
Reply to the thread first, then re-read that thread and record it with the mark as it stands after your reply, never the mark you read before answering:

```
bin/fm-artifact.sh handled <url> <thread-id> <mark>
```

## Never handle a comment twice

The ledger is what keeps the live subscription and the backstop from both answering the same comment.
Whenever you act on a comment - including one that arrived through the live watch, not the backstop - reply first, then re-read that thread and record it with `handled` using the mark as it stands after your reply.
Never record the mark you read before answering.
Skipping the record entirely is what makes the backstop re-surface an answered comment later.

The mark records the state you have actually seen, and a mark read before replying is already obsolete by the time the turn ends, because your own reply is the very next thing to land on that thread.
The mark moves for reasons that are not the captain: your own reply moves it, and so does the host's automatic comment acknowledgement, which is deliberately outside this mechanism and stays in place.
That is precisely why the read is placed after the reply.
A mark taken after the reply still cannot swallow a genuine comment: if the mark moves again after your read, the backstop re-surfaces the thread, and what you find when you look there is what decides whether it is genuinely new.
When you have read the thread and the only content newer than your last read is your own reply or the host's automatic acknowledgement, record `handled` at the current mark and say nothing to the captain; a comment from the captain is new content and must still surface.

Comparing the mark rather than the thread id alone is deliberate: a follow-up comment on a thread you already answered moves the mark, so it is correctly reported as new.

## Retire a finished surface

```
bin/fm-artifact.sh retire <url>
```

Retire when the review the artifact existed for is over, not merely when it has been quiet.
Retiring drops both the registry record and its handled-comment ledger, so a later re-register starts clean and every prior thread reads as new.
A retired artifact is neither re-armed nor polled.
