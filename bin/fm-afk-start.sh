#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Checks state/.supervise-daemon.lock, and:
#     - prints "afk: daemon already running pid=<pid>", refreshes state/.afk,
#       then exits 0 when that lock is held by a live daemon;
#     - otherwise verifies an injectable supervisor target exists (so away-mode
#       escalations can actually reach firstmate), then sets state/.afk and
#       execs bin/fm-supervise-daemon.sh in the foreground.
#
#   Fail-fast: when firstmate is NOT running inside a tmux or herdr pane and no
#   FM_SUPERVISOR_TARGET override is set, there is no verifiable pane to deliver
#   escalations to (the legacy firstmate:0 guess is a crewmate session, not
#   firstmate's input). Rather than set state/.afk and let the daemon wedge
#   silently overnight, this refuses immediately, attempts to clear any
#   pre-existing state/.afk flag, verifies it is absent before claiming full per-wake
#   supervision, and exits non-zero with a clear message. The same guard, plus
#   the supervisor discovery it shares, lives in bin/fm-supervisor-target-lib.sh.
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
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '' ) ;;
  -h|--help) usage; exit 0 ;;
  * ) echo "usage: $(basename "$0")" >&2; exit 2 ;;
esac

mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# shellcheck source=bin/fm-afk-state-lib.sh
. "$SCRIPT_DIR/fm-afk-state-lib.sh"

# Supervisor-target discovery + the trustworthy-target predicate, shared with
# the daemon so /afk refuses fast on exactly the targets the daemon would.
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"

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
  # A live daemon already verified its own supervisor target at startup, so a
  # re-invocation only refreshes the away flag - never re-checks or resets it.
  afk_enter "$STATE"
  echo "afk: daemon already running pid=$pid"
  exit 0
fi

if fm_pid_alive "$pid" && [ -n "$pid" ]; then
  fm_lock_remove_path "$LOCK" 2>/dev/null || true
fi

# Fail-fast BEFORE setting state/.afk: with no injectable supervisor target,
# entering away mode would only arm a daemon that cannot deliver escalations and
# wedges silently. Refuse loudly and leave the fleet in full per-wake mode.
if ! supervisor_target_is_trustworthy; then
  echo "afk: refusing to enter away mode - firstmate's own pane could not be verified as an escalation target." >&2
  echo "     firstmate is not running inside a tmux or herdr pane and no FM_SUPERVISOR_TARGET override is set, so away-mode escalations would be delivered to the wrong window and silently wedge." >&2
  if afk_flag_present "$STATE"; then
    if afk_clear_flag "$STATE"; then
      echo "     Cleared the pre-existing away flag (state/.afk): the fleet is back in full per-wake supervision instead of deferring to a daemon that cannot start." >&2
    else
      echo "     ERROR: state/.afk still exists after the clear attempt; full per-wake supervision is not guaranteed until that path is removed." >&2
    fi
  fi
  echo "     Run firstmate inside tmux/herdr, or export FM_SUPERVISOR_TARGET (and FM_SUPERVISOR_BACKEND) pointing at firstmate's own pane, then retry." >&2
  exit 1
fi

afk_enter "$STATE"
echo "afk: supervisor target verified"
echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
exec "$DAEMON"
