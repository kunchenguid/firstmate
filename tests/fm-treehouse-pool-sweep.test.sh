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

# The sweep resolves its config dir as FM_CONFIG_OVERRIDE, else $FM_HOME/config.
# An ambient export of either would outrank the per-test FM_HOME below and make
# these assertions read a config dir the fixture never wrote.
unset FM_CONFIG_OVERRIDE
unset FM_ROOT_OVERRIDE

fm_create_bare_repo() {
  local path=$1
  mkdir -p "$path"
  git init --bare "$path" 2>/dev/null
}

fm_create_test_repo() {
  local path=$1
  mkdir -p "$path"
  git init "$path" 2>/dev/null
  git -C "$path" symbolic-ref HEAD refs/heads/main
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

# The fixture must be one the sweep REFUSES when enabled, otherwise "exit 0"
# proves only that the worktree was safe, not that the sweep stayed deactivated.
fm_create_unsafe_dirty_repo() {
  local path=$1
  fm_create_test_repo "$path"
  ( cd "$path" || exit 1
    touch file.txt
    git add file.txt
    git commit -m "initial" 2>/dev/null
    echo "modified" > file.txt )
}

test_disabled_by_default() {
  local tmp config_dir rc
  tmp=$(fm_test_tmproot sweep-disabled)
  config_dir="$tmp/config"
  mkdir -p "$config_dir"
  [ ! -e "$config_dir/worktree-pool-sweep" ] \
    || fail "disabled by default: fixture must not create the config file"

  fm_create_unsafe_dirty_repo "$tmp/repo"

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "disabled by default: expected exit 0 on an unsafe worktree, got $rc"

  fm_config_sweep_on "$config_dir"
  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "disabled by default: fixture is not actually unsafe (enabled sweep gave $rc)"
  pass "sweep is disabled by default even for an unsafe worktree"
}

# The sweep runs as a child of fm-spawn.sh, which exports no FM_ROOT. Resolution
# must follow the repo-wide FM_CONFIG_OVERRIDE / $FM_HOME/config convention, so
# these fixtures poison both the old knob and $HOME to prove neither is consulted.
test_fm_home_config_activates_sweep() {
  local tmp config_dir rc
  tmp=$(fm_test_tmproot sweep-fm-home)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_unsafe_dirty_repo "$tmp/repo"

  HOME="$tmp/decoy-home" FM_ROOT="$tmp/decoy-root" FM_HOME="$tmp" \
    "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "FM_HOME config: expected exit 1, got $rc"
  pass "an enable under \$FM_HOME/config activates the sweep"
}

test_config_override_activates_sweep() {
  local tmp config_dir rc
  tmp=$(fm_test_tmproot sweep-config-override)
  config_dir="$tmp/elsewhere"
  fm_config_sweep_on "$config_dir"

  fm_create_unsafe_dirty_repo "$tmp/repo"

  HOME="$tmp/decoy-home" FM_ROOT="$tmp/decoy-root" FM_HOME="$tmp" \
    FM_CONFIG_OVERRIDE="$config_dir" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "FM_CONFIG_OVERRIDE: expected exit 1, got $rc"

  HOME="$tmp/decoy-home" FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "FM_CONFIG_OVERRIDE: enable leaked outside the override dir (got $rc)"
  pass "FM_CONFIG_OVERRIDE selects the config dir the sweep reads"
}

test_off_value_disables_sweep() {
  local tmp config_dir rc
  tmp=$(fm_test_tmproot sweep-off-value)
  config_dir="$tmp/config"
  fm_config_sweep_off "$config_dir"

  fm_create_unsafe_dirty_repo "$tmp/repo"

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "off value: expected exit 0 on an unsafe worktree, got $rc"
  pass "config value 'off' disables the sweep"
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

  err=$(FM_HOME="$tmp" "$SWEEP" "$tmp/repo" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 1 ] || fail "dirty worktree: expected exit 1, got $rc"
  assert_contains "$err" "unsafe: dirty worktree" "dirty worktree: missing diagnostic on stderr"
  pass "refuses dirty worktree with a diagnostic"
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
  git commit -m "initial" 2>/dev/null
  echo "staged" > staged.txt
  git add staged.txt

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "staged changes: expected exit 1, got $rc"
  pass "refuses staged changes against a real HEAD"
}

test_refuses_staged_change_restored_in_worktree() {
  local tmp config_dir rc
  tmp=$(fm_test_tmproot sweep-staged-restored)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  printf 'original\n' > file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  printf 'staged\n' > file.txt
  git add file.txt
  printf 'original\n' > file.txt
  git update-index --refresh >/dev/null 2>&1
  [ -n "$(git diff --cached --name-only)" ] \
    || fail "staged-then-restored: fixture left no staged delta"

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 1 ] || fail "staged-then-restored: expected exit 1, got $rc"
  pass "refuses an index that differs from HEAD even when the worktree matches HEAD"
}

# A pool worktree returned by teardown has fresh mtimes, so its index stat data
# is stale while its content still matches HEAD. That is clean, not dirty, and
# must agree with the `git status --porcelain` gate fm-spawn.sh applies later.
test_allows_stat_dirty_but_clean_worktree() {
  local tmp config_dir rc
  tmp=$(fm_test_tmproot sweep-stat-dirty)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  printf 'content\n' > file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  # A tag, so HEAD is durably reachable independently of the branch it is
  # attached to (which the sweep discounts). Without it the case would exit on
  # the reachability verdict and prove nothing about the dirty probe.
  git tag pool-base 2>/dev/null
  touch -t 203001010101 file.txt
  [ -z "$(git status --porcelain)" ] \
    || fail "stat-dirty: fixture is genuinely dirty, not merely stat-dirty"

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "stat-dirty: expected exit 0 for a stat-only mtime change, got $rc"
  pass "allows a stat-dirty worktree whose content matches HEAD"
}

# A HEAD git cannot resolve (unborn, or a worktree whose repo is unreadable)
# makes the dirty probe exit 128. That must still refuse, but the operator is
# told the real condition instead of being sent looking for uncommitted work.
test_refuses_uninspectable_head_with_its_own_diagnostic() {
  local tmp config_dir rc err
  tmp=$(fm_test_tmproot sweep-unborn-head)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  git rev-parse --verify --quiet HEAD >/dev/null 2>&1 \
    && fail "unborn HEAD: fixture already has a commit"

  err=$(FM_HOME="$tmp" "$SWEEP" "$tmp/repo" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 1 ] || fail "unborn HEAD: expected exit 1, got $rc"
  assert_contains "$err" "cannot inspect HEAD" \
    "unborn HEAD: missing the cannot-inspect diagnostic"
  case "$err" in
    *"dirty worktree"*) fail "unborn HEAD: reported as dirty, which it is not" ;;
  esac
  pass "refuses an uninspectable HEAD with its own diagnostic, not 'dirty'"
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

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
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

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
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

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
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

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "detached in main: expected exit 0, got $rc"
  pass "allows detached HEAD fully contained in main"
}

# The pool worktree is still sitting on the lane branch that carries its only
# copy of some committed work. That branch is not protection: the spawn path
# hard-resets it onto origin's default branch moments later, so counting it
# would green-light discarding the work.
test_refuses_head_held_only_by_the_checked_out_branch() {
  local tmp config_dir rc err lane_commit
  tmp=$(fm_test_tmproot sweep-attached-branch)
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
  git checkout -b fm/lane 2>/dev/null
  printf 'unlanded\n' > lane.txt
  git add lane.txt
  git commit -m "lane work" 2>/dev/null
  lane_commit=$(git rev-parse HEAD)
  [ "$(git rev-parse --abbrev-ref HEAD)" = "fm/lane" ] \
    || fail "attached branch: fixture is not checked out on the lane branch"
  [ -n "$lane_commit" ] || fail "attached branch: fixture has no lane commit"

  err=$(FM_HOME="$tmp" "$SWEEP" "$tmp/repo" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "attached branch: expected exit 2, got $rc"
  assert_contains "$err" "not reachable from durable refs" \
    "attached branch: missing the unreachable-HEAD diagnostic"
  pass "refuses HEAD whose only ref is the branch about to be hard-reset"
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

  err=$(FM_HOME="$tmp" "$SWEEP" "$tmp/repo" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "reflog only: expected exit 2, got $rc"
  assert_contains "$err" "not reachable from durable refs" \
    "reflog only: missing diagnostic on stderr"
  pass "refuses reflog-only reachability with a diagnostic"
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

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
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

  err=$(FM_HOME="$tmp" "$SWEEP" "$tmp/repo" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 3 ] || fail "remote only: expected exit 3, got $rc"
  assert_contains "$err" "covered only by remote-tracking refs" \
    "remote only: missing diagnostic on stderr"
  pass "refuses HEAD covered only by remote-tracking refs with a diagnostic"
}

# Exit 3 claims the commits survive on a remote-tracking ref. When the only refs
# are remote but HEAD is not contained in any of them, the honest answer is 2.
# With no refs at all, exit 3 must not be claimed: there is no remote-tracking
# ref the commits could be recovered from.
test_refuses_head_when_no_refs_exist_at_all() {
  local tmp config_dir rc err
  tmp=$(fm_test_tmproot sweep-no-refs)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  head_commit=$(git rev-parse HEAD)
  git checkout "$head_commit" 2>/dev/null
  git branch -D main 2>/dev/null
  [ -z "$(git for-each-ref --format='%(refname)')" ] \
    || fail "no refs: fixture still has refs"

  err=$(FM_HOME="$tmp" "$SWEEP" "$tmp/repo" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "no refs: expected exit 2, got $rc"
  assert_contains "$err" "not reachable from durable refs" \
    "no refs: must not claim remote-tracking coverage"
  pass "refuses HEAD as unreachable when no refs exist at all"
}

test_refuses_orphan_head_with_unrelated_remote_ref() {
  local tmp config_dir rc err
  tmp=$(fm_test_tmproot sweep-orphan-vs-remote)
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
  git checkout -b orphan 2>/dev/null
  touch never-pushed.txt
  git add never-pushed.txt
  git commit -m "never pushed" 2>/dev/null
  orphan_commit=$(git rev-parse HEAD)
  git checkout "$orphan_commit" 2>/dev/null
  git branch -D orphan 2>/dev/null
  git branch -D main 2>/dev/null
  [ "$(git rev-list --count HEAD --not --remotes)" -gt 0 ] \
    || fail "orphan vs remote: fixture HEAD is contained in a remote ref"

  err=$(FM_HOME="$tmp" "$SWEEP" "$tmp/repo" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "orphan vs remote: expected exit 2, got $rc"
  assert_contains "$err" "not reachable from durable refs" \
    "orphan vs remote: must not claim remote-tracking coverage it never verified"
  pass "refuses an orphan HEAD as unreachable, not as remote-covered"
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

  FM_HOME="$tmp" "$SWEEP" "$tmp/repo" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "local with remote: expected exit 0, got $rc"
  pass "allows HEAD when local branch exists alongside remote"
}

# A durable ref pointing at an object the shared store no longer has makes
# rev-list exit 128. The sweep must treat an unanswerable reachability question
# as unsafe rather than green-lighting the worktree.
test_refuses_when_reachability_cannot_be_computed() {
  local tmp config_dir rc git_dir err
  tmp=$(fm_test_tmproot sweep-broken-ref)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  fm_create_test_repo "$tmp/repo"
  cd "$tmp/repo" || exit 1
  touch file.txt
  git add file.txt
  git commit -m "initial" 2>/dev/null
  git_dir=$(git rev-parse --git-dir)
  mkdir -p "$git_dir/refs/heads"
  printf '%s\n' "0000000000000000000000000000000000000001" \
    > "$git_dir/refs/heads/dangling"
  git rev-list --count HEAD --not --branches >/dev/null 2>&1 \
    && fail "broken ref: fixture did not actually break rev-list"

  err=$(FM_HOME="$tmp" "$SWEEP" "$tmp/repo" 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "broken ref: expected exit 2, got $rc"
  assert_contains "$err" "cannot compute HEAD reachability" \
    "broken ref: missing the cannot-compute diagnostic"
  case "$err" in
    *"contains commits not reachable"*)
      fail "broken ref: reported as orphaned commits, but the question was unanswerable" ;;
  esac
  pass "refuses an uncomputable reachability question with its own diagnostic"
}

test_nonexistent_worktree() {
  local tmp config_dir
  tmp=$(fm_test_tmproot sweep-nonexistent)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  FM_HOME="$tmp" "$SWEEP" "$tmp/nonexistent" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 4 ] || fail "nonexistent: expected exit 4, got $rc"
  pass "exits 4 for nonexistent worktree"
}

test_missing_argument_is_a_usage_error() {
  local tmp config_dir rc
  tmp=$(fm_test_tmproot sweep-usage)
  config_dir="$tmp/config"
  fm_config_sweep_on "$config_dir"

  FM_HOME="$tmp" "$SWEEP" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 64 ] || fail "missing argument: expected exit 64, got $rc"
  [ "$rc" -ne 4 ] || fail "missing argument must not collide with the nonexistent-worktree code"
  pass "exits 64 for a missing worktree argument"
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
test_off_value_disables_sweep
test_fm_home_config_activates_sweep
test_config_override_activates_sweep
test_refuses_dirty_worktree
test_refuses_staged_changes
test_refuses_staged_change_restored_in_worktree
test_allows_stat_dirty_but_clean_worktree
test_refuses_uninspectable_head_with_its_own_diagnostic
test_refuses_untracked_files
test_allows_branch_reachable_head
test_allows_tag_reachable_head
test_allows_detached_head_fully_in_main
test_refuses_head_held_only_by_the_checked_out_branch
test_refuses_reflog_only_reachability
test_historical_reproduction
test_refuses_remote_only_refs
test_refuses_head_when_no_refs_exist_at_all
test_refuses_orphan_head_with_unrelated_remote_ref
test_allows_with_local_branch
test_refuses_when_reachability_cannot_be_computed
test_nonexistent_worktree
test_missing_argument_is_a_usage_error
test_help_text
