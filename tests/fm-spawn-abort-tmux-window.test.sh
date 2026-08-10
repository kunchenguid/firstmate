#!/usr/bin/env bash
# Regression test for issue #1913: fm-spawn.sh leaves an orphan tmux window
# behind when validate_spawn_worktree refuses a spawn.
#
# validate_spawn_worktree (bin/fm-spawn.sh) runs AFTER fm_backend_tmux_create_task
# has already created the task's tmux window and after `treehouse get` has
# settled the pane into a non-isolated location. Before the fix,
# spawn_abort_cleanup cleaned up herdr projections and orca worktrees but never
# the tmux window it created, so the window "firstmate:fm-<id>" survived the
# refusal. A second spawn attempt for the same task id then hit
# `error: window firstmate:fm-<id> already exists` from bin/backends/tmux.sh,
# because nothing ever removed the orphan.
#
# This test simulates a refusal (the pane settles into a real git checkout
# that is not itself a worktree top-level - a stand-in for any non-isolated
# location validate_spawn_worktree rejects) with a fake tmux that tracks which
# windows exist, exactly like a real tmux server would. It asserts the window
# is gone after the refusal, and that a second spawn attempt for the same id
# succeeds instead of hitting the duplicate-window error.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-abort-tmux-window)

# make_window_tracking_fakebin <dir>: a fake tmux that, in addition to the
# stale-then-settled pane_current_path simulation from
# fm-spawn-worktree-settle.test.sh, tracks window existence in a flat file so
# `list-windows` (fm_backend_tmux_create_task's duplicate check) and
# `kill-window` (fm_backend_kill's cleanup) behave like a real tmux server:
# a window created by new-window is visible to list-windows until a
# kill-window for it runs.
make_window_tracking_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
windows_file="${FM_FAKE_WINDOWS_FILE:?FM_FAKE_WINDOWS_FILE unset}"
touch "$windows_file"
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  has-session|new-session|send-keys|set-window-option) exit 0 ;;
  list-windows)
    cat "$windows_file"
    exit 0
    ;;
  new-window)
    wname=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "-n" ] && wname="$a"
      prev="$a"
    done
    if grep -qxF "$wname" "$windows_file" 2>/dev/null; then
      echo "error: window already exists" >&2
      exit 1
    fi
    printf '%s\n' "$wname" >> "$windows_file"
    printf '@%s\n' "$(wc -l < "$windows_file" | tr -d ' ')"
    exit 0
    ;;
  kill-window)
    target=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "-t" ] && target="$a"
      prev="$a"
    done
    wname=${target##*:}
    wname=${wname#=}
    grep -vxF "$wname" "$windows_file" > "$windows_file.tmp" 2>/dev/null || : > "$windows_file.tmp"
    mv "$windows_file.tmp" "$windows_file"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

id=abort-tmux-window-z1
case_dir="$TMP_ROOT/case"
home="$case_dir/home"
proj="$case_dir/project"
# A real, distinct git checkout that is NOT itself a worktree top-level - the
# pane "settles" into its subdirectory, so validate_spawn_worktree's
# `git rev-parse --show-toplevel` resolves to a DIFFERENT path than the
# candidate itself, and the spawn is refused as soon as the settle loop
# accepts the candidate (no isolation-guard timeout wait needed).
tangle_repo="$case_dir/tangle-repo"
tangle_sub="$tangle_repo/sub"
countfile="$case_dir/pane-call-count"
windows_file="$case_dir/tmux-windows"
fakebin=$(make_window_tracking_fakebin "$case_dir/fake")

mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
printf 'codex\n' > "$home/config/crew-harness"
fm_git_init_commit "$proj"
fm_git_init_commit "$tangle_repo"
mkdir -p "$tangle_sub"
mkdir -p "$home/data/$id"
printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
touch "$home/state/.last-watcher-beat"

run_spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$tangle_sub" FM_FAKE_PANE_STALE="" \
    FM_FAKE_PANE_STALE_READS=0 FM_FAKE_PANE_COUNTFILE="$countfile" \
    FM_FAKE_WINDOWS_FILE="$windows_file" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" --mode no-mistakes --yolo off 2>&1
}

test_refused_spawn_removes_its_own_tmux_window() {
  local out status
  out=$(run_spawn)
  status=$?
  expect_code 1 "$status" "spawn should refuse: the pane settled outside an isolated worktree"
  assert_contains "$out" "did not yield an isolated worktree" \
    "expected validate_spawn_worktree's refusal message"
  assert_absent "$home/state/$id.meta" \
    "a refused spawn must not publish task metadata"
  assert_no_grep "fm-$id" "$windows_file" \
    "the tmux window created for the refused spawn must be removed by abort cleanup"
  pass "a spawn refused by validate_spawn_worktree removes the tmux window it created"
}

test_respawn_after_refusal_does_not_hit_duplicate_window() {
  local out status
  # Reset the pane-read counter so the second attempt re-runs the same
  # settle sequence; the windows file is intentionally left as the first
  # attempt's cleanup (or lack of it) leaves it.
  rm -f "$countfile"
  out=$(run_spawn)
  status=$?
  assert_not_contains "$out" "already exists" \
    "a respawn after a refusal must not hit fm-spawn's duplicate-window error"
  expect_code 1 "$status" "the respawn hits the same isolation refusal, not a duplicate-window error"
  assert_contains "$out" "did not yield an isolated worktree" \
    "the respawn should fail for the same isolation reason as the first attempt, not a stale window"
  pass "a respawn after a refused spawn does not collide with an orphaned window"
}

test_refused_spawn_removes_its_own_tmux_window
test_respawn_after_refusal_does_not_hit_duplicate_window

echo "# all fm-spawn-abort-tmux-window tests passed"
