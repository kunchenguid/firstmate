#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against a freshly fetched
# PR head, not a stale local branch or a stale recorded pr_head= left behind
# after no-mistakes fix rounds push to the PR.
#
# Matrix:
#   (a) pr= + reachable pr_head=, no remote pull ref -> offline fallback to recorded SHA
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) pr= + STALE recorded pr_head= + newer remote pull head -> must use fetched head
#       (this is the class that bit reviewers holding merges over "missing" fixes)
#   (f) meta records branch=<custom-prefix> -> the recorded ship branch is
#       reviewed even when the worktree HEAD has moved off it
#   (g) meta records a corrupt branch= -> refused, never silently reviewed as
#       the moved worktree HEAD
#   (h) meta records base_branch= -> the diff is against origin/<base_branch>,
#       so the base branch's own commits never appear as task changes
#   (i) GitLab MR URL -> fetch refs/merge-requests/<iid>/head and diff that
#   (j) GitLab MR URL + stale recorded pr_head= -> the fetched merge-request
#       head wins, so a review never lags a published fix
#   (k) GitLab MR URL whose source branch was deleted from the origin -> the
#       merge request's own head ref still supplies the published content
#   (l) GitLab MR URL + unreachable remote -> recorded pr_head= is the offline
#       fallback, exactly as on GitHub
#   (m) GitLab MR URL whose head ref is absent -> local branch + warning
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

stale_and_pr_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on PR"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

run_review_diff() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$REVIEW_DIFF" "$@"
}

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  # No remote pull ref: fetch fails, recorded pr_head is the offline fallback.
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when recorded pr_head is reachable offline"
  pass "fm-review-diff falls back to recorded pr_head when pull head cannot be fetched"
}

test_stale_recorded_pr_head_loses_to_fetched_pull_head() {
  local case_dir out stale_sha
  case_dir=$(make_case stale-recorded)
  stale_and_pr_commits "$case_dir"
  stale_sha=$(git -C "$case_dir/wt" rev-parse fm/task-x1)
  # Remote PR head is newer (pipeline fix); meta still points at the older local tip.
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$stale_sha"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' \
    "stale-recorded: diff must show the fetched PR head, not the recorded stale SHA"
  assert_not_contains "$out" 'stale-local' \
    "stale-recorded: diff must not use the stale local/recorded content"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "stale-recorded: fetch of refs/pull/<n>/head should succeed"
  # Pre-fix behavior preferred reachable recorded pr_head= and would show stale-local.
  [ "$stale_sha" != "$PR_SHA" ] || fail "stale-recorded: fixture did not diverge recorded vs PR head"
  pass "fm-review-diff prefers freshly fetched PR head over a stale recorded pr_head="
}

test_pr_meta_fetches_pull_head_without_recorded_sha() {
  local case_dir out
  case_dir=$(make_case pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-fetch: diff should use fetched PR head"
  assert_not_contains "$out" 'stale-local' "pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-fetch: should not warn when fetch succeeds"
  pass "fm-review-diff fetches refs/pull/<n>/head when pr_head= is absent"
}

test_no_pr_meta_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-pr-meta)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+stale-local' "no-pr-meta: diff should still use the local branch"
  assert_not_contains "$out" '+pr-fixed' "no-pr-meta: diff must not jump to the unpushed PR commit"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "no-pr-meta: no warning without pr= in meta"
  pass "fm-review-diff without pr= keeps the worktree-branch diff"
}

test_unreachable_pr_head_falls_back_with_warning() {
  local case_dir out err
  case_dir=$(make_case fetch-fallback)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  set -e
  err=$(cat "$case_dir/stderr")

  assert_contains "$err" 'warning: PR head unavailable; diff may lag the open PR' \
    "fetch-fallback: must warn when PR head cannot be resolved"
  assert_contains "$out" '+stale-local' "fetch-fallback: should fall back to the local branch diff"
  assert_not_contains "$out" '+pr-fixed' "fetch-fallback: must not invent a PR head diff offline"
  pass "fm-review-diff falls back to local branch with a warning when PR head is unreachable"
}

test_recorded_branch_beats_moved_worktree_head() {
  local case_dir out
  case_dir=$(make_case recorded-branch)
  # The task ships on its recorded custom-prefix branch; the worktree's HEAD
  # has since moved to an unrelated branch and the legacy fm/<id> branch is
  # gone, so only meta can anchor the diff to the shipped work.
  git -C "$case_dir/wt" checkout -q -b fix/task-x1
  printf 'recorded-ship\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "recorded ship work"
  git -C "$case_dir/wt" checkout -q -b roam main
  git -C "$case_dir/wt" branch -q -D fm/task-x1
  write_task_meta "$case_dir" "branch=fix/task-x1"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+recorded-ship' \
    "recorded-branch: diff must use the meta-recorded ship branch, not the moved worktree HEAD"
  pass "fm-review-diff reviews the meta-recorded ship branch even when the worktree HEAD moved off it"
}

test_corrupt_recorded_branch_is_refused() {
  local case_dir out status
  case_dir=$(make_case corrupt-branch)
  stale_and_pr_commits "$case_dir"
  # A space can never be part of a branch name, so this record can only be a
  # hand-edited or corrupt one: refusing is the only outcome that cannot diff
  # the wrong content by falling back to the moved worktree HEAD.
  write_task_meta "$case_dir" "branch=fix task-x1"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "corrupt-branch: a corrupt recorded ship branch was accepted and reviewed the worktree HEAD"
  assert_contains "$(cat "$case_dir/stderr")" "invalid recorded ship branch 'fix task-x1'" \
    "corrupt-branch: the refusal did not name the branch it refused"
  assert_not_contains "$out" '+stale-local' \
    "corrupt-branch: the corrupt branch silently fell back to the worktree HEAD diff"
  pass "fm-review-diff refuses a corrupt recorded ship branch instead of reviewing the wrong content"
}

test_recorded_base_branch_is_the_review_base() {
  local case_dir out
  case_dir=$(make_case base-branch)
  git -C "$case_dir/project" checkout -q -b feature/hub main
  printf 'hub only\n' > "$case_dir/project/hub.txt"
  git -C "$case_dir/project" add hub.txt
  git -C "$case_dir/project" commit -qm "hub branch commit"
  git -C "$case_dir/project" push -q origin feature/hub
  git -C "$case_dir/wt" reset -q --hard origin/feature/hub 2>/dev/null \
    || { git -C "$case_dir/wt" fetch -q origin feature/hub && git -C "$case_dir/wt" reset -q --hard FETCH_HEAD; }
  printf 'task change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" commit -qam "task change on hub"
  write_task_meta "$case_dir" "base_branch=feature/hub"

  out=$(run_review_diff "$case_dir" task-x1)
  assert_contains "$out" '+task change' "base-branch: the task's own change is missing from the review diff"
  assert_not_contains "$out" 'hub.txt' "base-branch: the base branch's own commit was reviewed as a task change"
  pass "fm-review-diff compares a task against its recorded base branch"
}

# The GitLab twin of stale_and_pr_commits: a stale local ship branch and a
# pipeline fix published under the merge request's own head ref, which is how a
# GitLab instance serves the current published head. MR_SHA is that published
# head.
stale_and_mr_commits() {
  local case_dir=$1 iid=$2
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b mr-head-tmp
  printf 'mr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on MR"
  MR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "mr-head-tmp:refs/merge-requests/$iid/head"

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

test_gitlab_merge_request_head_is_fetched() {
  local case_dir out
  case_dir=$(make_case gitlab-mr-head)
  stale_and_mr_commits "$case_dir" 7
  write_task_meta "$case_dir" "pr=https://gitlab.example/group/subgroup/project/-/merge_requests/7"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+mr-fixed' \
    "gitlab-mr-head: diff should use the published merge request head"
  assert_not_contains "$out" 'stale-local' \
    "gitlab-mr-head: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "gitlab-mr-head: fetch of refs/merge-requests/<iid>/head should succeed"
  pass "fm-review-diff fetches refs/merge-requests/<iid>/head for a GitLab merge request"
}

test_gitlab_stale_recorded_head_loses_to_fetched_head() {
  local case_dir out stale_sha
  case_dir=$(make_case gitlab-stale-recorded)
  stale_and_mr_commits "$case_dir" 7
  stale_sha=$(git -C "$case_dir/wt" rev-parse fm/task-x1)
  write_task_meta "$case_dir" \
    "pr=https://gitlab.example/group/subgroup/project/-/merge_requests/7" \
    "pr_head=$stale_sha"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+mr-fixed' \
    "gitlab-stale-recorded: diff must show the fetched merge request head, not the recorded stale SHA"
  assert_not_contains "$out" 'stale-local' \
    "gitlab-stale-recorded: diff must not use the stale local/recorded content"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "gitlab-stale-recorded: fetch of refs/merge-requests/<iid>/head should succeed"
  [ "$stale_sha" != "$MR_SHA" ] || fail "gitlab-stale-recorded: fixture did not diverge recorded vs published head"
  pass "fm-review-diff prefers a freshly fetched merge request head over a stale recorded pr_head="
}

test_gitlab_deleted_source_branch_still_reviews_published_head() {
  local case_dir out
  case_dir=$(make_case gitlab-deleted-source)
  stale_and_mr_commits "$case_dir" 9
  # A merge request whose source branch was published and then deleted, as a
  # completed cleanup leaves it; the merge request's own head ref outlives that,
  # which is what keeps the review on the published content instead of the
  # worker copy.
  git -C "$case_dir/wt" push -q origin "mr-head-tmp:refs/heads/mr-source"
  git -C "$case_dir/wt" push -q origin --delete mr-source
  [ -z "$(git -C "$case_dir/wt" ls-remote --heads origin mr-source)" ] \
    || fail "gitlab-deleted-source: the fixture's source branch is still published"
  write_task_meta "$case_dir" "pr=https://gitlab.example/group/subgroup/project/-/merge_requests/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+mr-fixed' \
    "gitlab-deleted-source: the published head must still be reviewed after the source branch is deleted"
  assert_not_contains "$out" 'stale-local' \
    "gitlab-deleted-source: diff must not fall back to the local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "gitlab-deleted-source: the merge request's own head ref should still resolve"
  pass "fm-review-diff reviews a GitLab merge request whose source branch was deleted"
}

test_gitlab_unreachable_remote_falls_back_to_recorded_head() {
  local case_dir out
  case_dir=$(make_case gitlab-offline-recorded)
  stale_and_mr_commits "$case_dir" 7
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://gitlab.example/group/subgroup/project/-/merge_requests/7" \
    "pr_head=$MR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+mr-fixed' \
    "gitlab-offline-recorded: the recorded published head is the offline fallback"
  assert_not_contains "$out" 'stale-local' \
    "gitlab-offline-recorded: diff must not use the stale local branch"
  pass "fm-review-diff falls back to a recorded merge request head when the remote is unreachable"
}

test_gitlab_missing_head_ref_falls_back_with_warning() {
  local case_dir out
  case_dir=$(make_case gitlab-missing-ref)
  stale_and_mr_commits "$case_dir" 7
  # No ref for this merge request exists on the remote, and no head was recorded,
  # so the review must warn and diff the local branch rather than invent a head.
  write_task_meta "$case_dir" "pr=https://gitlab.example/group/subgroup/project/-/merge_requests/8"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable; diff may lag the open PR' \
    "gitlab-missing-ref: a missing merge request head must warn"
  assert_contains "$out" '+stale-local' \
    "gitlab-missing-ref: the local branch is the documented fallback"
  assert_not_contains "$out" '+mr-fixed' \
    "gitlab-missing-ref: another merge request's published head must never be reviewed"
  pass "fm-review-diff warns and diffs the local branch when a merge request head ref is absent"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_recorded_branch_beats_moved_worktree_head
test_corrupt_recorded_branch_is_refused
test_recorded_base_branch_is_the_review_base
test_gitlab_merge_request_head_is_fetched
test_gitlab_stale_recorded_head_loses_to_fetched_head
test_gitlab_deleted_source_branch_still_reviews_published_head
test_gitlab_unreachable_remote_falls_back_to_recorded_head
test_gitlab_missing_head_ref_falls_back_with_warning
