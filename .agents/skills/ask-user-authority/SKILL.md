---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding, regardless of the project's yolo posture, to distinguish corrections within accepted intent from product or engineering contract expansion that requires the captain.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision procedure for ask-user findings.
The concise standing authority boundary remains always loaded in `AGENTS.md` section 7.

## Decide who has authority

1. Check the project's configured authority first.
   With `yolo` off, every ask-user finding belongs to the captain, and the remaining steps structure that escalation rather than authorize an autonomous answer - UNLESS the finding qualifies for simple-ship autonomous parity authority (see "Simple-ship parity authority" below), which is a standing part of the captain-gated delivery workflow (`captain-gated-delivery`) rather than a per-project opt-in.
2. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
3. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
4. Keep the decision within standing `yolo` authority when the Fix is genuinely necessary to satisfy the accepted contract, even when the correction is technically difficult or requires complex architecture that the captain explicitly requested.
5. Escalate when the Fix would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent.
6. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.
7. Examine the causal theme across prior findings and fix rounds.
   Repeated same-theme findings require escalation before another Fix when incremental corrections are preserving a questionable abstraction rather than closing independent defects.
8. Apply the existing stronger captain boundaries first.
   Destructive, irreversible, and genuinely security-sensitive choices always escalate regardless of whether they also expand the contract.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Simple-ship parity authority

Under the captain-gated delivery workflow (load `captain-gated-delivery`), a simple ship is small, localized, behavior-preserving work that completes an accepted parity, fill, or alignment remedy family.
Inside that class only, firstmate may authorize Fix on an ask-user finding without a captain round-trip.

Use it only when ALL FOUR of these hold - this is the exact test, not a paraphrase:

1. The finding completes already-accepted intent rather than expanding it.
2. It applies the same treatment to the same selector or pattern family under the same contract.
3. The finding names the affected location and remedy.
4. The change is reversible, non-destructive, and not security-sensitive.

If classification is uncertain on any of the four, it is not this authority: use the normal escalation path.
This authority does not relax step 5's expansion boundary or step 8's destructive/irreversible/security-sensitive boundary; a finding that trips either of those escalates regardless.

Never silent: in the same turn, record every autonomous decision on the captain dashboard - the finding, why it qualified against all four conditions, and the authorized remedy - and mirror the callout in chat when the captain is present.
An autonomous Fix under this authority with no visible callout is a process failure even if the Fix itself was correct.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion stays within `yolo` authority, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
- A missing rule in the same selector family a simple-ship task already broadens, named file/line/remedy, reversible and non-security-sensitive: decide it under simple-ship parity authority and call it out on the dashboard, rather than escalating.
- The same missing-rule finding on a task whose classification as simple-ship is genuinely uncertain (mixed scope, unclear remedy family): escalate: uncertain classification is excluded from this authority by its own test.
