#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness process identity and, when discoverable, the terminal
# endpoint bound to this canonical FM_HOME. The shared lock format and liveness
# rules live in bin/fm-session-lock-lib.sh.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$SCRIPT_DIR/fm-supervisor-target-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
mkdir -p "$STATE"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: unsafe state directory at $STATE" >&2; exit 1; }

write_lock() {
  local pid=$1 start tmp canonical_home backend='' target=''
  start=$(fm_session_lock_process_start_time "$pid") || return 1
  canonical_home=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  if ! target=$(discover_supervisor_target) \
    || ! backend=$(discover_supervisor_backend) \
    || ! fm_session_lock_supervisor_target_owns_pid "$backend" "$target" "$pid"; then
    backend=
    target=
  fi
  tmp=$(mktemp "$STATE/.lock.XXXXXX") || return 1
  {
    printf '%s\n' "$pid"
    printf '%s\n' "$start"
    printf 'home=%s\n' "$canonical_home"
    if [ -n "$backend" ] && [ -n "$target" ]; then
      printf 'backend=%s\n' "$backend"
      printf 'target=%s\n' "$target"
    fi
  } > "$tmp" || return 1
  if [ -L "$LOCK" ] || { [ -e "$LOCK" ] && [ ! -f "$LOCK" ]; }; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$LOCK" || { rm -f "$tmp"; return 1; }
}

harness_pid() {
  local pid=$$ comm args command
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    command="$(basename "$comm") $args"
    if ! fm_session_lock_command_is_app_server "$command" && printf '%s' "$(basename "$comm")" | grep -qE "$FM_SESSION_LOCK_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*)
        if ! fm_session_lock_command_is_app_server "$command" && printf '%s' "$args" | grep -qE "$FM_SESSION_LOCK_HARNESS_RE"; then
          echo "$pid"; return 0
        fi
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(fm_session_lock_pid "$LOCK")
  if fm_session_lock_holder_alive "$LOCK"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(fm_session_lock_pid "$LOCK")
  if [ "$old" != "$me" ] && fm_session_lock_holder_alive "$LOCK"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
write_lock "$me" || { echo "error: cannot record harness process identity" >&2; exit 1; }
echo "lock acquired: harness pid $me"
