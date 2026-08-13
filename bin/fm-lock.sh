#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the verified harness session owner found by walking shell ancestry.
# A numeric harness pid is normal and lives for the whole session, unlike the
# transient subshell pid of one tool call. Hosted Codex seatbelt sessions may
# use a stable codex:<thread-id> token when process inspection is unavailable.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity, hosted Codex fallback, ancestry walking, and holder
# liveness are owned by the shared session-lock lib so every lock consumer uses
# the same conservative identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

lock_holder_description() {  # <owner> - reads FM_HARNESS_LIVE_KIND set by fm_harness_pid_alive
  local owner=$1
  case "$FM_HARNESS_LIVE_KIND" in
    codex) printf 'hosted Codex session %s\n' "$owner" ;;
    uninspectable_pid) printf 'uninspectable live holder pid %s\n' "$owner" ;;
    *) printf 'live harness pid %s\n' "$owner" ;;
  esac
}

lock_holder_error_description() {  # <owner> - reads FM_HARNESS_LIVE_KIND set by fm_harness_pid_alive
  local owner=$1
  case "$FM_HARNESS_LIVE_KIND" in
    codex) printf 'hosted Codex session %s\n' "$owner" ;;
    uninspectable_pid) printf 'uninspectable live holder pid %s\n' "$owner" ;;
    *) printf 'pid %s\n' "$owner" ;;
  esac
}

lock_acquired_line() {  # <owner>
  case "$1" in
    codex:*) printf 'lock acquired: harness %s\n' "$1" ;;
    *) printf 'lock acquired: harness pid %s\n' "$1" ;;
  esac
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(fm_session_lock_owner_read "$STATE") || {
    echo "lock: stale (malformed or invalid owner)"
    exit 0
  }
  if fm_harness_pid_alive "$old"; then
    echo "lock: held by $(lock_holder_description "$old")"
  else
    echo "lock: stale ($old dead or not a harness)"
  fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(fm_session_lock_owner_read "$STATE" || true)
  if [ "$old" = "$me" ]; then
    lock_acquired_line "$me"
    exit 0
  fi
  if fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock ($(lock_holder_error_description "$old")); operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(fm_session_lock_owner_read "$STATE" || true)
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    echo "error: another live firstmate session holds the lock ($(lock_holder_error_description "$old")); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(fm_session_lock_owner_read "$STATE") || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
lock_acquired_line "$me"
