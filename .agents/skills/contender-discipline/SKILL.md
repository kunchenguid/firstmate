---
name: contender-discipline
description: Agent-only policy for visual, design, and option-set contender work. Use before dispatching contender work, asking for a captain pick, re-rolling rejected options, or settling a contender.
user-invocable: false
metadata:
  internal: true
---

# contender-discipline

This is the one policy owner for contender selection, re-roll bounds, and the data-only contender lifecycle.

## Default and exceptions

For visual, design, or option-set work, dispatch one worker to produce up to three options by default.
Do not create a multi-model fan-out merely for comparison.
Parallel contender workers are allowed only when the captain explicitly requests maximum parallelism or multiple models, the same instructions have already failed twice with one model family, or genuine cross-family independent review is itself the requested deliverable.
A batch spawn requires a stated `--batch-reason`; `bin/fm-spawn.sh` records that reason and loudly warns when it is absent.
The stated reason does not make an otherwise disallowed contender fan-out acceptable.

## Re-roll state machine

1. One worker produces at most three options.
2. The captain picks one, or rejects all with a one-line reason.
3. Mutate the instructions from that reason and re-run the same model once.
4. If the second set is rejected, change model once.
5. If that set is rejected, stop and re-scope with the captain.

Do not treat a model change as a reason to reset the same-model retry budget.

## Durable pick and cleanup

A finished data-only contender is a scout with its deliverable at `data/<task-id>/report.md`, not a local-only ship that will never land.
When its options are ready for a captain pick, use `bin/fm-contender.sh await-pick`.
That command durably records `awaiting-pick`, runs ordinary safe scout cleanup, and leaves the report in `data/` without retaining a dead endpoint.
Use `bin/fm-contender.sh settle` after a pick, rejection, or supersession so interrupted cleanup can converge safely.
The captain's standing preference is to automatically clean finished contenders left over after a rejection or supersession.
A contender that has unlanded project work is not data-only and must stay on the ordinary delivery lifecycle.
