#!/usr/bin/env bash
# tests/fm-agent-process-lib.test.sh - tests for fm_process_tree_holds_drive_call
# and fm_backend_herdr_drive_call_alive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agent-process-lib)
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

# Build stand-in binary that stays alive and accepts arbitrary arguments.
STANDIN_BIN="$TMP_ROOT/standin"
cat > "$TMP_ROOT/standin.c" << 'C'
#include <unistd.h>
int main(int argc, char **argv) {
  int i;
  for (i = 0; i < 60; i++) sleep(1);
  return 0;
}
C
gcc -o "$STANDIN_BIN" "$TMP_ROOT/standin.c" 2>/dev/null || cc -o "$STANDIN_BIN" "$TMP_ROOT/standin.c" 2>/dev/null || {
  echo "skip: C compiler required for stand-in binary"
  exit 0
}

test_invalid_root_pid() {
  local out
  ! out=$(fm_process_tree_holds_drive_call "") || fail "empty root-pid must return 1, got '$out'"
  ! out=$(fm_process_tree_holds_drive_call "abc") || fail "alpha root-pid must return 1, got '$out'"
  ! out=$(fm_process_tree_holds_drive_call "-123") || fail "negative root-pid must return 1, got '$out'"
  pass "fm_process_tree_holds_drive_call: rejects invalid root pids"
}

test_axi_subcommands() {
  local sub parent_pid out child_bin
  for sub in run respond sync answer; do
    child_bin="$TMP_ROOT/bin-axi-$sub/axi"
    mkdir -p "$(dirname "$child_bin")"
    ln -sf "$STANDIN_BIN" "$child_bin"
    (
      "$child_bin" "$sub"
    ) &
    parent_pid=$!
    sleep 0.1
    out=$(fm_process_tree_holds_drive_call "$parent_pid") || {
      kill "$parent_pid" 2>/dev/null || true
      pkill -P "$parent_pid" 2>/dev/null || true
      fail "fm_process_tree_holds_drive_call failed for axi $sub"
    }
    kill "$parent_pid" 2>/dev/null || true
    pkill -P "$parent_pid" 2>/dev/null || true
    wait "$parent_pid" 2>/dev/null || true
    case "$out" in
      *[0-9]*\ axi) ;;
      *) fail "expected '<pid> axi' for axi $sub, got: '$out'" ;;
    esac
  done
  pass "fm_process_tree_holds_drive_call: recognizes axi run/respond/sync/answer"
}

test_no_mistakes_subcommands() {
  local nm_bin parent_pid out sub
  nm_bin="$TMP_ROOT/bin-nm/no-mistakes"
  mkdir -p "$(dirname "$nm_bin")"
  ln -sf "$STANDIN_BIN" "$nm_bin"

  for sub in attach rerun; do
    (
      "$nm_bin" "$sub"
    ) &
    parent_pid=$!
    sleep 0.1
    out=$(fm_process_tree_holds_drive_call "$parent_pid") || {
      kill "$parent_pid" 2>/dev/null || true
      pkill -P "$parent_pid" 2>/dev/null || true
      fail "fm_process_tree_holds_drive_call failed for no-mistakes $sub"
    }
    kill "$parent_pid" 2>/dev/null || true
    pkill -P "$parent_pid" 2>/dev/null || true
    wait "$parent_pid" 2>/dev/null || true
    case "$out" in
      *[0-9]*\ no-mistakes) ;;
      *) fail "expected '<pid> no-mistakes' for no-mistakes $sub, got: '$out'" ;;
    esac
  done

  for sub in run respond sync answer; do
    (
      "$nm_bin" axi "$sub"
    ) &
    parent_pid=$!
    sleep 0.1
    out=$(fm_process_tree_holds_drive_call "$parent_pid") || {
      kill "$parent_pid" 2>/dev/null || true
      pkill -P "$parent_pid" 2>/dev/null || true
      fail "fm_process_tree_holds_drive_call failed for no-mistakes axi $sub"
    }
    kill "$parent_pid" 2>/dev/null || true
    pkill -P "$parent_pid" 2>/dev/null || true
    wait "$parent_pid" 2>/dev/null || true
    case "$out" in
      *[0-9]*\ no-mistakes) ;;
      *) fail "expected '<pid> no-mistakes' for no-mistakes axi $sub, got: '$out'" ;;
    esac
  done
  pass "fm_process_tree_holds_drive_call: recognizes no-mistakes attach/rerun/axi"
}

test_generic_process_and_quiet_secs() {
  local worker_bin parent_pid out
  worker_bin="$TMP_ROOT/bin-worker/compile_worker"
  mkdir -p "$(dirname "$worker_bin")"
  ln -sf "$STANDIN_BIN" "$worker_bin"

  (
    "$worker_bin" some_file.c &
    wait
  ) &
  parent_pid=$!
  sleep 0.1

  # With quiet_secs=0, generic process is not matched if quiet_secs is 0?
  # Let's check spec:
  # { [ "$quiet_secs" -gt 0 ] && [ "$etimes" -le "$quiet_secs" ]; } || continue
  # So quiet_secs > 0 is required for generic process liveness probe!
  ! out=$(fm_process_tree_holds_drive_call "$parent_pid" 0) || {
    kill "$parent_pid" 2>/dev/null || true
    pkill -P "$parent_pid" 2>/dev/null || true
    fail "quiet_secs=0 must not match generic non-axi process"
  }

  # With quiet_secs=30, young generic process (etimes ~ 0) matches!
  out=$(fm_process_tree_holds_drive_call "$parent_pid" 30) || {
    kill "$parent_pid" 2>/dev/null || true
    pkill -P "$parent_pid" 2>/dev/null || true
    fail "quiet_secs=30 should match active generic child process"
  }
  kill "$parent_pid" 2>/dev/null || true
  pkill -P "$parent_pid" 2>/dev/null || true
  wait "$parent_pid" 2>/dev/null || true
  case "$out" in
    *[0-9]*\ compile_worker) ;;
    *) fail "expected '<pid> compile_worker', got: '$out'" ;;
  esac
  pass "fm_process_tree_holds_drive_call: recognizes generic active child under quiet_secs window"
}

test_excludes_shell_agent_guard_hook() {
  local guard_bin hook_bin parent_pid out
  guard_bin="$TMP_ROOT/bin-guard/fm-watchdog-guard"
  hook_bin="$TMP_ROOT/bin-hook/fm-pre-hook"
  mkdir -p "$(dirname "$guard_bin")" "$(dirname "$hook_bin")"
  ln -sf "$STANDIN_BIN" "$guard_bin"
  ln -sf "$STANDIN_BIN" "$hook_bin"

  (
    "$guard_bin" &
    "$hook_bin" &
    wait
  ) &
  parent_pid=$!
  sleep 0.1
  ! out=$(fm_process_tree_holds_drive_call "$parent_pid" 60) || {
    kill "$parent_pid" 2>/dev/null || true
    pkill -P "$parent_pid" 2>/dev/null || true
    fail "guard and hook processes must be excluded, got: '$out'"
  }
  kill "$parent_pid" 2>/dev/null || true
  pkill -P "$parent_pid" 2>/dev/null || true
  wait "$parent_pid" 2>/dev/null || true
  pass "fm_process_tree_holds_drive_call: excludes guard and hook processes"
}

test_backend_herdr_drive_call_alive() {
  local fb axi_bin parent_pid out
  # Test invalid target
  ! fm_backend_herdr_drive_call_alive "invalid-target" || fail "invalid target must fail"

  # Test with fake herdr CLI
  fb="$TMP_ROOT/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" << 'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  exit 0
fi
if [ "${1:-}" = pane ] && [ "${2:-}" = process-info ]; then
  pane="w1:p1"
  while [ $# -gt 0 ]; do
    if [ "$1" = --pane ]; then pane="$2"; shift 2; else shift; fi
  done
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[]}}}\n' \
    "$pane" "${HERDR_MOCK_SHELL_PID:-999999}" "${HERDR_MOCK_SHELL_PID:-999999}"
  exit 0
fi
exit 0
SH
  chmod +x "$fb/herdr"
  PATH="$fb:$PATH"
  export PATH

  # Run stand-in axi under shell
  axi_bin="$TMP_ROOT/bin-fake-herdr-axi/axi"
  mkdir -p "$(dirname "$axi_bin")"
  ln -sf "$STANDIN_BIN" "$axi_bin"
  (
    "$axi_bin" run &
    wait
  ) &
  parent_pid=$!
  sleep 0.1

  export HERDR_MOCK_SHELL_PID="$parent_pid"
  out=$(fm_backend_herdr_drive_call_alive "session1:w1:p1") || {
    kill "$parent_pid" 2>/dev/null || true
    pkill -P "$parent_pid" 2>/dev/null || true
    fail "fm_backend_herdr_drive_call_alive should succeed for target with active axi run"
  }
  kill "$parent_pid" 2>/dev/null || true
  pkill -P "$parent_pid" 2>/dev/null || true
  wait "$parent_pid" 2>/dev/null || true
  case "$out" in
    *[0-9]*\ axi) ;;
    *) fail "expected '<pid> axi', got: '$out'" ;;
  esac
  pass "fm_backend_herdr_drive_call_alive: parses herdr process-info and checks process tree"
}

test_invalid_root_pid
test_axi_subcommands
test_no_mistakes_subcommands
test_generic_process_and_quiet_secs
test_excludes_shell_agent_guard_hook
test_backend_herdr_drive_call_alive
