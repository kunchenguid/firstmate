# Ahoy

The captain asks what happened in this Firstmate chat since the last real captain message and is walked through any still-open decisions, without gathering a fresh fleet snapshot.

## Sub-features

- `helm-check` - if this session has no `SESSION START` digest yet, run session-start once before recapping
- `interval-recap` - recap visible outcomes after the previous real captain message
- `open-decisions` - list still-unanswered captain decisions from the whole visible session
- `bearings-fallback` - when `/ahoy` is the first real captain message, follow Bearings instead

## How to get to it (user POV)

- Type `/ahoy` (or `$ahoy` on Codex, `/skill:ahoy` on Pi) in an already-helmed Firstmate chat
- Type `/ahoy` as the first real captain message to get a Bearings digest instead of an empty recap

## Driving it with Firstmate chat history

Preconditions: a visible Firstmate harness transcript that already contains a `SESSION START` digest for this home; do not shell out to fleet snapshot commands for the normal recap branch.

- Confirm helm: look for a prior `SESSION START` banner in this session; if it is missing, run `bin/fm-session-start.sh` once and read that digest before recapping.
- Recap the interval: inspect only conversation already visible to this Firstmate and report outcomes after the previous real captain message.
- Report open decisions: include every visibly unanswered captain decision from the whole session, not only the interval.
- First-message fallback: if there is no prior real captain message, load `.agents/skills/bearings/SKILL.md` and drive Bearings instead of inventing a recap.

## Gotchas

The normal recap branch forbids fleet snapshots, GitHub calls, and file writes.

Operational injections that begin with U+2063 `FIRSTMATE_OP:` are not captain messages.

This feature cannot be proven by a script alone; skip it on a checkout that has no Firstmate chat history and write that reason to `$EVIDENCE/skip.txt`.
