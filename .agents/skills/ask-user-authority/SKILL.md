---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings and for any other question about to be escalated to the captain.
  Use before deciding any ask-user finding, regardless of the project's yolo posture, and before registering a captain decision from an investigation or review, to distinguish corrections within accepted intent from product or engineering contract expansion that requires the captain.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the escalate-or-decide boundary.
It governs every question about to reach the captain, whether it arrived as an ask-user finding from a validation gate or as an unresolved choice found by an investigation or review, which `decision-hold-lifecycle` routes here before registering anything.
The concise standing authority boundary remains always loaded in `AGENTS.md` section 7.

## The bar for asking

Escalation is expensive and the queue compounds, so the default is to decide.
Ask only when the answer is genuinely not derivable from the accepted contract, the code, and the evidence in front of you.

Apply this test before escalating anything:

1. Is there a defensible answer a careful engineer would reach from the accepted contract and the evidence?
   If yes, take it and record the reasoning; a difficult or debatable call is still yours.
2. Would the two candidate answers commit the project to materially different products, costs, or accepted risks?
   If yes, it is the captain's.
3. Does answering it require preference the evidence cannot supply, such as which of two defensible products to build, how much risk or spend to accept, or what an external commitment should say?
   If yes, it is the captain's.
4. Is it destructive, irreversible, or genuinely security-sensitive?
   If yes, it is the captain's under the stronger existing boundary.

An engineering trade-off with a defensible answer is Firstmate's call even when the trade-off is real, the alternatives are close, or getting it wrong would cost rework.
Difficulty, reviewer emphasis, and the presence of two options are not evidence that a question belongs to the captain.
Uncertainty about which answer is best is the ordinary condition of engineering work, not grounds to escalate.

Worked examples on both sides:

- The order in which two related pull requests should land, where one order is clearly safer, is Firstmate's call: the evidence settles it and neither order changes what gets built.
- Where a piece of infrastructure should live within an accepted architecture is Firstmate's call, even when two placements are defensible, because the choice does not change the product's behavior or its accepted risk.
- Whether to fix a defect in place or split it across two pull requests is Firstmate's call when both routes deliver the same accepted behavior; it becomes the captain's only if splitting changes what ships or when.
- Which of two documents is authoritative for a team's rules is the captain's: it is a standing policy choice about how the team works, and the evidence cannot rank the options.
- Accepting a known risk in order to ship sooner is the captain's, because it trades product risk for time.
- Anything that changes an outward-facing commitment, a cost, or a security posture is the captain's.

When a question fails this bar, do not register it as a captain decision and do not park the work waiting for one.
Decide it, record the reasoning where the work lives, and continue.

## Decide who has authority

1. Check the project's configured authority first.
   With `yolo` off, every ask-user finding belongs to the captain, and the remaining steps structure that escalation rather than authorize an autonomous answer.
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
