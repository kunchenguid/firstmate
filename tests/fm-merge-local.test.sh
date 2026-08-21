#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: it fast-forwards a project's default branch
# to a mode=local-only task's branch, whose name is the configured
# config/branch-prefix plus the task id (default prefix "fm/"; see
# bin/fm-branch-prefix-lib.sh, shared with bin/fm-brief.sh and
# bin/fm-review-diff.sh so all three agree on the same branch name).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

# make_case <name> <branch>: a project with one commit on its default branch
# (main) and a task branch named <branch> carrying one additional commit that
# is a clean fast-forward ahead of main.
make_case() {
  local name=$1 branch=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state" "$case_dir/config"

  fm_git_init_commit "$case_dir/project"
  git -C "$case_dir/project" branch -m main

  git -C "$case_dir/project" worktree add -q -b "$branch" "$case_dir/wt"
  printf 'task change\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -qm "task commit"
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"

  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "mode=local-only"

  printf '%s\n' "$case_dir"
}

run_merge_local() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
    "$MERGE_LOCAL" "$@"
}

test_default_prefix_merges_fm_branch() {
  local case_dir out before after
  case_dir=$(make_case default-prefix fm/task-x1)
  before=$(git -C "$case_dir/project" rev-parse --short main)

  out=$(run_merge_local "$case_dir" task-x1)

  assert_contains "$out" "merged fm/task-x1 into local main" \
    "default prefix: merge output did not name the fm/ branch"
  after=$(git -C "$case_dir/project" rev-parse --short main)
  [ "$after" != "$before" ] || fail "default prefix: main did not advance"
  assert_contains "$(cat "$case_dir/project/feature.txt" 2>/dev/null || true)" "task change" \
    "default prefix: fast-forward did not land the task commit"
  pass "fm-merge-local: an absent config/branch-prefix merges the fm/<id> branch"
}

# Incident follow-up (2026-08-20, no-mistakes document gate on task
# fmsendretry-u2): bin/fm-brief.sh honors config/branch-prefix, but
# fm-merge-local.sh still hardcoded "fm/<id>", so a captain-configured
# non-default prefix left local-only merges unable to find the branch.
test_configured_prefix_merges_configured_branch() {
  local case_dir out before after
  case_dir=$(make_case configured-prefix ryan-fm/task-x1)
  printf 'ryan-fm/\n' > "$case_dir/config/branch-prefix"
  before=$(git -C "$case_dir/project" rev-parse --short main)

  out=$(run_merge_local "$case_dir" task-x1)

  assert_contains "$out" "merged ryan-fm/task-x1 into local main" \
    "configured prefix: merge output did not name the configured ryan-fm/ branch"
  after=$(git -C "$case_dir/project" rev-parse --short main)
  [ "$after" != "$before" ] || fail "configured prefix: main did not advance"
  assert_contains "$(cat "$case_dir/project/feature.txt" 2>/dev/null || true)" "task change" \
    "configured prefix: fast-forward did not land the task commit"
  pass "fm-merge-local: a configured config/branch-prefix merges that prefix's branch, matching bin/fm-brief.sh"
}

test_configured_prefix_does_not_find_stock_fm_branch() {
  local case_dir out status
  case_dir=$(make_case mismatched-prefix fm/task-x1)
  printf 'ryan-fm/\n' > "$case_dir/config/branch-prefix"

  set +e
  out=$(run_merge_local "$case_dir" task-x1 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "mismatched prefix: merge should refuse when the configured-prefix branch does not exist"
  assert_contains "$out" "branch ryan-fm/task-x1 does not exist" \
    "mismatched prefix: error should name the configured branch it looked for, not the stock fm/ one"
  pass "fm-merge-local: with a configured prefix, it looks for that branch and refuses loudly rather than silently matching the stock fm/ name"
}

test_default_prefix_merges_fm_branch
test_configured_prefix_merges_configured_branch
test_configured_prefix_does_not_find_stock_fm_branch
