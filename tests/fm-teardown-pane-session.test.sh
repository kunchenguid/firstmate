#!/usr/bin/env bash
# Regression test: tmux cleanup reaps the closed pane's own POSIX session.
# tmux kill-window only hangs up the pane pty, so a pane-session member that
# ignores SIGHUP and sits in its own process group used to outlive a completed
# teardown. This drives bin/fm-teardown.sh against a real tmux server on a
# private TMUX_TMPDIR and asserts two such members are gone - one that yields
# to SIGTERM and one that also ignores it - while an identically shaped process
# in a sibling window's session survives.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
REAL_TMUX=$(command -v tmux || true)
SESSION=pane-session-reap
ID=reap-a
LAB=""

lab_tmux() {
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$LAB/tmux" "$REAL_TMUX" "$@"
}

# Kill only a recorded pid that still runs this lab's own child script.
lab_kill_child() {  # <pidfile>
  local pid
  pid=$(cat "$1" 2>/dev/null) || return 0
  ps -p "$pid" -o command= 2>/dev/null | grep -Fq "$LAB/child.py" || return 0
  kill -KILL "$pid" 2>/dev/null || true
}

lab_cleanup() {
  local pidfile
  [ -n "$LAB" ] || return 0
  lab_tmux kill-server 2>/dev/null || true
  for pidfile in "$LAB"/*.pid; do lab_kill_child "$pidfile"; done
  rm -rf "$LAB"
}
trap 'lab_cleanup; fm_test_cleanup' EXIT

write_child() {
  cat > "$LAB/child.py" <<'PY'
import os, signal, sys, time
os.setpgid(0, 0)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
if "termign" in sys.argv[2:]:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
os.chdir("/")
with open(sys.argv[1], "w") as f:
    f.write(str(os.getpid()))
time.sleep(100000)
PY
}

child_cmd() {  # <name> [termign]
  printf "python3 '%s/child.py' '%s/%s.pid' %s &" "$LAB" "$LAB" "$1" "${2:-}"
}

wait_for_pid_file() {  # <name>
  for _ in $(seq 1 100); do
    [ -s "$LAB/$1.pid" ] && return 0
    sleep 0.1
  done
  fail "$1 child never started"
}

pid_alive() {  # <name>
  kill -0 "$(cat "$LAB/$1.pid")" 2>/dev/null
}

wait_for_exit() {  # <name>
  for _ in $(seq 1 50); do
    pid_alive "$1" || return 0
    sleep 0.1
  done
  return 1
}

window_present() {  # <window>
  lab_tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fqx "$1"
}

start_windows() {
  local name
  lab_tmux new-session -d -s "$SESSION" -n keep || fail "cannot start private tmux server"
  lab_tmux new-window -d -t "=$SESSION:" -n "fm-$ID" \
    "$(child_cmd target) $(child_cmd stubborn termign) exec sleep 100000"
  lab_tmux new-window -d -t "=$SESSION:" -n control "$(child_cmd control) exec sleep 100000"
  for name in target stubborn control; do wait_for_pid_file "$name"; done
}

setup_lab() {
  # A short private root keeps the tmux socket path under the platform limit.
  LAB=$(mktemp -d /tmp/fmps.XXXXXX) || fail "cannot create lab root"
  mkdir -p "$LAB/tmux" "$LAB/home/state" "$LAB/home/data" "$LAB/home/config"
  write_child
  start_windows
  fm_write_meta "$LAB/home/state/$ID.meta" \
    "window=$SESSION:fm-$ID" "endpoint_task_id=$ID" \
    "worktree=$LAB/nonexistent-worktree" "project=$LAB/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
}

run_teardown() {
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$LAB/tmux" \
    FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT" "$TEARDOWN" "$ID" --force \
    > "$LAB/teardown.out" 2> "$LAB/teardown.err" \
    || fail "teardown failed: $(cat "$LAB/teardown.err")"
}

assert_reaped() {
  local name
  window_present "fm-$ID" && fail "teardown did not close the recorded window"
  for name in target stubborn; do
    wait_for_exit "$name" \
      || fail "SIGHUP-ignoring own-process-group pane-session member '$name' survived teardown (pid $(cat "$LAB/$name.pid"))"
  done
  grep -Fq "force-killing pane-session process(es) for $ID: $(cat "$LAB/stubborn.pid")" "$LAB/teardown.err" \
    || fail "the SIGTERM-ignoring member was not force-killed: $(cat "$LAB/teardown.err")"
}

assert_sibling_spared() {
  pid_alive control || fail "teardown killed a process in a sibling window's session"
  window_present control || fail "teardown closed the sibling control window"
}

test_tmux_teardown_reaps_hup_ignoring_pane_session_members() {
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "skip - python3 not installed"; return 0; }
  setup_lab
  run_teardown
  assert_reaped
  assert_sibling_spared
  pass "fm-teardown: tmux cleanup reaps the closed pane's session members and spares a sibling window's"
}

test_tmux_teardown_reaps_hup_ignoring_pane_session_members
