#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Transfers state/.supervision-owner to afk, sets state/.afk, checks
#   state/.supervise-daemon.lock, and:
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

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_owner_set "$STATE" afk || {
  echo "error: could not record away-mode supervision ownership" >&2
  exit 1
}
date '+%s' > "$STATE/.afk"

_owner=$(fm_daemon_lock_owner "$LOCK" 2>/dev/null || true)
pid=$([ -n "$_owner" ] && cat "$_owner/pid" 2>/dev/null || true)
if fm_daemon_lock_held_by_live_daemon "$LOCK" "$DAEMON"; then
  echo "afk: daemon already running pid=$pid"
  exit 0
fi

if fm_pid_alive "$pid" && [ -n "$pid" ]; then
  fm_lock_remove_path "$LOCK" 2>/dev/null || true
fi

echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
exec "$DAEMON"
