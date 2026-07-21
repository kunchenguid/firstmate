#!/usr/bin/env bash
# tests/fm-munra-architecture-intake.test.sh - the Munra architecture-intake skill
# must exist, stay agent-only, cover every required consult point of Munra PR
# #275's model, and be loaded by a real AGENTS.md trigger (a skill nothing loads
# is dead weight).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/munra-architecture-intake/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

test_skill_exists_agent_only() {
  assert_present "$SKILL" "the skill file exists"
  assert_grep "name: munra-architecture-intake" "$SKILL" "skill declares its name"
  assert_grep "user-invocable: false" "$SKILL" "skill is agent-only, not captain-invocable"
  pass "skill exists and is agent-only"
}

test_skill_covers_required_protocol() {
  # Refresh to current origin/master through the existing safe mechanism.
  assert_grep "origin/master" "$SKILL" "skill requires refresh against current origin/master"
  assert_grep "fm-fleet-sync.sh" "$SKILL" "skill reuses the guarded fleet-sync refresh"
  # Flexible selection from current reality, not a stale brief.
  assert_grep "stale" "$SKILL" "skill warns against a stale in-flight brief"
  # Consult the architecture index + change-impact protocol.
  assert_grep "docs/architecture/README.md" "$SKILL" "skill points at the architecture index"
  assert_grep "docs/development/CHANGE_PROTOCOL.md" "$SKILL" "skill points at the change protocol"
  # Source-of-truth boundary.
  assert_grep "source-of-truth boundary" "$SKILL" "skill applies the source-of-truth boundary"
  # Affected invariants + feature surfaces.
  assert_grep "INVARIANTS.md" "$SKILL" "skill names affected invariants"
  assert_grep "features.yaml" "$SKILL" "skill names affected feature surfaces"
  # Test lanes.
  assert_grep "FEATURE_TEST_STRATEGY.md" "$SKILL" "skill selects test lanes"
  pass "skill covers refresh, flexible selection, and every consult point"
}

test_agents_triggers_present() {
  # Section 13 canonical listing.
  assert_grep "\`munra-architecture-intake\` - load before selecting a Munra issue" "$AGENTS" \
    "section 13 lists the skill with a load trigger"
  # Brief-authoring trigger (section 11).
  assert_grep "load \`munra-architecture-intake\` before selecting the issue or writing the brief" "$AGENTS" \
    "the brief section triggers the skill"
  pass "AGENTS.md loads the skill at its intake and brief triggers"
}

test_skill_exists_agent_only
test_skill_covers_required_protocol
test_agents_triggers_present
