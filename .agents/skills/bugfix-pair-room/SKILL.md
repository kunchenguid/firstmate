---
name: bugfix-pair-room
description: Fix a reported flow bug autonomously with one strong driver and two cheaper seats (coder and evidence) in a chat room, with the root cause proven by a reproduction before any patch. Load when shipwright or firstmate dispatches a bug the owner found during usage, and when a bug brief has no proven root cause.
user-invocable: false
metadata:
  internal: true
---

# Bugfix pair room

One room, three seats, one pull request.
The driver owns the diagnosis and the scope.
The coder owns the diff.
The evidence seat owns the citations.
Nobody types a diff except the coder.

## When to use

- The owner reports a bug in the flow (rule FLOW BUGS SHIP ASAP in `data/captain-shared.md`).
- A bug brief arrives without a proven root cause, or with one that is a theory.

Tier branch, decided at intake by shipwright in one line in the brief:
- **Trivial** (one file, reproduced by the evidence seat in under five minutes, fix under twenty lines): no room; the coder fixes with the reproduction test and the driver reviews the exact head.
- **Everything else**: open the room.

## Seats

| Seat | Model class | Owns | Never |
|---|---|---|---|
| Driver | best of each vendor only: astra, fable, or opus xhigh (owner 2026-09-08); never a rotated cheap model | hypothesis table, scope, verdict at the exact head | edits files, runs suites |
| Coder | rotating cheap coder: luna xhigh, cursor grok 4.5/4.6, sonnet xhigh, terra high/xhigh, Kimi K3 via pi (owner 2026-09-08: vary for model telemetry) | branch, edits, regression test, PR | changes scope, guesses a cause |
| Evidence | rotating cheap fast model with file access (same roster as the coder, never the same model as this room's coder) | reproduction, related code, history, disconfirming evidence | edits, opinions without a citation |

Roster reads `config/crew-dispatch.json`.
The seat classes above are the intent.
The profile is the choice.

## Flow

1. **Room**: `bin/fm-room.sh start bugfix-<id>`, verify health, then create the driver brief before either cheaper seat spawns.
   Room join output goes to `data/<seat>/room-join.txt`, never to a worktree.
2. **Evidence first**: the evidence seat's first deliverable is a reproduction: a failing test or a deterministic command with output, at the exact head, plus the list of files and the last commits that touched them.
   No reproduction in thirty minutes means the evidence seat posts what it tried and the driver decides whether to widen or stop.
3. **Driver diagnoses**: from the reproduction and the evidence seat's citations, the driver writes `root cause: X at file:line, proven by <evidence>` in the room, one hypothesis at a time, following `diagnostic-reasoning`.
   A cause the reproduction does not isolate is not a cause.
   The driver sends the evidence seat back with the next hypothesis.
4. **Coder fixes**: the coder turns the reproduction into the regression test, confirms red, makes the smallest change that turns it green, and posts `head <sha> ready for driver re-verdict`.
   Second failed fix on the same symptom stops the coder.
   The driver re-diagnoses.
   Actionable packets use `bin/fm-room.sh handoff <review-id> <sender-seat> <recipient-task-id> <handoff-key> <message>`, which publishes the packet and durably notifies the recorded recipient as one action.
   Repeating the exact key and payload reuses the published packet and idempotent notification; a changed payload for that key fails loudly.
   Raw room chat remains conversation, not an actionable handoff.
5. **Driver verdict**: `driver-verdict <id> <PR URL> ok|defects: <one line>` at the exact head.
   The independent reviewer (shipwright-reviewer) stays outside the room and gates the PR as usual.
6. **Land and propagate**: shipwright merges through `bin/fm-pr-merge.sh` on the reviewer's exact-head LGTM plus the local gate, then `bin/fm-update.sh` so every running home gets the fix the same day.

## Bounds

- Bounded runs: the changed-test selection through `bin/fm-test-run.sh --changed`; a full sweep only when the driver names why.
- One bug, one PR; a second defect found on the way becomes its own item.
- Owner words go in `## Captain's intent` unchanged; the driver's root cause and scope go in `## Firstmate spec`.
- Close the room when the PR lands; record tokens per seat and wall-clock in the program record, or write `tokens unmeasured`.

## Model telemetry

Every seat records model, effort, tokens, wall-clock, and outcome (driver verdict, reviewer findings, rework rounds) in the program record, read from `state/<id>.meta` telemetry fields, never estimated.
Rotate the coder and evidence models across the roster so consecutive bugs do not reuse the same pair.
`bin/fm-model-usage.mjs` and `config/crew-dispatch.json` own the ledger and the profiles that learn from it.
