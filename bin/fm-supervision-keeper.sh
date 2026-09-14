#!/usr/bin/env bash
# Durable home-scoped supervisor for Firstmate's one-cycle watcher.
#
# fm-watch.sh intentionally exits after each wake. This process is the durable
# parent that re-arms it, records crash-loop evidence, and lets launchd restart
# this process if the parent itself dies. It never uses broad process matching.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
WATCH="${FM_KEEPER_WATCH_COMMAND:-$SCRIPT_DIR/fm-watch-arm.sh}"
DAEMON="${FM_KEEPER_DAEMON_COMMAND:-$SCRIPT_DIR/fm-supervise-daemon.sh}"
POLL="${FM_KEEPER_POLL:-5}"
STARTUP_GRACE="${FM_KEEPER_STARTUP_GRACE:-15}"
MAX_BACKOFF="${FM_KEEPER_MAX_BACKOFF:-60}"
MAX_RESTARTS="${FM_KEEPER_MAX_RESTARTS:-0}" # 0 = unlimited in normal mode
RESOURCE_COOLDOWN="${FM_KEEPER_RESOURCE_COOLDOWN:-60}"
LOG="$STATE/.supervision-keeper.log"
LOCK="$STATE/.supervision-keeper.lock"
PIDFILE="$STATE/.supervision-keeper.pid"
BEAT="$STATE/.supervision-keeper-beat"
WATCHER_PID=""
WATCHER_STARTED_AT=0
DAEMON_PID=""
CHILD_OUT=""
CHILD_ERR=""
BACKOFF=1
RESTARTS=0
HEARTBEAT_FAILURES=0
ALLOCATION_FAILURES=0
MAX_RESOURCE_FAILURES="${FM_KEEPER_MAX_RESOURCE_FAILURES:-3}"

case "$MAX_RESOURCE_FAILURES" in
  ''|*[!0-9]*|0) MAX_RESOURCE_FAILURES=3 ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_keeper_log() {
  local line
  mkdir -p "$STATE"
  line=$(printf '[%s] %s' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*")
  if ! printf '%s\n' "$line" >> "$LOG" 2>/dev/null; then
    printf '%s\n' "$line" >&2 2>/dev/null || true
    return 1
  fi
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" | tr -d ' ')" -gt 262144 ]; then
    tail -n 2000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null || true
    rm -f "$LOG.tmp" 2>/dev/null || true
  fi
}

fm_keeper_write_beat() {
  local now
  now=$(date +%s 2>/dev/null) || return 1
  printf '%s\n' "$now" > "$BEAT" 2>/dev/null
}

fm_keeper_resource_snapshot() {
  local current max
  if command -v sysctl >/dev/null 2>&1; then
    current=$(sysctl -n kern.num_files 2>/dev/null || true)
    max=$(sysctl -n kern.maxfiles 2>/dev/null || true)
    case "$current" in ''|*[!0-9]*) printf ' open_files=unknown'; return 0 ;; esac
    case "$max" in ''|*[!0-9]*) printf ' open_files=unknown'; return 0 ;; esac
    printf ' open_files=%s/%s' "$current" "$max"
    return 0
  fi
  printf ' open_files=unknown'
}

fm_keeper_resource_failure() {
  local kind=${1:-resource} delay failures
  case "$kind" in
    heartbeat*) HEARTBEAT_FAILURES=$((HEARTBEAT_FAILURES + 1)); failures=$HEARTBEAT_FAILURES ;;
    *) ALLOCATION_FAILURES=$((ALLOCATION_FAILURES + 1)); failures=$ALLOCATION_FAILURES ;;
  esac
  fm_keeper_log "$kind failed count=$failures$(fm_keeper_resource_snapshot)"
  if [ "$failures" -ge "$MAX_RESOURCE_FAILURES" ]; then
    fm_keeper_log "resource circuit open after $failures failures; exiting for supervisor restart"
    case "$RESOURCE_COOLDOWN" in
      ''|*[!0-9]*) RESOURCE_COOLDOWN=60 ;;
    esac
    [ "$RESOURCE_COOLDOWN" -eq 0 ] || sleep "$RESOURCE_COOLDOWN"
    return 75
  fi
  delay=$(fm_keeper_backoff "$HEARTBEAT_FAILURES")
  sleep "$delay"
  return 0
}

fm_keeper_backoff() {
  local current=${1:-1} next
  next=$((current * 2))
  [ "$next" -gt "$MAX_BACKOFF" ] && next=$MAX_BACKOFF
  printf '%s\n' "$next"
}

fm_keeper_watcher_healthy() {
  local watch_path="${1:-$SCRIPT_DIR/fm-watch.sh}" grace="${2:-${FM_GUARD_GRACE:-300}}"
  fm_watcher_healthy "$STATE" "$watch_path" "$grace" "$FM_HOME"
}

fm_keeper_watcher_needs_restart() {
  local now age
  fm_pid_alive "$WATCHER_PID" || return 1
  now=$(date +%s)
  age=$((now - WATCHER_STARTED_AT))
  [ "$age" -ge "$STARTUP_GRACE" ] || return 1
  ! fm_keeper_watcher_healthy
}

fm_keeper_pid_is_self() {
  local pid=$1 expected actual
  expected=$(cat "$LOCK/pid-identity" 2>/dev/null || true)
  actual=$(fm_pid_identity "$pid" 2>/dev/null || true)
  [ -n "$expected" ] && [ "$expected" = "$actual" ]
}

fm_keeper_acquire() {
  mkdir -p "$STATE"
  if ! fm_lock_try_acquire "$LOCK"; then
    fm_keeper_log "another keeper owns $LOCK; exiting without touching it"
    return 1
  fi
  printf '%s\n' "$$" > "$PIDFILE"
  fm_pid_identity "$$" > "$LOCK/pid-identity" 2>/dev/null || true
  return 0
}

fm_keeper_stop_child() {
  local pid=${1:-}
  if fm_pid_alive "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      fm_pid_alive "$pid" || break
      sleep 0.1
    done
    fm_pid_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
  fi
}

fm_keeper_cleanup() {
  trap - TERM INT HUP EXIT
  fm_keeper_stop_child "$WATCHER_PID"
  fm_keeper_stop_child "$DAEMON_PID"
  [ -n "$CHILD_OUT" ] && rm -f "$CHILD_OUT" 2>/dev/null || true
  [ -n "$CHILD_ERR" ] && rm -f "$CHILD_ERR" 2>/dev/null || true
  if fm_keeper_pid_is_self "$$"; then
    rm -f "$PIDFILE" "$BEAT" 2>/dev/null || true
    fm_lock_release "$LOCK" 2>/dev/null || true
  fi
}

fm_keeper_signal_exit() {
  local signal=${1:-TERM} code=143
  [ "$signal" = INT ] && code=130
  fm_keeper_cleanup
  exit "$code"
}

fm_keeper_start_watcher() {
  [ "${FM_KEEPER_TEST_FAIL_WATCHER_ALLOCATION:-0}" = 1 ] && return 1
  CHILD_OUT=$(mktemp "$STATE/.supervision-keeper-watch.XXXXXX") || return 1
  CHILD_ERR="$CHILD_OUT.err"
  "$WATCH" >"$CHILD_OUT" 2>"$CHILD_ERR" &
  WATCHER_PID=$!
  WATCHER_STARTED_AT=$(date +%s)
  fm_keeper_log "watcher started pid=$WATCHER_PID command=$WATCH"
}

fm_keeper_start_daemon_if_needed() {
  # Away-mode owns the injection daemon. The keeper repairs it when the durable
  # .afk intent is present, but does not create an injection path during normal
  # captain sessions where only the primary watcher is needed.
  [ -e "$STATE/.afk" ] || return 0
  fm_pid_alive "$DAEMON_PID" && return 0
  "$DAEMON" >>"$LOG" 2>&1 &
  DAEMON_PID=$!
  fm_keeper_log "away supervisor started pid=$DAEMON_PID command=$DAEMON"
}

fm_keeper_reap_watcher() {
  local rc reason
  fm_pid_alive "$WATCHER_PID" && return 0
  wait "$WATCHER_PID" 2>/dev/null; rc=$?
  reason=$(cat "$CHILD_OUT" 2>/dev/null || true)
  fm_keeper_log "watcher exited rc=$rc reason=$(printf '%s' "$reason" | tr '\n' ' ')"
  rm -f "$CHILD_OUT" "$CHILD_ERR" 2>/dev/null || true
  CHILD_OUT=""; CHILD_ERR=""; WATCHER_PID=""; WATCHER_STARTED_AT=0
  RESTARTS=$((RESTARTS + 1))
  if [ "${FM_KEEPER_TEST_MODE:-0}" = 1 ] && [ "$MAX_RESTARTS" -gt 0 ] && [ "$RESTARTS" -gt "$MAX_RESTARTS" ]; then
    fm_keeper_log "test mode stopping after $RESTARTS watcher starts"
    return 2
  fi
  fm_keeper_log "restarting watcher after ${BACKOFF}s (restart=$RESTARTS)"
  sleep "$BACKOFF"
  BACKOFF=$(fm_keeper_backoff "$BACKOFF")
  return 0
}

fm_keeper_main() {
  local mode=${1:-run}
  case "$mode" in
    --help|-h)
      echo "usage: $(basename "$0") [--status|--once]"
      echo "  runs a durable watcher keeper; launchd should own the keeper process"
      return 0
      ;;
    --status)
      if [ -f "$PIDFILE" ] && fm_pid_alive "$(cat "$PIDFILE" 2>/dev/null || true)"; then
        echo "keeper: alive pid=$(cat "$PIDFILE") beat_age=$(fm_path_age "$BEAT")s"
        return 0
      fi
      echo "keeper: down"
      return 1
      ;;
    --once) : ;; 
    run) : ;;
    *) echo "usage: $(basename "$0") [--status|--once]" >&2; return 2 ;;
  esac

  fm_keeper_acquire || return 0
  trap 'fm_keeper_signal_exit TERM' TERM
  trap 'fm_keeper_signal_exit INT' INT
  trap 'fm_keeper_signal_exit HUP' HUP
  trap fm_keeper_cleanup EXIT
  fm_keeper_log "keeper started pid=$$ home=$FM_HOME state=$STATE"
  while :; do
    if fm_keeper_write_beat; then
      HEARTBEAT_FAILURES=0
    elif ! fm_keeper_resource_failure "heartbeat write"; then
      return 75
    fi
    if [ -z "$WATCHER_PID" ]; then
      if ! fm_keeper_start_watcher; then
        if ! fm_keeper_resource_failure "watcher allocation"; then
          return 75
        fi
        continue
      fi
      ALLOCATION_FAILURES=0
      BACKOFF=1
    elif ! fm_pid_alive "$WATCHER_PID"; then
      fm_keeper_reap_watcher
      local reap_rc=$?
      [ "$reap_rc" -eq 2 ] && return 0
    elif fm_keeper_watcher_needs_restart; then
      fm_keeper_log "watcher unhealthy; restarting owned child pid=$WATCHER_PID after startup_grace=${STARTUP_GRACE}s"
      fm_keeper_stop_child "$WATCHER_PID"
      fm_keeper_reap_watcher
      local reap_rc=$?
      [ "$reap_rc" -eq 2 ] && return 0
    fi
    fm_keeper_start_daemon_if_needed
    [ "$mode" = --once ] && ! fm_pid_alive "$WATCHER_PID" && continue
    sleep "$POLL"
  done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_keeper_main "${1:-run}"
fi
