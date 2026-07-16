#!/usr/bin/env bash
# Static contract tests for the /retire-doc skill and its AGENTS.md trigger.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

test_retire_doc_skill_metadata_and_trigger() {
  local skill="$ROOT/.agents/skills/retire-doc/SKILL.md"
  local agents="$ROOT/AGENTS.md"

  assert_present "$skill" "retire-doc skill is missing"
  assert_grep 'name: retire-doc' "$skill" "retire-doc skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$skill" "retire-doc skill must be user-invocable"
  assert_grep '  internal: true' "$skill" "retire-doc skill must be internal"

  # shellcheck disable=SC2016 # Literal backticks must remain unexpanded.
  assert_grep 'When the captain invokes `/retire-doc`, load the `retire-doc` skill' "$agents" \
    "AGENTS.md lost the retire-doc trigger"
  pass "retire-doc skill has internal metadata and one AGENTS.md trigger"
}

test_retire_doc_skill_encodes_safety_procedure() {
  local skill="$ROOT/.agents/skills/retire-doc/SKILL.md"

  # shellcheck disable=SC2016 # Literal backticks/paths must remain unexpanded.
  assert_grep 'data/backups/' "$skill" "retire-doc skill does not require a dated backup tarball"
  assert_grep 'hash' "$skill" "retire-doc skill does not record the backup hash"
  for kind in archive rewrite-claim delete; do
    assert_grep "$kind" "$skill" "retire-doc skill is missing the $kind classification"
  done
  assert_grep 'sign-off' "$skill" "retire-doc skill does not require captain sign-off"
  assert_grep 'wait for the captain' "$skill" "retire-doc skill does not stop and wait at the provenance gate"
  assert_grep 'single source of truth' "$skill" "retire-doc skill does not enforce single-source consolidation"
  assert_grep 'Never leave two full copies' "$skill" "retire-doc skill does not forbid duplicate full copies"
  assert_grep 'never points at a retired path' "$skill" "retire-doc skill does not require the index update"
  assert_grep 'own document-lifecycle SOP' "$skill" "retire-doc skill does not defer to a local SOP"
  pass "retire-doc skill encodes backup, classification, gate, consolidation, index, and local-override steps"
}

test_agents_does_not_duplicate_retire_doc_procedure() {
  local agents="$ROOT/AGENTS.md"

  assert_no_grep 'data/backups/' "$agents" \
    "AGENTS.md duplicates the retire-doc backup mechanics from the skill owner"
  assert_no_grep 'rewrite-claim' "$agents" \
    "AGENTS.md duplicates the retire-doc classification from the skill owner"
  pass "AGENTS.md keeps the retire-doc trigger inline and leaves the procedure to the skill owner"
}

test_retire_doc_skill_metadata_and_trigger
test_retire_doc_skill_encodes_safety_procedure
test_agents_does_not_duplicate_retire_doc_procedure
