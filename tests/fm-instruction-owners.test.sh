#!/usr/bin/env bash
# Static contract tests for conditional instruction owners introduced before the
# AGENTS.md reduction pass.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIAG="$ROOT/.agents/skills/diagnostic-reasoning/SKILL.md"
PROJECT="$ROOT/.agents/skills/project-management/SKILL.md"
HARNESS="$ROOT/.agents/skills/harness-adapters/SKILL.md"
CODING="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
RECOVERY="$ROOT/.agents/skills/stuck-crewmate-recovery/SKILL.md"
CONFIG="$ROOT/docs/configuration.md"

test_new_skill_metadata_and_triggers() {
  local skill name count
  for pair in "diagnostic-reasoning:$DIAG" "project-management:$PROJECT"; do
    name=${pair%%:*}
    skill=${pair#*:}
    assert_present "$skill" "$name skill is missing"
    assert_grep "name: $name" "$skill" "$name skill metadata has the wrong name"
    assert_grep "user-invocable: false" "$skill" "$name skill must not be user-invocable"
    assert_grep "  internal: true" "$skill" "$name skill must be internal"
    count=$(grep -Fc -- "- \`$name\` -" "$ROOT/AGENTS.md")
    [ "$count" -eq 1 ] || fail "$name must have exactly one AGENTS.md trigger entry, found $count"
  done
  assert_grep 'Use before scoping a reported bug and before acting on a diagnostic report.' "$DIAG" \
    "diagnostic skill metadata lost its precise load trigger"
  assert_grep '`diagnostic-reasoning` - load before scoping a reported bug and before acting on a diagnostic report.' "$ROOT/AGENTS.md" \
    "AGENTS.md lost the diagnostic-reasoning trigger"
  assert_grep 'Use before adding, creating, removing, or initializing a project.' "$PROJECT" \
    "project-management skill metadata lost its precise load trigger"
  assert_grep '`project-management` - load before adding, creating, removing, or initializing a project.' "$ROOT/AGENTS.md" \
    "AGENTS.md lost the project-management trigger"
  pass "new internal skills have one precise AGENTS.md trigger each"
}

test_diagnostic_owner_covers_causal_procedure() {
  assert_grep "single owner of Firstmate's bug-diagnosis reasoning procedure" "$DIAG" \
    "diagnostic skill does not declare ownership"
  for phrase in \
    "end-to-end reproduction aligned with the real user path" \
    "initiating trigger" \
    "masking condition" \
    "visible symptom" \
    "proven path" \
    "relevant history" \
    "smallest counterfactual" \
    "disconfirming evidence"; do
    assert_grep "$phrase" "$DIAG" "diagnostic owner is missing '$phrase'"
  done
  assert_grep "evidence, not authorization to change code" "$DIAG" \
    "diagnostic owner lost the diagnosis-only authority boundary"
  pass "diagnostic-reasoning owns the approved evidence procedure"
}

test_project_management_owner_covers_guarded_operations() {
  assert_grep "single owner of Firstmate's project-management procedure" "$PROJECT" \
    "project-management skill does not declare ownership"
  for phrase in \
    'bin/fm-project-mode.sh' \
    '`no-mistakes`' \
    '`direct-PR`' \
    '`local-only`' \
    'Default it off' \
    'Creating a GitHub repository is outward-facing.' \
    "captain's explicit consent" \
    'Never issue a raw removal command from Firstmate.' \
    'no-mistakes init && no-mistakes doctor'; do
    assert_grep "$phrase" "$PROJECT" "project-management owner is missing '$phrase'"
  done
  pass "project-management owns registry, delivery posture, consent, initialization, and removal safety"
}

test_generic_effort_fallback_respects_precedence() {
  local section
  section=$(awk '
    /^Effort precedence is / { found = 1 }
    found && /^The supported launch-profile flags / { exit }
    found { print }
  ' "$HARNESS")
  assert_contains "$section" "explicit per-task captain instruction first" \
    "effort rubric lost per-task captain precedence"
  assert_contains "$section" "standing dispatch profile or secondmate pin" \
    "effort rubric lost standing configuration precedence"
  assert_contains "$section" 'Use `low` for well-understood work' \
    "effort rubric lost its low fallback"
  assert_contains "$section" '`xhigh` for ambiguous investigation or design' \
    "effort rubric lost its xhigh fallback"
  assert_contains "$section" "Choose intermediate levels proportionally" \
    "effort rubric lost proportional intermediate levels"
  assert_contains "$section" 'Never select `max` from this fallback' \
    "effort rubric permits max without an explicit captain preference"
  if printf '%s\n' "$section" | grep -qi sol; then
    fail "generic effort fallback must not contain Sol-specific policy"
  fi
  pass "generic effort fallback applies only below captain and standing configuration"
}

test_shared_authoring_requirements_are_owned() {
  assert_grep "review every affected supported primary harness and runtime backend" "$CODING" \
    "coding guidance lost the supported compatibility matrix review"
  assert_grep "prefer deterministic and idempotent enforcement over relying on agent memory alone" "$CODING" \
    "coding guidance lost deterministic idempotent enforcement"
  assert_grep "critical safety, routing, startup, and supervision infrastructure" "$CODING" \
    "coding guidance lost the critical infrastructure scope"
  pass "firstmate-coding-guidelines owns compatibility review and deterministic enforcement"
}

test_state_startup_and_ordinary_recovery_placement() {
  assert_grep "single owner of the top-level operational-home layout" "$CONFIG" \
    "configuration docs do not own the operational state layout"
  assert_grep "header is the single owner of session-start ordering" "$CONFIG" \
    "session-start mechanism is not assigned to the script header"
  assert_grep "Ordinary dead-direct-report recovery is owned by \`stuck-crewmate-recovery\`" "$CONFIG" \
    "D05 ordinary recovery placement is missing"
  assert_grep "## Session-start reconciliation for a dead ordinary direct report" "$RECOVERY" \
    "stuck-crewmate-recovery lacks the dead ordinary direct-report procedure"
  assert_grep "treehouse status" "$RECOVERY" \
    "ordinary recovery lost treehouse inventory inspection"
  assert_grep "recorded \`orca_worktree_id=\` and \`terminal=\`" "$RECOVERY" \
    "ordinary recovery lost Orca inventory inspection"
  assert_grep "session-start digest reports an ordinary direct report's endpoint dead or its metadata has no window" "$ROOT/AGENTS.md" \
    "AGENTS.md does not trigger ordinary dead-report recovery"
  pass "state, startup, and ordinary recovery have focused owners and triggers"
}

test_new_skill_metadata_and_triggers
test_diagnostic_owner_covers_causal_procedure
test_project_management_owner_covers_guarded_operations
test_generic_effort_fallback_respects_precedence
test_shared_authoring_requirements_are_owned
test_state_startup_and_ordinary_recovery_placement
