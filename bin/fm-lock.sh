#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# The harness PID is resolved, in order: an explicit FM_HARNESS_PID override
# (liveness-verified via kill -0), an ancestry walk via ps, or - when ps cannot
# see the shell's own ancestry but a verified harness env marker is present
# (e.g. Claude Code's sandboxed Bash tool, which reports "no such process" for
# its own $$) - the shell's own $$, trusted via the marker since ps cannot
# confirm it. Liveness is checked with kill -0, which works where ps is blind.
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
# ^pi$ matches the bare basename "pi" exactly; the unanchored alternatives
# match claude/codex/opencode/grok as substrings of a basename (e.g. codex-cli).
HARNESS_RE='claude|codex|opencode|grok|^pi$'

# True if $1 is a positive integer naming a live process. Uses kill -0, not ps,
# so it works where ps cannot see the process (e.g. Claude Code's Bash tool,
# whose sandbox reports "no such process" for its own $$).
live_pid() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ] 2>/dev/null || return 1
  kill -0 "$1" 2>/dev/null
}

# True if a verified harness environment marker is present. Mirrors the
# env-marker layer of bin/fm-harness.sh's detect_own; extend both in lockstep
# when a new adapter gains a marker.
harness_env_marker() {
  [ "${CLAUDECODE:-}" = "1" ] && return 0
  [ "${PI_CODING_AGENT:-}" = "true" ] && return 0
  [ "${GROK_AGENT:-}" = "1" ] && return 0
  return 1
}

harness_pid() {
  local pid=$$ comm args
  # Escape hatch for a harness whose bash sandbox cannot traverse its own
  # ancestry via ps (Claude Code's Bash tool reports "no such process" for $$
  # itself): the operator or a harness adapter may set FM_HARNESS_PID to a live
  # process id trusted as the session's harness. Verified only by liveness; the
  # setter vouches for the identity ps cannot confirm.
  if [ -n "${FM_HARNESS_PID:-}" ] && live_pid "$FM_HARNESS_PID"; then
    echo "$FM_HARNESS_PID"; return 0
  fi
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
  # Fallback when ps cannot see our own ancestry but a verified harness env
  # marker confirms we run inside a harness anyway. bash's $$ is the long-lived
  # main shell (durable across tool calls for a persistent-shell harness; for a
  # per-command shell it is transient, but the next acquire re-verifies liveness
  # via kill -0 and re-acquires harmlessly). This unblocks a ps-blind session
  # that would otherwise leave session-start stuck in read-only mode.
  if harness_env_marker && live_pid "$$"; then
    echo "$$"; return 0
  fi
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm base args
  live_pid "$pid" || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || {
    # ps cannot inspect the holder (e.g. a ps-blind sandbox session that wrote
    # its own $$): kill -0 says it is live, so fail safe - treat an
    # uninspectable live holder as held rather than let a second session steal
    # the lock based on our own blindness.
    return 0
  }
  # Match the basename exactly as harness_pid does, so a pi-held lock (basename
  # "pi") is recognized. The prior "<basename> <args>" concatenation grepped
  # with ^pi$ against "pi pi" and never matched, so a second pi session could
  # clobber a live one.
  base=$(basename "$comm")
  printf '%s' "$base" | grep -qE "$HARNESS_RE" && return 0
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$HARNESS_RE" && return 0 ;;
  esac
  return 1
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
