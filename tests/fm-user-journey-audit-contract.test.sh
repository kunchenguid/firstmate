#!/usr/bin/env bash
# Contract tests for the /user-journey-audit captain-invocable skill.
# These pin the load-bearing guarantees so a later edit cannot quietly drop the
# trigger, the dual-persona isolation, the headless default, the evidence/report
# requirements, or the captain-approval gate before any task is filed.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/user-journey-audit/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

test_skill_exists_and_is_captain_invocable() {
  assert_present "$SKILL" "user-journey-audit SKILL.md is missing"
  assert_grep 'name: user-journey-audit' "$SKILL" "skill name frontmatter is missing"
  assert_grep 'user-invocable: true' "$SKILL" "skill is not marked captain-invocable"
  assert_grep 'internal: true' "$SKILL" "skill is missing metadata.internal for installer hiding"
  pass "skill exists and is a captain-invocable internal skill"
}

test_trigger() {
  # Triggers on the slash command and on the natural-language new-and-returning ask.
  assert_grep '/user-journey-audit' "$SKILL" "skill does not declare the /user-journey-audit trigger"
  assert_grep 'new and returning user' "$SKILL" "skill does not trigger on auditing as a new and returning user"
  pass "trigger covers the slash command and the new/returning-user ask"
}

test_dual_persona_isolation() {
  # Two personas, and their state must be genuinely isolated from each other.
  assert_grep 'New user (clean state)' "$SKILL" "skill does not define a clean-state new-user persona"
  assert_grep 'Returning user (established state)' "$SKILL" "skill does not define an established-state returning-user persona"
  assert_grep 'strictly isolated' "$SKILL" "skill does not require the two personas to stay strictly isolated"
  assert_grep 'Never reuse the new user' "$SKILL" "skill does not forbid reusing new-user context for the returning user"
  pass "dual personas are defined and kept isolated"
}

test_headless_default() {
  assert_grep 'Headless by default' "$SKILL" "skill does not default to headless browsing"
  assert_grep 'visible headed mode only when the captain explicitly asks' "$SKILL" "skill does not gate headed mode on explicit captain request"
  pass "browser automation is headless by default, headed only on request"
}

test_local_instance_default() {
  assert_grep 'Local test instance by default' "$SKILL" "skill does not default to a local test instance"
  assert_grep 'never production' "$SKILL" "skill does not forbid auditing production by default"
  assert_grep 'explicitly authorizes' "$SKILL" "skill does not require explicit authorization for production/real-user scope"
  pass "audits a local instance by default and never mutates production without authorization"
}

test_scout_brief_receives_full_audit_contract() {
  assert_grep "resolved scope from section 1, the Safety rails, and the full audit methodology in sections 3 through 10" "$SKILL" "scout brief does not receive the safety rails and sections 3 through 10"
  pass "scout brief receives the safety rails and sections 3 through 10"
}

test_evidence_and_report_requirements() {
  assert_grep 'Screenshots' "$SKILL" "skill does not require screenshot evidence"
  assert_grep 'reproduction steps' "$SKILL" "skill does not require reproduction steps"
  assert_grep 'Avoid capturing secrets' "$SKILL" "skill does not require avoiding secret capture"
  assert_grep 'data/<id>/report.md' "$SKILL" "skill does not write the report to the scout report path"
  assert_grep 'data/<id>/evidence/' "$SKILL" "skill does not preserve supporting evidence outside the disposable worktree"
  # Three separated finding classes with the scoring fields.
  assert_grep 'Defects' "$SKILL" "report does not separate defects"
  assert_grep 'UX improvements' "$SKILL" "report does not separate UX improvements"
  assert_grep 'Potential features' "$SKILL" "report does not separate potential features"
  assert_grep 'Recommended acceptance criteria' "$SKILL" "report items lack recommended acceptance criteria"
  # Findings are rendered on the fleet report-viewer surface with a chat summary.
  assert_grep 'lavish-axi' "$SKILL" "skill does not render findings on the lavish report surface"
  pass "evidence, secret-avoidance, prioritized report classes, and rendered presentation are required"
}

test_feature_ideas_are_grounded() {
  assert_grep 'only where a real need surfaced during a journey' "$SKILL" "feature ideas are not grounded in journey needs"
  assert_grep 'Do not brainstorm ungrounded features' "$SKILL" "skill does not forbid ungrounded brainstorming"
  pass "feature ideas are grounded in journey evidence, not free brainstorm"
}

test_captain_approval_gate_before_task_creation() {
  assert_grep 'never files, dispatches, or starts an implementation task on its own' "$SKILL" "skill does not forbid auto-filing implementation tasks"
  assert_grep 'Only after the captain explicitly approves' "$SKILL" "skill does not gate task filing on explicit captain approval"
  assert_grep "Approval of one item is not approval of the rest" "$SKILL" "skill does not scope approval to named items"
  pass "task creation is gated behind explicit captain approval"
}

test_completed_scout_is_torn_down_before_approval_wait() {
  local teardown_line approval_line
  teardown_line=$(grep -n 'tear the scout down' "$SKILL" | head -1 | cut -d: -f1)
  approval_line=$(grep -n '^## 11\. Captain approval gate' "$SKILL" | cut -d: -f1)
  [ -n "$teardown_line" ] || fail "skill does not tear down the completed scout"
  [ -n "$approval_line" ] || fail "skill is missing the captain approval gate"
  [ "$teardown_line" -lt "$approval_line" ] || fail "completed scout remains alive while waiting for implementation approval"
  pass "completed scout is torn down before waiting for implementation approval"
}

test_idle_not_recurring() {
  assert_grep 'never schedule, repeat, or self-initiate an audit' "$SKILL" "skill does not forbid recurring or self-directed audits"
  pass "skill stays idle and never self-schedules"
}

test_agents_md_declares_load_trigger() {
  # Trigger hygiene: the captain-approved load trigger must stay declared inline.
  # Match a distinctive backtick-free slice of the trigger sentence (SC2016-safe).
  assert_grep 'a two-persona, evidence-backed audit as a scout' "$AGENTS" "AGENTS.md does not declare the user-journey-audit load trigger"
  pass "AGENTS.md declares the user-journey-audit load trigger"
}

test_skill_exists_and_is_captain_invocable
test_trigger
test_dual_persona_isolation
test_headless_default
test_local_instance_default
test_scout_brief_receives_full_audit_contract
test_evidence_and_report_requirements
test_feature_ideas_are_grounded
test_captain_approval_gate_before_task_creation
test_completed_scout_is_torn_down_before_approval_wait
test_idle_not_recurring
test_agents_md_declares_load_trigger
