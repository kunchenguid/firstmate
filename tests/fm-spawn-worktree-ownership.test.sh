#!/usr/bin/env bash
# Regression test: validate_spawn_worktree accepted ANY real, distinct git worktree, including
# another live firstmate home or a sibling task's worktree. A pane stably
# reporting such a path (e.g. treehouse get silently no-op'ing while the pane
# sat in a dead secondmate's home) sailed through the guard and the agent
# wrote into someone else's home. These tests drive the real fm-spawn.sh with
# a fake tmux whose pane_current_path stably reports an owned path and assert
# the spawn refuses, plus the positive cases (fresh and self-recorded
# worktrees still launch).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-ownership)

# make_ownership_fakebin <dir> builds a fake tmux whose #{pane_current_path}
# query always returns FM_FAKE_PANE_PATH - a pane stably sitting somewhere
# that is NOT the project (the persistently-wrong incident shape, which the
# two-stable-reads settle loop alone cannot catch).
make_ownership_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:?FM_FAKE_PANE_PATH unset}"
    exit 0
    ;;
  *"#{pane_current_command}"*)
    printf 'claude\n'
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    [ -n "${FM_FAKE_LIVE_WINDOW:-}" ] && printf '%s\n' "$FM_FAKE_LIVE_WINDOW"
    [ -f "${FM_FAKE_WINDOW_LOG:-/nonexistent}" ] && cat "$FM_FAKE_WINDOW_LOG"
    exit 0
    ;;
  new-window)
    # Record the window name so later list-windows sees the task's own endpoint.
    while [ $# -gt 0 ]; do
      [ "$1" = -n ] && { printf '%s\n' "${2:-}" >> "${FM_FAKE_WINDOW_LOG:?FM_FAKE_WINDOW_LOG unset}"; break; }
      shift
    done
    exit 0
    ;;
  has-session|new-session|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_ownership_case <name> builds a home, a primary project with a fresh
# real worktree, and echoes "$case_dir|$home|$proj|$wt|$fakebin".
make_ownership_case() {
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_ownership_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_ownership_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_ownership_spawn <id> <pane-path> [extra-env...]: run the real spawn with
# the pane stably reporting <pane-path>; echoes output, returns spawn status.
run_ownership_spawn() {
  local id=$1 pane=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_LIVE_WINDOW="${FM_FAKE_LIVE_WINDOW:-}" \
    FM_FAKE_WINDOW_LOG="$HOME_DIR/fake-windows" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off --model sonnet 2>&1
}

stage_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nbrief for %s\n\n## Firstmate spec\nbuild it\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
}

# A pane stably sitting in a sibling task's recorded worktree must be refused
# while that sibling is still live there (a positively alive endpoint).
test_sibling_task_worktree_is_refused() {
  local rec id out status other_wt
  id=own-sibling-task-z2
  rec=$(make_ownership_case sibling-task)
  read_ownership_record "$rec"
  stage_brief "$HOME_DIR" "$id"
  other_wt="$TMP_ROOT/sibling-task/other-wt"
  fm_git_worktree "$PROJ_DIR" "$other_wt" "wt-other-task"
  fm_write_meta "$HOME_DIR/state/other-task.meta" \
    "window=firstmate:fm-other-task" \
    "worktree=$other_wt" \
    "kind=ship" "harness=codex" "mode=no-mistakes" "yolo=off"

  out=$(FM_FAKE_LIVE_WINDOW=fm-other-task run_ownership_spawn "$id" "$other_wt"); status=$?
  [ "$status" -ne 0 ] || fail "spawn into a live sibling task worktree succeeded - expected refusal"
  assert_contains "$out" "task other-task" "refusal did not name the owning task"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn still published state/$id.meta"
  pass "a pane stably sitting in a live sibling task's worktree is refused"
}

# A STALE record must not veto a fresh allocation: the sibling's endpoint is
# gone (a session restart freed the slot, the harness fixture reuses one fake
# worktree), so the same path is accepted. Anything but a positively alive
# endpoint fails open exactly as before this guard.
test_stale_task_record_does_not_veto() {
  local rec id out status other_wt
  id=own-stale-record-z5
  rec=$(make_ownership_case stale-record)
  read_ownership_record "$rec"
  stage_brief "$HOME_DIR" "$id"
  other_wt="$TMP_ROOT/stale-record/other-wt"
  fm_git_worktree "$PROJ_DIR" "$other_wt" "wt-stale-task"
  fm_write_meta "$HOME_DIR/state/stale-task.meta" \
    "window=firstmate:fm-stale-task" \
    "worktree=$other_wt" \
    "kind=ship" "harness=codex" "mode=no-mistakes" "yolo=off"

  out=$(run_ownership_spawn "$id" "$other_wt"); status=$?
  expect_code 0 "$status" "spawn into a worktree with only a stale record should succeed: $out"
  assert_grep "worktree=$other_wt" "$HOME_DIR/state/$id.meta" \
    "meta did not record the worktree a stale record had claimed"
  pass "a stale sibling task record does not veto a fresh allocation"
}

# A fresh, unowned worktree is still accepted.
test_fresh_worktree_is_accepted() {
  local rec id out status
  id=own-fresh-z3
  rec=$(make_ownership_case fresh)
  read_ownership_record "$rec"
  stage_brief "$HOME_DIR" "$id"

  out=$(run_ownership_spawn "$id" "$WT_DIR"); status=$?
  expect_code 0 "$status" "spawn into a fresh worktree should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the fresh worktree"
  pass "a fresh, unowned worktree is accepted"
}

# The task's own recorded worktree never counts against it (the relaunch
# shape: adopting your own copy must not self-refuse).
test_own_recorded_worktree_is_accepted() {
  local rec id out status
  id=own-self-z4
  rec=$(make_ownership_case self)
  read_ownership_record "$rec"
  stage_brief "$HOME_DIR" "$id"
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$WT_DIR" \
    "kind=ship" "harness=codex" "mode=no-mistakes" "yolo=off"

  out=$(run_ownership_spawn "$id" "$WT_DIR"); status=$?
  expect_code 0 "$status" "spawn into the task's own recorded worktree should succeed"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not keep the task's own worktree"
  pass "the task's own recorded worktree is accepted"
}

test_sibling_task_worktree_is_refused
test_stale_task_record_does_not_veto
test_fresh_worktree_is_accepted
test_own_recorded_worktree_is_accepted

echo "# all fm-spawn-worktree-ownership tests passed"
