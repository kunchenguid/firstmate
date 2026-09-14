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
  mkdir -p "$case_dir/state" "$case_dir/data/task-x1"

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
  FM_DATA_OVERRIDE="$case_dir/data" \
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

test_recorded_base_branch_is_compare_base() {
  local case_dir out develop_sha
  case_dir=$(make_case recorded-base)
  git -C "$case_dir/wt" checkout -q -b develop
  printf 'from-develop\n' > "$case_dir/wt/develop.txt"
  git -C "$case_dir/wt" add develop.txt
  git -C "$case_dir/wt" commit -qm "develop tip"
  develop_sha=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin develop
  printf 'crew-only\n' > "$case_dir/wt/crew.txt"
  git -C "$case_dir/wt" add crew.txt
  git -C "$case_dir/wt" commit -qm "crew on develop"
  git -C "$case_dir/wt" branch -f fm/task-x1 HEAD
  git -C "$case_dir/wt" checkout -q fm/task-x1
  git -C "$case_dir/wt" tag origin/develop refs/heads/main
  git -C "$case_dir/wt" tag fm/task-x1 "$develop_sha"

  write_task_meta "$case_dir"
  out=$(run_review_diff "$case_dir" task-x1)
  assert_contains "$out" 'diff base: origin/main' \
    "absent base_branch= must keep the default-branch compare base"
  assert_contains "$out" '+from-develop' \
    "absent base_branch= should include named-base-only commits vs default"
  assert_contains "$out" '+crew-only' \
    "absent base_branch= should still include crew commits"

  write_task_meta "$case_dir" "base_branch=develop"
  out=$(run_review_diff "$case_dir" task-x1)
  assert_contains "$out" 'diff base: origin/develop' \
    "recorded base_branch= must become the compare base"
  assert_not_contains "$out" '+from-develop' \
    "recorded base_branch= must not treat named-base commits as the review diff"
  assert_contains "$out" '+crew-only' \
    "recorded base_branch= should still include crew commits vs that base"
  pass "fm-review-diff uses recorded base_branch= as compare base, default otherwise"
}

test_local_only_recorded_base_does_not_require_default_or_remote_ref() {
  local case_dir out
  case_dir=$(make_case local-only-base)
  git -C "$case_dir/project" branch develop main
  git -C "$case_dir/wt" checkout -q develop
  printf 'local-develop\n' > "$case_dir/wt/local-develop.txt"
  git -C "$case_dir/wt" add local-develop.txt
  git -C "$case_dir/wt" commit -qm "local develop tip"
  git -C "$case_dir/wt" checkout -q fm/task-x1
  printf 'local-crew\n' > "$case_dir/wt/local-crew.txt"
  git -C "$case_dir/wt" add local-crew.txt
  git -C "$case_dir/wt" commit -qm "local crew tip"
  write_task_meta "$case_dir" "mode=local-only" "base_branch=develop"

  out=$(run_review_diff "$case_dir" task-x1)
  assert_contains "$out" 'diff base: develop' \
    "local-only review did not use the local recorded base"
  assert_not_contains "$out" 'origin/develop' \
    "local-only review selected the remote-tracking base"
  assert_not_contains "$out" 'local-develop' \
    "local-only review included commits already on the recorded base"
  assert_contains "$out" '+local-crew' \
    "local-only review omitted crew changes"
  pass "fm-review-diff uses a local recorded base without resolving the default"
}

test_scout_recorded_local_base_when_remote_ref_is_absent() {
  local case_dir out
  case_dir=$(make_case scout-local-base)
  git -C "$case_dir/project" branch develop main
  git -C "$case_dir/wt" checkout -q develop
  printf 'local-develop\n' > "$case_dir/wt/local-develop.txt"
  git -C "$case_dir/wt" add local-develop.txt
  git -C "$case_dir/wt" commit -qm "local develop tip"
  git -C "$case_dir/wt" checkout -q fm/task-x1
  printf 'scout-crew\n' > "$case_dir/wt/scout-crew.txt"
  git -C "$case_dir/wt" add scout-crew.txt
  git -C "$case_dir/wt" commit -qm "scout crew tip"
  write_task_meta "$case_dir" "kind=scout" "base_branch=develop"

  out=$(run_review_diff "$case_dir" task-x1)
  assert_contains "$out" 'diff base: develop' \
    "scout review did not use its local recorded base"
  assert_not_contains "$out" 'origin/develop' \
    "scout review selected a missing remote-tracking base"
  assert_not_contains "$out" 'local-develop' \
    "scout review included commits already on its local base"
  assert_contains "$out" '+scout-crew' \
    "scout review omitted crew changes"
  pass "fm-review-diff falls back to a local recorded base for scouts"
}

test_recorded_base_branch_without_default() {
  local case_dir out
  case_dir=$(make_case recorded-base-no-default)
  git -C "$case_dir/project" branch develop main
  git -C "$case_dir/wt" checkout -q develop
  printf 'local-develop\n' > "$case_dir/wt/local-develop.txt"
  git -C "$case_dir/wt" add local-develop.txt
  git -C "$case_dir/wt" commit -qm "local develop tip"
  git -C "$case_dir/wt" checkout -q fm/task-x1
  printf 'local-crew\n' > "$case_dir/wt/local-crew.txt"
  git -C "$case_dir/wt" add local-crew.txt
  git -C "$case_dir/wt" commit -qm "local crew tip"
  git -C "$case_dir/project" checkout -q develop
  git -C "$case_dir/project" branch -D main >/dev/null
  git -C "$case_dir/project" remote remove origin
  write_task_meta "$case_dir" "mode=local-only" "base_branch=develop"

  out=$(run_review_diff "$case_dir" task-x1)
  assert_contains "$out" 'diff base: develop' \
    "review required an unrelated default branch before using the recorded base"
  assert_contains "$out" '+local-crew' \
    "review without a default omitted crew changes"
  pass "fm-review-diff honors a recorded base when no default branch exists"
}

test_recorded_crew_branch_ignores_parked_head() {
  local case_dir out
  case_dir=$(make_case recorded-crew)
  git -C "$case_dir/wt" checkout -q -b feature/custom
  printf 'custom-crew\n' > "$case_dir/wt/custom.txt"
  git -C "$case_dir/wt" add custom.txt
  git -C "$case_dir/wt" commit -qm "custom crew"
  git -C "$case_dir/wt" branch -D fm/task-x1 >/dev/null
  git -C "$case_dir/wt" checkout -q -b scratch main
  printf 'scratch-only\n' > "$case_dir/wt/scratch.txt"
  git -C "$case_dir/wt" add scratch.txt
  git -C "$case_dir/wt" commit -qm scratch
  printf '%s\n' '# Task' 'User text' '# Definition of done' 'Crew branch: branch=main' \
    '# Setup' 'Generated setup' '<!-- fm-generated-contract-boundary -->' '<!-- fm-generated-contract -->' '# Definition of done' \
    'Crew branch: branch=feature/custom' '<!-- fm-generated-contract-end -->' \
    > "$case_dir/data/task-x1/brief.md"
  cat >> "$case_dir/data/task-x1/brief.md" <<'EOF'

## Progress note (2026-09-10T00:00:00Z)
<!-- fm-generated-contract -->
# Definition of done
Crew branch: branch=main
EOF
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1)
  assert_contains "$out" '+custom-crew' \
    "review diff did not use the recorded custom crew branch"
  assert_not_contains "$out" '+scratch-only' \
    "review diff inferred the parked worktree branch"
  pass "fm-review-diff uses the recorded crew branch, not parked HEAD"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_recorded_base_branch_is_compare_base
test_local_only_recorded_base_does_not_require_default_or_remote_ref
test_scout_recorded_local_base_when_remote_ref_is_absent
test_recorded_base_branch_without_default
test_recorded_crew_branch_ignores_parked_head
