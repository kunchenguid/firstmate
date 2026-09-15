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

  mkdir -p "$case_dir/data"
  : > "$case_dir/data/projects.md"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

# The review base follows the TASK's delivery mode in state/<id>.meta, never the
# captain's registered posture for the project. These cases write that posture
# the same way the captain does and set it to disagree with the task, so a
# registry-keyed answer could not pass.
register_project_mode() {  # <case_dir> <mode>
  printf -- '- project [%s] - review base fixture (added 2026-09-11)\n' "$2" \
    > "$1/data/projects.md"
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
  FM_DATA_OVERRIDE="$case_dir/data" \
    "$REVIEW_DIFF" "$@"
}

# A `local-only` project can have an origin and still land approved work with
# bin/fm-merge-local.sh, which merges into the LOCAL default branch and never
# pushes. The review base has to follow the landed work, or the review reports it
# as part of the branch's own change.
land_on_local_default() {  # <case_dir> <file> <content>
  local case_dir=$1 file=$2 content=$3
  printf '%s\n' "$content" > "$case_dir/project/$file"
  git -C "$case_dir/project" add "$file"
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t commit -qm "land $file on local main"
}

commit_branch_work() {  # <case_dir>
  local case_dir=$1
  printf 'branch work\n' > "$case_dir/wt/branch.txt"
  git -C "$case_dir/wt" add branch.txt
  git -C "$case_dir/wt" commit -qm "branch work"
}

# The field shape: the worker's branch is cut from the pooled base, which for a
# local-only task is the LOCAL default branch, so origin/main is an ancestor of
# the branch and the landed commits are inside `origin/main...HEAD`. That is the
# only topology in which the base choice changes the diff CONTENT rather than
# just its label.
branch_from_landed_default() {  # <case_dir>
  git -C "$1/wt" reset --hard -q main
}

test_local_default_ahead_of_origin_is_the_review_base() {
  local case_dir out
  case_dir=$(make_case local-default-ahead)
  # Registered no-mistakes on purpose: the task's own mode decides the base.
  register_project_mode "$case_dir" no-mistakes
  land_on_local_default "$case_dir" landed-locally.txt 'approved work that was never pushed'
  branch_from_landed_default "$case_dir"
  commit_branch_work "$case_dir"
  write_task_meta "$case_dir" "mode=local-only"
  git -C "$case_dir/wt" diff --quiet "origin/main...HEAD" -- landed-locally.txt \
    && fail "local-default-ahead: fixture does not reproduce the failure - origin/main as base omits the landed file"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: refs/heads/main' \
    "local-default-ahead: the local default branch should be the review base"
  assert_contains "$out" '+branch work' "local-default-ahead: the branch's own change should still show"
  assert_not_contains "$out" 'landed-locally.txt' \
    "local-default-ahead: locally landed work was reported as part of the branch"
  pass "fm-review-diff reviews a local-only task against a local default branch that contains origin"
}

test_local_default_behind_origin_keeps_origin_review_base() {
  local case_dir out
  case_dir=$(make_case local-default-behind)
  git clone -q "$case_dir/origin.git" "$case_dir/publisher"
  printf 'pushed elsewhere\n' > "$case_dir/publisher/pushed.txt"
  git -C "$case_dir/publisher" add pushed.txt
  git -C "$case_dir/publisher" -c user.email=t@t -c user.name=t commit -qm "advance origin"
  git -C "$case_dir/publisher" push -q origin main
  branch_from_landed_default "$case_dir"
  commit_branch_work "$case_dir"
  write_task_meta "$case_dir" "mode=local-only"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/main' \
    "local-default-behind: origin must stay the review base when local trails it"
  assert_contains "$out" '+branch work' "local-default-behind: the branch's own change should still show"
  pass "fm-review-diff keeps origin as the review base when the local default branch trails it"
}

# A task delivered through a PR lands on origin, so an unpushed local default
# branch is not landed work for it. Reviewing against it would hide commits the
# PR against origin will carry. The project is registered local-only in both
# cases here, so only the task's own mode can produce the right answer.
test_pr_delivered_task_keeps_the_origin_review_base() {
  local case_dir out mode
  for mode in no-mistakes direct-PR; do
    case_dir=$(make_case "local-default-ahead-$mode")
    register_project_mode "$case_dir" local-only
    land_on_local_default "$case_dir" landed-locally.txt 'a local commit that was never pushed'
    branch_from_landed_default "$case_dir"
    commit_branch_work "$case_dir"
    write_task_meta "$case_dir" "mode=$mode"

    out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

    assert_contains "$out" 'diff base: origin/main' \
      "$mode: origin must stay the review base for a task that delivers through a PR"
    assert_contains "$out" '+branch work' "$mode: the branch's own change should still show"
    assert_contains "$out" 'landed-locally.txt' \
      "$mode: the review hid unpushed local commits the PR against origin would carry"
  done
  pass "fm-review-diff keeps the origin base for a PR-delivered task on a local-only project"
}

# A scout records no delivery mode, opens no PR and lands nothing, so no task
# fact says its work lands locally and origin stays the review base - on a
# project registered local-only included, which is the known limit
# bin/fm-pool-base-lib.sh records rather than closing from the registry.
test_task_without_a_recorded_mode_keeps_the_origin_review_base() {
  local case_dir out registered
  for registered in local-only no-mistakes; do
    case_dir=$(make_case "no-recorded-mode-$registered")
    register_project_mode "$case_dir" "$registered"
    land_on_local_default "$case_dir" landed-locally.txt 'approved work that was never pushed'
    branch_from_landed_default "$case_dir"
    commit_branch_work "$case_dir"
    write_task_meta "$case_dir"

    out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

    assert_contains "$out" 'diff base: origin/main' \
      "no recorded mode: origin must stay the review base on a $registered project"
    assert_contains "$out" 'landed-locally.txt' \
      "no recorded mode: the review against origin hid the unpushed local commits"
    assert_contains "$out" '+branch work' "no recorded mode: the branch's own change should still show"
  done
  pass "fm-review-diff keeps the origin base for a task that records no delivery mode"
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

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_local_default_ahead_of_origin_is_the_review_base
test_local_default_behind_origin_keeps_origin_review_base
test_pr_delivered_task_keeps_the_origin_review_base
test_task_without_a_recorded_mode_keeps_the_origin_review_base
