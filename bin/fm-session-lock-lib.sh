#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness identity holds this home's session
# lock, and does the current process descend from or match that identity?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Print Codex's thread identity when API-hosted Codex hides the harness process
# ancestry that process-backed adapters expose.
fm_codex_thread_identity() {
  [ -n "${CODEX_THREAD_ID:-}" ] || return 1
  printf 'codex-thread:%s\n' "$CODEX_THREAD_ID"
}

# Walk the current process ancestry (up to 16 hops) and print a harness identity.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). Process-backed adapters
# print a harness pid, which lives as long as the session, unlike the transient
# subshell pid of any one tool call. API-hosted Codex falls back to
# `codex-thread:<thread-id>` when no process ancestry match is visible.
fm_harness_ancestry_pid() {
  local pid=$$ comm args best='' bc extending=0 hit=0 is_claude=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    bc=$(basename "$comm")
    hit=0; is_claude=0
    if printf '%s' "$bc" | grep -qE "$FM_HARNESS_RE"; then
      hit=1
      case "$bc" in *claude*) is_claude=1 ;; esac
    else
      # Bare interpreter (e.g. node): match the harness name in its script path.
      case "$comm" in
        *node*|*python*)
          if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
            hit=1
            case "$args" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
    if [ "$hit" -eq 1 ]; then
      best="$pid"
      if [ "$is_claude" -eq 1 ]; then
        extending=1
      else
        break
      fi
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  fm_codex_thread_identity || return 1
}

# True if $1 is a live process or current Codex thread that looks like a
# verified harness identity.
fm_harness_pid_alive() {
  local pid=$1 comm args
  case "$pid" in
    codex-thread:*)
      [ -n "${CODEX_THREAD_ID:-}" ] && [ "$pid" = "codex-thread:$CODEX_THREAD_ID" ]
      return
      ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds a session lock whose identity belongs to the
# current process: this script runs inside the session that owns the home's
# fleet lock. A missing lock, a lock held by another live harness, or an
# identity that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_id my_id
  lock_id=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_id" in
    codex-thread:*) fm_harness_pid_alive "$lock_id"; return ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  my_id=$(fm_harness_ancestry_pid) || return 1
  [ "$my_id" = "$lock_id" ]
}
