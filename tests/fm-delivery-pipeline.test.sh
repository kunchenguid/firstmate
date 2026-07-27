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
  assert_grep 'Two implementation tasks do not run in the same repo at once, save for the carve-out `delivery-pipeline` owns:' "$AGENTS" \
    "AGENTS.md lost the same-repo serialization rule or its deferral to the skill"
  assert_grep 'a reason naming the blocking task' "$AGENTS" \
    "AGENTS.md hold rule lost the blocking-task reason"
  pass "same-repo serialization holds overflow with a reason naming the blocker"
}

test_research_produces_no_pr() {
  assert_grep 'ends at a report in `data/<scout-id>/report.md`, never a PR.' "$SKILL" \
    "delivery-pipeline no longer ends research at a report with no PR"
  assert_grep '**research** - dispatch exactly one scout crewmate to execute the approved plan; its report is the deliverable and there is no PR.' "$SKILL" \
    "delivery-pipeline stage 4 lost the research-no-PR branch"
  assert_grep 'bin/fm-brief.sh <scout-id> <repo> --scout' "$SKILL" \
    "delivery-pipeline stage 4 never dispatches the scout that writes the research report"
  assert_grep 'The scout writes `data/<scout-id>/report.md`; deliver that report to the captain and stop, because research never enters stage 5.' "$SKILL" \
    "delivery-pipeline research path lost its report deliverable"
  assert_grep 'Stage 5 is implementation-only; a research task already ended at its report in stage 4 and never reaches here.' "$SKILL" \
    "delivery-pipeline stage 5 no longer excludes research"
  pass "research dispatches a scout and ends at its report, never a PR"
}

test_planner_satisfies_scout_deliverable() {
  assert_grep 'A planner is a scout, scaffolded with `bin/fm-brief.sh <planner-id> <repo> --scout`.' "$SKILL" \
    "delivery-pipeline no longer states the planner's brief shape"
  assert_grep '`--plan` applies only to ship briefs' "$SKILL" \
    "delivery-pipeline lost the ship-only --plan constraint"
  assert_grep 'and the `data/<planner-id>/report.md` the generated brief already names' "$SKILL" \
    "planner brief no longer satisfies the scout report deliverable"
  pass "planner is briefed as a scout that leaves the report teardown requires"
}

test_planner_plan_path_is_absolute() {
  # A planner is a scout in a scratch worktree, so a relative plan path lands in
  # the worktree teardown discards.
  assert_grep 'the plan at `<this-firstmate-home>/data/<planner-id>/plan.html`' "$SKILL" \
    "the planner's plan artifact path is not stated in absolute form"
  assert_grep 'Name the plan path in absolute form every time you hand it to a planner' "$SKILL" \
    "delivery-pipeline lost the absolute-plan-path rule for planners"
  assert_grep 'The plan is one live artifact per task at `<this-firstmate-home>/data/<planner-id>/plan.html`' "$SKILL" \
    "the canonical plan location is no longer absolute"
  pass "the planner's plan path is absolute at every mention"
}

test_plan_sections_depend_on_intake_shape() {
  assert_grep 'Every plan artifact, whatever the intake shape, must contain at minimum:' "$SKILL" \
    "delivery-pipeline lost the shape-independent plan minimum"
  assert_grep 'An implementation plan must also contain:' "$SKILL" \
    "the implementation-only plan sections are no longer marked implementation-only"
  assert_grep 'A research or design plan writes no code and never reaches stage 5, so it omits those four as inapplicable and must instead contain:' "$SKILL" \
    "a research plan is still forced to carry an implementer's files table"
  assert_grep 'Deviation threshold, carried verbatim into every implementation plan artifact:' "$SKILL" \
    "stage 5 still demands the deviation threshold in plans stage 3 tells research to omit it from"
  assert_grep '- **Report outline** - the sections `data/<scout-id>/report.md` must carry.' "$SKILL" \
    "the research plan shape lost its report outline"
  pass "plan minimums are conditional on the intake shape"
}

test_plan_is_copied_to_the_ship_task() {
  assert_grep "Copy the approved plan from the planner's \`<this-firstmate-home>/data/<planner-id>/plan.html\` to the ship task's \`data/<ship-id>/plan.html\`" "$SKILL" \
    "delivery-pipeline no longer copies the approved plan into the ship task's data dir"
  assert_grep 'bin/fm-brief.sh <ship-id> <repo> --plan data/<ship-id>/plan.html' "$SKILL" \
    "delivery-pipeline lost the disambiguated ship-task brief invocation"
  assert_no_grep 'data/<id>/plan.html' "$SKILL" \
    "delivery-pipeline still uses the ambiguous <id> placeholder for the plan artifact"
  pass "planner id and ship id are distinct and the plan is copied before briefing"
}

test_hold_is_durable_and_bounded() {
  # tasks-axi hold fails NOT_FOUND on an id the backlog does not carry, so the
  # work item must be filed before the hold.
  assert_grep 'File the work item on the backlog first and hold it only then' "$SKILL" \
    "the hold is still recorded before the backlog item it targets exists"
  assert_grep 'tasks-axi hold <ship-id> --reason "held - waiting on <repo> #<n> to merge" --kind load' "$SKILL" \
    "a held task is not recorded durably on the backlog with the capacity hold kind"
  assert_no_grep 'to merge" --kind captain' "$SKILL" \
    "a slot wait is still recorded as a captain decision hold"
  assert_grep 'the durable re-evaluation of queued work after every teardown and heartbeat enforces the bound' "$SKILL" \
    "delivery-pipeline lost the queue-age bound on holds or its durable mechanism"
  assert_grep 'when it finds a held item older than 24 hours it surfaces it to the captain with the blocking PR' "$SKILL" \
    "delivery-pipeline lost the 24-hour escalation of an aged hold"
  assert_grep "Read that age from the held item's \`created\` timestamp" "$SKILL" \
    "the queue-age bound names no readable backlog field to measure the age from"
  assert_grep 'escalate it as a plan deviation for re-approval rather than starting silently on a stale plan.' "$SKILL" \
    "delivery-pipeline lost the banked-plan re-validation before auto-start"
  pass "holds are durable, age-bounded, and re-validated before auto-start"
}

test_p0_serialization_override() {
  assert_grep 'The single exception is a task the captain has explicitly flagged P0' "$SKILL" \
    "delivery-pipeline lost the explicit P0 carve-out to the same-repo cap"
  assert_grep 'Firstmate never opens that exception from its own read of urgency, so absent an explicit P0 flag the default stands.' "$SKILL" \
    "delivery-pipeline lost the rule that only the captain opens the P0 carve-out"
  assert_no_grep 'research alongside code, urgency - stays' "$SKILL" \
    "delivery-pipeline still contradicts itself by leaving urgency to firstmate's judgement"
  pass "the same-repo default and its P0 carve-out read consistently"
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
test_planner_satisfies_scout_deliverable
test_planner_plan_path_is_absolute
test_plan_sections_depend_on_intake_shape
test_plan_is_copied_to_the_ship_task
test_hold_is_durable_and_bounded
test_p0_serialization_override
test_planners_uncapped
test_issue_workflow_ranking_carried_verbatim
test_deviation_threshold_carried_verbatim
test_issue_workflow_fully_absorbed
