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
#   RECLAIM_BUSY        exit 13 - the reclaim mutex is temporarily held; retry
#
# Every reclaim path emits LOCK_RESULT= before exiting, including refused
# --expected mismatches and mid-mutex rechecks that reclassify the new state.
#
# Reclaim mutex (state/.lock-reclaim):
#   mkdir-based mutex with owner PID and start timestamp written after create.
#   Only a provably abandoned mutex may be removed and retaken: the recorded
#   owner PID is dead, or (legacy/no-pid) the directory age meets the mid-
#   acquire threshold. A live owner is never overridden.
#   For emergency recovery, re-run fm-lock.sh; it applies the required PID,
#   age, symlink, and mutex-generation checks before removing anything.
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
# Seconds a no-pid or mid-write reclaim mutex must age before it is treated as
# abandoned (same mid-acquire idea as bin/fm-wake-lib.sh's FM_LOCK_STALE_AFTER).
RECLAIM_MUTEX_STALE_AFTER="${FM_RECLAIM_MUTEX_STALE_AFTER:-2}"
# Short busy-mutex retries for free-claim and stale reclaim (not live takeover).
RECLAIM_BUSY_RETRIES="${FM_RECLAIM_BUSY_RETRIES:-4}"
RECLAIM_BUSY_SLEEP_SECS="${FM_RECLAIM_BUSY_SLEEP_SECS:-0.05}"
if ! mkdir -p "$STATE" 2>/dev/null || [ ! -d "$STATE" ] \
  || [ ! -w "$STATE" ] || [ ! -x "$STATE" ]; then
  printf '%s\n' "LOCK_RESULT=IDENTITY_UNAVAILABLE"
  printf '%s\n' "LOCK_DETAIL=cannot access lock state directory: $STATE"
  exit 12
fi

HARNESS_RE='claude|codex|opencode|grok|^pi$'
EXIT_LIVE_OTHER=10
EXIT_STALE_RECLAIMABLE=11
EXIT_IDENTITY_UNAVAILABLE=12
EXIT_RECLAIM_BUSY=13

CURRENT_OWNER=
PROCESS_TREE_UNAVAILABLE=0
LOCK_OWNER=
HOLDER_RESULT=
HOLDER_PROOF=
HOLDER_DETAIL=
PID_IDENTITY=
PID_IDENTITY_DETAIL=
RECLAIM_HELD=0
RECLAIM_ACQUIRE_ERROR=
RECLAIM_COMMAND_ACTIVE=0

usage() {
  sed -n '28,36p' "$0" | sed 's/^# \{0,1\}//'
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
    RECLAIM_BUSY)
      printf 'error: reclaim mutex busy (%s); retry briefly and re-check bin/fm-lock.sh status\n' "$detail" >&2
      ;;
  esac
}

result_exit_code() {
  case "$1" in
    OWNED) return 0 ;;
    LIVE_OTHER) return "$EXIT_LIVE_OTHER" ;;
    STALE_RECLAIMABLE) return "$EXIT_STALE_RECLAIMABLE" ;;
    IDENTITY_UNAVAILABLE) return "$EXIT_IDENTITY_UNAVAILABLE" ;;
    RECLAIM_BUSY) return "$EXIT_RECLAIM_BUSY" ;;
    *) return "$EXIT_IDENTITY_UNAVAILABLE" ;;
  esac
}

emit_classified_lock() {
  local detail_prefix=$1
  if ! read_lock; then
    emit_result IDENTITY_UNAVAILABLE "${detail_prefix}: lock is free"
    return "$EXIT_IDENTITY_UNAVAILABLE"
  fi
  classify_owner "$LOCK_OWNER"
  if [ "$HOLDER_RESULT" = OWNED ]; then
    current_owner || CURRENT_OWNER=$LOCK_OWNER
  fi
  emit_result "$HOLDER_RESULT" "${detail_prefix}: $HOLDER_DETAIL"
  result_exit_code "$HOLDER_RESULT"
  return $?
}

reclaim_mutex_generation() {
  reclaim_path_generation "$RECLAIM_LOCK"
}

reclaim_path_generation() {
  local path=$1 value
  if [ "$(uname)" = Darwin ]; then
    value=$(stat -f '%d.%i' "$path" 2>/dev/null) || return 1
  else
    value=$(stat -c '%d.%i' "$path" 2>/dev/null) || return 1
  fi
  case "$value" in ''|*[!0-9.]*) return 1 ;; esac
  printf '%s\n' "$value"
}

reclaim_mutex_age() {
  local path=${1:-$RECLAIM_LOCK} m now
  if [ "$(uname)" = Darwin ]; then
    m=$(stat -f %m "$path" 2>/dev/null) || return 1
  else
    m=$(stat -c %Y "$path" 2>/dev/null) || return 1
  fi
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$((now - m))"
}

# Provably abandoned: live owner PID is never overridden. Missing/invalid PID is
# treated like wake-lib mid-acquire: only after RECLAIM_MUTEX_STALE_AFTER seconds.
reclaim_mutex_is_provably_abandoned() {
  local generation=$1 current pid age min_age
  [ -d "$RECLAIM_LOCK" ] && [ ! -L "$RECLAIM_LOCK" ] || return 2
  reclaim_metadata_is_safe "$RECLAIM_LOCK/pid" || return 2
  reclaim_metadata_is_safe "$RECLAIM_LOCK/started" || return 2
  current=$(reclaim_mutex_generation 2>/dev/null || true)
  [ "$current" = "$generation" ] || return 1
  pid=$(cat "$RECLAIM_LOCK/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*)
      min_age=$RECLAIM_MUTEX_STALE_AFTER
      case "$min_age" in ''|*[!0-9]*) min_age=2 ;; esac
      [ "$min_age" -lt 2 ] && min_age=2
      # Allow test overrides that deliberately set 0 to force no-pid recovery.
      if [ "${FM_RECLAIM_MUTEX_STALE_AFTER:-}" = 0 ]; then
        min_age=0
      fi
      if ! age=$(reclaim_mutex_age); then
        return 2
      fi
      [ "$age" -ge "$min_age" ]
      return $?
      ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  return 0
}

remove_reclaim_mutex() {
  [ ! -L "$RECLAIM_LOCK" ] || return 1
  reclaim_metadata_is_safe "$RECLAIM_LOCK/pid" || return 1
  reclaim_metadata_is_safe "$RECLAIM_LOCK/started" || return 1
  rm -f "$RECLAIM_LOCK/pid" "$RECLAIM_LOCK/started" 2>/dev/null || true
  rmdir "$RECLAIM_LOCK" 2>/dev/null
}

reclaim_metadata_is_safe() {
  local path=$1
  [ ! -L "$path" ] && { [ ! -e "$path" ] || [ -f "$path" ]; }
}

reclaim_generation_dir_is_safe() {
  local path=$1
  [ ! -L "$path" ] && [ -d "$path" ] \
    && reclaim_metadata_is_safe "$path/pid" \
    && reclaim_metadata_is_safe "$path/started"
}

acquire_generation_claim() {
  local generation=$1 claim pid age attempt=0 now min_age claim_generation marker quarantine current
  claim="$RECLAIM_LOCK/.generation-claim-$generation"
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    if mkdir "$claim" 2>/dev/null; then
      now=$(date +%s 2>/dev/null) || return 2
      printf '%s\n' "${BASHPID:-$$}" > "$claim/pid" || return 2
      printf '%s\n' "$now" > "$claim/started" || return 2
      reclaim_generation_dir_is_safe "$claim" || return 2
      [ "$(cat "$claim/pid" 2>/dev/null || true)" = "${BASHPID:-$$}" ] \
        && [ "$(cat "$claim/started" 2>/dev/null || true)" = "$now" ] \
        || return 2
      return 0
    fi
    reclaim_generation_dir_is_safe "$claim" || return 2
    claim_generation=$(reclaim_path_generation "$claim" 2>/dev/null || true)
    [ -n "$claim_generation" ] || return 2
    pid=$(cat "$claim/pid" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*)
        age=$(reclaim_mutex_age "$claim" 2>/dev/null || true)
        case "$age" in ''|*[!0-9]*) return 2 ;; esac
        min_age=$RECLAIM_MUTEX_STALE_AFTER
        case "$min_age" in ''|*[!0-9]*) min_age=2 ;; esac
        [ "$min_age" -lt 2 ] && min_age=2
        if [ "${FM_RECLAIM_MUTEX_STALE_AFTER:-}" = 0 ]; then
          min_age=0
        fi
        [ "$age" -ge "$min_age" ] || return 1
        ;;
      *)
        kill -0 "$pid" 2>/dev/null && return 1
        ;;
    esac
    marker="$claim/.recovery-$claim_generation"
    mkdir "$marker" 2>/dev/null || [ -d "$marker" ] || return 2
    current=$(reclaim_path_generation "$claim" 2>/dev/null || true)
    if [ "$current" != "$claim_generation" ]; then
      rmdir "$marker" 2>/dev/null || true
      return 1
    fi
    quarantine="$STATE/.lock-reclaim-claim-retired-$generation.$claim_generation"
    [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] || return 2
    perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' \
      "$claim" "$quarantine" 2>/dev/null || return 1
  done
  return 1
}

release_generation_claim() {
  local generation=$1 claim pid
  claim="$RECLAIM_LOCK/.generation-claim-$generation"
  reclaim_generation_dir_is_safe "$claim" || return 1
  pid=$(cat "$claim/pid" 2>/dev/null || true)
  [ "$pid" = "${BASHPID:-$$}" ] || return 1
  rm -f "$claim/pid" "$claim/started" 2>/dev/null || return 1
  rmdir "$claim" 2>/dev/null
}

write_reclaim_owner() {
  local generation=$1 gate mypid=${BASHPID:-$$} now back_pid back_started current
  gate="$RECLAIM_LOCK/.generation-$generation"
  reclaim_generation_dir_is_safe "$gate" || return 1
  reclaim_metadata_is_safe "$RECLAIM_LOCK/pid" || return 1
  reclaim_metadata_is_safe "$RECLAIM_LOCK/started" || return 1
  current=$(reclaim_mutex_generation 2>/dev/null || true)
  [ "$current" = "$generation" ] || return 1
  now=$(date +%s 2>/dev/null) || return 1
  if ! printf '%s\n' "$mypid" > "$gate/pid"; then
    return 1
  fi
  if ! printf '%s\n' "$now" > "$gate/started"; then
    return 1
  fi
  [ "$(cat "$gate/pid" 2>/dev/null || true)" = "$mypid" ] \
    && [ "$(cat "$gate/started" 2>/dev/null || true)" = "$now" ] \
    || return 1
  if ! printf '%s\n' "$mypid" > "$RECLAIM_LOCK/pid"; then
    return 1
  fi
  if ! printf '%s\n' "$now" > "$RECLAIM_LOCK/started"; then
    return 1
  fi
  back_pid=$(cat "$RECLAIM_LOCK/pid" 2>/dev/null || true)
  back_started=$(cat "$RECLAIM_LOCK/started" 2>/dev/null || true)
  current=$(reclaim_mutex_generation 2>/dev/null || true)
  [ "$back_pid" = "$mypid" ] && [ "$back_started" = "$now" ] \
    && [ "$current" = "$generation" ] \
    && reclaim_generation_dir_is_safe "$gate"
}

release_reclaim_lock() {
  local recorded generation gate claimed retired mypid=${BASHPID:-$$}
  if [ "$RECLAIM_HELD" -ne 1 ]; then
    return 0
  fi
  reclaim_metadata_is_safe "$RECLAIM_LOCK/pid" || {
    RECLAIM_HELD=0
    return 1
  }
  recorded=$(cat "$RECLAIM_LOCK/pid" 2>/dev/null || true)
  if [ "$recorded" = "$mypid" ]; then
    generation=$(reclaim_mutex_generation 2>/dev/null || true)
    gate="$RECLAIM_LOCK/.generation-$generation"
    claimed="$RECLAIM_LOCK/.generation-claimed-$generation"
    if [ -n "$generation" ] && reclaim_generation_dir_is_safe "$gate" \
      && [ ! -e "$claimed" ] && [ ! -L "$claimed" ]; then
      perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' \
        "$gate" "$claimed" 2>/dev/null || {
        RECLAIM_HELD=0
        return 1
      }
      rm -rf "$claimed" 2>/dev/null || true
    fi
    for retired in "$STATE/.lock-reclaim-claim-retired-$generation".*; do
      if [ -e "$retired" ] || [ -L "$retired" ]; then
        rm -rf "$retired" 2>/dev/null || true
      fi
    done
    remove_reclaim_mutex
  fi
  RECLAIM_HELD=0
}

detach_abandoned_reclaim_mutex() {
  local generation=$1 gate claimed quarantine current pid now claim_pid gate_pid age min_age claim_rc=0 retired
  gate="$RECLAIM_LOCK/.generation-$generation"
  claimed="$RECLAIM_LOCK/.generation-claimed-$generation"
  quarantine="$STATE/.lock-reclaim-retired.${BASHPID:-$$}.$RANDOM.$generation"
  [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] || return 2
  command -v perl >/dev/null 2>&1 || return 2
  acquire_generation_claim "$generation" || claim_rc=$?
  [ "$claim_rc" -eq 0 ] || return "$claim_rc"
  if [ -e "$claimed" ] || [ -L "$claimed" ]; then
    reclaim_generation_dir_is_safe "$claimed" || return 2
    claim_pid=$(cat "$claimed/pid" 2>/dev/null || true)
    case "$claim_pid" in
      ''|*[!0-9]*)
        age=$(reclaim_mutex_age "$claimed" 2>/dev/null || true)
        case "$age" in ''|*[!0-9]*) return 1 ;; esac
        min_age=$RECLAIM_MUTEX_STALE_AFTER
        case "$min_age" in ''|*[!0-9]*) min_age=2 ;; esac
        [ "$min_age" -lt 2 ] && min_age=2
        [ "$age" -ge "$min_age" ] || return 1
        ;;
      *)
        kill -0 "$claim_pid" 2>/dev/null && return 1
        ;;
    esac
    perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' \
      "$claimed" "$gate" 2>/dev/null || return 1
  elif [ -e "$gate" ] || [ -L "$gate" ]; then
    reclaim_generation_dir_is_safe "$gate" || return 2
  else
    mkdir "$gate" 2>/dev/null || return 1
  fi
  reclaim_generation_dir_is_safe "$gate" || return 2
  gate_pid=$(cat "$gate/pid" 2>/dev/null || true)
  case "$gate_pid" in
    ''|*[!0-9]*) ;;
    *) kill -0 "$gate_pid" 2>/dev/null && return 1 ;;
  esac
  if ! perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' \
    "$gate" "$claimed" 2>/dev/null; then
    return 1
  fi
  reclaim_generation_dir_is_safe "$claimed" || return 2
  now=$(date +%s 2>/dev/null) || return 2
  printf '%s\n' "${BASHPID:-$$}" > "$claimed/pid" || return 2
  printf '%s\n' "$now" > "$claimed/started" || return 2
  current=$(reclaim_mutex_generation 2>/dev/null || true)
  if [ "$current" != "$generation" ]; then
    rm -rf "$claimed" 2>/dev/null || true
    release_generation_claim "$generation" 2>/dev/null || true
    return 1
  fi
  reclaim_metadata_is_safe "$RECLAIM_LOCK/pid" || return 2
  reclaim_metadata_is_safe "$RECLAIM_LOCK/started" || return 2
  pid=$(cat "$RECLAIM_LOCK/pid" 2>/dev/null || true)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      if kill -0 "$pid" 2>/dev/null; then
        rm -f "$claimed/pid" "$claimed/started" 2>/dev/null || true
        perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' \
          "$claimed" "$gate" 2>/dev/null || true
        release_generation_claim "$generation" 2>/dev/null || true
        return 1
      fi
      ;;
  esac
  if ! perl -e 'exit(rename($ARGV[0], $ARGV[1]) ? 0 : 1)' \
    "$RECLAIM_LOCK" "$quarantine" 2>/dev/null; then
    return 2
  fi
  rm -rf "$quarantine" 2>/dev/null || return 2
  [ ! -e "$quarantine" ] && [ ! -L "$quarantine" ] || return 2
  for retired in "$STATE/.lock-reclaim-claim-retired-$generation".*; do
    if [ -e "$retired" ] || [ -L "$retired" ]; then
      rm -rf "$retired" 2>/dev/null || return 2
    fi
  done
  return 0
}

# Returns 0 held, 1 busy (live or mid-acquire), 2 storage or malformed-state failure.
acquire_reclaim_lock() {
  local attempt=0 generation gate abandoned_rc detach_rc
  RECLAIM_ACQUIRE_ERROR=
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    if mkdir "$RECLAIM_LOCK" 2>/dev/null; then
      generation=$(reclaim_mutex_generation 2>/dev/null || true)
      gate="$RECLAIM_LOCK/.generation-$generation"
      if [ -n "$generation" ] && mkdir "$gate" 2>/dev/null \
        && write_reclaim_owner "$generation"; then
        RECLAIM_HELD=1
        return 0
      fi
      remove_reclaim_mutex
      RECLAIM_ACQUIRE_ERROR=io
      return 2
    fi
    if [ -L "$RECLAIM_LOCK" ] || { [ -e "$RECLAIM_LOCK" ] && [ ! -d "$RECLAIM_LOCK" ]; }; then
      RECLAIM_ACQUIRE_ERROR=io
      return 2
    fi
    generation=$(reclaim_mutex_generation 2>/dev/null || true)
    if [ -z "$generation" ]; then
      if [ -d "$RECLAIM_LOCK" ]; then
        RECLAIM_ACQUIRE_ERROR=io
        return 2
      fi
      continue
    fi
    abandoned_rc=0
    reclaim_mutex_is_provably_abandoned "$generation" || abandoned_rc=$?
    case "$abandoned_rc" in
      0)
        detach_rc=0
        detach_abandoned_reclaim_mutex "$generation" || detach_rc=$?
        if [ "$detach_rc" -eq 0 ]; then
          continue
        elif [ "$detach_rc" -eq 2 ]; then
          RECLAIM_ACQUIRE_ERROR=io
          return 2
        fi
        ;;
      2)
        RECLAIM_ACQUIRE_ERROR=io
        return 2
        ;;
      *)
        RECLAIM_ACQUIRE_ERROR=busy
        return 1
        ;;
    esac
    if [ ! -e "$RECLAIM_LOCK" ]; then
      continue
    fi
    RECLAIM_ACQUIRE_ERROR=busy
    return 1
  done
  if [ ! -e "$RECLAIM_LOCK" ]; then
    RECLAIM_ACQUIRE_ERROR=io
    return 2
  fi
  RECLAIM_ACQUIRE_ERROR=busy
  return 1
}

acquire_reclaim_lock_with_busy_retry() {
  local attempt=0 max=$RECLAIM_BUSY_RETRIES
  case "$max" in ''|*[!0-9]*) max=4 ;; esac
  while [ "$attempt" -le "$max" ]; do
    acquire_reclaim_lock
    case "$?" in
      0)
      return 0
      ;;
      2)
        return 2
        ;;
    esac
    attempt=$((attempt + 1))
    [ "$attempt" -le "$max" ] || break
    sleep "$RECLAIM_BUSY_SLEEP_SECS" 2>/dev/null || sleep 1
  done
  return 1
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

# claim_free: 0 success, 2 lock appeared, 3 reclaim mutex busy, 1 other failure.
claim_free() {
  local mutex_rc=0
  acquire_reclaim_lock_with_busy_retry || mutex_rc=$?
  [ "$mutex_rc" -eq 0 ] || {
    [ "$mutex_rc" -eq 1 ] && return 3
    return 1
  }
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
    emit_result IDENTITY_UNAVAILABLE "reclaim refused; expected owner $expected but the lock is free"
    return "$EXIT_IDENTITY_UNAVAILABLE"
  fi
  if [ "$LOCK_OWNER" != "$expected" ]; then
    classify_owner "$LOCK_OWNER"
    if [ "$HOLDER_RESULT" = OWNED ]; then
      current_owner || CURRENT_OWNER=$LOCK_OWNER
    fi
    emit_result "$HOLDER_RESULT" "reclaim refused; expected owner $expected but found $LOCK_OWNER ($HOLDER_DETAIL)"
    result_exit_code "$HOLDER_RESULT"
    return $?
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
    emit_classified_lock "reclaim refused; cannot identify this session through readable process ancestry or CODEX_THREAD_ID"
    return $?
  fi
  current=$CURRENT_OWNER

  local mutex_rc=0
  acquire_reclaim_lock_with_busy_retry || mutex_rc=$?
  if [ "$mutex_rc" -eq 1 ]; then
    emit_result RECLAIM_BUSY "another reclaim operation holds state/.lock-reclaim"
    return "$EXIT_RECLAIM_BUSY"
  elif [ "$mutex_rc" -ne 0 ]; then
    emit_classified_lock "reclaim mutex unavailable: cannot access or publish state/.lock-reclaim"
    return $?
  fi
  if ! read_lock || [ "$LOCK_OWNER" != "$expected" ]; then
    release_reclaim_lock
    emit_classified_lock "reclaim refused; owner changed while waiting for the reclaim mutex"
    return $?
  fi

  classify_owner "$expected"
  if [ "$initial_proof" = confirmed-closed-codex-thread ]; then
    if [ "$HOLDER_RESULT" != IDENTITY_UNAVAILABLE ] \
      || [ "$HOLDER_PROOF" != foreign-codex-thread-unverifiable ]; then
      release_reclaim_lock
      emit_result "$HOLDER_RESULT" "reclaim refused; the confirmed Codex owner state changed during verification ($HOLDER_DETAIL)"
      result_exit_code "$HOLDER_RESULT"
      return $?
    fi
  elif [ "$HOLDER_RESULT" != STALE_RECLAIMABLE ] \
    || [ "$HOLDER_PROOF" != "$initial_proof" ]; then
    release_reclaim_lock
    emit_result "$HOLDER_RESULT" "reclaim refused; the stale-owner proof changed during verification ($HOLDER_DETAIL)"
    result_exit_code "$HOLDER_RESULT"
    return $?
  fi

  CURRENT_OWNER=$current
  if ! write_owner "$CURRENT_OWNER"; then
    release_reclaim_lock
    emit_classified_lock "reclaim failed to write the new lock owner"
    return $?
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
        3)
          emit_result RECLAIM_BUSY "cannot acquire the reclaim mutex for a free lock"
          return "$EXIT_RECLAIM_BUSY"
          ;;
        *)
          emit_result IDENTITY_UNAVAILABLE "failed to write a free lock owner"
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

handle_lock_signal() {
  local code=$1
  release_reclaim_lock
  if [ "$RECLAIM_COMMAND_ACTIVE" -eq 1 ]; then
    emit_classified_lock "reclaim interrupted by signal"
  fi
  exit "$code"
}

trap release_reclaim_lock EXIT
trap 'handle_lock_signal 129' HUP
trap 'handle_lock_signal 130' INT
trap 'handle_lock_signal 143' TERM

case "${1:-}" in
  '')
    acquire_default
    ;;
  status)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    status_lock
    ;;
  reclaim)
    RECLAIM_COMMAND_ACTIVE=1
    shift
    expected=
    confirmed_closed=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --expected)
          [ "$#" -gt 1 ] || {
            emit_result IDENTITY_UNAVAILABLE "reclaim usage error: --expected requires an owner"
            exit "$EXIT_IDENTITY_UNAVAILABLE"
          }
          expected=$2
          shift 2
          ;;
        --confirmed-closed)
          confirmed_closed=1
          shift
          ;;
        *)
          emit_result IDENTITY_UNAVAILABLE "reclaim usage error: unknown argument $1"
          exit "$EXIT_IDENTITY_UNAVAILABLE"
          ;;
      esac
    done
    [ -n "$expected" ] || {
      emit_result IDENTITY_UNAVAILABLE "reclaim usage error: --expected owner is required"
      exit "$EXIT_IDENTITY_UNAVAILABLE"
    }
    if [ "$confirmed_closed" -eq 1 ] && [ "${expected#codex-thread:}" = "$expected" ]; then
      emit_result IDENTITY_UNAVAILABLE "reclaim usage error: --confirmed-closed requires a codex-thread owner"
      exit "$EXIT_IDENTITY_UNAVAILABLE"
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
