#!/usr/bin/env bash
# Regression tests for bin/fm-pr-check.sh's branch-identity check: a PR whose
# head branch is not this task's own branch (2026-09-05 shell/174 incident,
# see the script's own header) must be refused unless --prerequisite is
# passed, and a prerequisite PR must record under prerequisite_pr=, never
# pr=. tests/fm-pr-check-security.test.sh owns the broader canonical-PR
# parsing, poll, and private-artifact regression surface; this file owns
# only the branch-identity contract described above.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# A fake gh answering headRefName (this test file's own concern) and
# headRefOid (so the unrelated pr_head lookup does not fail the case), each
# overridable per invocation via FM_TEST_GH_BRANCH / FM_TEST_GH_HEAD.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$dir/wt" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *headRefName*) printf '%s\n' "${FM_TEST_GH_BRANCH:-fm/task-a}" ; exit 0 ;;
      *headRefOid*) printf '%s\n' "${FM_TEST_GH_HEAD:-}" ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$dir"
}

write_task_meta() {
  local dir=$1 id=${2:-task-a}
  fm_write_meta "$dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
}

run_pr_check() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/state" \
  PATH="$dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

test_mismatched_branch_refused() {
  local dir rc
  dir=$(make_case mismatch)
  write_task_meta "$dir" task-a

  set +e
  FM_TEST_GH_BRANCH=fm/other-task \
    run_pr_check "$dir" task-a https://github.com/example/repo/pull/5 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mismatch: fm-pr-check should refuse a PR built on another task's branch"
  assert_grep 'fm/other-task' "$dir/stderr" \
    "mismatch: refusal did not name the PR's observed head branch"
  assert_grep 'fm/task-a' "$dir/stderr" \
    "mismatch: refusal did not name the task's expected branch"
  assert_grep '--prerequisite' "$dir/stderr" \
    "mismatch: refusal did not mention the --prerequisite escape hatch"
  assert_no_grep 'pr=https://github.com/example/repo/pull/5' "$dir/state/task-a.meta" \
    "mismatch: a mismatched PR was recorded as this task's own delivery"
  pass "fm-pr-check refuses a PR whose head branch is not this task's own"
}

test_retry_suffix_accepted() {
  local dir rc suffix
  for suffix in -fix1 -r2; do
    dir=$(make_case "suffix$suffix")
    write_task_meta "$dir" task-a

    set +e
    FM_TEST_GH_BRANCH="fm/task-a$suffix" \
      run_pr_check "$dir" task-a https://github.com/example/repo/pull/6 \
      > "$dir/stdout" 2> "$dir/stderr"
    rc=$?
    set -e

    expect_code 0 "$rc" "suffix$suffix: fm-pr-check should accept a retry-suffixed branch"
    assert_grep 'pr=https://github.com/example/repo/pull/6' "$dir/state/task-a.meta" \
      "suffix$suffix: pr= was not recorded for a matching retry branch"
  done
  pass "fm-pr-check accepts an fm/<task-id> branch carrying a -fixN or -rN retry suffix"
}

test_prerequisite_recorded_separately() {
  local dir rc
  dir=$(make_case prerequisite)
  write_task_meta "$dir" task-a

  set +e
  FM_TEST_GH_BRANCH=fm/other-task \
    run_pr_check "$dir" --prerequisite task-a https://github.com/example/repo/pull/8 \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "prerequisite: --prerequisite should record a PR built for other work"
  assert_grep 'prerequisite_pr=https://github.com/example/repo/pull/8' "$dir/state/task-a.meta" \
    "prerequisite: prerequisite_pr= was not recorded"
  # A plain substring check for "pr=<url>" would also match inside
  # "prerequisite_pr=<url>" (it literally ends in "..._pr="), so the real
  # invariant - no exact pr= line - needs the anchored regex below instead.
  ! grep -qE '^pr=' "$dir/state/task-a.meta" \
    || fail "prerequisite: the prerequisite PR was recorded as pr= instead of prerequisite_pr="
  pass "fm-pr-check records a --prerequisite PR under prerequisite_pr=, never pr="
}

test_mismatched_branch_refused
test_retry_suffix_accepted
test_prerequisite_recorded_separately
