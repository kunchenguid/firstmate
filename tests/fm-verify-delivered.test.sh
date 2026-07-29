#!/usr/bin/env bash
# Behavior tests for bin/fm-verify-delivered.sh.
#
# This verifier has twice reported a clean result while checking nothing, so its
# whole value is that "no violations", "inspected no files", and "the search
# failed" stay three distinguishable outcomes. Every test below asserts the exit
# status as well as the wording, because the status is the contract callers act
# on, and the two regression tests named below are the reason this file exists:
#
#   test_zero_file_pathspec_reports_inspected_nothing
#     Bug 1 (2026-07-28): the pathspec matched no files, git grep reported that
#     as an ordinary no-match, and zero files inspected printed as zero
#     violations found.
#   test_no_match_is_a_result_not_a_fatal
#     Bug 2 (2026-07-29): git grep's no-match status aborted the run under
#     `set -o pipefail`, so the script printed its header and exited 1 on any
#     input. That status is now only reachable from a real violation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-verify-delivered)
VERIFY="$ROOT/bin/fm-verify-delivered.sh"

# --- fixtures ---------------------------------------------------------------

# fm_verify_assert_tmp <path>: refuse any fixture path outside this run's temp
# root. Without this, a helper handed an empty or unexpanded path would run
# `git -C ""` against whatever repo the suite happens to sit in, and `git add -A`
# plus `git commit` would land a fixture commit in the real checkout. An earlier
# draft of this file did exactly that, so the guard is load-bearing.
fm_verify_assert_tmp() {
  [ -n "${TMP_ROOT:-}" ] || fail "TMP_ROOT is unset; refusing to build a fixture"
  case "${1:-}" in
    "$TMP_ROOT"/?*) : ;;
    *) fail "fixture path '${1:-}' is not inside $TMP_ROOT; refusing to touch a real repo" ;;
  esac
}

# fm_verify_fixture <name> <subdir>: a git repo whose brand-identity source will
# live under <subdir>. Echoes the repo path. <subdir> is what lets a test point
# the scoped pathspec at nothing.
fm_verify_fixture() {
  local name=$1 subdir=$2
  local repo="$TMP_ROOT/$name"
  fm_verify_assert_tmp "$repo"
  mkdir -p "$repo/$subdir"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name 'Firstmate Tests'
  git -C "$repo" config user.email 'tests@example.invalid'
  printf '%s\n' "$repo"
}

# fm_verify_commit <repo>: commit the fixture tree and name it "checkme", the
# branch every run below inspects instead of a remote-tracking ref.
fm_verify_commit() {
  local repo=${1:-}
  fm_verify_assert_tmp "$repo"
  git -C "$repo" add -A
  git -C "$repo" commit -qm fixture
  git -C "$repo" branch -f checkme main
}

# fm_verify_write_source <repo> <path> graph|string: a candidate file that
# decides brand identity, consulting the graph only when told to.
fm_verify_write_source() {
  local repo=${1:-} path=$2 graph=$3
  fm_verify_assert_tmp "$repo"
  mkdir -p "$repo/$(dirname "$path")"
  {
    printf 'def compare(a, b):\n'
    printf '    return is_same_brand(a, b)\n'
    [ "$graph" != graph ] || printf '    # resolved through brand_relations in the graph\n'
  } > "$repo/$path"
}

# run_verify <repo> [args...]: run brand-identity against <repo> at the fixture
# branch with no network fetch. Sets OUT to the combined output and RC to the
# exit status. Both are globals on purpose: capturing the run in a command
# substitution would leave its exit status in a subshell the caller cannot read,
# and the exit status is most of what these tests assert.
RC=0
OUT=
run_verify() {
  local repo=$1
  shift
  OUT=$(FM_VERIFY_REPO="$repo" FM_VERIFY_REV=checkme "$VERIFY" brand-identity --no-fetch "$@" 2>&1)
  RC=$?
}

# run_env <name=value>... -- <args>...: run the script under an explicit
# environment, setting OUT and RC the same way.
run_env() {
  local -a env_kv=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    env_kv+=("$1")
    shift
  done
  shift
  OUT=$(env "${env_kv[@]}" "$VERIFY" "$@" 2>&1)
  RC=$?
}

# --- outcome 1: violations --------------------------------------------------

test_violation_is_reported_and_fails() {
  local repo
  repo=$(fm_verify_fixture violation schema-generator/app)
  fm_verify_write_source "$repo" schema-generator/app/migrated.py graph
  fm_verify_write_source "$repo" schema-generator/app/legacy.py string
  fm_verify_commit "$repo"

  run_verify "$repo"
  expect_code 1 "$RC" "a known violation must fail"
  assert_contains "$OUT" "UNMIGRATED: app/legacy.py" "the violating file was not named"
  assert_contains "$OUT" "VIOLATIONS:" "the violation verdict is missing"
  assert_contains "$OUT" "DO NOT report brand-identity work as complete" "the refusal line is missing"
  assert_not_contains "$OUT" "CLEAN:" "a tree with a violation printed a clean verdict"
  assert_contains "$OUT" "INSPECTED: 2 candidate file(s)" "the inspected count is missing or wrong"
  pass "fm-verify-delivered.sh: a known violation is reported and exits 1"
}

# --- outcome 2: clean -------------------------------------------------------

test_clean_tree_reports_clean() {
  local repo
  repo=$(fm_verify_fixture clean schema-generator/app)
  fm_verify_write_source "$repo" schema-generator/app/one.py graph
  fm_verify_write_source "$repo" schema-generator/app/two.py graph
  fm_verify_commit "$repo"

  run_verify "$repo"
  expect_code 0 "$RC" "a tree with no violation must pass"
  assert_contains "$OUT" "CLEAN: all 2 inspected file(s) consult the graph" "the clean verdict is missing or miscounted"
  assert_not_contains "$OUT" "UNMIGRATED" "a clean tree named a violation"
  assert_not_contains "$OUT" "INSPECTED NOTHING" "a clean tree claimed it inspected nothing"
  pass "fm-verify-delivered.sh: a tree with no violation reports clean and exits 0"
}

# The string-matching owners are allowed to compare strings, and excluding them
# must narrow the candidate list without turning the check vacuous.
test_owner_files_are_excluded_from_candidates() {
  local repo
  repo=$(fm_verify_fixture owners schema-generator/app)
  fm_verify_write_source "$repo" schema-generator/app/name_matching.py string
  fm_verify_write_source "$repo" schema-generator/app/competitor_guards.py string
  fm_verify_write_source "$repo" schema-generator/app/caller.py graph
  fm_verify_commit "$repo"

  run_verify "$repo"
  expect_code 0 "$RC" "excluded owner files must not count as violations"
  assert_contains "$OUT" "INSPECTED: 1 candidate file(s) out of 3" "owner exclusion did not narrow the candidates"
  assert_not_contains "$OUT" "name_matching.py" "an excluded owner file was reported"
  pass "fm-verify-delivered.sh: string-matching owners are excluded from candidates"
}

# --- outcome 3: inspected nothing (regression for bug 1) --------------------

test_zero_file_pathspec_reports_inspected_nothing() {
  local repo
  # The source lives somewhere else entirely, so the scoped pathspec resolves to
  # no file. That is exactly bug 1: git grep calls it a no-match, and the old
  # script called a no-match clean.
  repo=$(fm_verify_fixture empty-pathspec other-place)
  fm_verify_write_source "$repo" other-place/legacy.py string
  fm_verify_commit "$repo"

  run_verify "$repo"
  expect_code 3 "$RC" "a pathspec matching zero files must not exit 0"
  assert_contains "$OUT" "INSPECTED NOTHING:" "the empty-scope outcome is not distinguishable"
  assert_contains "$OUT" "matches no file" "the empty-scope reason is missing"
  assert_contains "$OUT" "NOT a clean result" "the empty-scope outcome was not called out as not-clean"
  assert_not_contains "$OUT" "CLEAN:" "a pathspec matching zero files printed a clean verdict"
  pass "fm-verify-delivered.sh: a pathspec matching zero files reports inspected nothing, not clean"
}

# The same collapse one layer in: the scope holds files, but the candidate
# pattern matches none of them, so nothing was examined for the violation.
test_zero_candidates_reports_inspected_nothing() {
  local repo
  repo=$(fm_verify_fixture no-candidates schema-generator/app)
  printf 'def unrelated():\n    return 1\n' > "$repo/schema-generator/app/unrelated.py"
  fm_verify_commit "$repo"

  run_verify "$repo"
  expect_code 3 "$RC" "zero candidate files must not exit 0"
  assert_contains "$OUT" "INSPECTED NOTHING:" "the zero-candidate outcome is not distinguishable"
  assert_contains "$OUT" "found nothing to check" "the zero-candidate reason is missing"
  assert_not_contains "$OUT" "CLEAN:" "zero candidate files printed a clean verdict"
  pass "fm-verify-delivered.sh: zero candidate files reports inspected nothing, not clean"
}

# --- outcome 4: search failed -----------------------------------------------

test_unresolvable_rev_reports_search_failed() {
  local repo
  repo=$(fm_verify_fixture bad-rev schema-generator/app)
  fm_verify_write_source "$repo" schema-generator/app/legacy.py string
  fm_verify_commit "$repo"

  run_env "FM_VERIFY_REPO=$repo" FM_VERIFY_REV=no-such-rev -- brand-identity --no-fetch
  expect_code 4 "$RC" "an unresolvable rev must report a failed search"
  assert_contains "$OUT" "SEARCH FAILED:" "the failed-search outcome is not distinguishable"
  assert_contains "$OUT" "cannot resolve rev 'no-such-rev'" "the failed-search reason is missing"
  assert_not_contains "$OUT" "CLEAN:" "an unresolvable rev printed a clean verdict"
  assert_not_contains "$OUT" "INSPECTED NOTHING" "a failed search was reported as an empty search"
  pass "fm-verify-delivered.sh: an unresolvable rev reports a failed search, not clean"
}

test_missing_repo_reports_search_failed() {
  run_env "FM_VERIFY_REPO=$TMP_ROOT/not-a-repo" FM_VERIFY_REV=checkme -- brand-identity --no-fetch
  expect_code 4 "$RC" "a missing repo must report a failed search"
  assert_contains "$OUT" "SEARCH FAILED:" "a missing repo is not reported as a failed search"
  assert_contains "$OUT" "is not a git repository" "the missing-repo reason is missing"
  assert_not_contains "$OUT" "CLEAN:" "a missing repo printed a clean verdict"
  pass "fm-verify-delivered.sh: a missing repo reports a failed search, not clean"
}

# git grep itself erroring mid-search, not a pre-check refusing to start. The
# shim fails only `git grep`, so the repo, the rev, and the scope all resolve
# first and the run reaches the search before it breaks.
test_erroring_git_grep_reports_search_failed() {
  local repo fakebin real_git
  repo=$(fm_verify_fixture grep-error schema-generator/app)
  fm_verify_write_source "$repo" schema-generator/app/legacy.py string
  fm_verify_commit "$repo"

  real_git=$(command -v git)
  fakebin=$(fm_fakebin "$TMP_ROOT/grep-error-shim")
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = grep ]; then
    printf 'fatal: simulated git grep failure\\n' >&2
    exit 128
  fi
done
exec "$real_git" "\$@"
SH
  chmod +x "$fakebin/git"

  run_env "PATH=$fakebin:$PATH" "FM_VERIFY_REPO=$repo" FM_VERIFY_REV=checkme -- brand-identity --no-fetch
  expect_code 4 "$RC" "an erroring search must not exit 0, 1, or 3"
  assert_contains "$OUT" "SEARCH FAILED:" "an erroring git grep is not reported as a failed search"
  assert_contains "$OUT" "status 128" "the underlying grep status is missing from the report"
  assert_not_contains "$OUT" "CLEAN:" "an erroring search printed a clean verdict"
  assert_not_contains "$OUT" "INSPECTED NOTHING" "an erroring search was reported as an empty search"
  pass "fm-verify-delivered.sh: an erroring git grep reports a failed search, not clean"
}

# --- bug 2 regression: a no-match must survive `set -o pipefail` ------------

test_no_match_is_a_result_not_a_fatal() {
  local repo
  # Bug 2's observed behaviour was header-only output and exit 1 on any input,
  # because git grep's no-match status aborted the run. This tree ends on a
  # graph no-match, the exact status that used to be fatal, so reaching the
  # verdict line at all is the regression assertion.
  repo=$(fm_verify_fixture pipefail schema-generator/app)
  fm_verify_write_source "$repo" schema-generator/app/legacy.py string
  fm_verify_commit "$repo"

  run_verify "$repo"
  expect_code 1 "$RC" "a single unmigrated file must exit 1 as a violation"
  assert_contains "$OUT" "UNMIGRATED: app/legacy.py" "the run died before classifying the file"
  assert_contains "$OUT" "VIOLATIONS: 1 of 1 inspected file(s)" "the run died before its verdict"
  pass "fm-verify-delivered.sh: a git grep no-match is a result, not a fatal under pipefail"
}

# --- task-id mode -----------------------------------------------------------

test_task_mode_extracts_claims() {
  local home="$TMP_ROOT/home-claims"
  mkdir -p "$home/data/fm-example"
  cat > "$home/data/fm-example/brief.md" <<'EOF'
# Task
1. Fix the thing.
2. Every call site must consult the graph.
EOF
  run_env "FM_HOME=$home" -- fm-example
  expect_code 0 "$RC" "a brief with acceptance claims must exit 0"
  assert_contains "$OUT" "ACCEPTANCE CLAIMS in the brief for fm-example" "the claims header is missing"
  assert_contains "$OUT" "Every call site must consult the graph." "an acceptance claim was dropped"
  assert_contains "$OUT" "NOT a clean verdict" "task-id mode did not disclaim being a verdict"
  pass "fm-verify-delivered.sh: task-id mode extracts acceptance claims"
}

# The same no-match hazard in the other mode: a brief whose claims do not parse
# is an unverified brief, not an approved one.
test_task_mode_without_claims_reports_inspected_nothing() {
  local home="$TMP_ROOT/home-no-claims"
  mkdir -p "$home/data/fm-bare"
  printf 'nothing here looks like an acceptance criterion\n' > "$home/data/fm-bare/brief.md"
  run_env "FM_HOME=$home" -- fm-bare
  expect_code 3 "$RC" "a brief with no parseable claims must not exit 0"
  assert_contains "$OUT" "INSPECTED NOTHING:" "an unparseable brief is not reported as an empty search"
  assert_contains "$OUT" "extracted nothing to verify" "the empty-claims reason is missing"
  pass "fm-verify-delivered.sh: a brief with no parseable claims reports inspected nothing"
}

test_task_mode_missing_brief_is_usage_error() {
  local home="$TMP_ROOT/home-missing"
  mkdir -p "$home/data"
  run_env "FM_HOME=$home" -- fm-absent
  expect_code 2 "$RC" "a missing brief must be a usage error"
  assert_contains "$OUT" "no brief for 'fm-absent'" "the missing-brief reason is missing"
  pass "fm-verify-delivered.sh: a missing brief is a usage error"
}

# --- invocation contract ----------------------------------------------------

test_no_mode_is_usage_error() {
  OUT=$("$VERIFY" 2>&1)
  RC=$?
  expect_code 2 "$RC" "no mode must be a usage error"
  assert_contains "$OUT" "no mode given" "the no-mode reason is missing"
  pass "fm-verify-delivered.sh: no mode is a usage error"
}

# --- the suite's own safety guard -------------------------------------------

test_fixture_guard_refuses_paths_outside_the_temp_root() {
  # Run in a subshell so the guard's fail() aborts only the probe. An empty path
  # is the dangerous one: `git -C ""` means "the current repo".
  OUT=$(fm_verify_assert_tmp "" 2>&1) && fail "the fixture guard accepted an empty path"
  assert_contains "$OUT" "refusing to touch a real repo" "the guard's refusal reason is missing"
  OUT=$(fm_verify_assert_tmp "$ROOT" 2>&1) && fail "the fixture guard accepted the firstmate checkout"
  OUT=$(fm_verify_assert_tmp "$TMP_ROOT/ok" 2>&1) || fail "the fixture guard rejected a valid temp path"
  pass "fm-verify-delivered.sh: the fixture guard refuses paths outside the temp root"
}

test_help_prints_the_outcome_contract() {
  OUT=$("$VERIFY" --help 2>&1) || fail "--help must exit 0"
  assert_contains "$OUT" "INSPECTED NOTHING" "--help does not document the empty-search outcome"
  assert_contains "$OUT" "SEARCH FAILED" "--help does not document the failed-search outcome"
  assert_contains "$OUT" "only 0 may be read as delivered" "--help does not state the exit-status contract"
  pass "fm-verify-delivered.sh: --help documents the four outcomes"
}

test_violation_is_reported_and_fails
test_clean_tree_reports_clean
test_owner_files_are_excluded_from_candidates
test_zero_file_pathspec_reports_inspected_nothing
test_zero_candidates_reports_inspected_nothing
test_unresolvable_rev_reports_search_failed
test_missing_repo_reports_search_failed
test_erroring_git_grep_reports_search_failed
test_no_match_is_a_result_not_a_fatal
test_task_mode_extracts_claims
test_task_mode_without_claims_reports_inspected_nothing
test_task_mode_missing_brief_is_usage_error
test_no_mode_is_usage_error
test_fixture_guard_refuses_paths_outside_the_temp_root
test_help_prints_the_outcome_contract
