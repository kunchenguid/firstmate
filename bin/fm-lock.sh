#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; always exits 1 on any failure. On failure
#                              it also prints a stable machine-readable line
#                              FM_LOCK_REASON=<reason> to stderr, alongside the
#                              human-readable error. The three reasons are:
#                                lock-held             another live session holds it
#                                ps-unavailable        a ps call failed or was denied
#                                                      (e.g. a Codex sandbox), so this
#                                                      session cannot identify its harness
#                                harness-detect-failed ps worked but no harness was
#                                                      found while walking the ancestry
#                              Callers must NOT treat ps-unavailable/harness-detect-failed
#                              as another session holding the lock.
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

# harness_pid() reports through globals rather than stdout so its failure
# classification survives: a caller must NOT wrap it in $(...) (a command
# substitution subshell would discard HARNESS_FAIL_REASON). On success it sets
# HARNESS_PID; on failure it sets HARNESS_FAIL_REASON so the caller can tell a
# denied ps (ps-unavailable) apart from a clean ancestry walk that simply found
# no harness (harness-detect-failed). These fail for entirely different reasons
# and must not be conflated with another session holding the lock.
HARNESS_PID=""
HARNESS_FAIL_REASON=""

harness_pid() {
  local pid=$$ comm args ppid
  HARNESS_PID=""
  HARNESS_FAIL_REASON=""
  for _ in 1 2 3 4 5 6 7 8; do
    if ! comm=$(ps -o comm= -p "$pid" 2>/dev/null); then
      HARNESS_FAIL_REASON=ps-unavailable
      return 1
    fi
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      HARNESS_PID=$pid; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { HARNESS_PID=$pid; return 0; } ;;
    esac
    if ! ppid=$(ps -o ppid= -p "$pid" 2>/dev/null); then
      HARNESS_FAIL_REASON=ps-unavailable
      return 1
    fi
    pid=$(printf '%s' "$ppid" | tr -d ' ')
    if [ -z "$pid" ] || [ "$pid" -le 1 ]; then
      HARNESS_FAIL_REASON=harness-detect-failed
      return 1
    fi
  done
  HARNESS_FAIL_REASON=harness-detect-failed
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

# Call harness_pid directly, never as $(harness_pid): its result travels through
# HARNESS_PID/HARNESS_FAIL_REASON, which a command-substitution subshell would
# strand.
if harness_pid; then
  me=$HARNESS_PID
else
  case "$HARNESS_FAIL_REASON" in
    ps-unavailable)
      echo "FM_LOCK_REASON=ps-unavailable" >&2
      echo "error: cannot inspect processes to identify this session's harness (ps failed or was denied)" >&2
      ;;
    *)
      echo "FM_LOCK_REASON=harness-detect-failed" >&2
      echo "error: cannot locate harness process in ancestry" >&2
      ;;
  esac
  exit 1
fi
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "FM_LOCK_REASON=lock-held" >&2
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
