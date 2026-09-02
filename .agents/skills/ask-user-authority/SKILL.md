---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding, including a worker's self-resolution check.
  This skill is the single owner of finding-decision policy: firstmate applies judgment to every finding that routes to it, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones; a worker may self-resolve only under the body's narrow warning carve-out.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate applies this judgment to every finding that routes to it, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding, except within the narrow self-resolution carve-out below.
Outside that carve-out, it stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Worker self-resolution carve-out

A worker MAY respond to an ask-user finding itself, with no firstmate round trip, only when every condition below holds:

1. The finding's severity is `warning`; any `error`, `critical`, or higher severity always routes to firstmate.
2. The finding's proposed action is `auto-fix`, so the pipeline applies the fix and the worker never hand-edits.
3. Every file the fix touches is already changed by this branch's own diff against its merge base; a fix reaching any file outside that diff always routes to firstmate.
4. The fix only restores or completes behavior already accepted in the brief or in a later firstmate instruction, adding no new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, monitoring requirement, or generalized framework.
5. The fix is not destructive, not irreversible, and not security-sensitive; those always route to firstmate and, above it, to the captain.
6. It is the first finding in its causal theme in this run; a second finding in the same theme always routes to firstmate, because repeated same-theme findings are the signal that fixes are accreting around a questionable abstraction.

If any condition is unmet, or the worker is unsure whether one is met, the rule above stands unchanged outside this carve-out: append `needs-decision:` with a key and stop.
Uncertainty routes to firstmate and is never resolved by self-approval.
This carve-out changes nothing about merge authority or the destructive, irreversible, and security-sensitive boundaries.

A self-resolved finding must never be invisible to firstmate.
A worker that self-resolves under this carve-out appends one status line naming the finding id, the six conditions it judged met, and the response it sent, in the existing `resolved: [key=...]` shape so the status classifier reads it as a closed decision rather than a new one.
Firstmate audits every self-resolved finding from the status log alone.

## Decide

1. Reconstruct the accepted contract from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that contract.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide when it misses any condition of the worker self-resolution carve-out, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
