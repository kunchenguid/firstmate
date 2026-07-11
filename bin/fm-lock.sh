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

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|(^|/| )omp( |$)|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "${comm##*/}" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (node/python/bun): match the harness name in its script path/args.
    case "$comm" in
      *node*|*python*|*bun*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "${comm##*/} $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
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
