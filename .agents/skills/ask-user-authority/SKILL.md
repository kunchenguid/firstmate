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

## A decision that directs a fix must carry a probe

Captain ruling, 2026-08-10.
Four times in one day a ruled criterion was reported APPLIED while not being MET, every one caught by a worker re-checking its own work rather than by any mechanism, and firstmate had made the criterion explicit in writing before the fourth.
Applied is an action the pipeline observes; met is a predicate nobody was evaluating, so the ruling and the fix were never bound together.

Every `data/<task-id>/decision-<key>.md` you write that directs a fix carries exactly one fenced `probe` block, in this pinned format:

````
```probe
tier: executable | cited-control | attested
run: <command, run from the task worktree; exit 0 means the criterion is met>
control: <name of the test or artifact that was watched to fail first>
reason: <required for tier attested only - why no probe is possible>
```
````

`run` is required for `executable` and `cited-control`; `control` is required for `cited-control`; `reason` is required for `attested`, which carries no `run`.
Exit 0 means met, non-zero means not met, and a probe that cannot execute is could-not-observe and never a pass.

Choose `cited-control` by default: it is the strongest routinely achievable form, confirming the named test passes now while citing the watched-it-fail observation as a named artifact rather than as a claim.
Use `attested` only where the criterion genuinely cannot execute, such as a comment reading accurately; that tier stays marked and visible and is never read as verified.
Forcing a probe where none is possible would manufacture a fake one and recreate this same failure one level up.

`bin/fm-commitment-register.sh` reads these blocks, and `bin/fm-classify-lib.sh`'s open-decision fold consults it, so a `resolved` event for a key with a registered probe is not accepted as resolved until that probe passes.
Do not back-fill a decision ruled before 2026-08-10 with an invented probe: it correctly reads could-not-observe, on the same principle that forbids back-filling historical verifier identities, because a fabricated record is indistinguishable from a real one afterwards.
None of this replaces a worker re-checking its own work; the probe is a floor beneath that diligence, never a substitute for it.

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
