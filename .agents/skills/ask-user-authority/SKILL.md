---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding.
  This skill is the single owner of finding-decision policy: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
  It also owns the rule that a finding reporting a configured check could not run is an environment fault, never answered by approval.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## A check that could not run is not a finding

A finding reporting that a configured check COULD NOT RUN - the tool was missing, the command was not found, the worktree had no installed dependencies - is an environment fault, not a code finding.
A configured check did not run, so validation is incomplete.
Never accept, approve, waive, or defer it: doing so permits delivery without the configured check, including coverage of the pipeline's own automatic fix commits.
Missing project dependencies can also disable a pre-commit formatting hook that needs those same dependencies, so that hook is not an independent safety net.

Do not assume that the gate's worktree has dependencies installed merely because the worker's copy does.
The finding must report a failure to execute validation tooling or prepare its environment; a product failure such as "Administrators cannot run exports" does not establish that a check failed to run.

Firstmate decides this itself and never escalates it, because nothing about it is a product or architecture call.
The only correct answer is Fix, framed as environment repair: install the project's dependencies from its frozen lockfile, run the configured checks for real over the changed files, fix whatever they actually report, and answer the gate with that real result.
An honest result may be that the checks ran and cover none of the changed paths; that is a valid answer and a silent could-not-run is not.
Repair the copy the gate is actually validating; copying the changed files into some other copy that has the tools diagnoses the fault but leaves the gate's own copy unchecked.

`bin/fm-crew-state.sh` names this case in its parked-gate detail, but that classifier reads agent-authored prose and can miss an unanticipated phrasing.
Apply this rule whenever a finding says a check did not actually run, whether or not the state line flagged it.
[`tests/fm-crew-state.test.sh`](../../../tests/fm-crew-state.test.sh) covers the recorded missing-dependency findings, mixed findings, and product failures that must not be labelled as environment faults.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
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

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
