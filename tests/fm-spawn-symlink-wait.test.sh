#!/usr/bin/env bash
# Behavior test for fm-spawn.sh's treehouse wait loop through a SYMLINKED
# project dir.
#
# Backends report the pane's PHYSICAL cwd, but PROJ_ABS is resolved with a
# logical pwd. Through a symlinked projects/<name>, physical != logical from
# the very first poll, so the old break condition (`p != PROJ_ABS`) fired
# before treehouse moved the pane, captured the project checkout as WT, and
# the isolation guard refused the launch. The fake tmux here returns the
# project's physical path for the first polls and the worktree afterwards,
# so the loop must keep waiting through the symlink mismatch to succeed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-symlink-wait)

# Fake tmux whose pane-path query is stateful: calls 1..FM_FAKE_PANE_MOVE_AFTER
# return FM_FAKE_PANE_PATH_BEFORE (the pane still sitting in the project),
# later calls return FM_FAKE_PANE_PATH (treehouse moved it to the worktree).
make_symlink_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    n=0
    if [ -n "${FM_FAKE_PANE_COUNT:-}" ] && [ -f "$FM_FAKE_PANE_COUNT" ]; then
      n=$(cat "$FM_FAKE_PANE_COUNT")
    fi
    n=$((n + 1))
    [ -z "${FM_FAKE_PANE_COUNT:-}" ] || printf '%s\n' "$n" > "$FM_FAKE_PANE_COUNT"
    if [ "$n" -le "${FM_FAKE_PANE_MOVE_AFTER:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_PATH_BEFORE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

test_symlinked_project_waits_for_worktree_move() {
  local id case_dir home proj proj_link proj_phys wt fakebin count out status
  id=symlink-wait-z1
  case_dir="$TMP_ROOT/symlink-wait"
  home="$case_dir/home"
  proj="$case_dir/project"
  proj_link="$case_dir/project-link"
  wt="$case_dir/wt"
  count="$case_dir/pane-count"
  fakebin=$(make_symlink_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  ln -s "$proj" "$proj_link"
  proj_phys=$(cd "$proj" && pwd -P)

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    FM_FAKE_PANE_COUNT="$count" FM_FAKE_PANE_MOVE_AFTER=2 \
    FM_FAKE_PANE_PATH_BEFORE="$proj_phys" FM_FAKE_PANE_PATH="$wt" \
    "$SPAWN" "$id" "$proj_link" 2>&1)
  status=$?
  expect_code 0 "$status" "spawn through a symlinked project dir should wait out the pane's physical-cwd polls and succeed"
  assert_not_contains "$out" "did not yield an isolated worktree" \
    "spawn treated the pane's physical project cwd as the worktree move"
  assert_contains "$out" "worktree=$wt" "spawn did not capture the real worktree path"
  assert_grep "worktree=$wt" "$home/state/$id.meta" "meta did not record the real worktree"
  pass "wait loop keeps polling while a symlinked project's pane reports its physical cwd"
}

test_symlinked_project_waits_for_worktree_move

echo "# all fm-spawn-symlink-wait tests passed"
