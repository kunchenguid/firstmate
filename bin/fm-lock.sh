#!/usr/bin/env bash
# Own the per-home firstmate session lock.
# The lock file contains exactly one verified harness PID and is changed only by
# this script inside a portable cross-process acquisition mutex.
#
# Usage: fm-lock.sh             acquire or idempotently confirm this session
#        fm-lock.sh status      print holder and liveness; always exits 0
#        fm-lock.sh ownership   print owned, missing, dead, other, malformed, or unknown
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
ACQUIRE_LOCK="$STATE/.session-lock.acquire"
LOCK_PID=
LOCK_STATE=
LOCK_PENDING=

harness_name_is_exact() {
  case "$1" in
    claude|codex|opencode|pi|grok) return 0 ;;
    *) return 1 ;;
  esac
}

interpreter_script_basename() {
  local args=$1 script
  script=$(printf '%s\n' "$args" | awk '
    {
      for (i = 2; i <= NF; i += 1) {
        if ($i == "--") {
          if (i + 1 <= NF) print $(i + 1)
          exit
        }
        if (substr($i, 1, 1) == "-") continue
        print $i
        exit
      }
    }
  ')
  [ -n "$script" ] || return 1
  script=${script#\"}
  script=${script%\"}
  script=${script#\'}
  script=${script%\'}
  printf '%s\n' "${script##*/}"
}

process_is_harness() {
  local pid=$1 comm base args script_base
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  comm=${comm#"${comm%%[![:space:]]*}"}
  comm=${comm%"${comm##*[![:space:]]}"}
  base=${comm##*/}
  if harness_name_is_exact "$base"; then
    return 0
  fi
  case "$base" in
    node|nodejs|python|python3)
      args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
      script_base=$(interpreter_script_basename "$args") || return 1
      harness_name_is_exact "$script_base"
      ;;
    *) return 1 ;;
  esac
}

harness_pid() {
  local pid=$$ parent
  for _ in 1 2 3 4 5 6 7 8; do
    if process_is_harness "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null) || return 1
    parent=${parent//[[:space:]]/}
    case "$parent" in
      ''|*[!0-9]*|0|1) return 1 ;;
    esac
    pid=$parent
  done
  return 1
}

holder_alive() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*|0|1) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  process_is_harness "$pid"
}

read_lock_pid() {
  local pid
  LOCK_PID=
  if [ -L "$LOCK" ]; then
    return 2
  fi
  if [ ! -e "$LOCK" ]; then
    return 1
  fi
  [ -f "$LOCK" ] || return 2
  pid=$(awk 'NR == 1 && /^[0-9]+$/ { value = $0; next } { exit 1 } END { if (NR != 1 || value == "") exit 1; print value }' "$LOCK" 2>/dev/null) || return 2
  case "$pid" in
    0|1) return 2 ;;
  esac
  [ "$pid" -gt 1 ] 2>/dev/null || return 2
  LOCK_PID=$pid
  return 0
}

classify_lock() {
  local me=${1:-} read_status
  LOCK_STATE=
  read_status=0
  read_lock_pid || read_status=$?
  case "$read_status" in
    1) LOCK_STATE=missing; return ;;
    2) LOCK_STATE=malformed; return ;;
  esac
  if [ -n "$me" ] && [ "$LOCK_PID" = "$me" ]; then
    LOCK_STATE=owned
  elif holder_alive "$LOCK_PID"; then
    LOCK_STATE=other
  else
    LOCK_STATE=dead
  fi
}

lock_ownership() {
  classify_lock "${1:-}"
  printf '%s\n' "$LOCK_STATE"
}

write_lock_atomically() {
  local pid=$1 temporary
  temporary=$(mktemp "$STATE/.lock.pending.XXXXXX") || return 1
  LOCK_PENDING=$temporary
  if ! printf '%s\n' "$pid" > "$temporary"; then
    rm -f "$temporary"
    LOCK_PENDING=
    return 1
  fi
  if ! mv "$temporary" "$LOCK"; then
    rm -f "$temporary"
    LOCK_PENDING=
    return 1
  fi
  LOCK_PENDING=
}

case "${1:-}" in
  status)
    classify_lock
    case "$LOCK_STATE" in
      missing) printf 'lock: free\n' ;;
      malformed) printf 'lock: malformed\n' ;;
      other) printf 'lock: held by live harness pid %s\n' "$LOCK_PID" ;;
      dead) printf 'lock: stale (pid %s dead or not a harness)\n' "$LOCK_PID" ;;
    esac
    exit 0
    ;;
  ownership)
    if me=$(harness_pid); then
      lock_ownership "$me"
    else
      printf 'unknown\n'
    fi
    exit 0
    ;;
  ''|acquire) ;;
  *) printf 'error: unknown fm-lock.sh command: %s\n' "$1" >&2; exit 2 ;;
esac

me=$(harness_pid) || { printf 'error: cannot locate harness process in ancestry\n' >&2; exit 1; }
mkdir -p "$STATE" || { printf 'error: cannot create session state directory: %s\n' "$STATE" >&2; exit 1; }

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
if ! fm_lock_try_acquire "$ACQUIRE_LOCK"; then
  printf 'error: session lock acquisition is already in progress; ownership was not changed\n' >&2
  exit 1
fi
release_acquire_lock() {
  [ -n "$LOCK_PENDING" ] && rm -f "$LOCK_PENDING"
  fm_lock_release "$ACQUIRE_LOCK"
}
trap release_acquire_lock EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

classify_lock "$me"
case "$LOCK_STATE" in
  owned)
    printf 'lock acquired: harness pid %s\n' "$me"
    exit 0
    ;;
  other)
    printf 'error: another live firstmate session holds the lock (pid %s); operate read-only until resolved\n' "$LOCK_PID" >&2
    exit 1
    ;;
  malformed)
    printf 'error: session lock is malformed; ownership was not changed\n' >&2
    exit 1
    ;;
  missing|dead) ;;
  *)
    printf 'error: unknown session lock state: %s\n' "$LOCK_STATE" >&2
    exit 1
    ;;
esac

write_lock_atomically "$me" || { printf 'error: failed to publish session lock ownership\n' >&2; exit 1; }
classify_lock "$me"
[ "$LOCK_STATE" = owned ] || { printf 'error: session lock ownership changed during publication\n' >&2; exit 1; }
printf 'lock acquired: harness pid %s\n' "$me"
