#!/usr/bin/env bash
# Tests for bin/fm-upstream-sync.sh: sync upstream changes into a fork repository.
#
# Guarantees under test:
#   - Requires remotes `origin` and `upstream`; refuses clearly if either is missing.
#   - `--check`: silent when up to date, prints exactly
#     "upstream: N new commits not in origin/main" when upstream has new commits,
#     exits 0 either way.
#   - Default run when up to date: prints up to date, exits 0.
#   - Clean merge path: creates disposable worktree under TMPDIR, merges upstream/main
#     with rerere enabled, runs bin/fm-test-run.sh --changed --base origin/main,
#     pushes branch to origin, opens PR against fork's main with required body.
#   - `--no-pr`: stops after tests pass without pushing or opening a PR.
#   - Unresolved conflicts: prints worktree path and conflicted files, leaves
#     the worktree for worker resolution, exits 2.
#   - Test failure: prints failing tests and worktree path, exits 1, pushes nothing.
#   - Invariant: never touches the primary checkout working tree or local main branch.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC_BIN="$ROOT/bin/fm-upstream-sync.sh"

# Deterministic git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-upstream-sync-tests)

# Helper to build a test world:
# Bare origin.git, bare upstream.git, and a working clone with both remotes.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/fakebin" "$w/fake"

  # Stubbed gh CLI
  cat > "$w/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_TEST_WORLD/fake/gh.log"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  printf 'https://github.com/landonbrice/firstmate-os/pull/42\n'
  exit 0
fi
exit 0
SH
  chmod +x "$w/fakebin/gh"

  # Initialize seed repo
  mkdir -p "$w/seed"
  git -C "$w/seed" init -q -b main
  printf 'init\n' > "$w/seed/common.txt"
  mkdir -p "$w/seed/bin"
  cat > "$w/seed/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ -f "$FM_TEST_WORLD/fake/test-run-fail" ]; then
  printf 'FM_TEST_END 2026-09-13T00:00:00Z tests/failing.test.sh exit=1 duration_ms=10 gate_skip=false\n'
  printf 'FM_TEST_SUMMARY total=1 failed=1 skipped_gate=0 duration_ms=10\n'
  exit 1
fi
printf 'FM_TEST_END 2026-09-13T00:00:00Z tests/passing.test.sh exit=0 duration_ms=10 gate_skip=false\n'
printf 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=10\n'
exit 0
SH
  chmod +x "$w/seed/bin/fm-test-run.sh"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "initial commit"

  # Initialize bare origin and upstream
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main

  git init -q --bare "$w/upstream.git"
  git -C "$w/upstream.git" symbolic-ref HEAD refs/heads/main

  # Push initial commit to both
  git -C "$w/seed" remote add origin "$w/origin.git"
  git -C "$w/seed" push -q origin main

  git -C "$w/seed" remote add upstream "$w/upstream.git"
  git -C "$w/seed" push -q upstream main

  # Add a fork-carried commit to origin so the fork has divergent history
  printf 'fork-carried feature\n' > "$w/seed/fork.txt"
  git -C "$w/seed" add fork.txt
  git -C "$w/seed" commit -qm "fork-carried feature"
  git -C "$w/seed" push -q origin main

  # Clone working repo from origin
  git clone -q "$w/origin.git" "$w/work"
  git -C "$w/work" remote add upstream "$w/upstream.git"

  printf '%s\n' "$w"
}

# --- Test 1: Missing remotes refusal ----------------------------------------
test_missing_remotes() {
  local w
  w=$(new_world missing-remotes)

  # Remove origin remote
  git -C "$w/work" remote remove origin
  local out rc=0
  out=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC_BIN" 2>&1) || rc=$?
  assert_equals 1 "$rc" "missing origin remote must exit 1"
  assert_contains "$out" "required remote 'origin' is missing" "error must name missing origin"

  # Restore origin, remove upstream
  git -C "$w/work" remote add origin "$w/origin.git"
  git -C "$w/work" remote remove upstream
  rc=0
  out=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC_BIN" 2>&1) || rc=$?
  assert_equals 1 "$rc" "missing upstream remote must exit 1"
  assert_contains "$out" "required remote 'upstream' is missing" "error must name missing upstream"

  pass "missing remotes refused clearly"
}

# --- Test 2: Up to date (both --check and default run) ----------------------
test_up_to_date() {
  local w
  w=$(new_world up-to-date)
  export FM_TEST_WORLD="$w"

  # --check: silent and exit 0
  local out rc=0
  out=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC_BIN" --check 2>&1) || rc=$?
  assert_equals 0 "$rc" "--check when up to date must exit 0"
  assert_equals "" "$out" "--check when up to date must print nothing"

  # default run: reports up to date and exit 0
  rc=0
  out=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC_BIN" 2>&1) || rc=$?
  assert_equals 0 "$rc" "default run when up to date must exit 0"
  assert_contains "$out" "already up to date" "default run reports up to date"

  pass "up to date behavior verified (--check silent, default reports up to date)"
}

# --- Test 3: --check line when upstream has new commits ---------------------
test_check_line() {
  local w
  w=$(new_world check-line)
  export FM_TEST_WORLD="$w"

  # Add 3 new commits to upstream
  git clone -q "$w/upstream.git" "$w/upstream-work"
  printf 'c1\n' >> "$w/upstream-work/common.txt"
  git -C "$w/upstream-work" commit -aqm "upstream c1"
  printf 'c2\n' >> "$w/upstream-work/common.txt"
  git -C "$w/upstream-work" commit -aqm "upstream c2"
  printf 'c3\n' >> "$w/upstream-work/common.txt"
  git -C "$w/upstream-work" commit -aqm "upstream c3"
  git -C "$w/upstream-work" push -q origin main

  local out rc=0
  out=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC_BIN" --check 2>&1) || rc=$?
  assert_equals 0 "$rc" "--check when behind must exit 0"
  assert_equals "upstream: 3 new commits not in origin/main" "$out" "--check format matches spec"

  pass "--check line prints expected count and exits 0"
}

# --- Test 4: Clean merge path -----------------------------------------------
test_clean_merge_path() {
  local w
  w=$(new_world clean-merge)
  export FM_TEST_WORLD="$w"
  local old_path="$PATH"
  export PATH="$w/fakebin:$PATH"

  # Add a non-conflicting commit to upstream
  git clone -q "$w/upstream.git" "$w/upstream-work"
  printf 'new feature from upstream\n' > "$w/upstream-work/upstream-file.txt"
  git -C "$w/upstream-work" add upstream-file.txt
  git -C "$w/upstream-work" commit -qm "upstream feature"
  git -C "$w/upstream-work" push -q origin main

  # Run sync
  local out rc=0
  out=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC_BIN" 2>&1) || rc=$?
  assert_equals 0 "$rc" "clean merge path must exit 0"

  local date_str
  date_str=$(date +%Y-%m-%d)
  local branch="fm/upstream-sync-$date_str"

  # Verify branch was pushed to origin.git
  local pushed_sha
  pushed_sha=$(git -C "$w/origin.git" rev-parse --verify "refs/heads/$branch" 2>/dev/null) || fail "branch $branch was not pushed to origin"

  # Verify pushed commit has 2 parents (merge commit)
  local parents
  parents=$(git -C "$w/origin.git" rev-list --parents -n 1 "$pushed_sha")
  local parent_count
  parent_count=$(printf '%s\n' "$parents" | awk '{print NF - 1}')
  assert_equals 2 "$parent_count" "pushed commit must be a merge commit with 2 parents"

  # Verify gh pr create was called with required body and line
  assert_present "$w/fake/gh.log" "gh must have been called"
  assert_grep "pr create" "$w/fake/gh.log" "gh pr create called"
  assert_grep "--base main" "$w/fake/gh.log" "gh pr create targets base main"
  assert_grep "--head $branch" "$w/fake/gh.log" "gh pr create uses head branch"
  assert_grep "merge with a merge commit, never squash" "$w/fake/gh.log" "PR body carries never squash line"
  assert_grep "bin/fm-test-run.sh --changed --base origin/main" "$w/fake/gh.log" "PR body carries test command"
  assert_grep "1 passed, 0 failed" "$w/fake/gh.log" "PR body carries pass/fail count"

  # Invariant: local main in primary checkout was NOT touched
  local work_main_head origin_main_head
  work_main_head=$(git -C "$w/work" rev-parse refs/heads/main)
  origin_main_head=$(git -C "$w/origin.git" rev-parse refs/heads/main)
  assert_equals "$origin_main_head" "$work_main_head" "local main must remain untouched"

  # --- Test --no-pr flag on a clean merge ---
  # Add another upstream commit
  printf 'another upstream change\n' > "$w/upstream-work/upstream-file2.txt"
  git -C "$w/upstream-work" add upstream-file2.txt
  git -C "$w/upstream-work" commit -qm "upstream change 2"
  git -C "$w/upstream-work" push -q origin main

  # Reset origin.git's fm/upstream-sync branch to verify --no-pr does NOT push
  git -C "$w/origin.git" branch -D "$branch" >/dev/null 2>&1 || true
  rm -f "$w/fake/gh.log"

  rc=0
  out=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC_BIN" --no-pr 2>&1) || rc=$?
  assert_equals 0 "$rc" "--no-pr must exit 0 after tests"
  assert_contains "$out" "stopping after tests (--no-pr)" "reports stopping due to --no-pr"

  # Branch must NOT be on origin.git
  local no_pr_pushed=0
  git -C "$w/origin.git" rev-parse --verify "refs/heads/$branch" >/dev/null 2>&1 || no_pr_pushed=1
  assert_equals 1 "$no_pr_pushed" "--no-pr must push nothing to origin"
  assert_absent "$w/fake/gh.log" "--no-pr must not call gh"

  export PATH="$old_path"
  pass "clean merge path and --no-pr verified"
}

# --- Test 5: Conflict path exits 2 leaving worktree ------------------------
test_conflict_path() {
  local w
  w=$(new_world conflict-path)
  export FM_TEST_WORLD="$w"

  # Create conflicting change in upstream
  git clone -q "$w/upstream.git" "$w/upstream-work"
  printf 'upstream conflict line\n' > "$w/upstream-work/common.txt"
  git -C "$w/upstream-work" commit -aqm "upstream conflict"
  git -C "$w/upstream-work" push -q origin main

  # Create conflicting change in origin
  git clone -q "$w/origin.git" "$w/origin-work"
  printf 'origin conflict line\n' > "$w/origin-work/common.txt"
  git -C "$w/origin-work" commit -aqm "origin conflict"
  git -C "$w/origin-work" push -q origin main

  local out rc=0
  out=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC_BIN" 2>&1) || rc=$?
  assert_equals 2 "$rc" "conflict path must exit 2"
  assert_contains "$out" "common.txt" "output lists conflicted file"
  assert_contains "$out" "unresolved conflicts in worktree" "output reports unresolved conflicts"

  # Extract worktree path from output
  local wt_path
  wt_path=$(printf '%s\n' "$out" | grep "unresolved conflicts in worktree" | awk '{print $NF}')
  [ -n "$wt_path" ] || fail "worktree path was not printed in conflict output"
  assert_present "$wt_path" "worktree must be left on disk for worker resolution"
  assert_present "$wt_path/common.txt" "worktree files must be intact"

  # No branch pushed to origin.git
  local date_str
  date_str=$(date +%Y-%m-%d)
  local pushed=0
  git -C "$w/origin.git" rev-parse --verify "refs/heads/fm/upstream-sync-$date_str" >/dev/null 2>&1 || pushed=1
  assert_equals 1 "$pushed" "conflicts must push nothing to origin"

  pass "conflict path exits 2 and leaves worktree intact"
}

# --- Test 6: Test failure pushes nothing ------------------------------------
test_test_failure() {
  local w
  w=$(new_world test-failure)
  export FM_TEST_WORLD="$w"
  local old_path="$PATH"
  export PATH="$w/fakebin:$PATH"

  # Add clean upstream change
  git clone -q "$w/upstream.git" "$w/upstream-work"
  printf 'upstream change\n' > "$w/upstream-work/file.txt"
  git -C "$w/upstream-work" add file.txt
  git -C "$w/upstream-work" commit -qm "upstream change"
  git -C "$w/upstream-work" push -q origin main

  # Signal test-run to fail
  touch "$w/fake/test-run-fail"

  local out rc=0
  out=$(FM_ROOT_OVERRIDE="$w/work" "$SYNC_BIN" 2>&1) || rc=$?
  assert_equals 1 "$rc" "test failure must exit 1"
  assert_contains "$out" "tests/failing.test.sh" "output lists failing test"
  assert_contains "$out" "worktree:" "output prints worktree path"

  # No branch pushed to origin.git
  local date_str
  date_str=$(date +%Y-%m-%d)
  local pushed=0
  git -C "$w/origin.git" rev-parse --verify "refs/heads/fm/upstream-sync-$date_str" >/dev/null 2>&1 || pushed=1
  assert_equals 1 "$pushed" "test failure must push nothing to origin"
  assert_absent "$w/fake/gh.log" "test failure must not call gh"

  export PATH="$old_path"
  pass "test failure prints failing tests and worktree and pushes nothing"
}

# Run all test cases
test_missing_remotes
test_up_to_date
test_check_line
test_clean_merge_path
test_conflict_path
test_test_failure

pass "all fm-upstream-sync tests passed"
