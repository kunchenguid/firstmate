---
name: ask-user-authority
description: >-
  Agent-only decision procedure for delivery findings, deferrals, and review limits.
  Use before deciding delivery findings, deferrals, or further review.
  This skill is the single owner of finding-decision policy: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of delivery-finding scope, disposition, and review-stopping policy, including no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted behavior and explicit exclusions from current authorized intent, specification, and steers.
   Reviewer suggestions and implementation choices do not add acceptance criteria.
   `bin/fm-dod-lib.sh` owns what the worker may pass as `--intent`.
2. For each actionable finding, identify the reachable trigger, realistic exposure, consequence, introduced or inherited provenance, and relationship to the requested behavior.
   Separate observation, source-proven path, and hypothesis; unknown frequency stays unknown.
   Severity labels do not decide scope.
3. Fix now when the change violates an explicit requirement, introduces a demonstrated material regression, or an existing defect concretely prevents safe or correct delivery of the requested behavior.
   Use the smallest causal repair that preserves known-good behavior, with targeted verification and accurate delivery evidence.
   Necessary downstream corrections remain in scope even outside the intake file list; explicitly requested complex architecture does not itself require escalation.
4. File a concise follow-up for a real minor, rare, inherited, or unrelated defect that does not block that delivery.
   Close duplicates, disproved claims, taste-only suggestions, and unsupported future requirements with a short reason; do not file every imagined edge case.
   A specific plausible safety concern without enough evidence may justify one bounded check or an affected deployment hold, not an automatic redesign.
5. Firstmate makes routine fix, defer, and close decisions under existing authority.
   Declining unrequested expansion needs no captain decision.
   Escalate only an unresolved product tradeoff, necessary contract expansion with no compliant bounded alternative, genuinely nonconvergent design choice, or action outside existing authority.
   Destructive, irreversible, and genuinely security-sensitive choices retain their stronger captain boundary.

## Review and stopping

Use the selected delivery path's independent review; do not add a second review path or a manual clean-verdict gate.
After a material fix, verify the changed behavior and directly affected interactions; reuse evidence whose code, configuration, and assumptions remain valid.
Prefer an actual end-to-end check where it answers the open question better than more theoretical coverage.
Reopen a resolved finding only for new evidence, a relevant changed dependency, or a failed targeted check, not rephrasing or unchanged speculation.
Stop as soon as accepted criteria, required checks, and material findings are settled.

Three review rounds is the normal upper bound, never a target or expected process.
Firstmate may allow a fourth or fifth only for a newly demonstrated major safety, data-loss, security, or core-correctness defect.
Five is the exceptional absolute maximum, not another default allowance.
Count the initial review and each subsequent review across restarts in the existing task record; a narrower task-specific limit or explicit authority requirement wins.
At the applicable limit, stop the review/fix cycle and retain the affected-delivery hold; present a bounded repair or scope-reduction proposal instead of silently starting another cycle.
This policy authorizes no sixth round and never authorizes approving an unsafe build.

## Carry findings without blocking unrelated work

Before continuing a gate, retain deferred finding IDs, affected head, trigger/evidence, disposition reason, follow-up owner/reference, and any deployment restriction in the existing task report and backlog.
Use supported selected-finding fixes for fix-now items.
Approve a step with remaining findings only after recording why none blocks its accepted contract; do not delete findings, fake passes, or skip a mandatory failing check.
If the tool cannot represent the authorized disposition, report that limitation and hold only dependent delivery.
Deferral is neither a fix nor a passed test.
Continue independent work that does not depend on the finding.

Distinguish software completion, draft readiness, deployment readiness, and hardware acceptance in existing reports, without adding a new state machine.
Draft readiness means reviewable code and evidence with pending validation visible.
Software completion means the requested software behavior and applicable checks are satisfied; identify missing device evidence separately.
Deployment readiness applies to the exact artifact and target, including required compatibility, startup, recovery, and operational conditions.
Hardware acceptance requires the identified artifact's required device behavior and human observations; host tests and source review cannot establish it.
Keep existing device-evidence requirements and restrictions on demonstrated unsafe builds while permitting independent software and draft work.
A source-proven unsafe output path may justify withholding deployment without deliberately reproducing dangerous motion; an unsupported hypothetical does not block every build.

## Captain-facing escalation

State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.
