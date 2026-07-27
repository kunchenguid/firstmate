#!/usr/bin/env bash
# Static contract tests for the universal delivery-pipeline skill that absorbed
# issue-workflow: five ordered stages, a universal plan gate, same-repo
# serialization, and the research-has-no-PR ending.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/delivery-pipeline/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

test_skill_present_and_internal() {
  assert_present "$SKILL" "delivery-pipeline skill is missing"
  assert_grep "name: delivery-pipeline" "$SKILL" "delivery-pipeline metadata has the wrong name"
  assert_grep "user-invocable: false" "$SKILL" "delivery-pipeline must not be user-invocable"
  assert_grep "  internal: true" "$SKILL" "delivery-pipeline must be internal"
  pass "delivery-pipeline exists and is an internal, non-user-invocable skill"
}

test_all_intake_shapes_enter_one_skill() {
  # Success criterion 1: an issue, a bug report, and a research question all
  # enter the same skill (the feature request too).
  assert_grep 'an open issue, a reported bug, a research or design question, or a feature request' "$SKILL" \
    "delivery-pipeline trigger no longer covers every intake shape"
  pass "every intake shape enters the one delivery-pipeline skill"
}

test_five_stages_present_and_ordered() {
  local headers expected
  headers=$(grep -n '^## Stage ' "$SKILL" | sed 's/^[0-9]*://')
  expected="## Stage 1 - Intake and classify
## Stage 2 - Grill
## Stage 3 - Plan for approval
## Stage 4 - Approve, hold, dispatch
## Stage 5 - Ship"
  [ "$headers" = "$expected" ] || fail "five stages not present in order"$'\n'"--- found ---"$'\n'"$headers"
  pass "five stages present and in order"
}

test_universal_plan_gate() {
  # Success criterion 2: no implementation agent dispatched without an approved
  # plan, for any intake shape.
  assert_grep 'no implementation crewmate is ever spawned, for any intake shape, before the captain approves a plan on record.' "$SKILL" \
    "delivery-pipeline lost the universal plan gate"
  assert_grep 'this gate is universal and has no exception for any intake shape.' "$SKILL" \
    "delivery-pipeline stage 4 lost the no-exception plan gate"
  assert_grep 'No implementation crewmate is ever spawned, for any intake shape, before the captain approves a plan on record.' "$AGENTS" \
    "AGENTS.md lost the universal plan gate hard rule"
  pass "plan gate is a universal hard rule in both the skill and AGENTS.md"
}

test_same_repo_serialization() {
  # Success criterion 3: a second implementation task in a busy repo is held,
  # with a reason naming the blocking task.
  assert_grep 'Two implementation tasks never run in the same repo at once.' "$SKILL" \
    "delivery-pipeline lost the same-repo serialization rule"
  assert_grep 'held with its approval already banked' "$SKILL" \
    "delivery-pipeline lost the banked-approval hold"
  assert_grep 'held - waiting on <repo> #<n> to merge' "$SKILL" \
    "delivery-pipeline lost the hold-reason shape naming the blocking task"
  assert_grep 'Two implementation tasks never run in the same repo at once:' "$AGENTS" \
    "AGENTS.md lost the same-repo serialization rule"
  assert_grep 'a reason naming the blocking task' "$AGENTS" \
    "AGENTS.md hold rule lost the blocking-task reason"
  pass "same-repo serialization holds overflow with a reason naming the blocker"
}

test_research_produces_no_pr() {
  assert_grep 'ends at a report in `data/<id>/report.md`, never a PR.' "$SKILL" \
    "delivery-pipeline no longer ends research at a report with no PR"
  assert_grep '**research** - the approved plan or report was the deliverable; deliver it, no PR, done.' "$SKILL" \
    "delivery-pipeline stage 4 lost the research-no-PR branch"
  pass "research ends at a report, never a PR"
}

test_planners_uncapped() {
  assert_grep 'planners are uncapped' "$SKILL" \
    "delivery-pipeline lost the uncapped-planner rule"
  pass "planners are uncapped and do not bind on the same-repo rule"
}

test_issue_workflow_ranking_carried_verbatim() {
  # The absorbed ranking text must survive so nothing regresses.
  assert_grep '1. Unblocked before blocked (nothing depends on unlanded or unstarted work).' "$SKILL" \
    "ranking rule 1 was not carried forward verbatim"
  assert_grep '2. Dependency-critical next (other issues wait on it).' "$SKILL" \
    "ranking rule 2 was not carried forward verbatim"
  assert_grep '3. Then best value for effort.' "$SKILL" \
    "ranking rule 3 was not carried forward verbatim"
  pass "issue-workflow ranking text carried forward verbatim"
}

test_deviation_threshold_carried_verbatim() {
  assert_grep '- **Minor mechanical deviations** (wording, ordering, naming): adapt, and disclose EVERY one where the delivery path surfaces it - the PR body under "Deviations from approved plan" for a PR-producing mode, or the final ready-branch done summary for local-only.' "$SKILL" \
    "minor-deviation threshold was not carried forward verbatim"
  assert_grep '- **Material deviations** (a different approach, files added or dropped, changed success criteria): STOP, append `needs-decision: plan deviation - {summary}` to the status file, and wait for re-approval.' "$SKILL" \
    "material-deviation threshold was not carried forward verbatim"
  pass "issue-workflow deviation-threshold text carried forward verbatim"
}

test_issue_workflow_fully_absorbed() {
  assert_absent "$ROOT/.agents/skills/issue-workflow/SKILL.md" \
    "issue-workflow skill must be deleted after absorption"
  assert_no_grep "issue-workflow" "$AGENTS" \
    "AGENTS.md still references the removed issue-workflow skill"
  pass "issue-workflow is fully absorbed and no longer referenced"
}

test_skill_present_and_internal
test_all_intake_shapes_enter_one_skill
test_five_stages_present_and_ordered
test_universal_plan_gate
test_same_repo_serialization
test_research_produces_no_pr
test_planners_uncapped
test_issue_workflow_ranking_carried_verbatim
test_deviation_threshold_carried_verbatim
test_issue_workflow_fully_absorbed
