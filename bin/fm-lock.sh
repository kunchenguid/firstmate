#!/usr/bin/env bash
# Acquire, inspect, or manually release the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh                   acquire; exit 1 if another live session holds it
#        fm-lock.sh status            print holder and liveness; always exits 0
#        fm-lock.sh release [--force] release this session or a stale lock; force takes any lock
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"

usage() {
  cat <<'USAGE'
Usage: fm-lock.sh
       fm-lock.sh status
       fm-lock.sh release [--force]
USAGE
}

command=acquire
force=0
case $# in
  0) ;;
  1)
    case "$1" in
      status) command=status ;;
      release) command=release ;;
      *)
        echo "error: unknown fm-lock command '$1'" >&2
        usage >&2
        exit 2
        ;;
    esac
    ;;
  2)
    if [ "$1" = "release" ] && [ "$2" = "--force" ]; then
      command=release
      force=1
    else
      echo "error: invalid fm-lock arguments: $*" >&2
      usage >&2
      exit 2
    fi
    ;;
  *)
    echo "error: invalid fm-lock arguments: $*" >&2
    usage >&2
    exit 2
    ;;
esac

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

process_inspection_available() {
  ps -o comm= -p "$$" >/dev/null 2>&1 && kill -0 "$$" 2>/dev/null
}

process_inspection_failure() {
  if [ -n "${CODEX_SANDBOX:-}" ]; then
    printf '%s\n' "process inspection is blocked by this harness's shell sandbox (CODEX_SANDBOX=$CODEX_SANDBOX); liveness cannot be evaluated from this session; a sandboxed session cannot manage the fleet - relaunch with codex --dangerously-bypass-approvals-and-sandbox"
  else
    printf '%s\n' "process inspection is blocked by this harness's shell sandbox; liveness cannot be evaluated from this session; a sandboxed session cannot manage the fleet - relaunch the harness without its shell sandbox (for codex: codex --dangerously-bypass-approvals-and-sandbox)"
  fi
}

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
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
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

if [ "$command" = "status" ]; then
  if ! process_inspection_available; then
    printf 'lock: %s\n' "$(process_inspection_failure)"
    exit 0
  fi
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

if [ "$command" = "release" ]; then
  if [ "$force" -ne 1 ] && ! process_inspection_available; then
    printf 'error: %s\n' "$(process_inspection_failure)" >&2
    exit 1
  fi
  if [ ! -f "$LOCK" ]; then
    echo "lock already free"
    exit 0
  fi
  old=$(cat "$LOCK")
  if [ "$force" -eq 1 ]; then
    rm -f "$LOCK"
    echo "WARNING: forced session lock release; took lock from pid $old" >&2
    exit 0
  fi
  me=$(harness_pid 2>/dev/null || true)
  if [ -n "$me" ] && [ "$old" = "$me" ]; then
    rm -f "$LOCK"
    echo "lock released: harness pid $old"
    exit 0
  fi
  if ! holder_alive "$old"; then
    rm -f "$LOCK"
    echo "stale lock cleared: pid $old dead or not a harness"
    exit 0
  fi
  echo "error: session lock held by different live harness pid $old; use 'fm-lock.sh release --force' to take it" >&2
  exit 1
fi

if ! process_inspection_available; then
  printf 'error: %s\n' "$(process_inspection_failure)" >&2
  exit 1
fi
mkdir -p "$STATE"
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
