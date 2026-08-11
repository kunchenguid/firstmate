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
   With `yolo` off, every ask-user finding belongs to the captain, and the remaining steps structure that escalation rather than authorize an autonomous answer - UNLESS the captain's standing domain policy (`data/captain.md`) grants a narrower parity-completion authority for this task's class (see "Simple-ship parity authority" below), in which case that narrower authority applies to findings squarely within it and every other finding still follows this default.
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

Some domains adopt a standing policy (recorded in `data/captain.md`) that grants firstmate a narrow, task-class-scoped exception to the yolo-off default above: for a task the policy designates as in its simple-ship class (small, localized, behavior-preserving work with a named remedy family), firstmate may authorize Fix on an ask-user finding that is a genuine parity completion of already-accepted intent, without a captain round-trip, even though the project's ordinary yolo posture is off.
This exception is opt-in per domain and does not exist unless `data/captain.md` states it; when no such policy is recorded, step 1's plain yolo-off default governs every finding.

Use it only when every one of these holds:

- The task is one the domain policy's simple-ship class actually covers.
- The finding is a parity completion of the accepted intent, not new scope: the same selector, pattern, or contract family the task already targets, with a concrete file, line, and remedy the reviewer named.
- The task's brief encoded completeness as a scan instruction (search the pattern family and bring every match into scope), so a missed family member is exactly this kind of ordinary in-scope fix rather than a guess about what the codebase contains.
- None of step 5's expansion boundary or step 8's destructive/irreversible/security-sensitive boundary apply; those escalate regardless of this authority.

Never silent: every decision made under this authority must be called out on the captain's configured standing review surface (e.g. a dashboard) in the same turn, and in chat too when the captain is present, naming the finding, the decision, and why it was in-scope parity.
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
- A missing rule in the same selector family the task already broadens, named file/line/remedy, on a domain-policy-covered simple-ship task with a scan-based brief: decide it under simple-ship parity authority and call it out on the dashboard, rather than escalating.
