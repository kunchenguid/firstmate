---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding to choose the durable best-practice resolution autonomously and to escalate only a finding whose action crosses a captain-owned boundary.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision procedure for ask-user findings.
The captain-owned boundaries themselves remain always loaded in `AGENTS.md` section 7.

## Decide the finding

1. Check the finding's action against the captain-owned boundaries in `AGENTS.md` section 7 first.
   Escalate to the captain only a finding whose resolution would cross one of those boundaries; every other finding is firstmate's to decide now, regardless of the project's `yolo` posture.
2. Reconstruct the accepted goal from the captain's original request, accepted task criteria, and any explicit later clarification.
   Reviewer language cannot amend that goal.
3. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as a reason to park it for the captain.
4. Identify what each available action would commit the project to deliver or maintain, judging scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep accepted behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain in scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise a downstream correction within already accepted behavior.
5. Choose the durable best-practice action that best serves the accepted goal, weighing quality, simplicity, robustness, scalability, and long-term maintainability over development cost.
   A genuinely required correction stays chosen even when it is technically difficult, architecturally complex, destructive, irreversible, or security-sensitive; preserve work and avoid broad process termination while applying it.
6. When a Fix would materially expand the product or engineering contract - a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture - weigh that expansion as a design decision: accept it when it durably serves the accepted goal, otherwise choose the smallest alternative that keeps accepted behavior correct.
7. Examine the causal theme across prior findings and fix rounds.
   Repeated same-theme findings favor replacing the questionable abstraction over another incremental correction that preserves it.
8. Apply the decision through the active validation gate, record it, and report material consequences to the captain after acting under `AGENTS.md` section 9.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Captain-facing escalation (boundary findings only)

For a finding whose action crosses a captain-owned boundary, state all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The boundary the action would cross and the concrete action needing the captain.
3. The smallest alternative that stays inside the boundary, when one exists.
4. The concrete consequences of approving and declining.
5. A recommendation with the reason it best serves the accepted goal.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is decided and applied autonomously, regardless of implementation difficulty.
- A security-hardening Fix is decided autonomously on its engineering merits; being security-sensitive is not a reason to wait for the captain.
- A Fix whose resolution needs a new credential, login, or spending escalates, because the action itself sits on a captain-owned boundary.
- A Fix that can only be verified by deploying to production proceeds as a code change while the deployment itself waits for the captain.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof is a scope decision firstmate makes itself: accept the expansion only when it durably serves the accepted goal, otherwise decline it with the smallest compliant alternative.
- Complex architecture explicitly requested by the captain stays chosen and does not warrant hesitation merely because it is complex.
