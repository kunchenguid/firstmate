#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness session holds this home's session
# lock, and does the current process belong to that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# Codex owners use one of these formats:
#   <pid>|codex:<thread-id>|harness
#   <pid>|codex:<thread-id>|fallback
# `harness` means the PID was verified from ancestry and can prove liveness.
# `fallback` means PID isolation hid the harness, so only the thread marker can
# prove same-session ownership and a different thread must treat it as
# unverifiable until Codex's SessionEnd hook releases it.
# The legacy two-field Codex owner remains readable and fail-closed.
# This file is sourced by scripts and has no side effects on source.

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Walk the current process ancestry (up to 8 hops) and print the first PID whose
# command looks like a verified harness.
# This function never falls back to a tool PID.
fm_verified_harness_ancestry_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  return 1
}

# Print the current owner record.
# Codex keeps working when its tool sandbox hides the harness PID: the fallback
# record is deliberately not reclaimable by a different thread, but the same
# thread can keep using it and SessionEnd can release it deterministically.
fm_session_lock_owner() {
  local pid
  if [ -n "${CODEX_THREAD_ID:-}" ]; then
    if pid=$(fm_verified_harness_ancestry_pid); then
      printf '%s|codex:%s|harness\n' "$pid" "$CODEX_THREAD_ID"
    else
      printf '%s|codex:%s|fallback\n' "$$" "$CODEX_THREAD_ID"
    fi
    return 0
  fi
  fm_verified_harness_ancestry_pid
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
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

# Print a Codex owner marker, or fail for a numeric/non-Codex owner.
fm_codex_owner_marker() {
  local owner=$1 pid rest marker suffix
  pid=${owner%%|*}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  rest=${owner#*|}
  case "$rest" in codex:*) rest=${rest#codex:} ;; *) return 1 ;; esac
  marker=${rest%%|*}
  case "$marker" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  if [ "$rest" != "$marker" ]; then
    suffix=${rest#*|}
    case "$suffix" in harness|fallback) ;; *) return 1 ;; esac
  fi
  printf '%s\n' "$marker"
}

fm_codex_owner_kind() {
  local owner=$1 rest marker suffix
  fm_codex_owner_marker "$owner" >/dev/null || return 1
  rest=${owner#*|codex:}
  marker=${rest%%|*}
  if [ "$rest" = "$marker" ]; then
    printf '%s\n' legacy
    return 0
  fi
  suffix=${rest#*|}
  printf '%s\n' "$suffix"
}

# Return 0 when owner $1 is live or belongs to the current Codex thread, 1 when
# it is provably stale, 2 when another Codex thread cannot verify it, and 3 for
# an invalid owner record.
fm_session_lock_holder_state() {
  local owner=$1 pid marker kind
  case "$owner" in
    *'|codex:'*)
      pid=${owner%%|*}
      case "$pid" in ''|*[!0-9]*) return 3 ;; esac
      marker=$(fm_codex_owner_marker "$owner") || return 3
      [ -n "$marker" ] || return 3
      if [ -n "${CODEX_THREAD_ID:-}" ] && [ "$CODEX_THREAD_ID" = "$marker" ]; then
        return 0
      fi
      kind=$(fm_codex_owner_kind "$owner") || return 3
      if [ "$kind" = harness ]; then
        fm_harness_pid_alive "$pid"
        return $?
      fi
      return 2
      ;;
    *)
      case "$owner" in ''|*[!0-9]*) return 3 ;; esac
      fm_harness_pid_alive "$owner"
      ;;
  esac
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 owner marker my_pid
  owner=$(cat "$state/.lock" 2>/dev/null || true)
  if marker=$(fm_codex_owner_marker "$owner"); then
    [ -n "${CODEX_THREAD_ID:-}" ] && [ "$CODEX_THREAD_ID" = "$marker" ]
    return $?
  fi
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac
  my_pid=$(fm_verified_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$owner" ]
}
