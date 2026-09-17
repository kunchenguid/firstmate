---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use before deciding any ask-user finding and before deciding whether another fix round should happen at all.
  This skill is the single owner of finding-decision policy: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
  It also owns the stopping rule: three fix rounds is the advisory cap, and the cap never authorizes approving past a correctness or contract defect.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
It settles two questions at every gate: whether firstmate may decide the finding at all, and whether fixing it is worth another review round.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
4. Fix only what makes the deliverable wrong.
   Approve past wording, restatement, simplification, and documentation-polish findings even when the reviewer is right, unless the text is actually false.
   Approving one of those records that the deliverable is already correct; it neither concedes nor disputes the reviewer's reading, and it leaves no defect unfixed.
5. Cap the work at three fix rounds per run, counting one round per gate response that opens a fix round: a `no-mistakes axi respond --action fix` the worker sends on its own judgment, never rounds the pipeline chains inside one of them and never a fresh three per gate or per step.
   A fix response that carries a decision firstmate returned, or that retries an unfinished step such as a protected-path refusal, opens no round and does not count against the cap.
   The cap is a proportionality rule with an advisory count, not an enforced limit: nothing records the count durably, so it resets on a context reset or a worker recovery.
   It also bounds only what the worker initiates, not what the pipeline does inside one of those responses, so three of them can still chain into more fix rounds and more wall clock than the number suggests.
   Step 4 is the binding half and holds at every round, while three is guidance for when to stop.
   Once three rounds have run, approve every remaining finding that is not a correctness or contract defect and file it as its own backlog work item with `bin/fm-tasks-axi.sh add` rather than opening a fourth round.
   Review wall-clock is the dominant cost of a small change, so hours already spent are a reason to stop rather than evidence that another round is warranted.
   The cap bounds proportionality and never correctness: it is never authority to approve past a correctness or contract defect, which is still fixed at the fourth round and beyond, and the criteria in step 6 still escalate regardless of how many rounds have run.
6. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
7. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

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
- A comment-wording, restatement, or documentation-polish finding is approved past even when the reviewer's reading is the better one, because neither the code nor the text it describes is wrong.
- A correctness defect surfaced at the fourth round is still fixed; the cap ends rounds of polish, never the obligation to ship a correct deliverable.
