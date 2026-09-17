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
#   (f) workspace_state=released (no worktree) -> no-checkout review in the project
#       clone from the fetched PR head and the PR's actual (possibly stacked) base,
#       refusing missing, mismatched, or unfetchable identity
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

# make_released_case <name>: a stacked PR (#9, head fm/task-x1 on base
# fm/lower) whose workspace is gone. Sets LOWER_SHA and PR_SHA.
make_released_case() {
  local case_dir
  case_dir=$(make_case "$1")
  git -C "$case_dir/wt" checkout -q -b fm/lower
  printf 'lower-layer\n' > "$case_dir/wt/lower.txt"
  git -C "$case_dir/wt" add lower.txt
  git -C "$case_dir/wt" commit -qm "lower stack layer"
  LOWER_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin fm/lower
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" reset -q --hard fm/lower
  printf 'upper-layer\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "upper stack layer"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin HEAD:refs/pull/9/head
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git -C "$case_dir/project" branch -q -D fm/task-x1 fm/lower
  printf '%s\n' "$case_dir"
}

write_released_meta() {  # <case-dir> [extra kv...]
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=" \
    "project=$case_dir/project" \
    "workspace_state=released" \
    "$@"
}

test_released_task_reviews_stacked_pr_without_a_checkout() {
  local case_dir out before_head before_worktrees
  case_dir=$(make_released_case released-stacked)
  PR_SHA=$(git -C "$case_dir/origin.git" rev-parse refs/pull/9/head)
  write_released_meta "$case_dir" "workspace_base=fm/lower" \
    "pr=https://github.com/example/repo/pull/9" "pr_head=$PR_SHA"
  before_head=$(git -C "$case_dir/project" rev-parse HEAD)
  before_worktrees=$(git -C "$case_dir/project" worktree list --porcelain)

  out=$(run_review_diff "$case_dir" task-x1) || fail "released stacked review failed: $out"
  assert_contains "$out" '+upper-layer' "released: the PR's own layer must be shown"
  assert_not_contains "$out" 'lower-layer' "released: a stacked PR must diff against its actual base, not trunk"
  assert_contains "$out" 'fm/lower' "released: the diff base line should name the actual PR base"
  assert_equals "$before_head" "$(git -C "$case_dir/project" rev-parse HEAD)" "released: review moved the project clone's HEAD"
  assert_equals "$before_worktrees" "$(git -C "$case_dir/project" worktree list --porcelain)" \
    "released: review reconstructed a workspace merely to read"
  [ -z "$(git -C "$case_dir/project" status --porcelain)" ] || fail "released: review dirtied the project clone"

  out=$(run_review_diff "$case_dir" task-x1 --stat) || fail "released --stat review failed: $out"
  assert_contains "$out" 'feature.txt' "released --stat: should summarize the changed file"
  assert_not_contains "$out" '+upper-layer' "released --stat: must not print the full diff"
  pass "fm-review-diff reviews a released stacked PR from fetched head and base refs with no checkout"
}

test_released_task_reviews_trunk_based_pr_with_workspace_head_proof() {
  local case_dir out
  case_dir=$(make_released_case released-trunk)
  PR_SHA=$(git -C "$case_dir/origin.git" rev-parse refs/pull/9/head)
  write_released_meta "$case_dir" "workspace_base=main" "workspace_head=$PR_SHA" \
    "pr=https://github.com/example/repo/pull/9"
  out=$(run_review_diff "$case_dir" task-x1) || fail "released trunk-based review failed: $out"
  assert_contains "$out" '+upper-layer' "released trunk: the upper layer must be shown"
  assert_contains "$out" '+lower-layer' "released trunk: a trunk-based PR shows everything above trunk"
  pass "fm-review-diff reviews a released trunk-based PR verified by its journaled workspace head"
}

test_released_task_refuses_missing_or_mismatched_identity() {
  local case_dir out rc
  case_dir=$(make_released_case released-refusals)
  PR_SHA=$(git -C "$case_dir/origin.git" rev-parse refs/pull/9/head)
  LOWER_SHA=$(git -C "$case_dir/origin.git" rev-parse refs/heads/fm/lower)

  write_released_meta "$case_dir" "workspace_base=fm/lower" "pr=https://github.com/example/repo/pull/9"
  rc=0; out=$(run_review_diff "$case_dir" task-x1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "released review without a recorded head must refuse"
  assert_contains "$out" 'no pr_head= or workspace_head=' "missing head proof refusal was not explicit"
  assert_not_contains "$out" 'upper-layer' "a refused review must print no diff"

  write_released_meta "$case_dir" "pr=https://github.com/example/repo/pull/9" "pr_head=$PR_SHA"
  rc=0; out=$(run_review_diff "$case_dir" task-x1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "released review without a recorded base must refuse"
  assert_contains "$out" 'no workspace_base=' "missing base refusal was not explicit"

  write_released_meta "$case_dir" "workspace_base=fm/lower" "pr_head=$PR_SHA"
  rc=0; out=$(run_review_diff "$case_dir" task-x1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "released review without a PR must refuse"
  assert_contains "$out" 'no pull-request number' "missing PR refusal was not explicit"

  write_released_meta "$case_dir" "workspace_base=fm/lower" \
    "pr=https://github.com/example/repo/pull/9" "pr_head=$LOWER_SHA"
  rc=0; out=$(run_review_diff "$case_dir" task-x1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "released review must refuse a fetched head that differs from the recorded head"
  assert_contains "$out" "PR #9 head is $PR_SHA but task task-x1 recorded $LOWER_SHA" "mismatched head refusal was not explicit"
  assert_not_contains "$out" 'upper-layer' "a mismatched head must print no diff"

  write_released_meta "$case_dir" "workspace_base=fm/lower" \
    "pr=https://github.com/example/repo/pull/9" "pr_head=$PR_SHA"
  git -C "$case_dir/project" remote set-url origin "$case_dir/no-such-origin.git"
  rc=0; out=$(run_review_diff "$case_dir" task-x1 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "released review must refuse when the remote proof is unavailable"
  assert_contains "$out" 'remote proof is unavailable' "unavailable remote refusal was not explicit"
  pass "fm-review-diff refuses a released task with missing, mismatched, or unfetchable identity"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_released_task_reviews_stacked_pr_without_a_checkout
test_released_task_reviews_trunk_based_pr_with_workspace_head_proof
test_released_task_refuses_missing_or_mismatched_identity
