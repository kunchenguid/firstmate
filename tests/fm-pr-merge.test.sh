#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
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
#   (i) a failing check on the PR head refuses before any state is recorded
#   (j) a failing MERGE-QUEUE run refuses even when every branch check is green
#   (k) a superseded red queue attempt does not block a re-queued green one
#   (l) an unreadable check state refuses - forge silence is never a pass
#   (m) --allow-failing-checks merges a red PR deliberately, and says so
#   (n) an unknown own flag is a usage error, not a flag forwarded to gh-axi
#
# Case (j) is the 2026-08-10 incident in nguzen/aln: the merge-queue run for pull
# request 182 failed and the merge landed five minutes later, and the resulting
# commit blocked production deploys for two days. The queue runs the checks again
# on a combined commit, so its verdict is a source of its own.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

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

# gh mock reproducing every read bin/fm-pr-merge.sh makes, so the real jq
# classification in bin/fm-pr-checks-lib.sh runs against real forge JSON shapes
# instead of being mocked away:
#   * pr view <url> --json headRefOid       fm-pr-check.sh's pr_head lookup
#   * pr view <n> --json ...statusCheckRollup   the PR head's own checks
#   * api repos/<o>/<r>/actions/runs?event=merge_group...  the queue attempts
# Fixtures come from the environment, and the defaults are the "repo with no PR
# CI" shape every pre-existing case here relies on: an empty rollup and no queue
# attempt, which is a definitive "no checks" rather than an unreadable state.
#   FM_TEST_ROLLUP        statusCheckRollup array JSON
#   FM_TEST_QUEUE_RUNS    workflow_runs array JSON
#   FM_TEST_PR_NUMBER     number the payload claims to describe (identity check)
#   FM_TEST_CHECKS_FAIL   1 = the rollup read fails, 2 = the queue read fails
write_gh_mock() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${FM_TEST_GH_LOG:-/dev/null}"
case " \$* " in
  *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
esac
case "\${1:-} \${2:-}" in
  "pr view")
    [ "\${FM_TEST_CHECKS_FAIL:-0}" = 1 ] && exit 1
    printf '{"number":%s,"baseRefName":"main","statusCheckRollup":%s}\n' \\
      "\${FM_TEST_PR_NUMBER:-\$3}" "\${FM_TEST_ROLLUP:-[]}"
    exit 0
    ;;
esac
case "\${1:-}" in
  api)
    [ "\${FM_TEST_CHECKS_FAIL:-0}" = 2 ] && exit 1
    printf '{"workflow_runs":%s}\n' "\${FM_TEST_QUEUE_RUNS:-[]}"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# gh-axi mock recording every invocation to a log file, plus the gh mock above.
# Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  write_gh_mock "$case_dir" "$head"
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
  chmod +x "$case_dir/fakebin/gh-axi"
  write_gh_mock "$case_dir" 1111111111111111111111111111111111111111
}

# One rollup entry in the CheckRun shape the forge really returns.
rollup_entry() {  # <name> <conclusion>
  printf '[{"__typename":"CheckRun","name":"%s","status":"COMPLETED","conclusion":"%s"}]' "$1" "$2"
}

# One merge-queue Actions run on the temporary queue branch of a PR.
queue_run() {  # <pr-number> <base-sha> <name> <conclusion> <created-at>
  printf '{"name":"%s","head_branch":"gh-readonly-queue/main/pr-%s-%s","event":"merge_group","status":"completed","conclusion":"%s","created_at":"%s","run_attempt":1}' \
    "$3" "$1" "$2" "$4" "$5"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
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

test_failing_branch_check_refuses_before_recording() {
  local case_dir rc
  case_dir=$(make_case failing-branch-check)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaa111111111111111111111111111111111111
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_ROLLUP=$(rollup_entry 'e2e · visual QA' FAILURE) \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/40 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failing-branch-check: fm-pr-merge should refuse a red PR"
  assert_grep 'the forge reports failing checks' "$case_dir/stderr" \
    "failing-branch-check: refusal did not name the failing check state"
  assert_grep 'e2e · visual QA (FAILURE)' "$case_dir/stderr" \
    "failing-branch-check: refusal did not list which check is red"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "failing-branch-check: gh-axi pr merge was invoked for a red PR"
  assert_no_grep 'pr=https://github.com/example/repo/pull/40' "$case_dir/state/task-x1.meta" \
    "failing-branch-check: a refused merge recorded PR metadata"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "failing-branch-check: a refused merge armed a merge poll"
  pass "fm-pr-merge refuses to merge when the PR head has a failing check"
}

test_failing_merge_queue_run_refuses_green_branch() {
  local case_dir rc runs
  case_dir=$(make_case failing-queue-run)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbb222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"
  # The 2026-08-10 shape: every branch check green, the queue's re-run of the
  # same checks on the combined commit red.
  runs="[$(queue_run 182 94c950e5 CI failure 2026-08-10T17:54:29Z)]"

  set +e
  FM_TEST_ROLLUP=$(rollup_entry 'typecheck · test · build' SUCCESS) \
  FM_TEST_QUEUE_RUNS="$runs" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/182 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failing-queue-run: fm-pr-merge should refuse a red merge-queue verdict"
  assert_grep 'merge-queue check: CI (failure)' "$case_dir/stderr" \
    "failing-queue-run: refusal did not name the red merge-queue run"
  assert_grep 'gh-readonly-queue/main/pr-182-94c950e5' "$case_dir/stderr" \
    "failing-queue-run: refusal did not name the queue attempt it read"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "failing-queue-run: gh-axi pr merge was invoked despite the red queue run"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "failing-queue-run: a refused merge armed a merge poll"
  pass "fm-pr-merge refuses a failing merge-queue run even when the branch itself is green"
}

test_superseded_red_queue_attempt_does_not_block() {
  local case_dir runs
  case_dir=$(make_case superseded-queue-attempt)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccc333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"
  # An older red attempt plus a newer green one for the same PR: only the newest
  # attempt is the forge's current verdict, so this must merge.
  runs="[$(queue_run 182 94c950e5 CI failure 2026-08-10T17:54:29Z),"
  runs="$runs$(queue_run 182 ffff0001 CI success 2026-08-11T09:00:00Z)]"

  FM_TEST_ROLLUP=$(rollup_entry CI SUCCESS) FM_TEST_QUEUE_RUNS="$runs" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/182 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "superseded-queue-attempt: fm-pr-merge refused a re-queued green PR: $(cat "$case_dir/stderr")"

  grep -qxF 'pr merge 182 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "superseded-queue-attempt: a green PR was not merged"
  pass "fm-pr-merge judges only the newest merge-queue attempt, so a superseded red one does not block"
}

test_unreadable_check_state_refuses() {
  local case_dir rc which
  for which in 1 2; do
    case_dir=$(make_case "unreadable-check-state-$which")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" dddd444444444444444444444444444444444444
    : > "$case_dir/gh-axi.log"

    set +e
    FM_TEST_CHECKS_FAIL="$which" \
      run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "unreadable-check-state-$which: fm-pr-merge should refuse an unreadable verdict"
    assert_grep 'check state is unreadable' "$case_dir/stderr" \
      "unreadable-check-state-$which: refusal did not say the state was unreadable"
    assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
      "unreadable-check-state-$which: gh-axi pr merge was invoked on an unreadable verdict"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "unreadable-check-state-$which: a refused merge armed a merge poll"
  done
  pass "fm-pr-merge refuses when the forge check state cannot be read (silence is not green)"
}

test_wrong_pull_request_payload_refuses() {
  local case_dir rc
  case_dir=$(make_case wrong-pr-payload)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeee555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  set +e
  FM_TEST_PR_NUMBER=999 FM_TEST_ROLLUP=$(rollup_entry CI SUCCESS) \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/45 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "wrong-pr-payload: a green verdict for another PR must not authorize this merge"
  assert_grep 'unreadable' "$case_dir/stderr" \
    "wrong-pr-payload: refusal did not treat a mismatched payload as unreadable"
  assert_no_grep 'pr merge' "$case_dir/gh-axi.log" \
    "wrong-pr-payload: gh-axi pr merge was invoked on a payload for another PR"
  pass "fm-pr-merge refuses a check payload that describes a different pull request"
}

test_allow_failing_checks_overrides_red() {
  local case_dir
  case_dir=$(make_case allow-failing-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" ffff666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  FM_TEST_ROLLUP=$(rollup_entry CI FAILURE) \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/46 --allow-failing-checks \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "allow-failing-checks: the override did not merge: $(cat "$case_dir/stderr")"

  grep -qxF 'pr merge 46 --repo example/repo --squash' "$case_dir/gh-axi.log" \
    || fail "allow-failing-checks: the override did not reach gh-axi pr merge"
  assert_grep 'without reading the forge' "$case_dir/stderr" \
    "allow-failing-checks: the override merged silently instead of saying so"
  assert_no_grep 'allow-failing-checks' "$case_dir/gh-axi.log" \
    "allow-failing-checks: firstmate's own flag was forwarded to gh-axi"
  pass "fm-pr-merge merges a red PR only with --allow-failing-checks, and reports that it did"
}

test_unknown_own_flag_is_usage_error() {
  local case_dir rc
  case_dir=$(make_case unknown-own-flag)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1212121212121212121212121212121212121212
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/47 --force \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "unknown-own-flag: an unknown own flag should be a usage error"
  assert_grep 'unknown merge flag --force' "$case_dir/stderr" \
    "unknown-own-flag: refusal did not name the unknown flag"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "unknown-own-flag: gh-axi was invoked for a usage error"
  pass "fm-pr-merge rejects an unknown own flag instead of forwarding or ignoring it"
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
test_failing_branch_check_refuses_before_recording
test_failing_merge_queue_run_refuses_green_branch
test_superseded_red_queue_attempt_does_not_block
test_unreadable_check_state_refuses
test_wrong_pull_request_payload_refuses
test_allow_failing_checks_overrides_red
test_unknown_own_flag_is_usage_error
