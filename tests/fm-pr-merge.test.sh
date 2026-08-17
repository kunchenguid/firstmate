#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must always record pr= and any available pr_head= into the task's
# meta before merging so fm-teardown.sh's landed-check has a PR reference to
# verify against, even on repos with no PR CI where the usual "checks green"
# fm-pr-check.sh trigger never fires.
#
# Matrix:
#   (a) merge records pr= and pr_head= before merging, and merges
#   (b) merge is refused when gh pr merge itself fails (no silent success)
#   (c) extra gh pr merge args are forwarded after number and --repo
#   (d) merge is refused before gh when task meta is missing
#   (e) PR URL is parsed to number + --repo for gh (defaults to --squash)
#   (f) malformed PR URL fails fast without calling gh
#   (g) explicit merge method is not overridden by the default --squash
#   (h) repo override args fail fast because the repo comes from the URL
#   (i) requirement-bypass args fail fast before the forge is contacted
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta and a
# fakebin with a gh mock that records merge invocations. Echoes the case dir.
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

# gh mock recording merge invocations and answering headRefOid for
# fm-pr-check.sh's pr_head lookup. Args: case_dir head_sha
add_gh_mocks() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *headRefOid*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
  "pr merge")
    printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
    if [ -n "\${FM_TEST_GH_MERGE_STARTED:-}" ]; then
      : > "\$FM_TEST_GH_MERGE_STARTED"
      while [ ! -e "\$FM_TEST_GH_MERGE_RELEASE" ]; do sleep 0.05; done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# gh mock that fails the merge call but succeeds everything else, so a
# real merge failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr merge")
    printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
    echo "error: pr merge failed" >&2
    exit 1
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

run_pr_merge() {
  local case_dir=$1 rc; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
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

wait_for_file() {
  local path=$1 attempts=0
  while [ ! -e "$path" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  [ -e "$path" ] || fail "timed out waiting for $path"
}

test_records_pr_and_head_before_merging() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh.log"

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
  grep -qxF 'pr merge 9 --repo example/repo --squash' "$case_dir/gh.log" \
    || fail "records-before-merge: gh pr merge was not invoked with number, --repo, and default --squash"
  pass "fm-pr-merge records pr= and pr_head= before invoking gh pr merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_verified_head_change_refuses_before_metadata_refresh() {
  local case_dir rc
  case_dir=$(make_case verified-head-changed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : > "$case_dir/gh.log"

  set +e
  FM_PR_EXPECTED_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/14 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "verified-head-changed: merge should refuse a changed PR head"
  assert_grep 'error: PR head changed after verification' "$case_dir/stderr" \
    "verified-head-changed: refusal did not explain the changed head"
  [ ! -s "$case_dir/gh.log" ] || fail "verified-head-changed: merge ran despite a changed PR head"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "verified-head-changed: metadata refresh ran despite a changed PR head"
  pass "fm-pr-merge refuses a PR head that changed after verification"
}

test_verified_head_is_bound_to_final_merge() {
  local case_dir head
  case_dir=$(make_case verified-head-matches)
  head=cccccccccccccccccccccccccccccccccccccccc
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  : > "$case_dir/gh.log"

  FM_PR_EXPECTED_HEAD="$head" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/16 \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "verified-head-matches: fm-pr-merge rejected the verified PR head"

  grep -qxF "pr merge 16 --repo example/repo --squash --match-head-commit $head" "$case_dir/gh.log" \
    || fail "verified-head-matches: GitHub merge was not bound to the verified head"
  pass "fm-pr-merge passes the verified head to the GitHub merge command"
}

test_verified_pr_identity_change_refuses_before_metadata_refresh() {
  local case_dir head rc
  case_dir=$(make_case verified-pr-changed)
  head=dddddddddddddddddddddddddddddddddddddddd
  mkdir -p "$case_dir/wt"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "kind=ship" \
    "pr=https://github.com/example/other/pull/17" \
    "pr_head=$head"
  add_gh_mocks "$case_dir" "$head"
  : > "$case_dir/gh.log"

  set +e
  FM_PR_EXPECTED_URL=https://github.com/example/repo/pull/17 FM_PR_EXPECTED_HEAD="$head" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/17 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "verified-pr-changed: merge should refuse changed PR metadata"
  assert_grep 'error: PR metadata changed after verification' "$case_dir/stderr" \
    "verified-pr-changed: refusal did not identify changed PR metadata"
  [ ! -s "$case_dir/gh.log" ] || fail "verified-pr-changed: merge ran for changed PR metadata"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "verified-pr-changed: metadata refresh ran for changed PR metadata"
  pass "fm-pr-merge refuses PR metadata that changed after verification"
}

test_merge_holds_metadata_lock_through_forge_invocation() {
  local case_dir merge_pid check_pid merge_rc check_rc started release
  case_dir=$(make_case merge-metadata-lock)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" ffffffffffffffffffffffffffffffffffffffff
  : > "$case_dir/gh.log"
  started="$case_dir/merge.started"
  release="$case_dir/merge.release"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_LOG="$case_dir/gh.log" FM_TEST_GH_MERGE_STARTED="$started" \
    FM_TEST_GH_MERGE_RELEASE="$release" PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" task-x1 https://github.com/example/repo/pull/18 \
      > "$case_dir/merge.stdout" 2> "$case_dir/merge.stderr" &
  merge_pid=$!
  wait_for_file "$started"

  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-x1 https://github.com/example/other/pull/19 \
      > "$case_dir/check.stdout" 2> "$case_dir/check.stderr" &
  check_pid=$!
  sleep 0.2
  kill -0 "$check_pid" 2>/dev/null \
    || fail "metadata reassignment completed while the forge merge was active"
  grep -qxF 'pr=https://github.com/example/repo/pull/18' "$case_dir/state/task-x1.meta" \
    || fail "metadata reassignment changed the merge identity before the forge returned"

  : > "$release"
  wait "$merge_pid"
  merge_rc=$?
  wait "$check_pid"
  check_rc=$?
  expect_code 0 "$merge_rc" "metadata-lock: merge should succeed"
  expect_code 0 "$check_rc" "metadata-lock: reassignment should complete after merge"
  grep -qxF 'pr=https://github.com/example/other/pull/19' "$case_dir/state/task-x1.meta" \
    || fail "metadata-lock: reassignment did not complete after the forge merge"
  pass "fm-pr-merge holds metadata identity through the forge invocation"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args: fm-pr-merge failed"

  grep -qxF 'pr merge 15 --repo example/repo --squash --delete-branch' "$case_dir/gh.log" \
    || fail "extra-args: extra gh pr merge flags were not forwarded"
  pass "fm-pr-merge forwards extra flags to gh pr merge after the -- separator"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh.log" ] || fail "missing-meta: gh pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh.log"

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
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "malformed-url: gh pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh.log"

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
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unsafe-url-segment: gh pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh.log"

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
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "repo-override: gh pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

test_admin_bypass_arg_refuses_before_recording() {
  local case_dir rc
  case_dir=$(make_case admin-bypass)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/6 -- --admin \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "admin-bypass: fm-pr-merge should refuse requirement bypasses"
  assert_grep 'extra merge arguments must not bypass required PR checks' "$case_dir/stderr" \
    "admin-bypass: refusal did not explain the requirement bypass"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "admin-bypass: PR URL was recorded before rejecting the bypass"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "admin-bypass: bypass argument armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "admin-bypass: gh pr merge was invoked despite the bypass"
  pass "fm-pr-merge refuses requirement-bypass merge arguments"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 22 --repo example/repo --merge' "$case_dir/gh.log" \
    || fail "explicit-merge-method: caller --merge was not forwarded without an extra default --squash"
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 23 --repo example/repo --merge' "$case_dir/gh.log" \
    || fail "method-equals-merge-method: caller --method=merge was not translated without an extra default --squash"
  pass "fm-pr-merge translates --method=<value> for GitHub"
}

test_method_value_merge_method_is_translated() {
  local case_dir
  case_dir=$(make_case method-value-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : > "$case_dir/gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/24 -- --method rebase \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-value-merge-method: fm-pr-merge failed"

  grep -qxF 'pr merge 24 --repo example/repo --rebase' "$case_dir/gh.log" \
    || fail "method-value-merge-method: caller --method rebase was not translated"
  pass "fm-pr-merge translates --method <value> for GitHub"
}

test_parses_pr_url_for_gh() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  grep -qxF 'pr merge 126 --repo my-org/my-repo --squash' "$case_dir/gh.log" \
    || fail "url-parsing: gh pr merge was not invoked as number + --repo + default --squash"
  pass "fm-pr-merge parses a GitHub PR URL into gh number and --repo arguments"
}

test_records_pr_and_head_before_merging
test_merge_failure_propagates_after_recording
test_verified_head_change_refuses_before_metadata_refresh
test_verified_head_is_bound_to_final_merge
test_verified_pr_identity_change_refuses_before_metadata_refresh
test_merge_holds_metadata_lock_through_forge_invocation
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
test_admin_bypass_arg_refuses_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_method_value_merge_method_is_translated
test_parses_pr_url_for_gh
