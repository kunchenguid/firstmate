#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Match harness processes the same way fm-harness.sh walks ancestry: comm basename
# first, then argv. cursor-agent often runs as comm=MainThread with cursor-agent in
# args, so comm-only regex matching is not enough.
fm_lock_process_is_harness() {
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  case "$(basename "$comm")" in
    *cursor-agent*) return 0 ;;
    *claude*) return 0 ;;
    *codex*) return 0 ;;
    *opencode*) return 0 ;;
    *grok*) return 0 ;;
    pi) return 0 ;;
  esac
  case "$args" in
    *cursor-agent*) return 0 ;;
    *claude*) return 0 ;;
    *codex*) return 0 ;;
    *opencode*) return 0 ;;
    *grok*) return 0 ;;
    *" pi "*|*/pi) return 0 ;;
  esac
  return 1
}

harness_pid() {
  local pid=$$
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if fm_lock_process_is_harness "$pid"; then
      echo "$pid"; return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1
  kill -0 "$pid" 2>/dev/null || return 1
  fm_lock_process_is_harness "$pid"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
