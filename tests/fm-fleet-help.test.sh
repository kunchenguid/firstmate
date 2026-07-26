#!/usr/bin/env bash
# Static contract tests for the internal /fleet-help navigator skill.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/fleet-help/SKILL.md"
CATALOG="$ROOT/.agents/skills/fleet-help/fleet-catalog.json"
README="$ROOT/README.md"

test_fleet_help_metadata_and_readme() {
  assert_present "$SKILL" "fleet-help skill is missing"
  assert_grep 'name: fleet-help' "$SKILL" "fleet-help skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$SKILL" "fleet-help skill is not user-invocable"
  assert_grep '  internal: true' "$SKILL" "fleet-help skill is not internal"
  assert_absent "$ROOT/skills/fleet-help" "fleet-help must not exist in the public installer-facing skills directory"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  assert_grep '| `/fleet-help`' "$README" "README built-in skills table does not list /fleet-help"
  pass "fleet-help is internal, user-invocable, and documented with built-in skills"
}

test_fleet_help_is_read_only_navigator() {
  assert_grep 'This is a navigator, not a workflow runner.' "$SKILL" \
    "fleet-help does not declare the navigator boundary"
  assert_grep 'This skill is read-only over fleet state.' "$SKILL" \
    "fleet-help does not declare read-only state access"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  assert_grep 'Do not spawn workers, steer workers, dispatch queued work, merge PRs, update Linear, update the backlog, write reports, arm supervision, or mutate `state/` or `data/` as a side effect of help.' "$SKILL" \
    "fleet-help lost the no-mutation and no-dispatch boundary"
  assert_grep 'If the best next step is actionable, say what the captain can ask for and stop.' "$SKILL" \
    "fleet-help does not stop before acting on recommendations"
  assert_grep 'Do not install BMAD, copy BMAD personas, or present named role menus.' "$SKILL" \
    "fleet-help does not preserve the no-BMAD and no-persona boundary"
  pass "fleet-help is a read-only guide rather than a runner"
}

test_fleet_help_reads_live_sources_not_status_logs() {
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  assert_grep '[`fleet-catalog.json`](fleet-catalog.json)' "$SKILL" \
    "fleet-help does not point to its machine-readable catalog"
  assert_grep 'bin/fm-bearings-snapshot.sh --json' "$SKILL" \
    "fleet-help does not use the bounded bearings snapshot"
  assert_grep 'bin/fm-fleet-snapshot.sh --json' "$SKILL" \
    "fleet-help does not define the canonical snapshot fallback"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  assert_grep 'Do not parse `state/*.status` directly because those files are append-only event history, not current state.' "$SKILL" \
    "fleet-help must not infer current state from raw status logs"
  pass "fleet-help uses live structured sources instead of raw status history"
}

test_fleet_catalog_generated_skills_match_user_invocable_internal_skills() {
  local expected actual skill id
  assert_present "$CATALOG" "fleet-help catalog is missing"
  jq -e '.schema == "fleet-help-catalog.v1"' "$CATALOG" >/dev/null \
    || fail "fleet-help catalog has the wrong schema or invalid JSON"

  expected=$(
    for skill in "$ROOT"/.agents/skills/*/SKILL.md; do
      id=$(basename "$(dirname "$skill")")
      if awk '
        /^---$/ { markers += 1; next }
        markers == 1 && /^user-invocable: true$/ { user = 1 }
        markers == 1 && /^  internal: true$/ { internal = 1 }
        END { exit !(user && internal) }
      ' "$skill"; then
        printf '%s\n' "$id"
      fi
    done | LC_ALL=C sort
  )
  actual=$(jq -r '.generated_skills[].id' "$CATALOG" | LC_ALL=C sort)
  [ "$actual" = "$expected" ] || fail "fleet-help generated skill catalog is out of sync"$'\n'"expected:"$'\n'"$expected"$'\n'"actual:"$'\n'"$actual"
  pass "fleet-help generated skill catalog matches internal user-invocable skills"
}

test_fleet_catalog_covers_script_owned_operations() {
  jq -e '
    (.lifecycle_operations | length) >= 8 and
    all(.lifecycle_operations[];
      (.id | type) == "string" and
      (.display | type) == "string" and
      (.summary | type) == "string" and
      (.owners | type) == "array" and
      (.sample_prompts | type) == "array" and
      (.sample_prompts | length) > 0 and
      (.mutates_when_requested_outside_help | type) == "array") and
    ([.lifecycle_operations[].id] | index("ship-task")) and
    ([.lifecycle_operations[].id] | index("scout-investigation")) and
    ([.lifecycle_operations[].id] | index("linear-backed-work")) and
    ([.lifecycle_operations[].id] | index("secondmate-routing"))
  ' "$CATALOG" >/dev/null || fail "fleet-help catalog does not cover the required script-owned operations"
  pass "fleet-help catalog includes hand-authored lifecycle operations"
}

test_fleet_help_metadata_and_readme
test_fleet_help_is_read_only_navigator
test_fleet_help_reads_live_sources_not_status_logs
test_fleet_catalog_generated_skills_match_user_invocable_internal_skills
test_fleet_catalog_covers_script_owned_operations
