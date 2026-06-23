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

# shellcheck source=bin/fm-proc.sh
. "$SCRIPT_DIR/fm-proc.sh"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|^pi$'

harness_pid() {
  local pid comm args base
  while IFS="$(printf '\t')" read -r pid comm args; do
    [ -n "$pid" ] || continue
    base=$(basename "$comm")
    if printf '%s' "$base" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its argv.
    case "$base" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
  done <<EOF
$(fm_proc_ancestry "$$")
EOF
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 info comm args
  fm_proc_alive "$pid" || return 1
  info=$(fm_proc_info "$pid") || return 1
  comm=$(printf '%s' "$info" | cut -f1)
  args=$(printf '%s' "$info" | cut -f2-)
  printf '%s %s' "$(basename "$comm")" "$args" | grep -qE "$HARNESS_RE"
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
