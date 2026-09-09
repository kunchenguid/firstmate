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

set_budget() {  # <world> <tokens>
  printf '%s\n' "$2" >"$1/home/config/project-recipe-budget"
}

# init is the one command that writes into a project directory, and that
# directory can be a live folder someone else is mid-operation in.
test_init_refuses_while_a_git_operation_is_in_flight() {
  local world out rc gitdir
  world=$(make_project inflight)
  git init -q "$world/project"
  gitdir=$(git -C "$world/project" rev-parse --absolute-git-dir)
  : >"$gitdir/index.lock"
  out=$(recipes_cmd "$world/home" init "$world/project") && rc=0 || rc=$?
  expect_code 1 "$rc" "init wrote into a directory someone was mid-operation in"
  assert_contains "$out" "git operation is in flight" "the refusal did not name the cause"
  assert_absent "$world/project/.agents/recipes.md" "the refused init still created a catalog"
  assert_absent "$world/project/AGENTS.md" "the refused init still wrote agent memory"
  rm -f "$gitdir/index.lock"
  out=$(recipes_cmd "$world/home" init "$world/project") || fail "init failed once the operation ended: $out"
  assert_present "$world/project/.agents/recipes.md" "init did not create the catalog once the folder was free"
  pass "fm-project-recipes.sh: init refuses while a git operation is in flight"
}

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

# The captain asked for the pointer "dentro de su respectivo claude.md": a
# project that keeps its own words in CLAUDE.md gets the pointer there, in
# place, and never has that file renamed out from under him.
test_init_points_an_existing_claude_md_without_renaming_it() {
  local world out
  world=$(make_project claudeonly)
  printf '# AutoEvals\n\nTwenty kilobytes of the captain'"'"'s own operating context.\n' >"$world/project/CLAUDE.md"
  out=$(recipes_cmd "$world/home" init "$world/project") || fail "init failed on a project that keeps a real CLAUDE.md: $out"
  assert_present "$world/project/.agents/recipes.md" "init did not create the catalog"
  assert_absent "$world/project/AGENTS.md" "init imposed an AGENTS.md on a project that keeps its memory in CLAUDE.md"
  assert_grep "Twenty kilobytes of the captain's own operating context" "$world/project/CLAUDE.md" \
    "init lost the captain's own CLAUDE.md content"
  assert_grep ".agents/recipes.md" "$world/project/CLAUDE.md" "CLAUDE.md does not point at the catalog"
  out=$(recipes_cmd "$world/home" init "$world/project") || fail "second init failed: $out"
  [ "$(grep -c '\.agents/recipes\.md' "$world/project/CLAUDE.md")" = 1 ] ||
    fail "init added a second pointer to CLAUDE.md"
  pass "fm-project-recipes.sh: init points an existing CLAUDE.md at the catalog without renaming it"
}

# AutoEvals today: AGENTS.md and CLAUDE.md coexist as distinct real files and
# CLAUDE.md does not import AGENTS.md. Workers read AGENTS.md and the captain's
# own sessions load CLAUDE.md, so the catalog has to be reachable from both.
test_init_succeeds_when_agents_and_claude_are_both_real_files() {
  local world out
  world=$(make_project bothreal)
  printf '# Agent memory\n\nWritten by an earlier worker.\n' >"$world/project/AGENTS.md"
  printf '# Operating context\n\nThe captain'"'"'s own words, not a pointer. See AGENTS.md for the rest.\n' >"$world/project/CLAUDE.md"
  out=$(recipes_cmd "$world/home" init "$world/project") || fail "init died on a project holding both AGENTS.md and CLAUDE.md: $out"
  assert_present "$world/project/.agents/recipes.md" "init did not create the catalog"
  assert_grep ".agents/recipes.md" "$world/project/AGENTS.md" "AGENTS.md does not point at the catalog"
  assert_grep "Written by an earlier worker" "$world/project/AGENTS.md" "init lost the existing AGENTS.md content"
  assert_grep ".agents/recipes.md" "$world/project/CLAUDE.md" \
    "a CLAUDE.md that does not import AGENTS.md was left without a pointer, so the captain's own sessions cannot reach the catalog"
  assert_grep "The captain's own words, not a pointer." "$world/project/CLAUDE.md" "init lost the captain's own CLAUDE.md content"
  out=$(recipes_cmd "$world/home" init "$world/project") || fail "second init failed: $out"
  [ "$(grep -c '\.agents/recipes\.md' "$world/project/AGENTS.md")" = 1 ] ||
    fail "init added a second pointer to AGENTS.md"
  [ "$(grep -c '\.agents/recipes\.md' "$world/project/CLAUDE.md")" = 1 ] ||
    fail "init added a second pointer to CLAUDE.md"
  pass "fm-project-recipes.sh: init points both real memory files at the catalog when CLAUDE.md does not import AGENTS.md"
}

# When CLAUDE.md imports AGENTS.md, everything in AGENTS.md is already loaded
# by the captain's sessions, so the pointer in AGENTS.md alone reaches them and
# CLAUDE.md stays untouched.
test_init_leaves_a_claude_md_that_imports_agents_md_untouched() {
  local world out claude_before
  world=$(make_project imports)
  printf '# Agent memory\n\nWritten by an earlier worker.\n' >"$world/project/AGENTS.md"
  printf '<!-- Points Claude at AGENTS.md via import; edit AGENTS.md, not this file. -->\n@AGENTS.md\n' >"$world/project/CLAUDE.md"
  claude_before=$(cat "$world/project/CLAUDE.md")
  out=$(recipes_cmd "$world/home" init "$world/project") || fail "init failed: $out"
  assert_grep ".agents/recipes.md" "$world/project/AGENTS.md" "AGENTS.md does not point at the catalog"
  [ "$(cat "$world/project/CLAUDE.md")" = "$claude_before" ] ||
    fail "init touched a CLAUDE.md that already imports AGENTS.md"
  pass "fm-project-recipes.sh: init leaves a CLAUDE.md that imports AGENTS.md untouched"
}

test_digest_names_the_catalog_by_absolute_path_on_request() {
  local world out home
  world=$(make_project absolute)
  mkdir -p "$world/project/.agents"
  printf '# Agent recipes\n' >"$world/project/.agents/recipes.md"
  write_recipe "$world/project/.agents/recipes.md" "First capability" "$(today)"
  write_recipe "$world/project/.agents/recipes.md" "Second capability" "$(today)"
  home=$(cd "$world/project" && pwd -P)
  set_budget "$world" 40
  out=$(recipes_cmd "$world/home" digest "$world/project" --absolute) || fail "digest failed: $out"
  assert_contains "$out" "is in \`$home/.agents/recipes.md\`" "the digest did not name the catalog by its absolute path"
  assert_contains "$out" "read \`$home/.agents/recipes.md\` for the rest" \
    "the omission note did not name the catalog by its absolute path"
  out=$(recipes_cmd "$world/home" digest "$world/project") || fail "digest failed: $out"
  assert_contains "$out" "is in \`.agents/recipes.md\`" "the plain digest stopped naming the catalog relatively"
  pass "fm-project-recipes.sh: digest names the catalog by absolute path on request"
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
  set_budget "$world" 40
  out=$(recipes_cmd "$world/home" digest "$world/project") || fail "digest failed: $out"
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

# check measures what the digest renders, not the catalog file: a catalog whose
# entries carry long gives:/notes: still fits the digest, and check must agree
# with digest about that.
test_check_reports_a_catalog_that_outgrew_its_budget() {
  local world out rc
  world=$(make_project overbudget)
  mkdir -p "$world/project/.agents"
  printf '# Agent recipes\n' >"$world/project/.agents/recipes.md"
  write_recipe "$world/project/.agents/recipes.md" "First capability" "$(today)"
  write_recipe "$world/project/.agents/recipes.md" "Second capability" "$(today)"
  write_recipe "$world/project/.agents/recipes.md" "Third capability" "$(today)"
  set_budget "$world" 40
  out=$(recipes_cmd "$world/home" check "$world/project") && rc=0 || rc=$?
  expect_code 1 "$rc" "a catalog whose digest cannot carry every entry did not fail the check"
  assert_contains "$out" "OVER_BUDGET" "the over-budget catalog was not reported"
  assert_contains "$out" "digest_shown: 1 of 3" "the check did not report how many entries the digest carries"
  assert_contains "$out" "consolidate" "the report did not say what to do about it"
  pass "fm-project-recipes.sh: check reports a catalog whose digest cannot carry every entry"
}

test_check_agrees_with_digest_when_only_the_full_entries_are_long() {
  local world out rc i
  world=$(make_project longnotes)
  mkdir -p "$world/project/.agents"
  printf '# Agent recipes\n' >"$world/project/.agents/recipes.md"
  i=0
  while [ "$i" -lt 6 ]; do
    cat >>"$world/project/.agents/recipes.md" <<EOF

## Capability $i
- when: it applies
- ask: \`run $i\`
- gives: $(printf 'a long description of what comes back %.0s' 1 2 3 4 5 6 7 8 9 10)
- notes: $(printf 'a long note about a sharp edge nobody needs at start %.0s' 1 2 3 4 5 6 7 8 9 10)
<!--r:$(today)-->
EOF
    i=$((i + 1))
  done
  set_budget "$world" 400
  out=$(recipes_cmd "$world/home" digest "$world/project") || fail "digest failed: $out"
  assert_contains "$out" "## Capability 5" "the digest did not carry every entry"
  assert_not_contains "$out" "capabilities shown" "the digest reported an omission it did not make"
  out=$(recipes_cmd "$world/home" check "$world/project") && rc=0 || rc=$?
  expect_code 0 "$rc" "check failed a catalog whose digest carries every entry: $out"
  assert_not_contains "$out" "OVER_BUDGET" "check measured the catalog file instead of the digest"
  assert_contains "$out" "digest_shown: 6 of 6" "check did not report that the digest carries every entry"
  pass "fm-project-recipes.sh: check agrees with digest when only the full entries are long"
}

# init writes only into the directory it is given. A CLAUDE.md that is a
# symlink is never written through: the conventional link to AGENTS.md is
# already served by the pointer in AGENTS.md, and a link anywhere else would
# land the pointer outside the project.
test_init_never_writes_through_a_symlinked_claude_md() {
  local world out rc outside_before
  world=$(make_project claudelink)
  printf '# Agent memory\n' >"$world/project/AGENTS.md"
  ln -s AGENTS.md "$world/project/CLAUDE.md"
  out=$(recipes_cmd "$world/home" init "$world/project") || fail "init failed on the conventional CLAUDE.md -> AGENTS.md link: $out"
  assert_grep ".agents/recipes.md" "$world/project/AGENTS.md" "AGENTS.md does not point at the catalog"
  [ -L "$world/project/CLAUDE.md" ] || fail "init replaced the CLAUDE.md link"
  [ "$(grep -c '\.agents/recipes\.md' "$world/project/AGENTS.md")" = 1 ] ||
    fail "init wrote the pointer twice through the CLAUDE.md link"

  world=$(make_project claudeaway)
  mkdir -p "$world/elsewhere"
  printf '# Someone else'"'"'s file\n' >"$world/elsewhere/CLAUDE.md"
  outside_before=$(cat "$world/elsewhere/CLAUDE.md")
  ln -s "$world/elsewhere/CLAUDE.md" "$world/project/CLAUDE.md"
  out=$(recipes_cmd "$world/home" init "$world/project") && rc=0 || rc=$?
  expect_code 1 "$rc" "init wrote through a CLAUDE.md that links outside the project"
  assert_contains "$out" "symlink" "the refusal did not name the cause"
  [ "$(cat "$world/elsewhere/CLAUDE.md")" = "$outside_before" ] ||
    fail "init wrote the pointer into a file outside the project"
  assert_absent "$world/project/.agents/recipes.md" "the refused init still created a catalog"
  pass "fm-project-recipes.sh: init never writes through a symlinked CLAUDE.md"
}

test_init_creates_the_catalog_and_points_agents_md_at_it
test_init_points_an_existing_claude_md_without_renaming_it
test_init_succeeds_when_agents_and_claude_are_both_real_files
test_init_leaves_a_claude_md_that_imports_agents_md_untouched
test_digest_names_the_catalog_by_absolute_path_on_request
test_digest_carries_when_and_ask_but_not_the_rest
test_digest_is_bounded_and_says_what_it_left_out
test_a_configured_budget_is_read_from_the_home
test_an_absent_catalog_costs_nothing
test_check_names_an_entry_nobody_reverified
test_check_names_an_undated_entry
test_check_reports_a_catalog_that_outgrew_its_budget
test_check_agrees_with_digest_when_only_the_full_entries_are_long
test_init_never_writes_through_a_symlinked_claude_md
test_digest_marks_an_entry_nobody_reverified
test_init_refuses_while_a_git_operation_is_in_flight
