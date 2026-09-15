---
name: handoff
description: >-
  Print a disposable paste-ready next-session starter from the current firstmate conversation so the captain can /clear and resume.
  Use when the captain invokes /handoff or explicitly asks for a session-reset prompt, a catch-up paste, or what to paste into a fresh session after /clear.
  Do not load this for /stow, "stow what you've learned", filing knowledge to disk, memory curation, or startup-memory budget work - those belong to the stow skill, which this skill must never duplicate.
user-invocable: true
metadata:
  internal: true
---

# handoff

Review this firstmate conversation and print one dense, paste-ready next-session starter so a fresh firstmate can resume without re-reading the old transcript.
This is disposable, session-specific catch-up text, not a durable-knowledge dump.
It is not `/stow`: write nothing, file nothing, and do not write to memory, the backlog, or any other disk surface.

## What it does

1. **Read this conversation end to end.**
   Walk the whole visible firstmate transcript, not only the last few turns.
   Scope is this conversation only: do not sweep fleet memory, secondmate homes, or work this session never mentioned.
   If compaction hid earlier turns, say so in the wrapping sentence and compose only from what is still visible.

2. **Keep only what still matters.**
   Extract the durable remainder:
   - every open captain decision or unanswered captain question still in play
   - every in-flight task this conversation still cares about, with its id
   - anything not yet committed, merged, or tested
   - any unresolved captain ask
   For each in-flight task, read current state from `bin/fm-crew-state.sh <id>` and the backlog.
   Those owners already define the vocabulary; do not invent a second one, and do not restate it here.
   Prefer that live current state over a stale conversational claim.
   Do not run a fleet-wide digest.
   Drop resolved back-and-forth that carries no forward-looking information: "ok let's look at this", "found a lead, trying a fix", confirmations that only meant proceed, settled investigation paths that did not change the outcome, and routine progress that is no longer true.

3. **Compose one next-session starter.**
   Write it as the captain's first message in a brand-new session, in the captain's voice, addressed to a fresh firstmate.
   It must ground that firstmate without the old transcript: which project(s), which task(s) with their ids, what is already true (landed or merged versus still open), and the concrete next step.
   Omit an empty heading rather than padding.
   Include every full `https://...` PR URL the remainder still needs; never invent an id or URL.
   If nothing durable remains, the starter is one line saying there is no open work to resume from this conversation.

4. **Print the starter in chat.**
   Put the starter in a single fenced code block so it copies in one shot.
   Wrap it in a short captain-facing sentence that it is ready to paste after `/clear`.
   The wrapping sentence follows `AGENTS.md` section 9.
   The starter itself is working text for a fresh firstmate and may name task ids, projects, and PR URLs.

## Starter shape

Keep it dense.
A typical non-empty starter looks like this, with unused headings left out:

```
Pick up this firstmate home from the catch-up below.
Do not re-litigate settled facts.

Projects: <names>
Already true: <landed, merged, or otherwise settled facts this session established>
In flight:
- <id> (<project>): <current state>. Still needs: <commit, merge, test, or captain answer>
Open decisions:
- <the question, options if they exist, and what is blocked on the answer>
Next: <one concrete action for the fresh firstmate>
```

## Hard exclusions

- Do not write the starter, or anything else this skill produces, to a file.
- Do not write to `data/`, `state/`, `config/`, or any memory file.
- Do not load or run `/stow`.
- Do not mention `/stow`'s internals beyond this plain-English "this is not that" note.
- Do not treat this as `/bearings` (no fleet snapshot) or `/ahoy` (not a recap for a captain who is staying in this session).
