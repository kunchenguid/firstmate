#!/usr/bin/env bash
# Direct behavior tests for bin/fm-merge-local.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)
fm_git_identity fmtest fmtest@example.invalid

make_case() {
  local case_dir="$TMP_ROOT/$1" id=task-x1
  mkdir -p "$case_dir/home/state" "$case_dir/root/bin"
  cat > "$case_dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/root/bin/fm-guard.sh"
  touch "$case_dir/home/state/.last-watcher-beat"
  git init -q "$case_dir/project"
  git -C "$case_dir/project" config user.name fmtest
  git -C "$case_dir/project" config user.email fmtest@example.invalid
  printf 'base\n' > "$case_dir/project/base.txt"
  git -C "$case_dir/project" add base.txt
  git -C "$case_dir/project" commit -qm base
  git -C "$case_dir/project" branch -M main
  git -C "$case_dir/project" worktree add -q -b "fm/$id" "$case_dir/wt" main
  fm_write_meta "$case_dir/home/state/$id.meta" \
    "window=fake" "endpoint_task_id=$id" "worktree=$case_dir/wt" \
    "project=$case_dir/project" "kind=ship" "mode=local-only" "yolo=off"
  printf '%s\n' "$case_dir"
}

run_merge() {
  local case_dir=$1
  FM_ROOT_OVERRIDE="$case_dir/root" FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" "$MERGE_LOCAL" task-x1
}

commit_task_change() {
  local case_dir=$1
  printf 'fix\n' > "$case_dir/wt/fix.txt"
  git -C "$case_dir/wt" add fix.txt
  git -C "$case_dir/wt" commit -qm fix
}

assert_refused_unchanged() {  # <case> <expected-error>
  local case_dir=$1 expected=$2 before rc=0
  before=$(git -C "$case_dir/project" rev-parse main)
  run_merge "$case_dir" >"$case_dir/out" 2>"$case_dir/err" || rc=$?
  expect_code 1 "$rc" "$expected"
  assert_grep "$expected" "$case_dir/err" "refusal did not name failed invariant: $(cat "$case_dir/err")"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "refused local merge moved main"
}

test_clean_exact_tip_succeeds() {
  local case_dir tip
  case_dir=$(make_case clean)
  commit_task_change "$case_dir"
  tip=$(git -C "$case_dir/wt" rev-parse HEAD)
  run_merge "$case_dir" >/dev/null || fail "clean local merge refused"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$tip" ] \
    || fail "clean local merge did not fast-forward main"
  pass "clean recorded ship worktree fast-forwards local main"
}

test_dirty_worktree_refuses() {
  local case_dir
  case_dir=$(make_case dirty)
  commit_task_change "$case_dir"
  printf 'untracked\n' > "$case_dir/wt/untracked.tmp"
  assert_refused_unchanged "$case_dir" 'has uncommitted or untracked changes'
  assert_present "$case_dir/wt/untracked.tmp" "refusal discarded untracked work"
  pass "tracked or untracked task dirt refuses before main moves"
}

test_wrong_branch_and_foreign_repo_refuse() {
  local case_dir
  case_dir=$(make_case wrong-branch)
  commit_task_change "$case_dir"
  git -C "$case_dir/wt" checkout -q -b other
  assert_refused_unchanged "$case_dir" "expected 'fm/task-x1'"

  # A second checkout of the same repo can carry fm/<id> at the identical SHA,
  # so branch name and tip alone prove nothing about whose tree was inspected.
  case_dir=$(make_case foreign-repo)
  commit_task_change "$case_dir"
  git clone -q "$case_dir/project" "$case_dir/impostor"
  git -C "$case_dir/impostor" checkout -q -b fm/task-x1 origin/fm/task-x1
  [ "$(git -C "$case_dir/impostor" rev-parse HEAD)" = "$(git -C "$case_dir/project" rev-parse fm/task-x1)" ] \
    || fail "the impostor checkout is not at the task branch tip, so this case proves nothing"
  awk -v wt="$case_dir/impostor" '
    /^worktree=/ { print "worktree=" wt; next }
    { print }
  ' "$case_dir/home/state/task-x1.meta" > "$case_dir/meta.tmp"
  mv "$case_dir/meta.tmp" "$case_dir/home/state/task-x1.meta"
  assert_refused_unchanged "$case_dir" 'not an isolated task worktree'
  pass "wrong task branch or a foreign same-named checkout refuses before main moves"
}

test_harness_artifacts_do_not_block_landing() {
  local case_dir tip
  case_dir=$(make_case harness-artifacts)
  commit_task_change "$case_dir"
  mkdir -p "$case_dir/wt/.claude"
  printf '{}\n' > "$case_dir/wt/.claude/settings.local.json"
  printf '{}\n' > "$case_dir/wt/.claude/other.json"
  printf 'token=t\n' > "$case_dir/wt/.fm-grok-turnend"
  tip=$(git -C "$case_dir/wt" rev-parse HEAD)
  run_merge "$case_dir" >/dev/null \
    || fail "firstmate's own harness artifacts blocked an approved landing"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$tip" ] \
    || fail "landing with harness artifacts present did not fast-forward main"
  pass "firstmate-written harness artifacts are not crewmate dirt"
}

test_non_ship_and_divergence_refuse() {
  local case_dir
  case_dir=$(make_case non-ship)
  commit_task_change "$case_dir"
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "window=fake" "endpoint_task_id=task-x1" "worktree=$case_dir/wt" \
    "project=$case_dir/project" "kind=scout" "mode=local-only" "yolo=off"
  assert_refused_unchanged "$case_dir" 'not a ship'

  case_dir=$(make_case diverged)
  commit_task_change "$case_dir"
  printf 'main advance\n' > "$case_dir/project/main.txt"
  git -C "$case_dir/project" add main.txt
  git -C "$case_dir/project" commit -qm main-advance
  assert_refused_unchanged "$case_dir" 'not a fast-forward'
  pass "non-ship and divergent branch refuse before main moves"
}

# The readiness checks LAYER OVER the role partition rather than replacing it:
# landing stays main-owned, and the supervision branch is still refused first,
# before any worktree is even inspected.
test_branch_actor_is_still_refused_first() {
  local case_dir before rc=0
  case_dir=$(make_case branch-actor)
  commit_task_change "$case_dir"
  before=$(git -C "$case_dir/project" rev-parse main)
  FM_SUPERVISION_ACTOR=branch run_merge "$case_dir" >"$case_dir/out" 2>"$case_dir/err" || rc=$?
  expect_code 6 "$rc" "the supervision branch was not refused the local landing"
  assert_grep 'never performs this action' "$case_dir/err" \
    "the role-partition refusal was lost: $(cat "$case_dir/err")"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "a branch-actor landing moved main"
  pass "the supervision-branch role partition still refuses local landing ahead of the readiness checks"
}

# The readiness checks certify ONE commit. Everything between them and the
# merge used to re-resolve the mutable branch name, so a worker that committed
# in that window had its uninspected tip landed. The shim below advances
# fm/task-x1 exactly when the script reaches its fast-forward check.
install_racing_git() {  # <fakebin> <task-worktree> <marker>
  cat > "$1/git" <<'SH'
#!/usr/bin/env bash
real=${FM_TEST_REAL_GIT:?}
for arg in "$@"; do
  [ "$arg" = merge-base ] || continue
  if [ ! -e "${FM_TEST_RACE_MARK:?}" ]; then
    : > "$FM_TEST_RACE_MARK"
    printf 'late\n' > "${FM_TEST_RACE_WT:?}/late.txt"
    "$real" -C "$FM_TEST_RACE_WT" add late.txt >/dev/null 2>&1
    "$real" -C "$FM_TEST_RACE_WT" commit -qm late-work >/dev/null 2>&1
  fi
  break
done
exec "$real" "$@"
SH
  chmod +x "$1/git"
  FM_TEST_REAL_GIT=$(command -v git)
  FM_TEST_RACE_WT=$2
  FM_TEST_RACE_MARK=$3
  export FM_TEST_REAL_GIT FM_TEST_RACE_WT FM_TEST_RACE_MARK
}

test_branch_advanced_during_validation_refuses() {
  local case_dir fakebin inspected before raced rc=0
  case_dir=$(make_case racing-branch)
  commit_task_change "$case_dir"
  inspected=$(git -C "$case_dir/wt" rev-parse HEAD)
  before=$(git -C "$case_dir/project" rev-parse main)
  fakebin=$(fm_fakebin "$case_dir")
  install_racing_git "$fakebin" "$case_dir/wt" "$case_dir/raced"

  PATH="$fakebin:$PATH" run_merge "$case_dir" >"$case_dir/out" 2>"$case_dir/err" || rc=$?
  unset FM_TEST_REAL_GIT FM_TEST_RACE_WT FM_TEST_RACE_MARK

  # Without a real divergence this case would pass vacuously on any script.
  assert_present "$case_dir/raced" "the shim never fired, so this case proves nothing"
  raced=$(git -C "$case_dir/wt" rev-parse HEAD)
  [ "$raced" != "$inspected" ] || fail "the task branch did not move during validation"

  expect_code 1 "$rc" "a branch that advanced during validation was not refused"
  assert_grep 'advanced from' "$case_dir/err" \
    "the refusal did not name the moved branch: $(cat "$case_dir/err")"
  [ "$(git -C "$case_dir/project" rev-parse main)" = "$before" ] \
    || fail "a refused landing moved main (uninspected tip $raced)"
  pass "a task branch that advances during validation refuses instead of landing an uninspected commit"
}

test_clean_exact_tip_succeeds
test_branch_actor_is_still_refused_first
test_dirty_worktree_refuses
test_harness_artifacts_do_not_block_landing
test_wrong_branch_and_foreign_repo_refuse
test_non_ship_and_divergence_refuse
test_branch_advanced_during_validation_refuses

echo '# all fm-merge-local tests passed'
