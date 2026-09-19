---
name: quiet
description: >-
  Enter quiet supervision mode when the captain invokes /quiet or asks for quiet mode, quiet-while-present, or fewer routine wake turns while they stay in the session.
  It records durable quiet mode while preserving extension-owned supervision on Pi and omp and daemon-owned supervision elsewhere; ordinary captain chat does NOT exit it - only an explicit `/quiet off` does.
user-invocable: true
metadata:
  internal: true
---

# quiet

Quiet mode keeps routine updates out of captain chat without treating ordinary messages as a return from absence.
On Pi, pi-signed, and omp, the existing extension remains the only supervision owner.
The watcher retains its ordinary suppression of proven-working activity; actionable notifications still reach the supervision session, which batches routine responses and surfaces decisions, failures, credentials, and review-ready work.
This is not a promise to eliminate every model turn.
On other harnesses, the daemon mechanisms remain owned by the `afk` skill.

## What it does

1. **On Pi, pi-signed, and omp**, run `FM_AFK_MODE=quiet bin/fm-afk-launch.sh start`.
   This writes the durable quiet flag without proposing or confirming an away record, starting a daemon, or replacing the existing supervision cycle.
   Repeating the command, or a bare refresh while quiet is already active, preserves quiet mode.
   If an away record or daemon lifecycle remains, finish its normal return before entering quiet mode; never erase those records to bypass the refusal.
   **On other harnesses**, follow the `afk` skill's daemon lifecycle with `FM_AFK_MODE=quiet`.

2. **Acknowledge** in `AGENTS.md` section 9 language: "Captain, quiet mode is
   active; I will batch routine updates and surface only decisions, failures,
   credentials, or review-ready work - ordinary chat will not exit this, say
   `/quiet off` when you want normal per-wake responses back."

## How to exit quiet mode

Unlike `/afk`, ordinary chat is never the exit signal - that is the entire
point of this mode (AGENTS.md section 8's away-mode stub, quiet branch).

- Only an explicit `/quiet off` (or the captain plainly asking to leave quiet
  mode / resume normal supervision) exits it: run `bin/fm-afk-return.sh`
  unchanged, exactly the procedure `/afk`'s "How to exit afk" section
  documents for its own return path (correct-ordered daemon shutdown,
  durable wake presentation and acknowledgement, escalation/wedge evidence,
  and the return-catch-up gate).
- A marked daemon escalation, or a message beginning `/quiet` while already
  in quiet mode (refresh, not exit) -> stay in quiet mode and process it, the
  same two carve-outs `/afk` documents for away mode.
- Every other message while in quiet mode is simply answered as ordinary
  work; the flag and existing supervision are left untouched.

## Orthogonal to approval authority

Identical to `/afk`: quiet mode changes how aggressively firstmate surfaces
things, never who approves what.
A PR ready for merge keeps the merge authority from `AGENTS.md` section 7, and
a needs-decision finding keeps the `ask-user-authority` policy.

## Must not hide a decision or a failure

Per the issue's own author triage: quiet mode is presentation only.
Progress, retries, and internal mechanics stay below deck exactly as in away
mode, but review-ready work, findings, decisions, failures, and credentials
escalate every time, through the same classification policy `/afk` owns.
Quiet mode is opt-in and never the unconsented default; only an explicit
`/quiet` invocation enters it.
