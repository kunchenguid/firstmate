#!/usr/bin/env bash
# fm-relaunch-missing-endpoint: relaunch recovery when the runtime endpoint was
# destroyed outside teardown, and the teardown worktree collision guard.
#
# Tests:
#   1. fm-spawn --relaunch accepts a provably absent (missing) endpoint and
#      creates a replacement.
#   2. fm-spawn --relaunch still refuses an unreadable endpoint (mutation check:
#      treating "I could not check" as "it is gone" must fail).
#   3. fm-control.sh exit still refuses a missing endpoint when called standalone.
#   4. fm-teardown.sh refuses when another task's metadata claims the same worktree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-relaunch-missing)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as the existing relaunch tests.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
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
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          ;;
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          ;;
      esac
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
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  new-window)
    shift
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -n) shift 2 ;;
        -P) shift ;;
        -F) shift 2 ;;
        *) break ;;
      esac
    done
    printf 'fakepane\n'
    exit 0 ;;
  has-session) exit 0 ;;
  new-session) exit 0 ;;
  set-option) exit 0 ;;
  set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  # Stub treehouse to report the worktree path.
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get) printf '%s\n' "$FM_FAKE_CWD_OVERRIDE" ;;
  return) exit 0 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fb/treehouse"
}

new_case() {  # <name> <id>
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

add_ship_task() {  # <case-dir> <id> [harness]
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  printf '# brief for %s\n\nDo the thing.\n' "$id" > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_FAKE_CWD_OVERRIDE="$dir/wt" \
    "$SPAWN" "$@" 2>&1
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_FAKE_CWD_OVERRIDE="$dir/wt" \
    "$CONTROL" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

# --- 1. fm-spawn --relaunch accepts a provably absent endpoint ---------------

test_spawn_relaunch_accepts_missing_endpoint() {
  local dir out rc
  dir=$(new_case missing-ok rl-m1)
  add_ship_task "$dir" rl-m1 claude
  # Make the endpoint provably absent: the window is NOT in the tmux session's
  # window list. The tmux agent_state classifier returns 'missing' for this.
  printf '' > "$dir/fake/windows"
  # The agent is not running (command is zsh, not claude).
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl-m1 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch with a provably absent endpoint should succeed"
  assert_contains "$out" "provably absent" "the output should mention the endpoint was provably absent"
  # The meta file must exist and point at the task.
  [ -f "$dir/home/state/rl-m1.meta" ] \
    || fail "relaunch with missing endpoint should publish a replacement meta"
  [ "$(meta_field "$dir" rl-m1 endpoint_task_id)" = rl-m1 ] \
    || fail "the replacement meta must preserve the task id"
  [ "$(meta_field "$dir" rl-m1 harness)" = claude ] \
    || fail "the replacement meta must record the harness"
  pass "fm-spawn --relaunch: accepts a provably absent endpoint and creates a replacement"
}

# --- 2. Mutation check: unreadable endpoint must NOT be treated as missing ----

test_spawn_relaunch_refuses_unreadable_endpoint() {
  local dir out rc
  dir=$(new_case unreadable rl-m2)
  add_ship_task "$dir" rl-m2 claude
  # Make the tmux stub return a non-zero exit code with an UNRECOGNIZED error
  # message, so the classifier returns 'unreadable' rather than 'missing'.
  # Override the tmux stub to produce an unreadable result.
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    echo "error: unexpected internal failure" >&2
    exit 42
    ;;
  display-message)
    printf 'fakepane\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  out=$(run_spawn "$dir" rl-m2 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunch with an unreadable endpoint must refuse"
  assert_contains "$out" "unreadable" "the refusal should name the unreadable state"
  pass "fm-spawn --relaunch: refuses an unreadable endpoint (mutation check passed)"
}

# --- 3. fm-control.sh exit still refuses a missing endpoint -------------------

test_control_exit_refuses_missing_endpoint() {
  local dir out rc
  dir=$(new_case exit-missing rl-m3)
  add_ship_task "$dir" rl-m3 claude
  # Make the endpoint provably absent.
  printf '' > "$dir/fake/windows"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_control "$dir" rl-m3 exit); rc=$?
  expect_code 1 "$rc" "standalone exit with a missing endpoint should refuse"
  assert_contains "$out" "recorded endpoint is gone" "the exit refusal should explain the endpoint is gone"
  assert_contains "$out" "reconcile" "the exit refusal should suggest reconciliation"
  pass "fm-control.sh exit: still refuses when the endpoint is missing"
}

# --- 4. Teardown worktree collision guard ------------------------------------

test_teardown_skips_reap_on_worktree_collision() {
  local dir out rc id1=td-c1 id2=td-c2
  dir=$(new_case teardown-collision "$id1")
  add_ship_task "$dir" "$id1" claude
  local wt
  wt=$(meta_field "$dir" "$id1" worktree)
  # Create a second task's meta that claims the SAME worktree.
  {
    echo "window=fmses:fm-$id2"
    echo "endpoint_task_id=$id2"
    echo "worktree=$wt"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
  } > "$dir/home/state/$id2.meta"
  # Make the first task's endpoint dead (so exit checks pass).
  printf 'zsh' > "$dir/fake/command"
  # Push a commit so landed-work checks pass in --force mode.
  (cd "$dir/wt" && git add -A && git -c user.name='Test' -c user.email='t@t' commit -qm work && git push -q origin HEAD 2>/dev/null) || true
  # Attempt teardown of the first task - should succeed but skip the CWD reap.
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 FM_TEARDOWN_GUARD_DONE=1 \
    "$TEARDOWN" "$id1" 2>&1); rc=$?
  # Teardown should succeed (exit 0), not refuse.
  expect_code 0 "$rc" "teardown should succeed when a sibling claims the same worktree"
  assert_contains "$out" "$id2" "the warning should name the colliding task"
  assert_contains "$out" "skipping CWD-based process reap" "the warning should explain the reap was skipped"
  pass "fm-teardown.sh: skips CWD-based process reap when another task claims the same worktree"
}

# --- run all tests -----------------------------------------------------------

test_spawn_relaunch_accepts_missing_endpoint
test_spawn_relaunch_refuses_unreadable_endpoint
test_control_exit_refuses_missing_endpoint
test_teardown_skips_reap_on_worktree_collision

echo "all tests passed"
