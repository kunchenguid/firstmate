#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against the PR head, not a
# stale local branch left behind after no-mistakes fix rounds push to the PR.
# The base side is the repo default branch, unless the task declared a non-default
# intended base (fm-brief.sh --base, recorded as base= in meta).
#
# Matrix:
#   (a) pr= + reachable pr_head= -> diff uses PR head, not the lagging local branch
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) base= present -> diff against that base, not the repo default
#   (f) base= present but gone from origin (merged and auto-deleted) -> fall back
#       to the default branch with a warning, never a hard stop
#   (g) base= present but origin cannot be asked at all -> stop, do not guess
#   (h) base= absent -> unchanged default-branch diff base
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
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when pr_head is reachable"
  pass "fm-review-diff uses recorded pr_head instead of the lagging local branch"
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

# A task whose intended base is a feature branch (fm-brief.sh --base, recorded as
# base= in meta) must be reviewed against THAT base. Diffing it against the repo
# default would present the entire feature base's unmerged history as if it were
# the crewmate's change - a misleading, potentially enormous diff at exactly the
# moment firstmate decides whether to relay the PR.
test_declared_base_is_the_diff_base() {
  local case_dir out
  case_dir=$(make_case declared-base)

  # A feature base carrying its own unmerged work, then the crewmate's branch
  # stacked on it carrying only the fix.
  git -C "$case_dir/wt" checkout -q -b feature/base origin/main
  printf 'feature-base-work\n' > "$case_dir/wt/base-only.txt"
  git -C "$case_dir/wt" add base-only.txt
  git -C "$case_dir/wt" commit -qm "feature base work"
  git -C "$case_dir/wt" push -q origin feature/base
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard feature/base
  printf 'crew-fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add fix.txt
  git -C "$case_dir/wt" commit -qm "the crewmate's fix"

  write_task_meta "$case_dir" "base=feature/base"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/feature/base' \
    "declared-base: the review should state the declared base as its diff base"
  assert_contains "$out" '+crew-fix' "declared-base: diff should show the crewmate's own change"
  assert_not_contains "$out" 'feature-base-work' \
    "declared-base: diff must not present the feature base's unmerged history as the crewmate's change"
  pass "fm-review-diff diffs a based task against its declared base, not the repo default"
}

test_no_declared_base_still_diffs_against_default() {
  local case_dir out
  case_dir=$(make_case no-declared-base)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" 'diff base: origin/main' \
    "no-declared-base: a task without base= must keep diffing against the repo default"
  pass "fm-review-diff without base= keeps the default-branch diff base"
}

# The normal END-STATE of a stacked PR: the intended base merged and its branch was
# deleted from origin (GitHub does this by default). Erroring out on the missing
# branch would leave firstmate unable to review a PR that is now perfectly ordinary,
# so the diff falls back to the default branch and says why.
test_deleted_base_falls_back_to_default_with_warning() {
  local case_dir out rc
  case_dir=$(make_case deleted-base)

  git -C "$case_dir/wt" checkout -q -b feature/base origin/main
  printf 'feature-base-work\n' > "$case_dir/wt/base-only.txt"
  git -C "$case_dir/wt" add base-only.txt
  git -C "$case_dir/wt" commit -qm "feature base work"
  git -C "$case_dir/wt" push -q origin feature/base
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard feature/base
  printf 'crew-fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add fix.txt
  git -C "$case_dir/wt" commit -qm "the crewmate's fix"

  # feature/base merges into main and origin deletes the branch.
  git -C "$case_dir/origin.git" update-ref refs/heads/main refs/heads/feature/base
  git -C "$case_dir/origin.git" update-ref -d refs/heads/feature/base

  write_task_meta "$case_dir" "base=feature/base"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  rc=$?
  set -e

  expect_code 0 "$rc" "deleted-base: a gone base must not make the pre-merge review impossible"
  assert_contains "$out" 'diff base: origin/main' \
    "deleted-base: a base that no longer exists on origin must fall back to the default branch"
  assert_grep 'no longer exists on origin' "$case_dir/stderr" \
    "deleted-base: the fallback must say why it is not using the declared base"
  assert_contains "$out" '+crew-fix' "deleted-base: the crewmate's own change should still be shown"
  pass "fm-review-diff falls back to the default branch when the declared base is gone from origin"
}

# A probe origin cannot ANSWER is not the same as a base that is gone: reviewing
# against the wrong base silently would be worse than stopping.
test_unreachable_origin_stops_instead_of_guessing() {
  local case_dir rc
  case_dir=$(make_case unreachable-origin)
  write_task_meta "$case_dir" "base=feature/base"
  git -C "$case_dir/project" remote set-url origin "$case_dir/no-such-origin.git"

  set +e
  run_review_diff "$case_dir" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unreachable-origin: an unanswerable base probe must not silently pick a base"
  assert_grep 'could not be asked' "$case_dir/stderr" \
    "unreachable-origin: the error did not name the failed probe"
  pass "fm-review-diff stops when origin cannot be asked whether the declared base exists"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_declared_base_is_the_diff_base
test_deleted_base_falls_back_to_default_with_warning
test_unreachable_origin_stops_instead_of_guessing
test_no_declared_base_still_diffs_against_default
