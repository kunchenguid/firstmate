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

# fm_verify_broken_origin <name>: a fixture repo holding one string-only
# candidate whose 'origin' points at a local path that does not exist, so
# `git fetch origin` fails without touching the network. Echoes the repo path.
fm_verify_broken_origin() {
  local name=$1 repo
  repo=$(fm_verify_fixture "$name" schema-generator/app)
  fm_verify_write_source "$repo" schema-generator/app/legacy.py string
  fm_verify_commit "$repo"
  git -C "$repo" remote add origin "$TMP_ROOT/$name-no-such-remote.git"
  printf '%s\n' "$repo"
}

# fm_verify_registry_home <name> <repo>: an FM_HOME whose data/projects.md
# records <repo> for inception in the `repo at <path>` form this script parses.
# The line shape is the coupling under test: if the registry format moves, the
# tests that use this helper fail instead of the parse silently going dead.
fm_verify_registry_home() {
  local name=$1 repo=$2
  local home="$TMP_ROOT/$name"
  fm_verify_assert_tmp "$home"
  mkdir -p "$home/data"
  {
    printf '# Projects\n\n'
    printf -- '- inception [build] - SEO schema tool (repo at %s, added 2026-07-01)\n' "$repo"
  } > "$home/data/projects.md"
  printf '%s\n' "$home"
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
  # The fixture's own graph marker is a comment, which is why the verdict may
  # only claim the identifier appears in the file, not that the file consults it.
  assert_contains "$OUT" "CLEAN: all 2 inspected file(s) reference a graph identifier somewhere in the file" \
    "the clean verdict is missing or miscounted"
  assert_contains "$OUT" "not proof they consult it" "the clean verdict does not qualify what the search proved"
  assert_not_contains "$OUT" "consult the graph" "the clean verdict claims more than the per-file search proves"
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
  assert_contains "$OUT" "matched nothing in scope" "the zero-candidate reason does not say the pattern itself matched nothing"
  assert_not_contains "$OUT" "allowed string-matching owner" "a tree with no pattern match blamed the owner exclusion"
  assert_not_contains "$OUT" "CLEAN:" "zero candidate files printed a clean verdict"
  pass "fm-verify-delivered.sh: zero candidate files reports inspected nothing, not clean"
}

# Same outcome, different cause, and the report has to tell them apart. Here the
# pattern did match files; every one of them is an owner allowed to compare
# strings, so the exclusion emptied the candidate list. Saying "the pattern
# matched nothing" here would be a false statement from a script whose only job
# is honest reporting of what it inspected.
test_only_owner_candidates_reports_inspected_nothing() {
  local repo
  repo=$(fm_verify_fixture owners-only schema-generator/app)
  fm_verify_write_source "$repo" schema-generator/app/name_matching.py string
  fm_verify_write_source "$repo" schema-generator/app/competitor_guards.py string
  printf 'def unrelated():\n    return 1\n' > "$repo/schema-generator/app/unrelated.py"
  fm_verify_commit "$repo"

  run_verify "$repo"
  expect_code 3 "$RC" "an owners-only tree must not exit 0"
  assert_contains "$OUT" "INSPECTED NOTHING:" "the owners-only outcome is not distinguishable"
  assert_contains "$OUT" "every file it matched is an allowed string-matching owner" \
    "the owners-only reason does not say the exclusion emptied the candidate list"
  assert_contains "$OUT" "all 2 file(s)" "the owners-only reason does not count the pre-exclusion matches"
  assert_not_contains "$OUT" "matched nothing in scope" \
    "an owners-only tree falsely claimed the candidate pattern matched nothing"
  assert_not_contains "$OUT" "CLEAN:" "an owners-only tree printed a clean verdict"
  pass "fm-verify-delivered.sh: an owners-only tree says the exclusion emptied the candidates"
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
  assert_contains "$OUT" "set FM_VERIFY_REPO" "the missing-repo report is not actionable"
  assert_not_contains "$OUT" "CLEAN:" "a missing repo printed a clean verdict"
  pass "fm-verify-delivered.sh: a missing repo reports a failed search, not clean"
}

# A fetch that was asked for and failed leaves the rev at whatever is on disk, so
# any verdict below it would be about an unknown rev. That is the same
# "unknown reads as clean" collapse the outcome table exists to prevent, so it is
# outcome 4 and not a warning. The broken origin is a local path, so no network.
test_failed_fetch_reports_search_failed() {
  local repo
  repo=$(fm_verify_broken_origin failed-fetch)

  run_env "FM_VERIFY_REPO=$repo" FM_VERIFY_REV=checkme -- brand-identity
  expect_code 4 "$RC" "a failed fetch must report a failed search, not a verdict"
  assert_contains "$OUT" "SEARCH FAILED:" "a failed fetch is not reported as a failed search"
  assert_contains "$OUT" "git fetch origin failed" "the failed-fetch reason is missing"
  assert_contains "$OUT" "does not appear to be a git repository" \
    "the failed-fetch report drops git's own stderr, so the reader cannot tell why"
  assert_contains "$OUT" "--no-fetch" "the failed-fetch report does not name the opt-in for a local ref"
  assert_not_contains "$OUT" "CLEAN:" "a failed fetch printed a clean verdict"
  assert_not_contains "$OUT" "VIOLATIONS:" "a failed fetch reached a violations verdict against a stale rev"
  assert_not_contains "$OUT" "WARNING" "a failed fetch was downgraded to a warning"
  pass "fm-verify-delivered.sh: a failed fetch reports a failed search, not a verdict"
}

# The other half of that contract: --no-fetch is the deliberate escape hatch for
# inspecting a local ref, so on the very same unfetchable repo it must still
# reach a real verdict rather than becoming an error.
test_no_fetch_still_reaches_a_verdict_on_an_unfetchable_repo() {
  local repo
  repo=$(fm_verify_broken_origin no-fetch-hatch)

  run_verify "$repo"
  expect_code 1 "$RC" "--no-fetch must still reach a verdict when origin is unfetchable"
  assert_contains "$OUT" "UNMIGRATED: app/legacy.py" "--no-fetch did not inspect the local ref"
  assert_contains "$OUT" "VIOLATIONS: 1 of 1 inspected file(s)" "--no-fetch did not reach its verdict"
  assert_not_contains "$OUT" "SEARCH FAILED:" "--no-fetch turned an accepted local ref into an error"
  pass "fm-verify-delivered.sh: --no-fetch still reaches a verdict when origin is unfetchable"
}

# --- repo resolution --------------------------------------------------------

# The script parses data/projects.md for `repo at <path>` itself. data/ is
# gitignored, so nothing in-repo would notice that form drifting; this test is
# what notices. It fails if the recorded form changes or the parse is removed.
test_registry_recorded_repo_is_inspected() {
  local repo home
  repo=$(fm_verify_broken_origin registry-repo)
  home=$(fm_verify_registry_home home-registry "$repo")

  run_env "FM_HOME=$home" FM_VERIFY_REV=checkme -- brand-identity --no-fetch
  expect_code 1 "$RC" "the registry-recorded repo was not inspected"
  assert_contains "$OUT" "repo: $repo" "the path recorded as 'repo at <path>' was not resolved"
  assert_contains "$OUT" "UNMIGRATED: app/legacy.py" "the resolved path was printed but not inspected"
  pass "fm-verify-delivered.sh: the repo recorded in data/projects.md is resolved and inspected"
}

test_explicit_repo_overrides_the_registry() {
  local registry_repo clean_repo home
  registry_repo=$(fm_verify_broken_origin registry-loser)
  clean_repo=$(fm_verify_fixture registry-winner schema-generator/app)
  fm_verify_write_source "$clean_repo" schema-generator/app/one.py graph
  fm_verify_commit "$clean_repo"
  home=$(fm_verify_registry_home home-precedence "$registry_repo")

  run_env "FM_HOME=$home" "FM_VERIFY_REPO=$clean_repo" FM_VERIFY_REV=checkme -- brand-identity --no-fetch
  expect_code 0 "$RC" "FM_VERIFY_REPO must win over the registry-recorded path"
  assert_contains "$OUT" "repo: $clean_repo" "FM_VERIFY_REPO was not the repo inspected"
  assert_not_contains "$OUT" "$registry_repo" "the registry-recorded path outranked the explicit override"
  pass "fm-verify-delivered.sh: FM_VERIFY_REPO outranks the registry-recorded path"
}

# No override and no registry: resolution falls through to the standard clone
# location, and a miss there is still outcome 4 with an actionable message.
test_unresolvable_repo_falls_through_to_search_failed() {
  local home="$TMP_ROOT/home-no-registry"
  mkdir -p "$home/data"

  run_env "FM_HOME=$home" FM_VERIFY_REV=checkme -- brand-identity --no-fetch
  expect_code 4 "$RC" "an unresolvable repo must not exit 0"
  assert_contains "$OUT" "$home/projects/inception is not a git repository" \
    "resolution did not fall through to the standard clone location"
  assert_contains "$OUT" "set FM_VERIFY_REPO" "the fall-through report is not actionable"
  assert_not_contains "$OUT" "CLEAN:" "an unresolvable repo printed a clean verdict"
  pass "fm-verify-delivered.sh: an unresolvable repo falls through to a failed search"
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

# The ERR trap, which is the catch-all the other three outcome-4 tests bypass by
# exercising branches the script classifies for itself. A failure nobody wrote a
# branch for must still land on "unknown", never on exit 1, which in this
# script's vocabulary means "violations found".
#
# The failure is forced with an unusable TMPDIR, so the run dies on its own
# mktemp inside verify_brand_identity with the repo, rev and pathspec all valid.
# That location is the point: bash does not carry an ERR trap into a function
# without `set -E`, so without it this exits 1 with no SEARCH FAILED line at all.
test_unclassified_failure_in_a_mode_function_reports_search_failed() {
  local repo
  repo=$(fm_verify_fixture errtrace schema-generator/app)
  fm_verify_write_source "$repo" schema-generator/app/legacy.py string
  fm_verify_commit "$repo"

  run_env "TMPDIR=$TMP_ROOT/errtrace-no-such-tmpdir" "FM_VERIFY_REPO=$repo" FM_VERIFY_REV=checkme \
    -- brand-identity --no-fetch
  expect_code 4 "$RC" "an unclassified failure must report a failed search, not violations"
  assert_contains "$OUT" "SEARCH FAILED:" "the ERR trap did not fire inside the mode function"
  assert_contains "$OUT" "unhandled command failure" "the unclassified-failure reason is missing"
  assert_contains "$OUT" "in verify_brand_identity" "the report does not name the function that failed"
  assert_contains "$OUT" "ERRLOG=" "the report does not name the command that actually failed"
  assert_not_contains "$OUT" "CLEAN:" "an unclassified failure printed a clean verdict"
  assert_not_contains "$OUT" "VIOLATIONS:" "an unclassified failure was reported as violations"
  pass "fm-verify-delivered.sh: an unclassified failure inside a mode function reports a failed search"
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

# Bug 2's class in the other mode. The claim list is truncated for display, and
# `head` closes the pipe as soon as it has its lines; once the list outgrows the
# pipe buffer the writer is cut off mid-write and pipefail turns that into a
# fatal, so a brief with many claims fails while a short one passes. The brief
# below is sized past the buffer on purpose: at ~40 claims the `head` spelling
# still passes, so a smaller fixture would assert nothing.
test_task_mode_long_claim_list_is_truncated_not_fatal() {
  local home="$TMP_ROOT/home-long-claims"
  mkdir -p "$home/data/fm-long"
  awk 'BEGIN {
    for (i = 1; i <= 1200; i++)
      printf "%d. Every call site number %d must consult the graph and satisfy the acceptance criteria on this line.\n", i, i
  }' > "$home/data/fm-long/brief.md"

  run_env "FM_HOME=$home" -- fm-long
  expect_code 0 "$RC" "a long claim list must not turn a truncated display into a failure"
  assert_contains "$OUT" "CHECKLIST: 1200 claim line(s) extracted" "the count reports the truncated display, not every claim found"
  assert_contains "$OUT" "40:40. Every call site number 40 " "the display stopped short of its 40-line cap"
  assert_not_contains "$OUT" "41:41. Every call site number 41 " "the display printed past its 40-line cap"
  pass "fm-verify-delivered.sh: a long claim list is truncated for display, not fatal"
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
test_only_owner_candidates_reports_inspected_nothing
test_unresolvable_rev_reports_search_failed
test_missing_repo_reports_search_failed
test_failed_fetch_reports_search_failed
test_no_fetch_still_reaches_a_verdict_on_an_unfetchable_repo
test_registry_recorded_repo_is_inspected
test_explicit_repo_overrides_the_registry
test_unresolvable_repo_falls_through_to_search_failed
test_erroring_git_grep_reports_search_failed
test_unclassified_failure_in_a_mode_function_reports_search_failed
test_no_match_is_a_result_not_a_fatal
test_task_mode_extracts_claims
test_task_mode_long_claim_list_is_truncated_not_fatal
test_task_mode_without_claims_reports_inspected_nothing
test_task_mode_missing_brief_is_usage_error
test_no_mode_is_usage_error
test_fixture_guard_refuses_paths_outside_the_temp_root
test_help_prints_the_outcome_contract
