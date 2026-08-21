---
name: routing-promotion
description: >-
  Agent-only procedure for re-staffing a task whose worker re-resolved its own tier upward mid-task.
  Load on any promoted status wake, and whenever an open promoted record appears in an OPEN DECISIONS listing or a landing path refuses on one.
user-invocable: false
metadata:
  internal: true
---

# Routing promotion and the re-staff obligation

A worker reports an upward mid-task re-resolve of its own tier with the routing-promotion verb, and keeps working.
`bin/fm-classify-lib.sh` owns that verb, the two-pass tier contract behind it, and the keyed fold that holds the record open.

The record staying open is the obligation.
Firstmate owes it a re-staff, and both landing paths refuse until it is closed, so a promotion cannot quietly land at the rigor its own diff already disproved.
`bin/fm-promotion-gate-lib.sh` owns that refusal and its last-resort override.
Closing a promotion is a supervisor assertion that a re-staff happened, deliberately not machine-verified.
Its protection is durable visibility: the promotion, answer text, and any override reason are all recorded.

## Handle it

1. **Read the record, not the pane.**
   The wake carries the key, the new tier, the factor, and what raised it.
   A promotion is nonterminal, so the worker is still working; reconcile current state with `bin/fm-crew-state.sh` only when your next action depends on it, and never treat a promotion as a stop, a pause, or a blocker.

2. **Re-staff the worker's strength.**
   Re-resolve the dispatch decision at the new tier exactly as at intake: consult this home's dispatch profiles, and load `quota-array-dispatch` before choosing among a matched profile array.
   Apply it with `bin/fm-control.sh <task-id> relaunch`, which keeps the same endpoint and the same local copy and accepts an explicitly chosen `--harness`, `--model`, and `--effort`.
   Its `--note` is required and is the whole handover: the replacement inherits the work on disk but none of the conversation, so state the new tier, what raised it, and what to carry forward.
   Load `harness-adapters` before the relaunch, and see [`docs/agent-control.md`](../../../docs/agent-control.md) for the transaction's own guarantees.
   Relaunching is not a teardown and never discards unlanded work; if a relaunch would cost more than the promotion is worth, say so and keep the current worker rather than relaunching reflexively.
   That judgment does not re-staff the task or discharge the promotion: leave its keyed record OPEN, escalate the decision to the captain, and keep landing refused until the captain answers.

3. **Add review as its own task where it helps.**
   A higher tier often wants another lens rather than a stronger implementer.
   Commission that as a separate scout with its own brief; do not fold it into the promoted task.

4. **A delivery-path raise is the captain's call.**
   Delivery mode is an intake decision recorded in both the worker's instructions and its durable record, and the spawn guard requires the two to agree, so raising it mid-task means rewriting a worker's instructions underneath it.
   Do not do that.
   When the promotion genuinely implies a stronger delivery path, escalate to the captain with the evidence, the consequence, and your recommendation.
   Standing routine authority does not cover it; load `ask-user-authority` when the promotion also surfaces a gate finding.

5. **Close only after a re-staff or captain answer.**
   Close the record only after an actual re-staff onto a stronger runtime, or after the captain has answered an escalation.
   Answer the worker with `bin/fm-send.sh <target> --resolve-key <key> '<the re-staff decision>'`, which closes the record as it delivers.
   When the worker is already gone, hold the promotion for the captain instead and load `captain-hold-lifecycle` for that procedure; the transfer closes the live record without losing the promotion.
   Either way the answer must name the actual re-staff or the captain's escalation decision, because that text is the durable account of how the promotion was discharged.

## Boundaries

- Never demote.
  The effective tier is the higher of the two passes, so a promotion is one-way and a later reassessment never lowers it.
- Never close a promotion you did not act on.
  A resolution that re-staffed nothing converts the gate into a formality.
- Never use the landing override to avoid a re-staff.
  It exists only for a promotion that can be neither answered nor transferred, and it demands a stated reason precisely so that case stays visible.
- Never relay the record verbatim to the captain.
  Report the outcome in plain language: what the work turned out to touch, what you changed about how it is being built, and what still needs their decision.
