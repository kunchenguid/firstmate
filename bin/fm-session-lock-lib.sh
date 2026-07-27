#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness session holds this home's lock, and
# does the current process belong to that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# A numeric harness pid is the normal owner identity. Hosted Codex seatbelt
# sessions can deny process ancestry reads, so they fall back to a stable
# codex:<thread-id> token that is never age-reclaimed or treated as stale.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$'
FM_SESSION_OWNER_LIVE_KIND=

# Print the stable hosted Codex owner token only in the environment where
# process inspection is known to be denied by the seatbelt sandbox.
fm_codex_owner_token() {
  [ -n "${CODEX_THREAD_ID:-}" ] || return 1
  [ "${CODEX_SANDBOX:-}" = seatbelt ] || return 1
  printf 'codex:%s\n' "$CODEX_THREAD_ID"
}

# Walk the current process ancestry (up to 8 hops) and print the first pid whose
# command looks like a verified harness. The harness pid lives as long as the
# session, unlike the transient subshell pid of any one tool call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# Print the current session's lock owner identity.
fm_session_owner() {
  fm_harness_ancestry_pid && return 0
  fm_codex_owner_token
}

# True if $1 is a live or conservatively uninspectable session owner.
# A different hosted Codex token is deliberately treated as live forever: no
# clock or age heuristic may steal another thread's durable fleet lock.
fm_session_owner_alive() {
  local owner=$1 comm
  FM_SESSION_OWNER_LIVE_KIND=
  case "$owner" in
    codex:*)
      FM_SESSION_OWNER_LIVE_KIND=codex
      return 0
      ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$owner" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$owner" 2>/dev/null) || {
    if [ -n "${CODEX_THREAD_ID:-}" ] && [ "${CODEX_SANDBOX:-}" = seatbelt ]; then
      FM_SESSION_OWNER_LIVE_KIND=uninspectable_pid
      return 0
    fi
    return 1
  }
  if printf '%s' "$(basename "$comm") $(ps -o args= -p "$owner" 2>/dev/null)" | grep -qE "$FM_HARNESS_RE"; then
    FM_SESSION_OWNER_LIVE_KIND=harness_pid
    return 0
  fi
  return 1
}

# True if $1 is a live numeric process that looks like a verified harness.
fm_harness_pid_alive() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  fm_session_owner_alive "$1"
}

fm_session_owner_description() {
  local owner=$1
  case "$FM_SESSION_OWNER_LIVE_KIND" in
    codex) printf 'hosted Codex session %s\n' "$owner" ;;
    uninspectable_pid) printf 'uninspectable live holder pid %s\n' "$owner" ;;
    harness_pid) printf 'live harness pid %s\n' "$owner" ;;
    *) printf 'live holder %s\n' "$owner" ;;
  esac
}

fm_session_owner_error_description() {
  local owner=$1
  case "$FM_SESSION_OWNER_LIVE_KIND" in
    codex) printf 'hosted Codex session %s\n' "$owner" ;;
    uninspectable_pid) printf 'uninspectable live holder pid %s\n' "$owner" ;;
    harness_pid) printf 'pid %s\n' "$owner" ;;
    *) printf 'owner %s\n' "$owner" ;;
  esac
}

# True when state dir $1 holds the current session's numeric pid or hosted
# Codex token. A missing lock, a different owner, or an identity that cannot be
# resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_owner my_owner
  lock_owner=$(cat "$state/.lock" 2>/dev/null || true)
  [ -n "$lock_owner" ] || return 1
  my_owner=$(fm_session_owner) || return 1
  [ "$my_owner" = "$lock_owner" ]
}
