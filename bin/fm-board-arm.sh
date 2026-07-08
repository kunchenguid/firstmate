#!/usr/bin/env bash
# Safe, home-scoped start/verify/restart of the board-automation daemon
# (bin/fm-board-daemon.sh), modelled on bin/fm-watch-arm.sh.
#
# Unlike the watcher (which blocks until a wake and exits, so its arm WAITS on
# it), the board daemon is a persistent 24/7 poll loop. So this arm launches it
# DETACHED (nohup + disown, under nice -n 19) so it survives this call, then
# VERIFIES a genuinely live daemon before returning - it confirms the singleton
# lock names a live process whose identity matches AND the liveness beacon
# (state/.board-daemon-beat) is fresh within FM_GUARD_GRACE. It prints exactly
# one honest status line:
#   board-daemon: started pid=<N> (beacon fresh)
#   board-daemon: healthy pid=<N> (beacon <age>s)     - one was already live+fresh
#   board-daemon: FAILED - no live daemon with a fresh beacon   (exit non-zero)
#
# --restart stops ONLY this FM_HOME's daemon (the pid recorded in this home's
# state/.board-daemon.lock) and starts a fresh one. It signals exactly that pid,
# so it can never touch another home's daemon. NEVER `pkill -f
# bin/fm-board-daemon.sh`: that matches every home's daemon (secondmate homes run
# the same script) and would kill siblings.
#
# Note: arming does not by itself make the daemon act. The daemon idles while the
# kill switch state/.board-daemon.off is present; remove it to enable auto-spawn.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DAEMON="$SCRIPT_DIR/fm-board-daemon.sh"
LOCK="$STATE/.board-daemon.lock"
BEAT="$STATE/.board-daemon-beat"
LOG="$STATE/.board-daemon.log"
GRACE=${FM_GUARD_GRACE:-300}
CONFIRM_TIMEOUT=${FM_BOARD_ARM_CONFIRM_TIMEOUT:-15}

# A daemon is "healthy" iff the lock names a live process that is genuinely THIS
# home's daemon (identity match guards a recycled pid) AND the beacon is fresh.
HEALTHY_PID=
lock_matches_pid() {   # <pid>
  local pid=$1 lock_home lock_path lock_identity current_identity
  lock_home=$(cat "$LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$LOCK/daemon-path" 2>/dev/null || true)
  lock_identity=$(cat "$LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 1
  [ "$lock_path" = "$DAEMON" ] || return 1
  [ -n "$lock_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid") || return 1
  [ "$current_identity" = "$lock_identity" ]
}

healthy_daemon() {
  local pid age
  HEALTHY_PID=
  pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  lock_matches_pid "$pid" || return 1
  age=$(fm_path_age "$BEAT")
  [ "$age" -lt "$GRACE" ] || return 1
  HEALTHY_PID=$pid
}

report_healthy() {
  local age; age=$(fm_path_age "$BEAT")
  echo "board-daemon: healthy pid=$HEALTHY_PID (beacon ${age}s)"
}

clear_stale_recorded_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$LOCK/daemon-path" 2>/dev/null || true)
  lock_identity=$(cat "$LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$DAEMON" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_lock_remove_path "$LOCK" || true
}

mode=arm
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --restart) mode=restart ;;
  *) echo "usage: $(basename "$0") [--restart]" >&2; exit 2 ;;
esac

if [ "$mode" = restart ]; then
  lock_pid=$(cat "$LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if lock_matches_pid "$lock_pid"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do sleep 0.1; i=$((i + 1)); done
    else
      clear_stale_recorded_lock
    fi
  fi
fi

if [ "$mode" = arm ] && healthy_daemon; then
  report_healthy
  exit 0
fi

# Launch DETACHED so the daemon outlives this arm call. nohup + disown keeps it
# running after we exit; nice -n 19 backstops the daemon's own self-renice.
mkdir -p "$STATE"
nohup nice -n 19 "$DAEMON" >> "$LOG" 2>&1 &
child=$!
disown "$child" 2>/dev/null || true

deadline=$(( $(date +%s) + CONFIRM_TIMEOUT ))
while :; do
  if healthy_daemon; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      echo "board-daemon: started pid=$child (beacon fresh)"
    else
      # Another daemon holds the singleton (startup race); our child stood down.
      report_healthy
    fi
    exit 0
  fi
  # If the child died without becoming healthy, another live daemon may still
  # hold the lock; healthy_daemon above would have caught it. Give up on timeout.
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.3
done

echo "board-daemon: FAILED - no live daemon with a fresh beacon"
exit 1
