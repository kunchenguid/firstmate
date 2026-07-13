#!/usr/bin/env bash
# bin/fm-supervise-orca.sh - keep the orca terminal daemon alive.
#
# The orca GUI process is a single-instance AppImage; on Linux without a
# desktop session it can die (X server disconnect, single-instance lock left
# by a crashed peer, AppImage FUSE unmount). The runtime state then reads
# stale_bootstrap and the orca backend refuses every spawn.
#
# This supervisor polls the daemon via bin/fmod info on a bounded cadence.
# On any failure it reaps the stale socket + pid file, kills any leftover
# orca-ide / orca processes from this user, and relaunches the AppImage
# under setsid so the new instance is its own session leader.
#
# Usage: fm-supervise-orca.sh [start|stop|status|once|--follow]
#   start   background this supervisor (writes pid to state/.orca-supervisor.pid)
#   stop    kill the running supervisor (idempotent)
#   status  print supervisor liveness and daemon reachability
#   once    one health check, exit 0 if daemon healthy, 1 otherwise (no relaunch)
#   --follow  foreground loop (for harness-tracked background)
#
# Env:
#   FM_ORCA_CHECK_INTERVAL  seconds between polls (default 30)
#   FM_ORCA_BIN             path to the orca binary (default: which orca)
#   FM_ORCA_FMOD            path to bin/fmod (default: bin/fmod next to this script)
#   FM_ORCA_RUNTIME_FILE    runtime state file to clear on stale (default
#                           ${XDG_CONFIG_HOME:-~/.config}/orca/orca-runtime.json)
#   FM_ORCA_SOCKET_DIR      daemon socket dir to clear on stale (default
#                           ${XDG_CONFIG_HOME:-~/.config}/orca/daemon)
#
# Exit codes: 0 healthy / relaunch succeeded; 1 supervisor failed to start;
# 2 daemon unhealthy AND relaunch failed; 3 already supervised.
#
# Why this lives here and not in fm-watch.sh: the watcher is the per-task
# supervision loop; this is the per-RUNTIME loop. They have different cadences,
# different escalation rules, and different restart semantics. Keeping them
# separate means a flaky orca daemon never widens into per-task noise.

set -u

SCRIPT_DIR=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PIDFILE="$STATE/.orca-supervisor.pid"
PIDIDENTITY="$PIDFILE.identity"

CHECK_INTERVAL=${FM_ORCA_CHECK_INTERVAL:-30}
ORCA_BIN=${FM_ORCA_BIN:-$(command -v orca 2>/dev/null || true)}
FMOD=${FM_ORCA_FMOD:-"$SCRIPT_DIR/fmod"}
ORCA_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/orca"
RUNTIME_FILE=${FM_ORCA_RUNTIME_FILE:-"$ORCA_CONFIG_DIR/orca-runtime.json"}
SOCKET_DIR=${FM_ORCA_SOCKET_DIR:-"$ORCA_CONFIG_DIR/daemon"}
SINGLE_INSTANCE_LOCK="$ORCA_CONFIG_DIR/single-instance.lock"

log() { printf '[orca-supervisor] %s\n' "$*"; }

fmod_info_reachable() {
  timeout 5 "$FMOD" info 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("daemon_reachable") and d.get("daemon_pong",{}).get("pong") else 1)' \
    2>/dev/null
}

reap_orca_user_procs() {
  # Kill any orca / orca-ide / orca.AppImage processes owned by the current user.
  # pkill -f matches the AppImage mountpoint names; -x matches the bare process.
  pkill -TERM -u "$USER" -f 'orca.AppImage' 2>/dev/null || true
  pkill -KILL -u "$USER" -f 'orca.AppImage' 2>/dev/null || true
  pkill -TERM -u "$USER" -x 'orca-ide' 2>/dev/null || true
  pkill -KILL -u "$USER" -x 'orca-ide' 2>/dev/null || true
  sleep 1
}

reap_stale_state() {
  # The single-instance lock and the per-version daemon socket+token+pid are
  # the durable state a fresh orca daemon will refuse to reuse if it sees them
  # mid-handshake. Clear them so the relaunch starts on a clean slate.
  rm -f "$RUNTIME_FILE" 2>/dev/null || true
  rm -f "$SINGLE_INSTANCE_LOCK" 2>/dev/null || true
  if [ -d "$SOCKET_DIR" ]; then
    find "$SOCKET_DIR" -maxdepth 1 -type f \( -name '*.sock' -o -name '*.pid' -o -name '*.token' \) -delete 2>/dev/null || true
  fi
  # Mount points left by a dead AppImage FUSE mount: best-effort cleanup.
  for mp in /tmp/.mount_orca.*; do
    [ -d "$mp" ] || continue
    fusermount -u "$mp" 2>/dev/null || umount "$mp" 2>/dev/null || true
  done
}

relaunch_orca() {
  [ -n "$ORCA_BIN" ] || { log "error: no orca binary on PATH"; return 1; }
  [ -x "$(command -v setsid)" ] || { log "error: setsid missing (install util-linux)"; return 1; }
  # setsid --fork detaches into its own session so the AppImage survives our
  # parent shell exit; stdin/stdout/stderr all go to /dev/null.
  setsid --fork "$ORCA_BIN" </dev/null >/tmp/orca-supervisor.log 2>&1 || {
    log "error: setsid --fork orca failed"; return 1; }
  # Give the daemon time to bind the unix socket before we return success.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if fmod_info_reachable; then
      log "relaunched, daemon reachable after ${i}s"
      return 0
    fi
    sleep 1
  done
  log "error: relaunched but daemon still unreachable after 10s"
  return 1
}

ensure_healthy() {
  if fmod_info_reachable; then
    return 0
  fi
  log "daemon unreachable, reaping + relaunching"
  reap_orca_user_procs
  reap_stale_state
  relaunch_orca
}

already_supervised() {
  [ -f "$PIDFILE" ] || return 1
  local pid current_identity stored_identity
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  current_identity=$(supervisor_pid_identity "$pid") || return 1
  stored_identity=$(cat "$PIDIDENTITY" 2>/dev/null || true)
  [ -n "$stored_identity" ] || return 1
  [ "$current_identity" = "$stored_identity" ]
}

supervisor_pid_identity() {
  local pid=$1 command identity
  identity=$(ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$identity" ] || return 1
  command=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
  case "$command" in
    *fm-supervise-orca.sh*"--follow"*) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$identity" | sed 's/^[[:space:]]*//'
}

clear_pidfile() {
  rm -f "$PIDFILE" "$PIDIDENTITY"
}

status() {
  if already_supervised; then
    echo "supervisor: live pid=$(cat "$PIDFILE")"
  else
    echo "supervisor: not running"
  fi
  if fmod_info_reachable; then
    echo "daemon:     reachable"
    exit 0
  else
    echo "daemon:     UNREACHABLE"
    exit 1
  fi
}

stop() {
  if ! already_supervised; then
    clear_pidfile
    echo "supervisor: not running"
    exit 0
  fi
  local pid
  pid=$(cat "$PIDFILE")
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  kill -KILL "$pid" 2>/dev/null || true
  clear_pidfile
  echo "supervisor: stopped (pid=$pid)"
}

case "${1:-status}" in
  once)
    fmod_info_reachable
    ;;
  start)
    mkdir -p "$STATE" 2>/dev/null || true
    if already_supervised; then
      echo "supervisor: already live pid=$(cat "$PIDFILE")"
      exit 3
    fi
    # Make sure the daemon is healthy before we fork ourselves; otherwise
    # the supervisor's first poll would just report what we already saw.
    ensure_healthy || exit 2
    clear_pidfile
    setsid --fork "$0" --follow </dev/null >/tmp/fm-supervise-orca.log 2>&1 &
    disown
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if already_supervised; then
        echo "supervisor: started pid=$(cat "$PIDFILE")"
        exit 0
      fi
      sleep 0.1
    done
    echo "supervisor: FAILED to confirm pid"
    exit 1
    ;;
  --follow)
    # Foreground loop: written for harness-tracked background invocation.
    # Trap signals so a SIGTERM (from `stop` or session tear-down) exits
    # cleanly without leaving a stale pidfile behind.
    clear_pidfile
    supervisor_pid_identity "$$" > "$PIDIDENTITY" 2>/dev/null || true
    echo $$ > "$PIDFILE"
    trap 'rm -f "$PIDFILE" "$PIDIDENTITY"; exit 0' TERM INT
    log "loop entered, interval=${CHECK_INTERVAL}s, bin=$ORCA_BIN"
    while :; do
      ensure_healthy || log "warning: ensure_healthy returned non-zero"
      sleep "$CHECK_INTERVAL" &
      wait $!
    done
    ;;
  stop) stop ;;
  status) status ;;
  *)
    echo "usage: $0 [start|stop|status|once|--follow]" >&2
    exit 64
    ;;
esac
