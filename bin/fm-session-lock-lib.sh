#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
# cursor-agent: CLI binary basename. Cursor Helper / Cursor.app: IDE primary
# (matched on process identity below, not via a loose args substring — Cursor's
# tool wrappers embed prior command text in zsh args and would false-positive).
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|cursor-agent'

# True when $1 (comm) / $2 (args) identify a Cursor IDE primary process.
fm_harness_is_cursor_ide() {
  local comm=$1 args=$2
  case "$comm" in
    'Cursor Helper'*|*'Cursor Helper (Plugin)'*) return 0 ;;
    */MacOS/Cursor|Cursor) return 0 ;;
  esac
  case "$args" in
    /Applications/Cursor.app/Contents/MacOS/Cursor*|*/Cursor.app/Contents/MacOS/Cursor*) return 0 ;;
  esac
  return 1
}

# Walk the current process ancestry (up to 8 hops) and print the first pid whose
# command looks like a verified harness. The harness pid lives as long as the
# session, unlike the transient subshell pid of any one tool call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args base
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    base=$(basename "$comm")
    if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    if fm_harness_is_cursor_ide "$comm" "$args"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name as an argv token /
    # path segment, not as a substring of an unrelated wrapper script.
    case "$comm" in
      *node*|*python*)
        if printf '%s' "$args" | grep -qE '(^|[ /])(claude|codex|opencode|grok|kimi|pi|cursor-agent)([ ]|$)'; then
          echo "$pid"; return 0
        fi
        ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args base
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  base=$(basename "$comm")
  printf '%s' "$base" | grep -qE "$FM_HARNESS_RE" && return 0
  fm_harness_is_cursor_ide "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}
