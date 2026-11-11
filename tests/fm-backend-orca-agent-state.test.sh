#!/usr/bin/env bash
# tests/fm-backend-orca-agent-state.test.sh - the Orca adapter's
# recovery-grade agent-state classifier (bin/backends/orca.sh
# fm_backend_orca_agent_state) and the exit verb it unlocks.
#
# A fake `orca` CLI answers only the two reads the classifier makes -
# `terminal show` (the terminal's ptyId, or Orca's terminal_handle_stale) and
# `diagnostics memory` (ptyId -> pty root pid) - while the process trees under
# that root are REAL processes, so the verdicts come from the same kernel
# facts a live pane yields:
#   1. A harness-named process below the root is `alive`, even though Orca's
#      sticky agentIdentity is deliberately left set on every response.
#   2. A root with only a shell below it, or nothing, is `dead`.
#   3. An unrecognized process below the root is `ambiguous`, never `dead`.
#   4. A stale handle is `missing`; a pty Orca's sweep does not name, or a
#      failing CLI, is `unreadable`.
#   5. fm-control exit on an Orca pi worker submits /quit and proves the stop
#      from the tree; an agent that never stops is reported unconfirmed; and
#      relaunch stays refused on Orca.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-orca-agent-state)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
PIDS=()
cleanup_procs() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do
    pkill -P "$p" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
}
trap cleanup_procs EXIT

# Harness-named and stranger-named long-running executables, so `ps -o comm=`
# reports those exact names for real processes. Each must be a real executable
# whose own file name is the name under test: a symlink to a system binary is
# not portable, because Ubuntu 25.10 ships coreutils as the uutils multicall
# binary, which refuses to run under a name that does not match the utility it
# was asked for ("Security violation: Requested utility `pi` does not match
# executable name"). That made the child die instantly and the pane read `dead`
# on CI while passing locally. Compiling our own tiny spinner keeps the identity
# equal to the name on every platform, and unlike a copy of a signed system
# binary it is not killed by macOS arm64 code-signing validation. Where no C
# compiler exists the symlink fallback still covers the platforms whose `sleep`
# tolerates being renamed.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
CC_BIN=$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)
if [ -n "$CC_BIN" ]; then
  printf '%s\n' '#include <unistd.h>' 'int main(void){for(;;)sleep(60);return 0;}' > "$TMP_ROOT/spin.c"
fi
make_stand_in() {  # <path>
  if [ -n "$CC_BIN" ] && "$CC_BIN" -o "$1" "$TMP_ROOT/spin.c" 2>/dev/null; then
    return 0
  fi
  ln -sf "$(command -v sleep)" "$1"
}
make_stand_in "$BIN/pi"
make_stand_in "$BIN/mystery"

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/orca" <<'SH'
#!/usr/bin/env bash
set -u
D=${FM_FAKE_ORCA_DIR:?}
printf '%s\n' "$*" >> "$D/log"
[ ! -f "$D/fail" ] || exit 1
case "${1:-} ${2:-}" in
  "terminal show")
    if [ -f "$D/stale" ]; then
      printf '{"ok":false,"error":{"code":"terminal_handle_stale","message":"terminal_handle_stale"}}\n'
      exit 1
    fi
    printf '{"ok":true,"result":{"terminal":{"handle":"term-1","ptyId":"wt::/x@@pty1","worktreePath":"/x","agentIdentity":"pi","title":"Pi ready"}}}\n'
    ;;
  "diagnostics memory")
    root=$(cat "$D/root" 2>/dev/null || echo 0)
    printf '{"ok":true,"result":{"worktrees":[{"worktreeId":"wt::/x","sessions":[{"sessionId":"wt::/x@@other","pid":1},{"sessionId":"%s","pid":%s}]}]}}\n' \
      "$(cat "$D/pty" 2>/dev/null || echo 'wt::/x@@pty1')" "$root"
    ;;
  "terminal send")
    case "$*" in
      *"--text /quit"*)
        [ -n "${FM_FAKE_NEVER_DIES:-}" ] || kill "$(cat "$D/agent.pid" 2>/dev/null)" 2>/dev/null || true
        ;;
    esac
    printf '{"ok":true,"result":{"send":{"accepted":true}}}\n'
    ;;
  "terminal read")
    printf '{"ok":true,"result":{"terminal":{"tail":["╭────╮","│    │","╰────╯"]}}}\n'
    ;;
  *) printf '{"ok":true,"result":{}}\n' ;;
esac
SH
chmod +x "$FAKEBIN/orca"

new_dir() {  # <name> -> echoes a fake-orca state dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  : > "$d/log"
  printf '%s\n' "$d"
}

# start_root <dir> <child-command...>: a real root process (Orca's pty
# wrapper stand-in) running one child; records the root pid for the fake
# sweep and the child pid as the agent.
start_root() {
  local d=$1 root i
  shift
  # The root outlives its child, as a pane's login wrapper does.
  bash -c '"$@" & echo $! > "$0/agent.pid"; wait; exec sleep 600' "$d" "$@" &
  root=$!
  PIDS+=("$root")
  printf '%s\n' "$root" > "$d/root"
  i=0
  while [ ! -s "$d/agent.pid" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  sleep 0.2
}

agent_state() {  # <dir>
  PATH="$FAKEBIN:$PATH" FM_FAKE_ORCA_DIR="$1" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state orca term-1' _ "$ROOT"
}

test_harness_below_root_is_alive_despite_sticky_identity() {
  local d st
  d=$(new_dir alive)
  start_root "$d" "$BIN/pi" 60
  st=$(agent_state "$d")
  [ "$st" = alive ] || fail "a pi process below the pty root should read alive, got '$st'"
  kill "$(cat "$d/agent.pid")" 2>/dev/null; sleep 0.3
  st=$(agent_state "$d")
  [ "$st" = dead ] \
    || fail "after the agent exits the same terminal (identity still 'pi') should read dead, got '$st'"
  pass "orca agent state: a harness below the pty root is alive; Orca's sticky identity never keeps it alive"
}

test_shell_only_tree_is_dead() {
  local d st fifo
  d=$(new_dir shell)
  fifo="$d/fifo"; mkfifo "$fifo"
  # shellcheck disable=SC2016 # $1 expands in the child shell.
  start_root "$d" bash -c 'read -r x < "$1"' _ "$fifo"
  st=$(agent_state "$d")
  printf 'x\n' > "$fifo" &
  [ "$st" = dead ] || fail "a pty holding only a shell should read dead, got '$st'"
  pass "orca agent state: a pty holding only a shell is dead"
}

test_stranger_below_root_is_ambiguous() {
  local d st
  d=$(new_dir stranger)
  start_root "$d" "$BIN/mystery" 60
  st=$(agent_state "$d")
  [ "$st" = ambiguous ] \
    || fail "an unrecognized process below the root must be ambiguous, never dead; got '$st'"
  pass "orca agent state: an unrecognized process below the root is ambiguous"
}

test_missing_and_unreadable() {
  local d st
  d=$(new_dir stale)
  : > "$d/stale"
  st=$(agent_state "$d")
  [ "$st" = missing ] || fail "Orca's stale-handle answer should read missing, got '$st'"
  d=$(new_dir unswept)
  printf 'wt::/x@@somewhere-else\n' > "$d/pty"
  printf '4242\n' > "$d/root"
  st=$(agent_state "$d")
  [ "$st" = unreadable ] || fail "a pty Orca's sweep does not name should read unreadable, got '$st'"
  d=$(new_dir failing)
  : > "$d/fail"
  st=$(agent_state "$d")
  [ "$st" = unreadable ] || fail "a failing Orca CLI should read unreadable, got '$st'"
  pass "orca agent state: a stale handle is missing; an unswept pty or failing CLI is unreadable"
}

# An Orca pi task record exactly as fm-spawn writes one.
orca_task_home() {  # <dir> -> echoes home
  local d=$1 home wt
  home="$d/home"; wt="$d/wt"
  mkdir -p "$home/state" "$home/data/t1"
  fm_git_init_commit "$wt" >/dev/null 2>&1
  printf '# brief\n' > "$home/data/t1/brief.md"
  fm_write_meta "$home/state/t1.meta" "window=fm-t1" "endpoint_task_id=t1" \
    "worktree=$wt" "project=$wt" "harness=pi" "kind=ship" "mode=no-mistakes" "yolo=off" \
    "backend=orca" "orca_worktree_id=wt-1" "terminal=term-1"
  printf '%s\n' "$home"
}

run_control() {  # <dir> <home> <args...>
  local d=$1 home=$2
  shift 2
  env PATH="$FAKEBIN:$PATH" FM_FAKE_ORCA_DIR="$d" FM_HOME="$home" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT="${FM_CONTROL_EXIT_WAIT:-6}" \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

test_control_exit_on_orca() {
  local d home out rc
  d=$(new_dir exit)
  home=$(orca_task_home "$d")
  start_root "$d" "$BIN/pi" 60
  out=$(run_control "$d" "$home" t1 exit); rc=$?
  expect_code 0 "$rc" "exit on an Orca pi worker should succeed"$'\n'"$out"
  assert_contains "$out" "stopped t1 harness=pi backend=orca" "exit should report the proven stop"
  assert_contains "$(cat "$d/log")" "terminal send --terminal term-1 --text /quit" \
    "exit should submit pi's exit command to the recorded terminal"
  out=$(run_control "$d" "$home" t1 exit); rc=$?
  expect_code 0 "$rc" "a repeated exit should be idempotent"
  assert_contains "$out" "already-stopped" "a repeated exit should report already-stopped"

  d=$(new_dir exit-stubborn)
  home=$(orca_task_home "$d")
  start_root "$d" "$BIN/pi" 60
  out=$(FM_FAKE_NEVER_DIES=1 FM_CONTROL_EXIT_WAIT=1 run_control "$d" "$home" t1 exit); rc=$?
  [ "$rc" -ne 0 ] || fail "an agent that never stops must not be reported stopped"
  assert_contains "$out" "exit=unconfirmed" "a stubborn agent should be reported unconfirmed"

  out=$(run_control "$d" "$home" t1 relaunch --note x); rc=$?
  [ "$rc" -ne 0 ] || fail "relaunch must stay refused on Orca"
  assert_contains "$out" "in-place relaunch is not proven" "the relaunch refusal should name why"
  pass "fm-control: exit on Orca proves the stop from the pane tree, stays idempotent, and relaunch stays refused"
}

test_harness_below_root_is_alive_despite_sticky_identity
test_shell_only_tree_is_dead
test_stranger_below_root_is_ambiguous
test_missing_and_unreadable
test_control_exit_on_orca
