#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry
# or, for detached Codex tool hosts, the current tmux pane's descendants. That
# process lives as long as the firstmate session - unlike the transient subshell
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
HARNESS_RE='claude|codex|opencode|grok|^pi$'

process_is_harness() {
  local pid=$1 comm args
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" ;;
    *) return 1 ;;
  esac
}

descendant_harness_pid() {
  local pane_pid=$1 frontier next parent child
  case "$pane_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac

  frontier=$pane_pid
  for _ in 1 2 3 4 5 6 7 8; do
    next=
    for parent in $frontier; do
      while IFS= read -r child; do
        case "$child" in
          ''|*[!0-9]*) continue ;;
        esac
        if process_is_harness "$child"; then
          echo "$child"
          return 0
        fi
        next="$next $child"
      done < <(pgrep -P "$parent" 2>/dev/null || true)
    done
    [ -n "$next" ] || return 1
    frontier=$next
  done
  return 1
}

tmux_session_pointer_pid() {
  local session=$1 runtime_root runtime_session pointer pointer_session pointer_cwd pointer_pid
  runtime_root=$(tmux show-environment -t "$session" OMX_ROOT 2>/dev/null) || return 1
  runtime_session=$(tmux show-environment -t "$session" OMX_SESSION_ID 2>/dev/null) || return 1
  runtime_root=${runtime_root#OMX_ROOT=}
  runtime_session=${runtime_session#OMX_SESSION_ID=}
  [ -n "$runtime_root" ] && [ -n "$runtime_session" ] || return 1

  pointer=$runtime_root/.omx/state/session.json
  [ -f "$pointer" ] || return 1
  pointer_session=$(sed -nE 's/^[[:space:]]*"session_id":[[:space:]]*"([^"]+)",?$/\1/p' "$pointer" | head -1)
  pointer_cwd=$(sed -nE 's/^[[:space:]]*"cwd":[[:space:]]*"([^"]+)",?$/\1/p' "$pointer" | head -1)
  pointer_pid=$(sed -nE 's/^[[:space:]]*"pid":[[:space:]]*([0-9]+),?$/\1/p' "$pointer" | head -1)
  [ "$pointer_session" = "$runtime_session" ] || return 1
  [ "$pointer_cwd" = "$FM_ROOT" ] || return 1
  case "$pointer_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$pointer_pid"
}

tmux_harness_pid() {
  local pane_pid session
  [ -n "${TMUX:-}" ] || [ -n "${TMUX_PANE:-}" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  command -v pgrep >/dev/null 2>&1 || return 1

  if [ -n "${TMUX_PANE:-}" ]; then
    session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || return 1
    if tmux_session_pointer_pid "$session"; then
      return 0
    fi
    pane_pid=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_pid}' 2>/dev/null) || return 1
    descendant_harness_pid "$pane_pid"
    return
  fi

  # Codex Desktop preserves TMUX but strips TMUX_PANE from tool commands. At
  # session start there must be exactly one attached session rooted in this
  # Firstmate checkout; ambiguity fails closed instead of guessing authority.
  session=$(tmux list-panes -a \
    -F '#{session_name}|#{session_attached}|#{pane_current_path}' 2>/dev/null \
    | awk -F '|' -v root="$FM_ROOT" \
      '$2 + 0 > 0 && $3 == root { seen[$1] = 1 } END { for (name in seen) { count++; only=name } if (count == 1) print only }')
  [ -n "$session" ] || return 1
  if tmux_session_pointer_pid "$session"; then
    return 0
  fi
  while IFS= read -r pane_pid; do
    if descendant_harness_pid "$pane_pid"; then
      return 0
    fi
  done < <(tmux list-panes -t "$session" -F '#{pane_pid}' 2>/dev/null)
  return 1
}

harness_pid() {
  local pid=$$
  for _ in 1 2 3 4 5 6 7 8; do
    if process_is_harness "$pid"; then
      echo "$pid"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  tmux_harness_pid
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  kill -0 "$1" 2>/dev/null || return 1
  process_is_harness "$1"
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
