#!/usr/bin/env bash
# Behavior tests for bin/fm-project-recipes.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-project-recipes)

recipes_cmd() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$ROOT/bin/fm-project-recipes.sh" "$@" 2>&1
}

make_project() {  # <name>
  local world="$TMP_ROOT/$1"
  mkdir -p "$world/home/config" "$world/project"
  printf '%s\n' "$world"
}

# One catalog entry, dated <date>, in the documented format.
write_recipe() {  # <file> <heading> <date>
  cat >>"$1" <<EOF

## $2
- when: the situation that calls for it
- ask: \`the exact command\`
- gives: what comes back
- notes: a sharp edge the digest deliberately leaves out
<!--r:$3-->
EOF
}

today() { date -u +%Y-%m-%d; }

test_init_creates_the_catalog_and_points_agents_md_at_it() {
  local world out
  world=$(make_project init)
  out=$(recipes_cmd "$world/home" init "$world/project") || fail "init failed: $out"
  assert_present "$world/project/.agents/recipes.md" "init did not create the catalog"
  assert_present "$world/project/AGENTS.md" "init did not establish the project's agent memory"
  assert_grep ".agents/recipes.md" "$world/project/AGENTS.md" "AGENTS.md does not point at the catalog"
  out=$(recipes_cmd "$world/home" init "$world/project") || fail "second init failed: $out"
  assert_contains "$out" "unchanged" "init was not idempotent"
  [ "$(grep -c '\.agents/recipes\.md' "$world/project/AGENTS.md")" = 1 ] ||
    fail "init added a second pointer to AGENTS.md"
  pass "fm-project-recipes.sh: init creates the catalog once and points AGENTS.md at it"
}

test_digest_carries_when_and_ask_but_not_the_rest() {
  local world out
  world=$(make_project digest)
  mkdir -p "$world/project/.agents"
  printf '# Agent recipes\n' >"$world/project/.agents/recipes.md"
  write_recipe "$world/project/.agents/recipes.md" "Find the production bug behind one conversation" "$(today)"
  out=$(recipes_cmd "$world/home" digest "$world/project") || fail "digest failed: $out"
  assert_contains "$out" "Find the production bug behind one conversation" "the capability name is missing from the digest"
  assert_contains "$out" "- when: the situation that calls for it" "the digest dropped when:"
  assert_contains "$out" "- ask: \`the exact command\`" "the digest dropped ask:"
  assert_not_contains "$out" "a sharp edge the digest deliberately leaves out" "the digest carried the full entry"
  pass "fm-project-recipes.sh: the digest carries when and ask only"
}

test_digest_is_bounded_and_says_what_it_left_out() {
  local world out
  world=$(make_project bounded)
  mkdir -p "$world/project/.agents"
  printf '# Agent recipes\n' >"$world/project/.agents/recipes.md"
  write_recipe "$world/project/.agents/recipes.md" "First capability" "$(today)"
  write_recipe "$world/project/.agents/recipes.md" "Second capability" "$(today)"
  write_recipe "$world/project/.agents/recipes.md" "Third capability" "$(today)"
  out=$(recipes_cmd "$world/home" digest "$world/project" --budget 40) || fail "digest failed: $out"
  assert_contains "$out" "First capability" "the bounded digest dropped its first entry"
  assert_not_contains "$out" "Third capability" "the digest exceeded its budget"
  assert_contains "$out" "of 3 capabilities shown" "the digest did not say what it left out"
  pass "fm-project-recipes.sh: the digest stays inside its budget and says what it omitted"
}

test_digest_marks_an_entry_nobody_reverified() {
  local world out
  world=$(make_project digeststale)
  mkdir -p "$world/project/.agents"
  printf '# Agent recipes\n' >"$world/project/.agents/recipes.md"
  write_recipe "$world/project/.agents/recipes.md" "Still true" "$(today)"
  write_recipe "$world/project/.agents/recipes.md" "Nobody checked this in a year" "2020-01-02"
  out=$(recipes_cmd "$world/home" digest "$world/project") || fail "digest failed: $out"
  assert_contains "$out" "Nobody checked this in a year (UNVERIFIED since 2020-01-02" \
    "the digest presented a lapsed recipe as current"
  assert_contains "$out" "## Still true" "the digest dropped the current entry"
  assert_not_contains "$out" "## Still true (UNVERIFIED" "a current entry was marked unverified"
  pass "fm-project-recipes.sh: the digest marks an entry nobody re-verified"
}

test_a_configured_budget_is_read_from_the_home() {
  local world out
  world=$(make_project configured)
  mkdir -p "$world/project/.agents"
  printf '# Agent recipes\n' >"$world/project/.agents/recipes.md"
  write_recipe "$world/project/.agents/recipes.md" "First capability" "$(today)"
  write_recipe "$world/project/.agents/recipes.md" "Second capability" "$(today)"
  printf '40\n' >"$world/home/config/project-recipe-budget"
  out=$(recipes_cmd "$world/home" digest "$world/project") || fail "digest failed: $out"
  assert_not_contains "$out" "Second capability" "the configured budget was ignored"
  assert_contains "$out" "budget is 40 estimated tokens" "the digest did not report the configured budget"
  pass "fm-project-recipes.sh: the home's configured digest budget is honoured"
}

test_an_absent_catalog_costs_nothing() {
  local world out rc
  world=$(make_project absent)
  out=$(recipes_cmd "$world/home" digest "$world/project") && rc=0 || rc=$?
  expect_code 0 "$rc" "digest failed for a project with no catalog"
  [ -z "$out" ] || fail "a project with no catalog produced digest output: $out"
  out=$(recipes_cmd "$world/home" check "$world/project") && rc=0 || rc=$?
  expect_code 0 "$rc" "check failed for a project with no catalog"
  assert_contains "$out" "absent" "check did not report the catalog as absent"
  pass "fm-project-recipes.sh: a project with no catalog costs nothing"
}

test_check_names_an_entry_nobody_reverified() {
  local world out rc
  world=$(make_project stale)
  mkdir -p "$world/project/.agents"
  printf '# Agent recipes\n' >"$world/project/.agents/recipes.md"
  write_recipe "$world/project/.agents/recipes.md" "Still true" "$(today)"
  write_recipe "$world/project/.agents/recipes.md" "Nobody checked this in a year" "2020-01-02"
  out=$(recipes_cmd "$world/home" check "$world/project") && rc=0 || rc=$?
  expect_code 1 "$rc" "a stale entry did not fail the check"
  assert_contains "$out" "STALE: Nobody checked this in a year" "the stale entry was not named"
  assert_not_contains "$out" "STALE: Still true" "a current entry was reported as stale"
  pass "fm-project-recipes.sh: check names an entry nobody re-verified"
}

test_check_names_an_undated_entry() {
  local world out rc
  world=$(make_project undated)
  mkdir -p "$world/project/.agents"
  cat >"$world/project/.agents/recipes.md" <<'EOF'
# Agent recipes

## An entry someone added without a date
- when: whenever
- ask: `something`
EOF
  out=$(recipes_cmd "$world/home" check "$world/project") && rc=0 || rc=$?
  expect_code 1 "$rc" "an undated entry did not fail the check"
  assert_contains "$out" "UNDATED: An entry someone added without a date" "the undated entry was not named"
  pass "fm-project-recipes.sh: check names an entry with no verification date"
}

test_check_reports_a_catalog_that_outgrew_its_budget() {
  local world out rc
  world=$(make_project overbudget)
  mkdir -p "$world/project/.agents"
  printf '# Agent recipes\n' >"$world/project/.agents/recipes.md"
  write_recipe "$world/project/.agents/recipes.md" "One capability" "$(today)"
  out=$(recipes_cmd "$world/home" check "$world/project" --budget 5) && rc=0 || rc=$?
  expect_code 1 "$rc" "a catalog over its budget did not fail the check"
  assert_contains "$out" "OVER_BUDGET" "the over-budget catalog was not reported"
  assert_contains "$out" "consolidate" "the report did not say what to do about it"
  pass "fm-project-recipes.sh: check reports a catalog that outgrew its digest budget"
}

test_init_creates_the_catalog_and_points_agents_md_at_it
test_digest_carries_when_and_ask_but_not_the_rest
test_digest_is_bounded_and_says_what_it_left_out
test_a_configured_budget_is_read_from_the_home
test_an_absent_catalog_costs_nothing
test_check_names_an_entry_nobody_reverified
test_check_names_an_undated_entry
test_check_reports_a_catalog_that_outgrew_its_budget
test_digest_marks_an_entry_nobody_reverified
