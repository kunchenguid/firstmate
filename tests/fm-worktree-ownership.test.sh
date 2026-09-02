#!/usr/bin/env bash
# Tests for task ownership guards around pooled worktrees.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-ownership)

make_spawn_case() {
  local name=$1 dir="$TMP_ROOT/spawn-$1" home project worktree fakebin
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  mkdir -p "$dir"
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" spawn-task
  fm_git_worktree "$project" "$worktree" "fm/spawn-owner"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fakebin")
  printf '%s\n' "$home|$project|$worktree|$fakebin"
}

read_spawn_case() {
  IFS='|' read -r HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  fm_test_run_spawn "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off
}

make_teardown_case() {
  local name=$1 dir="$TMP_ROOT/teardown-$1" home project worktree fakebin
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  fakebin="$dir/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  fm_git_worktree "$project" "$worktree" "fm/teardown-task"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$dir/fakebin/tmux" "$dir/fakebin/treehouse" "$dir/fakebin/no-mistakes"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$dir|$home|$project|$worktree|$fakebin"
}

read_teardown_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

write_teardown_meta() {
  local id=$1
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$WORKTREE_DIR" \
    "project=$PROJECT_DIR" \
    "kind=ship" \
    "mode=no-mistakes" \
    "spawn_gen=ownership-test-$id"
}

run_teardown() {
  local id=$1
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_RUNTIME_LOG="$CASE_DIR/runtime.log" \
    PATH="$FAKEBIN_DIR:$PATH" "$TEARDOWN" "$id" --force
}

test_spawn_collision_refuses() {
  local rec out rc before after
  rec=$(make_spawn_case collision)
  read_spawn_case "$rec"
  fm_write_meta "$HOME_DIR/state/spawn-owner.meta" \
    "window=firstmate:fm-spawn-owner" "worktree=$WORKTREE_DIR" "kind=ship"
  before=$(git -C "$WORKTREE_DIR" rev-parse HEAD)

  set +e
  out=$(run_spawn spawn-task 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "spawn collision must refuse"
  assert_contains "$out" "worktree '$WORKTREE_DIR' is already held by task 'spawn-owner'" \
    "spawn collision did not name the holding task and worktree"
  assert_contains "$out" "Resolve task 'spawn-owner'" \
    "spawn collision did not provide an operator next step"
  assert_absent "$HOME_DIR/state/spawn-task.meta" \
    "refused spawn published task metadata"
  after=$(git -C "$WORKTREE_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "refused spawn changed the held worktree"
  pass "fm-spawn refuses a worktree already named by another task"
}

test_spawn_free_worktree_succeeds() {
  local rec out rc
  rec=$(make_spawn_case free)
  read_spawn_case "$rec"

  set +e
  out=$(run_spawn spawn-task 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "free spawn must succeed"
  assert_contains "$out" "spawned spawn-task" "free spawn did not report success"
  assert_grep "worktree=$WORKTREE_DIR" "$HOME_DIR/state/spawn-task.meta" \
    "free spawn did not record its worktree"
  pass "fm-spawn still succeeds on a genuinely free worktree"
}

test_teardown_other_task_branch_refuses() {
  local rec out rc branch
  rec=$(make_teardown_case collision)
  read_teardown_case "$rec"
  write_teardown_meta teardown-task
  git -C "$WORKTREE_DIR" branch -m fm/other-task
  fm_write_meta "$HOME_DIR/state/other-task.meta" \
    "window=firstmate:fm-other-task" \
    "endpoint_task_id=other-task" \
    "worktree=$WORKTREE_DIR" \
    "project=$PROJECT_DIR" \
    "kind=ship"
  : > "$CASE_DIR/runtime.log"

  set +e
  out=$(run_teardown teardown-task 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "teardown of another task branch must refuse"
  assert_contains "$out" "branch fm/other-task for task other-task" \
    "teardown refusal did not name the branch and holding task"
  assert_contains "$out" "retry teardown after its work is safely landed" \
    "teardown refusal did not provide an operator next step"
  assert_present "$HOME_DIR/state/teardown-task.meta" \
    "refused teardown removed task metadata"
  assert_present "$HOME_DIR/state/other-task.meta" \
    "refused teardown removed holding metadata"
  assert_present "$WORKTREE_DIR/.git" "refused teardown changed worktree git state"
  branch=$(git -C "$WORKTREE_DIR" symbolic-ref --short HEAD)
  [ "$branch" = fm/other-task ] || fail "refused teardown changed branch to $branch"
  [ ! -s "$CASE_DIR/runtime.log" ] || fail "refused teardown ran cleanup: $(cat "$CASE_DIR/runtime.log")"
  pass "fm-teardown refuses a copy checked out on another task's branch"
}

test_teardown_own_task_branch_succeeds() {
  local rec out rc
  rec=$(make_teardown_case own)
  read_teardown_case "$rec"
  write_teardown_meta teardown-task
  : > "$CASE_DIR/runtime.log"

  set +e
  out=$(run_teardown teardown-task 2>&1)
  rc=$?
  set -e

  expect_code 0 "$rc" "teardown of own branch must succeed"
  assert_contains "$out" "teardown teardown-task complete" \
    "own-branch teardown did not report success"
  assert_absent "$HOME_DIR/state/teardown-task.meta" \
    "own-branch teardown left task metadata"
  pass "fm-teardown still succeeds for a copy on its own task branch"
}

test_spawn_collision_refuses
test_spawn_free_worktree_succeeds
test_teardown_other_task_branch_refuses
test_teardown_own_task_branch_succeeds

echo "# all fm-worktree-ownership tests passed"
