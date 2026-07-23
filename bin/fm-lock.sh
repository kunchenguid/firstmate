#!/usr/bin/env bash
# Acquire, inspect, or atomically reclaim the per-home firstmate session lock.
# A normal session owner is the harness process PID found by walking the shell's
# ancestry.
# When that process tree cannot be inspected, Codex may instead use its stable
# CODEX_THREAD_ID as codex-thread:<id>.
#
# Machine-readable acquisition outcomes are printed as LOCK_RESULT=<result>:
#   OWNED               exit 0  - this session owns the lock
#   LIVE_OTHER          exit 10 - a different live harness is proven
#   STALE_RECLAIMABLE   exit 11 - the recorded numeric owner is proven stale
#   IDENTITY_UNAVAILABLE exit 12 - ownership or liveness cannot be proven
#
# Usage: fm-lock.sh
#          Acquire a free lock or atomically reclaim a proven-stale lock.
#        fm-lock.sh status
#          Print the current typed state without mutating the lock; always exit 0.
#        fm-lock.sh reclaim --expected <owner> [--confirmed-closed]
#          Compare and replace exactly <owner> under the reclaim mutex.
#          --confirmed-closed is accepted only for a codex-thread owner and only
#          after the captain explicitly confirms that its old window is closed.
# There is deliberately no unconditional clear command.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
RECLAIM_LOCK="$STATE/.lock-reclaim"
mkdir -p "$STATE"

HARNESS_RE='claude|codex|opencode|grok|^pi$'
EXIT_LIVE_OTHER=10
EXIT_STALE_RECLAIMABLE=11
EXIT_IDENTITY_UNAVAILABLE=12

CURRENT_OWNER=
PROCESS_TREE_UNAVAILABLE=0
LOCK_OWNER=
HOLDER_RESULT=
HOLDER_PROOF=
HOLDER_DETAIL=
PID_IDENTITY=
PID_IDENTITY_DETAIL=
RECLAIM_HELD=0

usage() {
  sed -n '8,20p' "$0" | sed 's/^# \{0,1\}//'
}

valid_codex_thread_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

process_owner() {
  local pid=$$ comm base args parent
  CURRENT_OWNER=
  PROCESS_TREE_UNAVAILABLE=0

  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || {
      PROCESS_TREE_UNAVAILABLE=1
      return 1
    }
    base=$(basename "$comm")
    if printf '%s' "$base" | grep -qE "$HARNESS_RE"; then
      CURRENT_OWNER=$pid
      return 0
    fi
    case "$comm" in
      *node*|*python*)
        args=$(ps -o args= -p "$pid" 2>/dev/null) || {
          PROCESS_TREE_UNAVAILABLE=1
          return 1
        }
        if printf '%s' "$args" | grep -qE "$HARNESS_RE"; then
          CURRENT_OWNER=$pid
          return 0
        fi
        ;;
    esac
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || {
      PROCESS_TREE_UNAVAILABLE=1
      return 1
    }
    case "$parent" in
      ''|*[!0-9]*|0|1) return 1 ;;
      *) pid=$parent ;;
    esac
  done
  return 1
}

current_owner() {
  CURRENT_OWNER=
  if process_owner; then
    return 0
  fi
  if [ "$PROCESS_TREE_UNAVAILABLE" -eq 1 ] \
    && valid_codex_thread_id "${CODEX_THREAD_ID:-}"; then
    CURRENT_OWNER="codex-thread:$CODEX_THREAD_ID"
    return 0
  fi
  return 1
}

read_lock() {
  LOCK_OWNER=
  [ -f "$LOCK" ] || return 1
  IFS= read -r LOCK_OWNER < "$LOCK" || true
  return 0
}

inspect_pid_identity() {
  local owner=$1 comm base args
  PID_IDENTITY=
  PID_IDENTITY_DETAIL=

  comm=$(ps -o comm= -p "$owner" 2>/dev/null) || {
    PID_IDENTITY=UNAVAILABLE
    PID_IDENTITY_DETAIL="pid $owner is alive but its process identity cannot be read"
    return 0
  }
  base=$(basename "$comm")
  if printf '%s' "$base" | grep -qE "$HARNESS_RE"; then
    PID_IDENTITY=HARNESS
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$owner" 2>/dev/null) || {
        PID_IDENTITY=UNAVAILABLE
        PID_IDENTITY_DETAIL="pid $owner is alive but its process arguments cannot be read"
        return 0
      }
      if printf '%s' "$args" | grep -qE "$HARNESS_RE"; then
        PID_IDENTITY=HARNESS
        return 0
      fi
      ;;
  esac
  PID_IDENTITY=NOT_HARNESS
}

classify_live_harness_pid() {
  local owner=$1
  if current_owner && [ "$CURRENT_OWNER" = "$owner" ]; then
    HOLDER_RESULT=OWNED
    HOLDER_PROOF='current-harness-pid'
    HOLDER_DETAIL="current harness pid $owner"
  elif [ -n "$CURRENT_OWNER" ] && printf '%s' "$CURRENT_OWNER" | grep -qE '^[0-9]+$'; then
    HOLDER_RESULT=LIVE_OTHER
    HOLDER_PROOF='live-harness-pid'
    HOLDER_DETAIL="another live harness pid $owner"
  else
    HOLDER_RESULT=IDENTITY_UNAVAILABLE
    HOLDER_PROOF='current-identity-unavailable'
    HOLDER_DETAIL="pid $owner is a live harness but this session identity cannot be compared safely"
  fi
}

classify_owner() {
  local owner=$1
  HOLDER_RESULT=
  HOLDER_PROOF=
  HOLDER_DETAIL=

  case "$owner" in
    codex-thread:*)
      if [ "$owner" = "codex-thread:${CODEX_THREAD_ID:-}" ] \
        && valid_codex_thread_id "${CODEX_THREAD_ID:-}"; then
        HOLDER_RESULT=OWNED
        HOLDER_PROOF='current-codex-thread'
        HOLDER_DETAIL="current Codex thread"
      else
        HOLDER_RESULT=IDENTITY_UNAVAILABLE
        HOLDER_PROOF='foreign-codex-thread-unverifiable'
        HOLDER_DETAIL="Codex thread $owner has no verifiable lifecycle signal"
      fi
      return 0
      ;;
    ''|*[!0-9]*)
      HOLDER_RESULT=IDENTITY_UNAVAILABLE
      HOLDER_PROOF='invalid-owner'
      HOLDER_DETAIL="lock owner '$owner' is not a supported identity"
      return 0
      ;;
  esac

  if ! kill -0 "$owner" 2>/dev/null; then
    HOLDER_RESULT=STALE_RECLAIMABLE
    HOLDER_PROOF='pid-dead'
    HOLDER_DETAIL="pid $owner is not alive"
    return 0
  fi

  inspect_pid_identity "$owner"
  case "$PID_IDENTITY" in
    HARNESS)
      classify_live_harness_pid "$owner"
      ;;
    UNAVAILABLE)
      HOLDER_RESULT=IDENTITY_UNAVAILABLE
      HOLDER_PROOF='pid-identity-unreadable'
      HOLDER_DETAIL=$PID_IDENTITY_DETAIL
      ;;
    *)
      HOLDER_RESULT=STALE_RECLAIMABLE
      HOLDER_PROOF='pid-not-harness'
      HOLDER_DETAIL="pid $owner is alive but is not a harness process"
      ;;
  esac
}

emit_result() {
  local result=$1 detail=$2
  printf 'LOCK_RESULT=%s\n' "$result"
  case "$result" in
    OWNED)
      case "$CURRENT_OWNER" in
        codex-thread:*) printf 'lock acquired: Codex thread %s\n' "${CURRENT_OWNER#codex-thread:}" ;;
        *) printf 'lock acquired: harness pid %s\n' "$CURRENT_OWNER" ;;
      esac
      ;;
    LIVE_OTHER)
      printf 'error: another live firstmate session holds the lock (%s); operate read-only until resolved\n' "$detail" >&2
      ;;
    STALE_RECLAIMABLE)
      printf 'lock: stale and reclaimable (%s)\n' "$detail"
      ;;
    IDENTITY_UNAVAILABLE)
      printf 'error: lock identity unavailable (%s); no live rival or stale owner has been proven\n' "$detail" >&2
      ;;
  esac
}

result_exit_code() {
  case "$1" in
    OWNED) return 0 ;;
    LIVE_OTHER) return "$EXIT_LIVE_OTHER" ;;
    STALE_RECLAIMABLE) return "$EXIT_STALE_RECLAIMABLE" ;;
    IDENTITY_UNAVAILABLE) return "$EXIT_IDENTITY_UNAVAILABLE" ;;
    *) return "$EXIT_IDENTITY_UNAVAILABLE" ;;
  esac
}

release_reclaim_lock() {
  if [ "$RECLAIM_HELD" -eq 1 ]; then
    rmdir "$RECLAIM_LOCK" 2>/dev/null || true
    RECLAIM_HELD=0
  fi
}

acquire_reclaim_lock() {
  mkdir "$RECLAIM_LOCK" 2>/dev/null || return 1
  RECLAIM_HELD=1
}

write_owner() {
  local owner=$1 tmp="$STATE/.lock.tmp.$$"
  if ! printf '%s\n' "$owner" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$LOCK"; then
    rm -f "$tmp"
    return 1
  fi
}

claim_free() {
  acquire_reclaim_lock || return 1
  if [ -f "$LOCK" ]; then
    release_reclaim_lock
    return 2
  fi
  if ! write_owner "$CURRENT_OWNER"; then
    release_reclaim_lock
    return 1
  fi
  release_reclaim_lock
  return 0
}

reclaim_expected() {
  local expected=$1 confirmed_closed=$2 initial_proof current

  if ! read_lock; then
    printf 'error: reclaim refused; expected owner %s but the lock is free\n' "$expected" >&2
    return 1
  fi
  if [ "$LOCK_OWNER" != "$expected" ]; then
    printf 'error: reclaim refused; expected owner %s but found %s\n' "$expected" "$LOCK_OWNER" >&2
    return 1
  fi

  classify_owner "$expected"
  if [ "$HOLDER_RESULT" = OWNED ]; then
    current_owner || CURRENT_OWNER=$expected
    emit_result OWNED "$HOLDER_DETAIL"
    return 0
  fi
  if [ "$HOLDER_RESULT" = STALE_RECLAIMABLE ]; then
    initial_proof=$HOLDER_PROOF
  elif [ "$HOLDER_RESULT" = IDENTITY_UNAVAILABLE ] \
    && [ "$confirmed_closed" -eq 1 ] \
    && [ "${expected#codex-thread:}" != "$expected" ]; then
    initial_proof=confirmed-closed-codex-thread
  else
    emit_result "$HOLDER_RESULT" "$HOLDER_DETAIL"
    result_exit_code "$HOLDER_RESULT"
    return $?
  fi

  if ! current_owner; then
    emit_result IDENTITY_UNAVAILABLE "cannot identify this session through readable process ancestry or CODEX_THREAD_ID"
    return "$EXIT_IDENTITY_UNAVAILABLE"
  fi
  current=$CURRENT_OWNER

  if ! acquire_reclaim_lock; then
    emit_result IDENTITY_UNAVAILABLE "another reclaim operation is in progress"
    return "$EXIT_IDENTITY_UNAVAILABLE"
  fi
  if ! read_lock || [ "$LOCK_OWNER" != "$expected" ]; then
    release_reclaim_lock
    printf 'error: reclaim refused; owner changed while waiting for the reclaim lock\n' >&2
    return 1
  fi

  classify_owner "$expected"
  if [ "$initial_proof" = confirmed-closed-codex-thread ]; then
    if [ "$HOLDER_RESULT" != IDENTITY_UNAVAILABLE ] \
      || [ "$HOLDER_PROOF" != foreign-codex-thread-unverifiable ]; then
      release_reclaim_lock
      printf 'error: reclaim refused; the confirmed Codex owner state changed during verification\n' >&2
      return 1
    fi
  elif [ "$HOLDER_RESULT" != STALE_RECLAIMABLE ] \
    || [ "$HOLDER_PROOF" != "$initial_proof" ]; then
    release_reclaim_lock
    printf 'error: reclaim refused; the stale-owner proof changed during verification\n' >&2
    return 1
  fi

  CURRENT_OWNER=$current
  if ! write_owner "$CURRENT_OWNER"; then
    release_reclaim_lock
    emit_result IDENTITY_UNAVAILABLE "failed to write the new lock owner"
    return "$EXIT_IDENTITY_UNAVAILABLE"
  fi
  release_reclaim_lock
  emit_result OWNED "reclaimed from $expected"
  return 0
}

status_lock() {
  if ! read_lock; then
    printf 'lock: free\n'
    return 0
  fi
  classify_owner "$LOCK_OWNER"
  if [ "$HOLDER_RESULT" = OWNED ]; then
    current_owner || CURRENT_OWNER=$LOCK_OWNER
  fi
  printf 'LOCK_RESULT=%s\n' "$HOLDER_RESULT"
  case "$HOLDER_RESULT" in
    OWNED) printf 'lock: owned by this session (%s)\n' "$HOLDER_DETAIL" ;;
    LIVE_OTHER) printf 'lock: held by live harness pid %s (%s)\n' "$LOCK_OWNER" "$HOLDER_DETAIL" ;;
    STALE_RECLAIMABLE) printf 'lock: stale and reclaimable (%s)\n' "$HOLDER_DETAIL" ;;
    IDENTITY_UNAVAILABLE) printf 'lock: identity unavailable (%s)\n' "$HOLDER_DETAIL" ;;
  esac
}

acquire_default() {
  local attempt=0 claim_rc
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    if ! read_lock; then
      if ! current_owner; then
        emit_result IDENTITY_UNAVAILABLE "cannot identify this session through readable process ancestry or CODEX_THREAD_ID"
        return "$EXIT_IDENTITY_UNAVAILABLE"
      fi
      claim_rc=0
      claim_free || claim_rc=$?
      case "$claim_rc" in
        0)
          emit_result OWNED "new lock"
          return 0
          ;;
        2)
          continue
          ;;
        *)
          emit_result IDENTITY_UNAVAILABLE "cannot acquire the reclaim mutex for a free lock"
          return "$EXIT_IDENTITY_UNAVAILABLE"
          ;;
      esac
    fi

    classify_owner "$LOCK_OWNER"
    case "$HOLDER_RESULT" in
      OWNED)
        current_owner || CURRENT_OWNER=$LOCK_OWNER
        emit_result OWNED "$HOLDER_DETAIL"
        return 0
        ;;
      LIVE_OTHER|IDENTITY_UNAVAILABLE)
        emit_result "$HOLDER_RESULT" "$HOLDER_DETAIL"
        result_exit_code "$HOLDER_RESULT"
        return $?
        ;;
      STALE_RECLAIMABLE)
        reclaim_expected "$LOCK_OWNER" 0
        return $?
        ;;
    esac
  done

  emit_result IDENTITY_UNAVAILABLE "lock ownership changed repeatedly during acquisition"
  return "$EXIT_IDENTITY_UNAVAILABLE"
}

trap release_reclaim_lock EXIT
trap 'release_reclaim_lock; exit 129' HUP
trap 'release_reclaim_lock; exit 130' INT
trap 'release_reclaim_lock; exit 143' TERM

case "${1:-}" in
  '')
    acquire_default
    ;;
  status)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    status_lock
    ;;
  reclaim)
    shift
    expected=
    confirmed_closed=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --expected)
          [ "$#" -gt 1 ] || { echo "error: --expected requires an owner" >&2; exit 2; }
          expected=$2
          shift 2
          ;;
        --confirmed-closed)
          confirmed_closed=1
          shift
          ;;
        *)
          echo "error: unknown reclaim argument: $1" >&2
          usage >&2
          exit 2
          ;;
      esac
    done
    [ -n "$expected" ] || { echo "error: reclaim requires --expected <owner>" >&2; exit 2; }
    if [ "$confirmed_closed" -eq 1 ] && [ "${expected#codex-thread:}" = "$expected" ]; then
      echo "error: --confirmed-closed is valid only for a codex-thread owner" >&2
      exit 2
    fi
    reclaim_expected "$expected" "$confirmed_closed"
    ;;
  clear)
    echo "error: unconditional clear is not supported; use reclaim --expected <owner>" >&2
    exit 2
    ;;
  -h|--help)
    usage
    ;;
  *)
    echo "error: unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac
