#!/usr/bin/env bash
# Regression test: tmux cleanup reaps the closed pane's own POSIX session.
# tmux kill-window only hangs up the pane pty, so a pane-session member that
# ignores SIGHUP and sits in its own process group used to outlive a completed
# teardown. This drives bin/fm-teardown.sh against a real tmux server on a
# private TMUX_TMPDIR and asserts that member is gone while an identically
# shaped process in a sibling window's session survives.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
REAL_TMUX=$(command -v tmux || true)
SESSION=pane-session-reap
LAB=""

lab_cleanup() {
  [ -n "$LAB" ] || return 0
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$LAB/tmux" "$REAL_TMUX" kill-server 2>/dev/null || true
  local pidfile
  for pidfile in "$LAB"/*.pid; do
    [ -s "$pidfile" ] && kill -KILL "$(cat "$pidfile")" 2>/dev/null
  done
  rm -rf "$LAB"
}
trap 'lab_cleanup; fm_test_cleanup' EXIT

lab_tmux() {
  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$LAB/tmux" "$REAL_TMUX" "$@"
}

# A window whose pane shell starts a child that leaves the foreground process
# group, ignores SIGHUP, and moves its cwd out of any task copy, then stays.
start_window_child() {  # <window> <name>
  local window=$1 name=$2
  lab_tmux new-window -d -t "=$SESSION:" -n "$window" \
    "python3 '$LAB/child.py' '$LAB/$name.pid' & exec sleep 100000"
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

test_tmux_teardown_reaps_hup_ignoring_pane_session_member() {
  local id=reap-a home
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  command -v python3 >/dev/null 2>&1 || { echo "skip - python3 not installed"; return 0; }
  # A short private root keeps the tmux socket path under the platform limit.
  LAB=$(mktemp -d /tmp/fmps.XXXXXX) || fail "cannot create lab root"
  mkdir -p "$LAB/tmux" "$LAB/home/state" "$LAB/home/data" "$LAB/home/config"
  cat > "$LAB/child.py" <<'PY'
import os, signal, sys, time
os.setpgid(0, 0)
signal.signal(signal.SIGHUP, signal.SIG_IGN)
os.chdir("/")
with open(sys.argv[1], "w") as f:
    f.write(str(os.getpid()))
time.sleep(100000)
PY
  lab_tmux new-session -d -s "$SESSION" -n keep || fail "cannot start private tmux server"
  start_window_child "fm-$id" target
  start_window_child control control
  wait_for_pid_file target
  wait_for_pid_file control
  home="$LAB/home"
  fm_write_meta "$home/state/$id.meta" \
    "window=$SESSION:fm-$id" "endpoint_task_id=$id" \
    "worktree=$LAB/nonexistent-worktree" "project=$LAB/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"

  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$LAB/tmux" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$TEARDOWN" "$id" --force \
    > "$LAB/teardown.out" 2> "$LAB/teardown.err" \
    || fail "teardown failed: $(cat "$LAB/teardown.err")"

  lab_tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fqx "fm-$id" \
    && fail "teardown did not close the recorded window"
  wait_for_exit target \
    || fail "SIGHUP-ignoring own-process-group pane-session member survived teardown (pid $(cat "$LAB/target.pid"))"
  pid_alive control || fail "teardown killed a process in a sibling window's session"
  lab_tmux list-windows -t "=$SESSION" -F '#{window_name}' | grep -Fqx control \
    || fail "teardown closed the sibling control window"
  pass "fm-teardown: tmux cleanup reaps the closed pane's session members and spares a sibling window's"
}

test_tmux_teardown_reaps_hup_ignoring_pane_session_member
