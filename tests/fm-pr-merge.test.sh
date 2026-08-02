#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# It must also re-verify the pull request's current head before merging. A
# cross-repo fork PR held at action_required dispatches zero workflows, so its
# check rollup is empty and reports zero failures; reading that absence as
# success is what let an unverified head reach a merge. Every refusal below has
# a negative control that constructs the failing condition and watches the guard
# fire, because a guard proven only by "no bad merge happened" is not proven.
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
#   (i) an empty check rollup refuses, distinguishably from a failing rollup
#   (j) an all-successful rollup with the same zero failure count still merges
#   (k) a non-success check run refuses
#   (l) a non-mergeable PR refuses, including a not-yet-computed UNKNOWN
#   (m) a review requesting changes refuses
#   (n) an unreadable or absent gh refuses rather than merging unverified
#   (o) --allow-unverified merges without verifying and records the override
#   (p) the override is never inferred from the environment or from after --
#   (q) the torn-down-metadata refusal still fires first, unchanged
#   (r) the real GitHub query is exercised end to end against API-shaped JSON
#   (s) a head that changes after the early check is refused by the final check
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

GREEN_HEAD=deadbeefcafefeed0000000000000000deadbeef

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh-axi mock that records how it was invoked. Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin" "$case_dir/emptybin"
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

# write_verify_payload <file> <head> <mergeable> <review> <checks> <unsuccessful>
# The five lines fm-pr-merge.sh reads back from its single `gh pr view` call.
write_verify_payload() {
  printf 'head=%s\nmergeable=%s\nreview=%s\nchecks=%s\nunsuccessful=%s\n' \
    "$2" "$3" "$4" "$5" "$6" > "$1"
}

# A green head: mergeable, no review blocking, ten check runs, none unsuccessful.
write_green_payload() {
  write_verify_payload "$1" "${2:-$GREEN_HEAD}" MERGEABLE '' 10 0
}

# gh-axi mock recording every invocation to a log file, and a `gh` mock standing
# in for the forge. The `gh` mock answers both callers off its argv: the single
# headRefOid field is fm-pr-check.sh's pr_head lookup, and any request naming
# statusCheckRollup is fm-pr-merge.sh's merge-time verification. When a JSON
# fixture is supplied it evaluates the script's real -q query against that
# fixture with jq, so the query itself is under test and not just the branch
# logic reading a canned answer.
add_gh_mocks() {
  local case_dir=$1 head=${2:-$GREEN_HEAD}
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
fields=
query=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) fields=${2:-}; shift; [ "$#" -gt 0 ] && shift ;;
    -q|--jq) query=${2:-}; shift; [ "$#" -gt 0 ] && shift ;;
    *) shift ;;
  esac
done
case "$fields" in
  *statusCheckRollup*)
    [ "${FM_TEST_GH_VERIFY_RC:-0}" = 0 ] || exit "${FM_TEST_GH_VERIFY_RC}"
    if [ -n "${FM_TEST_GH_FIXTURE:-}" ]; then
      jq -r "$query" "$FM_TEST_GH_FIXTURE"
      exit $?
    fi
    if [ -n "${FM_TEST_GH_VERIFY_SEQUENCE_PREFIX:-}" ]; then
      verify_call=$(cat "$FM_TEST_GH_VERIFY_SEQUENCE_PREFIX.count" 2>/dev/null || printf '0')
      verify_call=$((verify_call + 1))
      printf '%s\n' "$verify_call" > "$FM_TEST_GH_VERIFY_SEQUENCE_PREFIX.count"
      cat "$FM_TEST_GH_VERIFY_SEQUENCE_PREFIX.$verify_call"
      exit 0
    fi
    cat "$FM_TEST_GH_VERIFY_PAYLOAD"
    exit 0
    ;;
  *headRefOid*)
    printf '%s\n' "${FM_TEST_GH_HEAD:-}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
  printf '%s\n' "$head" > "$case_dir/head"
  write_green_payload "$case_dir/verify.txt" "$head"
}

# gh-axi mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  add_gh_mocks "$case_dir" "${2:-$GREEN_HEAD}"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") echo "error: pr merge failed" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

run_pr_merge() {
  local case_dir=$1 rc head; shift
  head=$(cat "$case_dir/head" 2>/dev/null || printf '%s' "$GREEN_HEAD")
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_HEAD="$head" \
  FM_TEST_GH_VERIFY_PAYLOAD="$case_dir/verify.txt" \
  FM_TEST_GH_VERIFY_RC="${FM_TEST_GH_VERIFY_RC:-0}" \
  FM_TEST_GH_FIXTURE="${FM_TEST_GH_FIXTURE:-}" \
  FM_TEST_GH_VERIFY_SEQUENCE_PREFIX="${FM_TEST_GH_VERIFY_SEQUENCE_PREFIX:-}" \
  PATH="${FM_TEST_PATH_OVERRIDE:-$case_dir/fakebin:$PATH}" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

# Every refusal must leave the task untouched: no PR recorded, no merge poll
# armed, and no merge attempted.
assert_no_merge_side_effects() {
  local case_dir=$1 label=$2
  assert_no_grep 'pr=https://' "$case_dir/state/task-x1.meta" \
    "$label: a refused merge recorded a PR in the task record"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "$label: a refused merge armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "$label: a refused merge still invoked gh-axi pr merge"
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
  local case_dir
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
  : > "$case_dir/gh.log"

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
  # The head guard must compose with the torn-down-metadata refusal rather than
  # replace it: the released task is refused before any forge lookup happens.
  assert_no_grep 'statusCheckRollup' "$case_dir/gh.log" \
    "missing-meta: the released task was verified against the forge instead of refused first"
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

# --- head verification: negative controls -----------------------------------

# The defect this guard exists for. An empty rollup reports zero failures, which
# is byte-identical to an all-successful rollup's zero failures, so the refusal
# must key on the run count and not on the failure count.
test_zero_check_runs_refuses() {
  local case_dir rc head=1111111111111111111111111111111111111111
  case_dir=$(make_case zero-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_verify_payload "$case_dir/verify.txt" "$head" MERGEABLE '' 0 0
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/31 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "zero-checks: an empty check rollup must refuse the merge"
  assert_grep 'no check runs exist on this head' "$case_dir/stderr" \
    "zero-checks: refusal did not name the empty check rollup"
  assert_grep "$head" "$case_dir/stderr" \
    "zero-checks: refusal did not name the head commit it evaluated"
  assert_no_grep 'are not successful' "$case_dir/stderr" \
    "zero-checks: empty rollup was reported as a failing rollup instead of an empty one"
  assert_no_merge_side_effects "$case_dir" zero-checks
  pass "fm-pr-merge refuses a head with zero check runs and names it as empty, not failing"
}

# The positive control paired with the case above: same zero failure count, but
# check runs actually exist and all passed.
test_all_successful_checks_still_merges() {
  local case_dir rc
  case_dir=$(make_case all-success)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$GREEN_HEAD"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/32 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "all-success: a green, mergeable PR must still merge"
  grep -qxF 'pr merge 32 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "all-success: a verified green PR was not merged"
  assert_grep "merge_verified_head=$GREEN_HEAD" "$case_dir/state/task-x1.meta" \
    "all-success: the verified head was not recorded"
  pass "fm-pr-merge still merges a green, mergeable, unreviewed PR"
}

test_failing_check_run_refuses() {
  local case_dir rc head=2121212121212121212121212121212121212121
  case_dir=$(make_case failing-check)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_verify_payload "$case_dir/verify.txt" "$head" MERGEABLE '' 10 2
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/33 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failing-check: a non-success check run must refuse the merge"
  assert_grep '2 of 10 check runs are not successful' "$case_dir/stderr" \
    "failing-check: refusal did not name the failing check runs"
  assert_grep "$head" "$case_dir/stderr" \
    "failing-check: refusal did not name the head commit it evaluated"
  assert_no_grep 'no check runs exist' "$case_dir/stderr" \
    "failing-check: a failing rollup was reported as an empty one"
  assert_no_merge_side_effects "$case_dir" failing-check
  pass "fm-pr-merge refuses a head with non-successful check runs, distinguishably from an empty one"
}

test_not_mergeable_refuses() {
  local case_dir rc head=3131313131313131313131313131313131313131
  case_dir=$(make_case not-mergeable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_verify_payload "$case_dir/verify.txt" "$head" CONFLICTING '' 10 0
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/34 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "not-mergeable: a conflicting PR must refuse the merge"
  assert_grep 'the pull request is not mergeable (mergeable=CONFLICTING)' "$case_dir/stderr" \
    "not-mergeable: refusal did not name the mergeable state"
  assert_grep "$head" "$case_dir/stderr" \
    "not-mergeable: refusal did not name the head commit it evaluated"
  assert_no_merge_side_effects "$case_dir" not-mergeable
  pass "fm-pr-merge refuses a pull request that is not mergeable"
}

# GitHub computes mergeability asynchronously, so UNKNOWN means "not yet known",
# never "fine". It must refuse rather than merge on an unread state.
test_unknown_mergeable_refuses() {
  local case_dir rc head=4141414141414141414141414141414141414141
  case_dir=$(make_case unknown-mergeable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_verify_payload "$case_dir/verify.txt" "$head" UNKNOWN '' 10 0
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/35 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unknown-mergeable: an uncomputed mergeable state must refuse the merge"
  assert_grep 'the pull request is not mergeable (mergeable=UNKNOWN)' "$case_dir/stderr" \
    "unknown-mergeable: refusal did not name the uncomputed mergeable state"
  assert_no_merge_side_effects "$case_dir" unknown-mergeable
  pass "fm-pr-merge refuses a pull request whose mergeability is not yet computed"
}

test_changes_requested_refuses() {
  local case_dir rc head=5151515151515151515151515151515151515151
  case_dir=$(make_case changes-requested)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_verify_payload "$case_dir/verify.txt" "$head" MERGEABLE CHANGES_REQUESTED 10 0
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/36 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "changes-requested: a review requesting changes must refuse the merge"
  assert_grep 'a review requests changes' "$case_dir/stderr" \
    "changes-requested: refusal did not name the blocking review"
  assert_grep "$head" "$case_dir/stderr" \
    "changes-requested: refusal did not name the head commit it evaluated"
  assert_no_merge_side_effects "$case_dir" changes-requested
  pass "fm-pr-merge refuses a pull request whose review requests changes"
}

# An approved review is not a blocker, so it must not be swept up with the
# changes-requested refusal.
test_approved_review_still_merges() {
  local case_dir rc
  case_dir=$(make_case approved-review)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$GREEN_HEAD"
  write_verify_payload "$case_dir/verify.txt" "$GREEN_HEAD" MERGEABLE APPROVED 10 0
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/37 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "approved-review: an approved green PR must still merge"
  grep -qxF 'pr merge 37 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "approved-review: an approved green PR was not merged"
  pass "fm-pr-merge merges a green pull request that a review approved"
}

# A truncated or garbled response must refuse rather than fall through the
# numeric comparisons. An absent check count paired with a zero failure count is
# the shape that most easily reads as "nothing wrong here".
test_unreadable_check_counts_refuse() {
  local case_dir rc head=8181818181818181818181818181818181818181
  case_dir=$(make_case unreadable-counts)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf 'head=%s\nmergeable=MERGEABLE\nreview=\nchecks=\nunsuccessful=0\n' "$head" \
    > "$case_dir/verify.txt"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/40 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreadable-counts: an unreadable check count must refuse the merge"
  assert_grep 'the check rollup could not be read from GitHub' "$case_dir/stderr" \
    "unreadable-counts: refusal did not name the unreadable check rollup"
  assert_no_merge_side_effects "$case_dir" unreadable-counts

  # The mirrored shape: a readable count with an unreadable failure count.
  printf 'head=%s\nmergeable=MERGEABLE\nreview=\nchecks=3\nunsuccessful=\n' "$head" \
    > "$case_dir/verify.txt"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/40 \
    > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreadable-counts: an unreadable failure count must refuse the merge"
  assert_grep 'the check rollup could not be read from GitHub' "$case_dir/stderr2" \
    "unreadable-counts: refusal did not name the unreadable failure count"
  assert_no_merge_side_effects "$case_dir" unreadable-counts-mirrored
  pass "fm-pr-merge refuses a check rollup it could not read as two whole counts"
}

test_unreadable_forge_state_refuses() {
  local case_dir rc
  case_dir=$(make_case unreadable-state)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$GREEN_HEAD"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_GH_VERIFY_RC=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/38 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreadable-state: an unreadable pull request must refuse the merge"
  assert_grep 'could not be read from GitHub' "$case_dir/stderr" \
    "unreadable-state: refusal did not explain the unreadable pull request"
  assert_no_merge_side_effects "$case_dir" unreadable-state
  pass "fm-pr-merge refuses when the pull request state cannot be read"
}

# gh ships in the same system directory as the utilities the script needs, so a
# PATH filtered by directory would strip both. Build a curated directory holding
# the tools this path uses and no gh at all. A tool this misses shows up as a
# loud 127 rather than a quietly wrong pass.
minimal_bin_without_gh() {
  local dir=$1 tool src
  mkdir -p "$dir"
  # bash and env are needed for the #!/usr/bin/env bash shebang to resolve.
  for tool in bash env dirname uname stat mktemp grep chmod mv rm cat sed; do
    src=$(command -v "$tool" 2>/dev/null) && ln -sf "$src" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

# An absent forge CLI must refuse rather than skip verification.
test_absent_gh_refuses() {
  local case_dir rc
  case_dir=$(make_case absent-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$GREEN_HEAD"
  rm -f "$case_dir/fakebin/gh"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_PATH_OVERRIDE="$case_dir/fakebin:$(minimal_bin_without_gh "$case_dir/minbin")" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/39 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "absent-gh: a missing forge CLI must refuse the merge"
  assert_grep 'gh is not on PATH' "$case_dir/stderr" \
    "absent-gh: refusal did not name the missing forge CLI"
  assert_no_merge_side_effects "$case_dir" absent-gh
  pass "fm-pr-merge refuses rather than merging unverified when gh is unavailable"
}

# --- explicit override ------------------------------------------------------

test_allow_unverified_merges_and_records_override() {
  local case_dir rc head=6161616161616161616161616161616161616161
  case_dir=$(make_case override-allowed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  # Red on every axis, so only the explicit override can let this through.
  write_verify_payload "$case_dir/verify.txt" "$head" CONFLICTING CHANGES_REQUESTED 0 0
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/41 --allow-unverified \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "override-allowed: the explicit override should merge"
  grep -qxF 'pr merge 41 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "override-allowed: the overridden merge did not run"
  assert_grep 'merge_verification=override' "$case_dir/state/task-x1.meta" \
    "override-allowed: the override was not recorded in the task record"
  assert_no_grep 'merge_verification=verified' "$case_dir/state/task-x1.meta" \
    "override-allowed: an unverified merge was recorded as verified"
  assert_no_grep 'merge_verified_head=' "$case_dir/state/task-x1.meta" \
    "override-allowed: an unverified merge recorded a verified head"
  assert_no_grep 'statusCheckRollup' "$case_dir/gh.log" \
    "override-allowed: the override still queried the forge for a verification it ignores"
  pass "fm-pr-merge merges on the explicit override and records it as unverified"
}

test_verified_merge_records_verification() {
  local case_dir rc
  case_dir=$(make_case override-recorded-verified)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$GREEN_HEAD"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/42 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "override-recorded-verified: a green PR should merge"
  assert_grep 'merge_verification=verified' "$case_dir/state/task-x1.meta" \
    "override-recorded-verified: a verified merge was not recorded as verified"
  assert_grep "merge_verified_head=$GREEN_HEAD" "$case_dir/state/task-x1.meta" \
    "override-recorded-verified: the verified head was not recorded"
  assert_no_grep 'merge_verification=override' "$case_dir/state/task-x1.meta" \
    "override-recorded-verified: a verified merge was recorded as an override"
  pass "fm-pr-merge records the verified head so a verified merge is distinguishable"
}

test_final_verification_refuses_changed_head() {
  local case_dir rc
  local early_head=9191919191919191919191919191919191919191
  local changed_head=9292929292929292929292929292929292929292
  case_dir=$(make_case final-verification-race)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$early_head"
  write_green_payload "$case_dir/verify-sequence.1" "$early_head"
  write_verify_payload "$case_dir/verify-sequence.2" "$changed_head" MERGEABLE '' 10 1
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  FM_TEST_GH_VERIFY_SEQUENCE_PREFIX="$case_dir/verify-sequence" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "final-verification-race: a changed red head must refuse the merge"
  assert_grep '1 of 10 check runs are not successful' "$case_dir/stderr" \
    "final-verification-race: the final check did not report the changed head's failure"
  assert_grep "$changed_head" "$case_dir/stderr" \
    "final-verification-race: the refusal did not name the changed head"
  assert_grep 'pr=https://github.com/example/repo/pull/44' "$case_dir/state/task-x1.meta" \
    "final-verification-race: the final check did not run after fm-pr-check"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "final-verification-race: the changed red head still reached gh-axi pr merge"
  pass "fm-pr-merge re-verifies after fm-pr-check and refuses a changed red head"
}

# The override must be an explicit flag on this invocation and nothing else: no
# environment fallback, and no smuggling it through to gh-axi after --.
test_override_is_never_inferred() {
  local case_dir rc head=7171717171717171717171717171717171717171
  case_dir=$(make_case override-not-inferred)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_verify_payload "$case_dir/verify.txt" "$head" MERGEABLE '' 0 0
  : > "$case_dir/gh-axi.log"

  set +e
  FM_ALLOW_UNVERIFIED=1 ALLOW_UNVERIFIED=1 FM_PR_MERGE_ALLOW_UNVERIFIED=1 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "override-not-inferred: an environment variable must not grant the override"
  assert_grep 'no check runs exist on this head' "$case_dir/stderr" \
    "override-not-inferred: the environment variable suppressed the refusal"
  assert_no_grep 'merge_verification=override' "$case_dir/state/task-x1.meta" \
    "override-not-inferred: an environment variable recorded an override"
  assert_no_merge_side_effects "$case_dir" override-not-inferred

  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/43 -- --allow-unverified \
    > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e

  expect_code 1 "$rc" "override-not-inferred: --allow-unverified after -- must not grant the override"
  assert_grep 'no check runs exist on this head' "$case_dir/stderr2" \
    "override-not-inferred: a forwarded flag suppressed the refusal"
  assert_no_merge_side_effects "$case_dir" override-not-inferred-after-separator
  pass "fm-pr-merge grants the override only for the explicit flag, never from the environment or after --"
}

# --- the real GitHub query, end to end --------------------------------------

# The cases above feed fm-pr-merge.sh a canned answer, which proves the branch
# logic but not the query that produces it. Here the mock evaluates the script's
# own -q expression against JSON shaped exactly like the GitHub responses this
# guard was built from, so a query that mis-reads the API is caught too.
# jq is the same filter language gh embeds; the case is skipped without it.
write_rollup_fixture() {
  printf '{"headRefOid":"%s","mergeable":"%s","reviewDecision":"%s","statusCheckRollup":%s}\n' \
    "$2" "$3" "$4" "$5" > "$1"
}

check_runs_json() {
  local total=$1 conclusion=$2 i out=
  for ((i = 0; i < total; i++)); do
    out="$out{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"$conclusion\"},"
  done
  printf '%s' "$out"
}

run_fixture_case() {
  local name=$1 rollup=$2 mergeable=$3 review=$4 number=$5 expect_rc=$6 expect_msg=$7
  local case_dir rc head=9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a9a
  case_dir=$(make_case "fixture-$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_rollup_fixture "$case_dir/pr.json" "$head" "$mergeable" "$review" "$rollup"
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_GH_FIXTURE="$case_dir/pr.json" \
    run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$number" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code "$expect_rc" "$rc" "fixture-$name: unexpected outcome from the real query"
  if [ "$expect_rc" -eq 0 ]; then
    grep -qxF "pr merge $number --repo example/repo --squash" "$case_dir/gh-axi.log" \
      || fail "fixture-$name: a green fixture was not merged"
  else
    assert_grep "$expect_msg" "$case_dir/stderr" \
      "fixture-$name: refusal did not name the expected condition"
    assert_no_merge_side_effects "$case_dir" "fixture-$name"
  fi
}

test_real_query_against_api_shaped_json() {
  if ! command -v jq >/dev/null 2>&1; then
    pass "fm-pr-merge real-query control skipped: jq is not installed"
    return 0
  fi
  local success_runs
  success_runs=$(check_runs_json 10 SUCCESS)

  # An empty rollup: the exact shape the incident PR returned.
  run_fixture_case empty-rollup '[]' MERGEABLE '' 51 1 'no check runs exist on this head'
  # A null rollup: a head GitHub reports no rollup for at all.
  run_fixture_case null-rollup 'null' MERGEABLE '' 52 1 'no check runs exist on this head'
  # Ten successful check runs: the same zero failures, but genuinely green.
  run_fixture_case all-success "[${success_runs%,}]" MERGEABLE '' 53 0 ''
  # One still-running check run among nine passes: not yet an observed pass.
  run_fixture_case in-progress \
    "[${success_runs%,},{\"__typename\":\"CheckRun\",\"status\":\"IN_PROGRESS\",\"conclusion\":\"\"}]" \
    MERGEABLE '' 54 1 '1 of 11 check runs are not successful'
  # A held cross-repo workflow reports ACTION_REQUIRED rather than a pass.
  run_fixture_case action-required \
    '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"ACTION_REQUIRED"}]' \
    MERGEABLE '' 55 1 '1 of 1 check runs are not successful'
  # A legacy commit status carries .state instead of .conclusion.
  run_fixture_case legacy-status-success \
    '[{"__typename":"StatusContext","context":"ci/legacy","state":"SUCCESS"}]' \
    MERGEABLE '' 56 0 ''
  run_fixture_case legacy-status-failure \
    '[{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"}]' \
    MERGEABLE '' 57 1 '1 of 1 check runs are not successful'
  # Mergeability and review decision read off the same single response.
  run_fixture_case conflicting "[${success_runs%,}]" CONFLICTING '' 58 1 \
    'the pull request is not mergeable (mergeable=CONFLICTING)'
  run_fixture_case changes-requested "[${success_runs%,}]" MERGEABLE CHANGES_REQUESTED 59 1 \
    'a review requests changes'
  pass "fm-pr-merge's own GitHub query reads API-shaped responses correctly, empty rollups included"
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
test_zero_check_runs_refuses
test_all_successful_checks_still_merges
test_failing_check_run_refuses
test_not_mergeable_refuses
test_unknown_mergeable_refuses
test_changes_requested_refuses
test_approved_review_still_merges
test_unreadable_check_counts_refuse
test_unreadable_forge_state_refuses
test_absent_gh_refuses
test_allow_unverified_merges_and_records_override
test_verified_merge_records_verification
test_final_verification_refuses_changed_head
test_override_is_never_inferred
test_real_query_against_api_shaped_json
