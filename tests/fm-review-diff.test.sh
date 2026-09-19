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
#
# The base side has the same failure class: a task launched from a working branch
# that is not the remote default must be reviewed against that branch, or the
# branch's own commits are presented as the task's change.
#   (f) base_branch= recorded -> diff against that branch
#   (g) base_branch= absent   -> unchanged default-branch resolution
#   (h) base_branch= recorded but deleted from origin (the ordinary fate of a
#       working branch once it merges) -> legible fallback to the default branch
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

# Put a working branch on origin that carries a commit of somebody else's, then
# branch the task off it, exactly as a slot placed on that branch would. Diffing
# against the remote default would present that foreign commit as the task's own.
make_working_branch_case() {
  local case_dir=$1 branch=$2
  git clone -q "$case_dir/origin.git" "$case_dir/_pub"
  git -C "$case_dir/_pub" checkout -q -b "$branch"
  printf 'billing rewrite\n' > "$case_dir/_pub/foreign.txt"
  git -C "$case_dir/_pub" add foreign.txt
  git -C "$case_dir/_pub" -c user.email=t@t -c user.name=t commit -qm "somebody else's commit"
  git -C "$case_dir/_pub" push -q origin "$branch"
  rm -rf "$case_dir/_pub"

  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" reset --hard -q "origin/$branch"
  printf 'the task change\n' > "$case_dir/wt/task.txt"
  git -C "$case_dir/wt" add task.txt
  git -C "$case_dir/wt" commit -qm "the task's own commit"
}

test_recorded_base_branch_decides_the_review_base() {
  local case_dir out
  case_dir=$(make_case recorded-base-branch)
  make_working_branch_case "$case_dir" develop
  write_task_meta "$case_dir" "base_branch=develop"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/develop' \
    "recorded-base-branch: the recorded working branch must be the diff base"
  assert_contains "$out" '+the task change' \
    "recorded-base-branch: the diff should show the task's own commit"
  assert_not_contains "$out" 'billing rewrite' \
    "recorded-base-branch: the working branch's own commits must not ride along"
  pass "fm-review-diff diffs against the base branch recorded in the task record"
}

test_absent_base_branch_keeps_the_default_branch_resolution() {
  local case_dir out
  case_dir=$(make_case absent-base-branch)
  make_working_branch_case "$case_dir" develop
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/main' \
    "absent-base-branch: a task record naming no base branch must resolve origin/HEAD as before"
  assert_contains "$out" '+the task change' \
    "absent-base-branch: the diff should still show the task's own commit"
  pass "fm-review-diff without base_branch= resolves the default branch exactly as before"
}

test_recorded_base_branch_deleted_on_origin_falls_back_legibly() {
  local case_dir out err status
  case_dir=$(make_case deleted-base-branch)
  make_working_branch_case "$case_dir" release/2026
  write_task_meta "$case_dir" "base_branch=release/2026"
  # The release branch merges and origin drops it while the task is in flight.
  git -C "$case_dir/origin.git" branch -q -D release/2026

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  status=$?
  set -e
  err=$(cat "$case_dir/stderr")

  [ "$status" -eq 0 ] \
    || fail "deleted-base-branch: review should continue against the default branch (exit $status)"
  assert_contains "$err" 'release/2026' \
    "deleted-base-branch: the diagnostic did not name the recorded base branch"
  assert_contains "$err" 'base_branch=' \
    "deleted-base-branch: the diagnostic did not say where the recorded base came from"
  assert_contains "$err" "falling back to the project's default branch 'main'" \
    "deleted-base-branch: the diagnostic did not say it was falling back to the default branch"
  assert_not_contains "$err" 'fatal:' \
    "deleted-base-branch: git's own fatal reached the operator"
  assert_contains "$out" 'diff base: origin/main' \
    "deleted-base-branch: the diff should continue against the default branch"
  assert_contains "$out" '+the task change' \
    "deleted-base-branch: the fallback diff should still show the task's own commit"
  pass "fm-review-diff falls back legibly when the recorded base branch is gone from origin"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_recorded_base_branch_decides_the_review_base
test_absent_base_branch_keeps_the_default_branch_resolution
test_recorded_base_branch_deleted_on_origin_falls_back_legibly
