#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, and refuses unsafe or unavailable CI before invoking gh-axi.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh-axi pr merge itself fails (no silent success)
#   (c) extra gh-axi pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh-axi when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh-axi (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh-axi
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) CI must be green, with explicit focused-check attestation for no-CI PRs
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)
CI_STATE_PREFIX='fm-pr-merge-ci-state:'

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  # No worktree/project on disk; fm-pr-check.sh tolerates a worktree it cannot
  # stat and simply skips the pr_head lookup via `gh` in that case, so give it
  # one that resolves for cases that want pr_head recorded.
  printf '%s\n' "$case_dir"
}

# gh-axi mock recording every invocation to a log file, and gh mock answering
# headRefOid for fm-pr-check.sh's pr_head lookup and CI state lookups.
# Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
: "\${FM_TEST_HEAD:=$head}"
case "\${1:-} \${2:-}" in
  "pr view")
    if [ "\${FM_TEST_GH_VIEW_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    case " \$* " in
      *headRefOid*) printf '%s\n' "\$FM_TEST_HEAD" ;;
      *statusCheckRollup*)
        if [ "\${FM_TEST_ROLLUP_UNAVAILABLE:-0}" = 1 ]; then
          exit 1
        fi
        [ "\${FM_TEST_EMPTY_ROLLUP:-0}" = 1 ] || \
          printf '%s\n' "\${FM_TEST_CHECK_STATES:-fm-pr-merge-ci-state:SUCCESS}"
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *headRefOid*) printf '%s\n' "${FM_TEST_HEAD:-deadbeefcafefeed0000000000000000deadbeef}" ;;
  *statusCheckRollup*) printf '%s\n' "${FM_TEST_CHECK_STATES:-fm-pr-merge-ci-state:SUCCESS}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "records-before-merge: gh-axi pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh-axi pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh-axi.log" \
    || fail "extra-args: extra gh-axi pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh-axi pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "missing-meta: gh-axi pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/repo/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a non-GitHub PR URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/repo/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh-axi.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --method=merge' "$case_dir/gh-axi.log" \
    || fail "method-equals-merge-method: caller --method=merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh-axi.log" \
    || fail "url-parsing: gh-axi pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_green_ci_states_allow_merge() {
  local case_dir rc
  case_dir=$(make_case green-ci-states)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_CHECK_STATES="${CI_STATE_PREFIX}SUCCESS"$'\n'"${CI_STATE_PREFIX}SKIPPED"$'\n'"${CI_STATE_PREFIX}NEUTRAL" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "green-ci-states: fm-pr-merge should merge with green CI states"
  assert_grep 'pr merge 31' "$case_dir/gh-axi.log" \
    "green-ci-states: gh-axi pr merge was not invoked"
  pass "fm-pr-merge merges only when every reported CI state is green"
}

assert_ci_refusal() {
  local name=$1 states=$2 expected_error=$3 case_dir rc
  shift 3
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_CHECK_STATES="$states" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 "$@" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "$name: fm-pr-merge should refuse unsafe CI"
  assert_grep "$expected_error" "$case_dir/stderr" \
    "$name: refusal did not explain the CI state"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "$name: gh-axi pr merge was invoked despite unsafe CI"
}

test_failure_ci_refuses_before_merge() {
  assert_ci_refusal failure-ci "${CI_STATE_PREFIX}FAILURE" 'error: PR CI is not green: FAILURE'
  pass "fm-pr-merge refuses failed CI before invoking gh-axi pr merge"
}

test_pending_ci_refuses_before_merge() {
  assert_ci_refusal pending-ci "${CI_STATE_PREFIX}IN_PROGRESS" 'error: PR CI is not green: IN_PROGRESS'
  pass "fm-pr-merge refuses pending CI before invoking gh-axi pr merge"
}

test_cancelled_ci_refuses_before_merge() {
  assert_ci_refusal cancelled-ci "${CI_STATE_PREFIX}CANCELLED" 'error: PR CI is not green: CANCELLED'
  pass "fm-pr-merge refuses cancelled CI before invoking gh-axi pr merge"
}

test_unknown_ci_refuses_before_merge() {
  assert_ci_refusal unknown-ci "${CI_STATE_PREFIX}UNKNOWN_STATE" 'error: PR CI is not green: UNKNOWN_STATE'
  pass "fm-pr-merge refuses unrecognized CI states before invoking gh-axi pr merge"
}

test_empty_ci_state_refuses_even_with_attestation() {
  assert_ci_refusal empty-ci-state "$CI_STATE_PREFIX" 'error: PR CI returned an empty state' --no-ci-verified
  pass "fm-pr-merge refuses a reported empty CI state despite the no-CI attestation"
}

test_trailing_empty_ci_state_refuses_even_with_attestation() {
  assert_ci_refusal trailing-empty-ci-state "${CI_STATE_PREFIX}SUCCESS"$'\n'"$CI_STATE_PREFIX" \
    'error: PR CI returned an empty state' --no-ci-verified
  pass "fm-pr-merge preserves and refuses a trailing reported empty CI state"
}

test_ci_lookup_failure_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case ci-lookup-failure)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_GH_VIEW_FAIL=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ci-lookup-failure: fm-pr-merge should refuse unavailable CI"
  assert_grep 'error: cannot verify PR CI status' "$case_dir/stderr" \
    "ci-lookup-failure: refusal did not explain unavailable CI"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "ci-lookup-failure: gh-axi pr merge was invoked despite unavailable CI"
  pass "fm-pr-merge refuses when the CI status lookup fails"
}

test_null_ci_rollup_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case null-ci-rollup)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP_UNAVAILABLE=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/37 --no-ci-verified \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "null-ci-rollup: fm-pr-merge should refuse unavailable rollups"
  assert_grep 'error: cannot verify PR CI status' "$case_dir/stderr" \
    "null-ci-rollup: refusal did not explain the unavailable rollup"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "null-ci-rollup: gh-axi pr merge was invoked despite unavailable rollup"
  pass "fm-pr-merge refuses a null or unavailable CI rollup before merging"
}

test_no_ci_requires_explicit_attestation() {
  local case_dir rc
  case_dir=$(make_case no-ci-unattested)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_EMPTY_ROLLUP=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-ci-unattested: fm-pr-merge should refuse no-CI PRs"
  assert_grep 'error: PR reports no CI checks; verify focused local checks and rerun with --no-ci-verified' "$case_dir/stderr" \
    "no-ci-unattested: refusal did not require the focused-check attestation"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "no-ci-unattested: gh-axi pr merge was invoked without CI attestation"
  pass "fm-pr-merge requires a focused-check attestation when the PR has no CI"
}

test_no_ci_attestation_allows_merge() {
  local case_dir rc
  case_dir=$(make_case no-ci-attested)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_EMPTY_ROLLUP=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 --no-ci-verified \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-ci-attested: fm-pr-merge should accept explicit attestation"
  assert_grep 'pr merge 35' "$case_dir/gh-axi.log" \
    "no-ci-attested: gh-axi pr merge was not invoked after attestation"
  assert_no_grep '--no-ci-verified' "$case_dir/gh-axi.log" \
    "no-ci-attested: attestation leaked into gh-axi arguments"
  pass "fm-pr-merge permits no-CI PRs only with the explicit focused-check attestation"
}

test_no_ci_attestation_is_not_a_forwarded_merge_argument() {
  local case_dir rc
  case_dir=$(make_case no-ci-forwarded)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/36 -- --no-ci-verified \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "no-ci-forwarded: fm-pr-merge should reject forwarded attestation"
  assert_grep 'error: --no-ci-verified must appear before --' "$case_dir/stderr" \
    "no-ci-forwarded: refusal did not explain the attestation position"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "no-ci-forwarded: gh-axi pr merge was invoked with attestation"
  pass "fm-pr-merge keeps the no-CI attestation out of forwarded gh-axi arguments"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_green_ci_states_allow_merge
test_failure_ci_refuses_before_merge
test_pending_ci_refuses_before_merge
test_cancelled_ci_refuses_before_merge
test_unknown_ci_refuses_before_merge
test_empty_ci_state_refuses_even_with_attestation
test_trailing_empty_ci_state_refuses_even_with_attestation
test_ci_lookup_failure_refuses_before_merge
test_null_ci_rollup_refuses_before_merge
test_no_ci_requires_explicit_attestation
test_no_ci_attestation_allows_merge
test_no_ci_attestation_is_not_a_forwarded_merge_argument
