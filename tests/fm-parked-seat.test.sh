#!/usr/bin/env bash
# tests/fm-parked-seat.test.sh - verify parked-seat watcher suppression and teardown safety.
#
#   1. Teardown safety: fm-teardown unlanded-work refusal stays authoritative and
#      parking preserves unlanded commits.
#   2. Watcher probe loop: recorded_windows in fm-watch omits parked windows while
#      the shared target helper still resolves the parked endpoint for other callers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

CONTROL="$ROOT/bin/fm-control.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-parked-seat)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT
fm_git_identity fmtest fmtest@example.invalid

# --- fake tmux stub ---------------------------------------------------------
make_tmux_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D="$FM_FAKE_DIR"
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      if [ "$payload" = /exit ] || [ "$payload" = /quit ]; then
        printf 'zsh' > "$D/command"
      fi
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ -f "$D/pane" ]; then cat "$D/pane"; else printf '╭────╮\n│    │\n╰────╯\n'; fi
    exit 0 ;;
  list-windows)
    if [ -f "$D/windows" ]; then cat "$D/windows"; fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

new_case() {  # <name>
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'zsh' > "$dir/fake/command"
  make_tmux_stub "$dir" >/dev/null
  printf '%s\n' "$dir"
}

setup_task() {  # <case-dir> <id> <harness>
  local dir=$1 id=$2 harness=$3
  local home="$dir/home" proj="$dir/proj-$id" wt="$dir/wt-$id"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_SETTLE_WAIT=0.05 \
    FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

# --- 1. teardown refuses unlanded work on parked task -----------------------
test_teardown_refuses_parked_task_with_unlanded_work() {
  local dir wt proj head out rc
  dir=$(new_case teardown-refusal)
  setup_task "$dir" t1 claude
  wt="$dir/wt-t1"
  proj="$dir/proj-t1"

  # Create an unpushed / unlanded commit in the task worktree
  printf 'unlanded progress\n' >> "$wt/progress.txt"
  git -C "$wt" add progress.txt
  git -C "$wt" commit -q -m "unlanded commit"
  head=$(git -C "$wt" rev-parse HEAD)

  # Park the seat
  run_control "$dir" t1 park >/dev/null || fail "parking task should succeed"
  [ "$(fm_meta_get "$dir/home/state/t1.meta" parked)" = 1 ] || fail "task should be parked"

  # Run teardown: MUST REFUSE because work is unlanded
  set +e
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" "$TEARDOWN" t1 2>&1)
  rc=$?
  set -e

  expect_code 1 "$rc" "teardown of parked seat with unlanded work must refuse"
  assert_contains "$out" "REFUSED" "teardown refusal should say REFUSED"

  # Unlanded commit and worktree must remain 100% intact
  [ -d "$wt" ] || fail "worktree must not be removed"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] || fail "worktree head must be unchanged"
  [ -f "$dir/home/state/t1.meta" ] || fail "task metadata must remain intact"

  pass "teardown: unlanded-work refusal stays authoritative and preserves unlanded commits"
}

# --- 2. watcher omits parked windows -------------------------------------
test_watcher_omits_parked_windows() {
  local dir home state windows
  dir=$(new_case watcher)
  setup_task "$dir" t1 claude
  home="$dir/home"
  state="$home/state"

  # Agent is stopped
  printf 'zsh' > "$dir/fake/command"

  # When unparked: recorded_windows includes the task window
  windows=$(
    # shellcheck disable=SC2034 # read by the sourced watcher at call time
    FM_HOME="$home" STATE="$state" SCRIPT_DIR="$ROOT/bin"
    # shellcheck source=/dev/null
    . "$WATCH"
    recorded_windows
  )
  assert_contains "$windows" "fmses:fm-t1" "unparked task window must be probed by watcher"

  # Park the task
  run_control "$dir" t1 park >/dev/null || fail "parking task should succeed"
  [ "$(fm_meta_get "$state/t1.meta" parked)" = 1 ] || fail "task should be parked"

  # When parked: recorded_windows DOES NOT include the task window
  windows=$(
    # shellcheck disable=SC2034 # read by the sourced watcher at call time
    FM_HOME="$home" STATE="$state" SCRIPT_DIR="$ROOT/bin"
    # shellcheck source=/dev/null
    . "$WATCH"
    recorded_windows
  )
  assert_not_contains "$windows" "fmses:fm-t1" "parked task window must be omitted from recorded_windows"

  [ "$(fm_backend_target_of_meta "$state/t1.meta")" = "fmses:fm-t1" ] \
    || fail "the parked endpoint record must still resolve for non-watcher callers"

  # Unpark and verify recorded_windows probes the window again
  run_control "$dir" t1 unpark >/dev/null || fail "unparking task should succeed"
  windows=$(
    # shellcheck disable=SC2034 # read by the sourced watcher at call time
    FM_HOME="$home" STATE="$state" SCRIPT_DIR="$ROOT/bin"
    # shellcheck source=/dev/null
    . "$WATCH"
    recorded_windows
  )
  assert_contains "$windows" "fmses:fm-t1" "unparked task window must be restored to recorded_windows"

  pass "watcher: parked task is omitted from recorded_windows and restored on unpark"
}

test_teardown_refuses_parked_task_with_unlanded_work
test_watcher_omits_parked_windows

echo "all fm-parked-seat tests passed"
