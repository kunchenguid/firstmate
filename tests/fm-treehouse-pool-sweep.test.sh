#!/usr/bin/env bash
# tests/fm-treehouse-pool-sweep.test.sh - Test suite for worktree pool sweep.
#
# Tests the pre-acquire worktree pool safety sweep. Runs against synthetic scratch
# pools under mktemp -d, never touching the real ~/.treehouse pool or invoking
# treehouse get.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SWEEP="$ROOT/bin/fm-treehouse-pool-sweep.sh"

fm_create_bare_repo() {
  local path=$1
  mkdir -p "$path"
  git init --bare "$path" 2>/dev/null
}

fm_create_test_repo() {
  local path=$1
  mkdir -p "$path"
  git init "$path" 2>/dev/null
  git -C "$path" config user.email "test@example.com"
  git -C "$path" config user.name "Test"
}

fm_config_sweep_on() {
  local config_dir=$1
  mkdir -p "$config_dir"
  echo "on" > "$config_dir/worktree-pool-sweep"
}

fm_config_sweep_off() {
  local config_dir=$1
  mkdir -p "$config_dir"
  echo "off" > "$config_dir/worktree-pool-sweep"
}

test_disabled_by_default() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-disabled)
  config_dir="$tmp/config"
  mkdir -p "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "disabled by default: expected exit 0, got $rc"
  pass "sweep is disabled by default"
}

test_refuses_dirty_worktree() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-dirty)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  echo "modified" > file.txt

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "dirty worktree: expected exit 1, got $rc"
  pass "refuses dirty worktree"
}

test_refuses_staged_changes() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-staged)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  echo "staged" > staged.txt
  git add staged.txt

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "staged changes: expected exit 1, got $rc"
  pass "refuses staged changes"
}

test_refuses_untracked_files() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-untracked)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  touch untracked.txt

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "untracked files: expected exit 1, got $rc"
  pass "refuses untracked files"
}

test_allows_branch_reachable_head() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-branch-reachable)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  git checkout -b feature 2>/dev/null
  touch feature.txt
  git add feature.txt
  git commit -m "feature work" 2>/dev/null
  git checkout main 2>/dev/null

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "branch reachable: expected exit 0, got $rc"
  pass "allows branch-reachable HEAD"
}

test_allows_tag_reachable_head() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-tag-reachable)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  git tag v1.0.0 2>/dev/null

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "tag reachable: expected exit 0, got $rc"
  pass "allows tag-reachable HEAD"
}

test_allows_detached_head_fully_in_main() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-detached-main)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  main_commit=$(git rev-parse HEAD)
  git checkout "$main_commit" 2>/dev/null

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "detached in main: expected exit 0, got $rc"
  pass "allows detached HEAD fully contained in main"
}

test_refuses_reflog_only_reachability() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-reflog-only)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  git checkout -b feature 2>/dev/null
  touch feature.txt
  git add feature.txt
  git commit -m "feature work" 2>/dev/null
  feature_commit=$(git rev-parse HEAD)
  git checkout "$feature_commit" 2>/dev/null
  git branch -D feature 2>/dev/null || true

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "reflog only: expected exit 2, got $rc"
  pass "refuses reflog-only reachability"
}

test_historical_reproduction() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-historical)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null

  git checkout -b fm/lane-branch 2>/dev/null
  touch lane-work.txt
  git add lane-work.txt
  git commit -m "lane work" 2>/dev/null

  git rebase main 2>/dev/null || true

  touch rebased-work.txt
  git add rebased-work.txt
  git commit -m "work after rebase" 2>/dev/null
  rebased_commit=$(git rev-parse HEAD)

  git checkout "$rebased_commit" 2>/dev/null
  git update-ref -d refs/heads/fm/lane-branch 2>/dev/null || true

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "historical reproduction: expected exit 2, got $rc"
  pass "historical reproduction: refuses orphaned commits after branch deletion"
}

test_refuses_remote_only_refs() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-remote-only)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_bare_repo "$tmp/origin"
  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  git remote add origin "$tmp/origin"
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  git push -u origin main 2>/dev/null
  origin_main=$(git rev-parse origin/main)
  git checkout "$origin_main" 2>/dev/null
  git branch -D main 2>/dev/null || true
  git remote prune origin 2>/dev/null

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 3 ] || fail "remote only: expected exit 3, got $rc"
  pass "refuses HEAD covered only by remote-tracking refs"
}

test_allows_with_local_branch() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-local-with-remote)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_bare_repo "$tmp/origin"
  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  git remote add origin "$tmp/origin"
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  git push -u origin main 2>/dev/null
  git checkout -b feature 2>/dev/null
  touch feature.txt
  git add feature.txt
  git commit -m "feature" 2>/dev/null
  git push -u origin feature 2>/dev/null
  git checkout main 2>/dev/null
  git branch -D feature 2>/dev/null

  FM_ROOT="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "local with remote: expected exit 0, got $rc"
  pass "allows HEAD when local branch exists alongside remote"
}

test_nonexistent_worktree() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-nonexistent)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  FM_ROOT="$tmp" "$SWEEP" "$tmp/nonexistent" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 4 ] || fail "nonexistent: expected exit 4, got $rc"
  pass "exits 4 for nonexistent worktree"
}

test_help_text() {
  local out
  out=$("$SWEEP" --help 2>&1) || true
  assert_contains "$out" "Pre-acquire worktree pool safety sweep" "help missing description"
  assert_contains "$out" "MITIGATION" "help missing MITIGATION note"
  assert_contains "$out" "INVARIANT" "help missing INVARIANT note"
  assert_contains "$out" "config/worktree-pool-sweep" "help missing config location"
  pass "help text contains required information"
}

test_disabled_by_default
test_refuses_dirty_worktree
test_refuses_staged_changes
test_refuses_untracked_files
test_allows_branch_reachable_head
test_allows_tag_reachable_head
test_allows_detached_head_fully_in_main
test_refuses_reflog_only_reachability
test_historical_reproduction
test_refuses_remote_only_refs
test_allows_with_local_branch
test_nonexistent_worktree
test_help_text
