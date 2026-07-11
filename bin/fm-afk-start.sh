#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Sets state/.afk, checks state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>" then exits 0 when that
#       lock is held by a live daemon;
#     - otherwise execs bin/fm-supervise-daemon.sh in the foreground.
#
# Run this command as its own tracked background terminal/session.
# Do not wrap it in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background command stays
# attached to the harness and has a real lifecycle.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.supervise-daemon.lock"
DAEMON="$SCRIPT_DIR/fm-supervise-daemon.sh"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '' ) ;;
  -h|--help) usage; exit 0 ;;
  * ) echo "usage: $(basename "$0")" >&2; exit 2 ;;
esac

mkdir -p "$STATE"
date '+%s' > "$STATE/.afk"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

daemon_lock_owner() {
  local owner
  if [ -L "$LOCK" ]; then
    owner=$(readlink "$LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$LOCK" ] || return 1
  printf '%s\n' "$LOCK"
}

daemon_pid_matches() {
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$DAEMON"*|*"fm-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

daemon_lock_pid() {
  local owner
  owner=$(daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

daemon_lock_held_by_live_daemon() {
  local owner pid
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  daemon_pid_matches "$pid" "$owner"
}

pid=$(daemon_lock_pid 2>/dev/null || true)
if daemon_lock_held_by_live_daemon; then
  echo "afk: daemon already running pid=$pid"
  exit 0
fi

if fm_pid_alive "$pid" && [ -n "$pid" ]; then
  fm_lock_remove_path "$LOCK" 2>/dev/null || true
fi

echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
exec "$DAEMON"
