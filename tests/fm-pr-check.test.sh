#!/usr/bin/env bash
# Tests for bin/fm-pr-check.sh: records pr= and the forge's pr_head= into
# state/<id>.meta, then arms state/<id>.check.sh to poll for merge. The PR
# URL's shape (bin/fm-pr-url-lib.sh) picks the forge: a GitHub URL
# (.../pull/<n>) uses gh; a Gitea URL (any host, plural .../pulls/<n>) uses tea,
# run with cwd inside the task's worktree so tea auto-discovers the login/host
# from its origin remote.
#
# Matrix:
#   (a) GitHub URL records pr= and pr_head= via gh; arms a gh-based check.sh
#   (b) GitHub check.sh reports "merged" when gh reports state MERGED
#   (c) Gitea URL records pr= and pr_head= via tea; arms a tea-based check.sh
#   (d) Gitea check.sh reports "merged" when tea reports hasMerged true
#   (e) Gitea check.sh stays silent when tea reports hasMerged false
#   (f) no worktree on disk: pr= is still recorded, pr_head= is skipped (both forges)
#   (g) Gitea check.sh re-reads the worktree from meta at poll time, so a
#       worktree that appears after arming (not just at arm time) still lets
#       the merge poll succeed instead of silently failing forever
#   (h) Bitbucket URL (any host, plural "pull-requests") has no gh/tea CLI here:
#       pr= is recorded without pr_head= even with a worktree present, and the
#       armed check.sh is the silent manual-merge poll
#   (i) Bitbucket check.sh stays silent (the merge happens manually in the browser)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-tests)

# Build a fresh sandbox for one test case: a state dir with a task meta (whose
# worktree exists on disk unless the caller skips mkdir) and a fakebin. Echoes
# the case dir.
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
  printf '%s\n' "$case_dir"
}

add_gh_mock() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
      *"state"*) printf '%s\n' 'MERGED' ; exit 0 ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh"
}

# tea mock: `tea pulls <n> --repo <owner/repo> -o json` prints headSha/hasMerged.
add_tea_mock() {
  local case_dir=$1 head=$2 merged=$3
  cat > "$case_dir/fakebin/tea" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pulls "*)
    printf '{"headSha":"%s","hasMerged":%s}\n' '$head' '$merged' ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tea"
}

run_pr_check() {
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$@"
}

test_github_records_pr_head_and_arms_check() {
  local case_dir rc
  case_dir=$(make_case github-record)
  mkdir -p "$case_dir/wt"
  add_gh_mock "$case_dir" cafefeeddeadbeef0000000000000000cafefeed

  set +e
  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-record: fm-pr-check should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "github-record: pr= was not recorded"
  assert_grep 'pr_head=cafefeeddeadbeef0000000000000000cafefeed' "$case_dir/state/task-x1.meta" \
    "github-record: pr_head= was not recorded"
  assert_grep 'gh pr view' "$case_dir/state/task-x1.check.sh" \
    "github-record: check.sh was not armed with a gh-based poll"
  pass "fm-pr-check records pr= and pr_head= via gh and arms a gh-based check.sh"
}

test_github_check_reports_merged() {
  local case_dir out
  case_dir=$(make_case github-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mock "$case_dir" 1111111111111111111111111111111111111111

  run_pr_check "$case_dir" task-x1 https://github.com/example/repo/pull/11 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-merged: fm-pr-check failed"

  out=$(PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh") || true
  assert_contains "$out" "merged" "github-merged: armed check.sh did not report merged"
  pass "fm-pr-check's armed check.sh reports merged when gh reports state MERGED"
}

test_gitea_records_pr_head_and_arms_check() {
  local case_dir rc
  case_dir=$(make_case gitea-record)
  mkdir -p "$case_dir/wt"
  add_tea_mock "$case_dir" beefcafedeadbeef0000000000000000beefcafe false

  set +e
  run_pr_check "$case_dir" task-x1 https://git.example.com/example/repo/pulls/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitea-record: fm-pr-check should succeed"
  assert_grep 'pr=https://git.example.com/example/repo/pulls/9' "$case_dir/state/task-x1.meta" \
    "gitea-record: pr= was not recorded"
  assert_grep 'pr_head=beefcafedeadbeef0000000000000000beefcafe' "$case_dir/state/task-x1.meta" \
    "gitea-record: pr_head= was not recorded"
  assert_grep 'tea pulls' "$case_dir/state/task-x1.check.sh" \
    "gitea-record: check.sh was not armed with a tea-based poll"
  pass "fm-pr-check records pr= and pr_head= via tea for a Gitea PR URL and arms a tea-based check.sh"
}

test_gitea_check_reports_merged() {
  local case_dir out
  case_dir=$(make_case gitea-merged)
  mkdir -p "$case_dir/wt"
  add_tea_mock "$case_dir" 2222222222222222222222222222222222222222 true

  run_pr_check "$case_dir" task-x1 https://git.example.com/example/repo/pulls/12 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "gitea-merged: fm-pr-check failed"

  out=$(PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh") || true
  assert_contains "$out" "merged" "gitea-merged: armed check.sh did not report merged"
  pass "fm-pr-check's armed check.sh reports merged when tea reports hasMerged true"
}

test_gitea_check_stays_silent_when_not_merged() {
  local case_dir out
  case_dir=$(make_case gitea-not-merged)
  mkdir -p "$case_dir/wt"
  add_tea_mock "$case_dir" 3333333333333333333333333333333333333333 false

  run_pr_check "$case_dir" task-x1 https://git.example.com/example/repo/pulls/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "gitea-not-merged: fm-pr-check failed"

  out=$(PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh") || true
  [ -z "$out" ] || fail "gitea-not-merged: armed check.sh should stay silent (got: $out)"
  pass "fm-pr-check's armed check.sh stays silent when tea reports hasMerged false"
}

test_no_worktree_records_pr_without_head() {
  local case_dir rc
  case_dir=$(make_case no-worktree)
  add_tea_mock "$case_dir" 4444444444444444444444444444444444444444 false

  set +e
  run_pr_check "$case_dir" task-x1 https://git.example.com/example/repo/pulls/14 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-worktree: fm-pr-check should succeed"
  assert_grep 'pr=https://git.example.com/example/repo/pulls/14' "$case_dir/state/task-x1.meta" \
    "no-worktree: pr= was not recorded"
  assert_no_grep 'pr_head=' "$case_dir/state/task-x1.meta" \
    "no-worktree: pr_head= should not be recorded without a worktree to resolve tea's login from"
  pass "fm-pr-check records pr= without pr_head= when the task's worktree is missing"
}

test_gitea_check_polls_worktree_recorded_after_arming() {
  local case_dir out
  case_dir="$TMP_ROOT/gitea-late-worktree"
  mkdir -p "$case_dir/state" "$case_dir/fakebin"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"

  # Mirrors real tea: only succeeds when invoked with cwd inside the recorded
  # worktree (tea auto-discovers login/host from the worktree's origin
  # remote), so this fails unless the generated check.sh actually cd's there.
  local expected_wt
  expected_wt=$(cd "$case_dir" && mkdir -p wt && cd wt && pwd -P)
  cat > "$case_dir/fakebin/tea" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pulls "*)
    [ "\$(pwd -P)" = "$expected_wt" ] || exit 1
    printf '{"headSha":"%s","hasMerged":%s}\n' '5555555555555555555555555555555555555555' 'true' ; exit 0 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tea"

  run_pr_check "$case_dir" task-x1 https://git.example.com/example/repo/pulls/15 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "gitea-late-worktree: fm-pr-check failed"
  assert_no_grep 'pr_head=' "$case_dir/state/task-x1.meta" \
    "gitea-late-worktree: pr_head= should not be recorded before the worktree is known"

  mkdir -p "$case_dir/wt"
  echo "worktree=$case_dir/wt" >> "$case_dir/state/task-x1.meta"
  out=$(PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh") || true
  assert_contains "$out" "merged" \
    "gitea-late-worktree: armed check.sh should poll a worktree recorded after arming, not stay silent forever"
  pass "fm-pr-check's armed check.sh re-reads the worktree from meta at poll time and still detects merge"
}

test_bitbucket_records_pr_without_head() {
  local case_dir rc
  case_dir=$(make_case bitbucket-record)
  mkdir -p "$case_dir/wt"
  # gh mock that would resolve a headRefOid if the code wrongly fell through to
  # the GitHub path for a Bitbucket URL; pr_head= must stay absent regardless.
  add_gh_mock "$case_dir" 9999999999999999999999999999999999999999

  set +e
  run_pr_check "$case_dir" task-x1 https://bitbucket.org/example/repo/pull-requests/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "bitbucket-record: fm-pr-check should succeed"
  assert_grep 'pr=https://bitbucket.org/example/repo/pull-requests/9' "$case_dir/state/task-x1.meta" \
    "bitbucket-record: pr= was not recorded"
  assert_no_grep 'pr_head=' "$case_dir/state/task-x1.meta" \
    "bitbucket-record: pr_head= should not be recorded without a CLI to resolve it"
  assert_grep 'merged manually in the browser' "$case_dir/state/task-x1.check.sh" \
    "bitbucket-record: check.sh was not armed with the silent manual-merge poll"
  pass "fm-pr-check records pr= without pr_head= for a Bitbucket PR URL and arms a silent check.sh"
}

test_bitbucket_check_stays_silent() {
  local case_dir out
  case_dir=$(make_case bitbucket-silent)
  mkdir -p "$case_dir/wt"

  run_pr_check "$case_dir" task-x1 https://bitbucket.org/example/repo/pull-requests/12 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "bitbucket-silent: fm-pr-check failed"

  out=$(PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-x1.check.sh") || true
  [ -z "$out" ] || fail "bitbucket-silent: armed check.sh should stay silent (got: $out)"
  pass "fm-pr-check's armed Bitbucket check.sh stays silent (manual browser merge)"
}

test_github_records_pr_head_and_arms_check
test_github_check_reports_merged
test_gitea_records_pr_head_and_arms_check
test_gitea_check_reports_merged
test_gitea_check_stays_silent_when_not_merged
test_no_worktree_records_pr_without_head
test_gitea_check_polls_worktree_recorded_after_arming
test_bitbucket_records_pr_without_head
test_bitbucket_check_stays_silent
