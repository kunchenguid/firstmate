#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written. In
# sandboxed Codex tool calls where process inspection is unavailable, it falls
# back to Codex's stable per-thread session id.
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
HARNESS_RE='claude|codex|opencode|grok|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  # Codex exposes this stable session identifier to every tool call. Prefer
  # process ancestry whenever it is readable, but do not make Firstmate's
  # session lock depend on ps permission in a sandboxed Codex session.
  if [ -n "${CODEX_THREAD_ID:-}" ]; then
    printf 'codex-thread:%s\n' "$CODEX_THREAD_ID"
    return 0
  fi
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  case "$pid" in
    codex-thread:*)
      return 0
      ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 0
  printf '%s' "$(basename "$comm") $args" | grep -qE "$HARNESS_RE"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then
    case "$old" in
      "codex-thread:${CODEX_THREAD_ID:-}") echo "lock: held by current Codex session" ;;
      codex-thread:*) echo "lock: held by another or unknown Codex session" ;;
      *) echo "lock: held by live harness pid $old" ;;
    esac
  else
    case "$old" in
      codex-thread:*) echo "lock: stale (Codex session is no longer current)" ;;
      *) echo "lock: stale (pid $old dead or not a harness)" ;;
    esac
  fi
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
case "$me" in
  codex-thread:*) echo "lock acquired: Codex session" ;;
  *) echo "lock acquired: harness pid $me" ;;
esac
