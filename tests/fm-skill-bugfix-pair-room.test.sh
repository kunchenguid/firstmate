#!/usr/bin/env bash
# Behavior tests for the bugfix-pair-room skill and its load triggers.
set -u

export LC_ALL=C

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/bugfix-pair-room/SKILL.md"
CHARTER_TEMPLATE="$ROOT/.agents/skills/secondmate-provisioning/templates/shipwright-charter.md"
# shellcheck disable=SC2016 # Backticks are literal trigger markup.
TRIGGER='`bugfix-pair-room` before dispatching a bug the captain found in the flow or any bug brief without a proven root cause.'

test_skill_contract() {
  assert_present "$SKILL" "bugfix-pair-room skill is missing"
  assert_grep 'name: bugfix-pair-room' "$SKILL" "skill frontmatter is missing name"
  assert_grep 'description:' "$SKILL" "skill frontmatter is missing description"
  assert_grep 'user-invocable: false' "$SKILL" "skill frontmatter is missing user-invocable"
  assert_grep 'metadata:' "$SKILL" "skill frontmatter is missing metadata"
  assert_grep 'internal: true' "$SKILL" "skill frontmatter is missing metadata.internal"
  assert_grep 'bin/fm-room.sh' "$SKILL" "skill does not reference bin/fm-room.sh"
  assert_grep 'diagnostic-reasoning' "$SKILL" "skill does not reference diagnostic-reasoning"
  assert_grep 'bin/fm-test-run.sh --changed' "$SKILL" "skill does not reference changed-test selection"
  pass "bugfix-pair-room: skill contract and frontmatter are present"
}

test_agents_trigger() {
  local section_13
  section_13=$(awk '/^## 13\./ { capture=1; next } /^## 14\./ { capture=0 } capture { print }' "$ROOT/AGENTS.md")
  assert_contains "$section_13" "$TRIGGER" \
    "AGENTS.md section 13 does not name the bugfix-pair-room load trigger"
  pass "bugfix-pair-room: AGENTS.md names the load trigger"
}

test_shipwright_charter_template() {
  assert_present "$CHARTER_TEMPLATE" "shipwright charter template is missing"
  assert_contains "$(cat "$CHARTER_TEMPLATE")" "$TRIGGER" \
    "shipwright charter template does not carry the bugfix-pair-room load trigger"
  pass "bugfix-pair-room: shipwright charter template carries the load trigger"
}

test_skill_contract
test_agents_trigger
test_shipwright_charter_template
