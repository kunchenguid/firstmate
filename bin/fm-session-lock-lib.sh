#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake; and the watcher core
# (bin/fm-watch.sh, bin/fm-watch-arm.sh) uses fm_session_owner_fence below so
# supervision can never be started, retained, or attached by a process from a
# session that no longer owns the home.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Walk the current process ancestry (up to 16 hops) and print a harness pid.
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
# session that launched a test as its own subprocess). The harness pid lives
# as long as the session, unlike the transient subshell pid of any one tool
# call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args best='' bc extending=0 hit=0 is_claude=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    bc=$(basename -- "$comm")
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
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename -- "$comm")" | grep -qE "$FM_HARNESS_RE"; then
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

# Memoized-per-process harness-ancestor resolution. The ancestry walk shells out
# to ps several times, and the owner fence below runs once per watcher cycle, so
# resolve the harness pid and its stable process identity once and reuse both.
# Call this in the CURRENT shell (never inside a command substitution, which
# would discard the memo) and read FM_SESSION_SELF_HARNESS_PID and
# FM_SESSION_SELF_HARNESS_IDENTITY after it returns; an unresolvable ancestry
# leaves both empty.
FM_SESSION_SELF_HARNESS_PID=
FM_SESSION_SELF_HARNESS_IDENTITY=
FM_SESSION_SELF_HARNESS_RESOLVED=0
fm_session_process_identity() {
  local pid=$1 out
  if [ "$(type -t fm_pid_identity 2>/dev/null)" = function ]; then
    fm_pid_identity "$pid"
    return
  fi
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
}

fm_session_self_harness_resolve() {
  local pid identity
  [ "$FM_SESSION_SELF_HARNESS_RESOLVED" -eq 1 ] && return 0
  pid=$(fm_harness_ancestry_pid 2>/dev/null || true)
  identity=
  if [ -n "$pid" ]; then
    identity=$(fm_session_process_identity "$pid" 2>/dev/null || true)
  fi
  if [ -n "$identity" ]; then
    FM_SESSION_SELF_HARNESS_PID=$pid
    FM_SESSION_SELF_HARNESS_IDENTITY=$identity
  fi
  FM_SESSION_SELF_HARNESS_RESOLVED=1
}

# Supervision session-owner fence: ONE owner of the "may this process start or
# keep supervising this home" decision for the watcher core (bin/fm-watch.sh,
# bin/fm-watch-arm.sh) and any future supervision entry point. Returns 0 when
# supervision may proceed and 1 when it is fenced because the home's session
# lock names a live verified-harness process this process does not descend
# from; on 1, FM_SESSION_OWNER_FOREIGN_PID names that foreign owner.
# Pass cases keep every supported supervision path working:
#   - no or malformed state/.lock: tests, manual runs, a home between sessions;
#   - state/.afk present: the away-mode daemon owns supervision and is not
#     harness-descended;
#   - the lock pid is this process's own harness ancestor: the owning session
#     (Codex checkpoints, Claude Stop-hook and recovery arms, Pi/OpenCode
#     adapter spawns, Grok background arms all descend from it);
#   - the lock pid is dead or not a harness: a stale lock, so recovery
#     proceeds unchanged and bin/fm-lock.sh's takeover path stays authoritative.
FM_SESSION_OWNER_FOREIGN_PID=
fm_session_owner_fence() {  # <state-dir>
  local state=$1 lock_pid lock_identity
  FM_SESSION_OWNER_FOREIGN_PID=
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ -e "$state/.afk" ]; then
    return 0
  fi
  fm_session_self_harness_resolve
  if [ "$lock_pid" = "$FM_SESSION_SELF_HARNESS_PID" ] && [ -n "$FM_SESSION_SELF_HARNESS_IDENTITY" ]; then
    lock_identity=$(fm_session_process_identity "$lock_pid" 2>/dev/null || true)
    if [ "$lock_identity" = "$FM_SESSION_SELF_HARNESS_IDENTITY" ]; then
      return 0
    fi
  fi
  fm_harness_pid_alive "$lock_pid" || return 0
  # Consumed by callers (bin/fm-watch.sh, bin/fm-watch-arm.sh) after a fenced return.
  # shellcheck disable=SC2034
  FM_SESSION_OWNER_FOREIGN_PID=$lock_pid
  return 1
}
