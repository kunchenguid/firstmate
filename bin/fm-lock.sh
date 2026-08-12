#!/usr/bin/env bash
# Acquire or inspect the per-home Firstmate session lock.
# Writes a verified harness PID. Codex adds its stable thread marker and whether
# the PID came from verified ancestry or a PID-isolated fallback.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
#
# This script is the ONLY writer of state/.lock. The owner record is never
# hand-edited, and acquisition never displaces a live holder: an existing lock
# naming another live harness refuses, and a declared task worker
# (bin/fm-worker-isolation-lib.sh) refuses acquisition before touching the
# record at all. Read-only status remains available to task workers.
# A task child that inherited a primary's FM_HOME would otherwise resolve THIS
# home's state directory and take the primary's own session ownership - the
# 2026-07-24 incident where a suspended-then-resumed primary came back locked
# out of its own home and stopped monitoring.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

SECOND_MATE_SESSION=0
fm_worker_declared_secondmate_proven && SECOND_MATE_SESSION=1
LOCK="$STATE/.lock"

# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = bootstrap ]; then
  fm_worker_refuse_primary_initialization "session lock initialization" || exit 1
  if [ "$SECOND_MATE_SESSION" -eq 0 ]; then
    fm_worker_primary_attestation_prepare || {
      echo "error: could not prepare primary authorization; refusing session lock initialization" >&2
      exit 1
    }
  fi
elif [ "${1:-}" != status ]; then
  fm_worker_refuse_unproven_session_entry "session lock acquisition" || exit 1
fi

if [ "${1:-}" = status ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || { echo "lock: unreadable"; exit 0; }
  fm_session_lock_holder_state "$old"
  holder_status=$?
  case "$holder_status" in
    0) case "$old" in
         *'|codex:'*) echo "lock: held by live Codex session owner $old" ;;
         *) echo "lock: held by live harness pid $old" ;;
       esac ;;
    1) echo "lock: stale (owner $old dead or not a harness)" ;;
    2) echo "lock: held by unverifiable Codex session owner $old" ;;
    *) echo "lock: invalid owner record; manual inspection required" ;;
  esac
  exit 0
fi

mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

owner=$(fm_session_lock_owner) || {
  echo "error: cannot locate harness process in ancestry" >&2
  exit 1
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
FM_SESSION_LOCK_BOOTSTRAP=1
. "$SCRIPT_DIR/fm-wake-lib.sh"
unset FM_SESSION_LOCK_BOOTSTRAP
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
fm_lock_acquire_wait "$CLAIM_LOCK" || {
  echo "error: could not serialize session lock acquisition; operate read-only until resolved" >&2
  exit 1
}
CLAIM_LOCK_HELD=1

previous_lock_present=0
previous_lock_content=
if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  previous_lock_content=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  previous_lock_present=1
fi

rollback_session_lock() {
  local current
  [ -f "$LOCK" ] && [ ! -L "$LOCK" ] || return 0
  current=$(cat "$LOCK" 2>/dev/null || true)
  [ "$current" = "$owner" ] || return 0
  if [ "$previous_lock_present" -eq 1 ]; then
    printf '%s\n' "$previous_lock_content" > "$LOCK"
  else
    rm -f -- "$LOCK"
  fi
}

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  old_marker=$(fm_codex_owner_marker "$old" 2>/dev/null || true)
  owner_marker=$(fm_codex_owner_marker "$owner" 2>/dev/null || true)
  if [ -n "$old_marker" ] && [ "$old_marker" = "$owner_marker" ]; then
    owner=$old
  elif [ "$old" = "${owner%%|*}" ] && [ -n "$owner_marker" ]; then
    :
  elif [ "$old" != "$owner" ]; then
    fm_session_lock_holder_state "$old"
    holder_status=$?
    case "$holder_status" in
      0)
        echo "error: another live firstmate session holds the lock (owner $old); operate read-only until resolved" >&2
        exit 1 ;;
      2)
        echo "error: cannot verify whether another Codex session holds the lock (owner $old); operate read-only until resolved" >&2
        exit 1 ;;
      3)
        echo "error: session lock has an invalid owner record; operate read-only until resolved" >&2
        exit 1 ;;
    esac
  fi
fi
publication_tmp=$(mktemp "$STATE/.lock-publish.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
if ! printf '%s\n' "$owner" > "$publication_tmp" 2>/dev/null \
  || ! mv -f -- "$publication_tmp" "$LOCK" 2>/dev/null; then
  rm -f -- "$publication_tmp" 2>/dev/null || true
  rollback_session_lock
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  rollback_session_lock
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$owner" ]; then
  rollback_session_lock
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
if [ "$SECOND_MATE_SESSION" -eq 0 ]; then
  primary_root=$(fm_worker_canonical_path "$FM_ROOT" 2>/dev/null || true)
  if [ -z "$primary_root" ] || ! fm_worker_primary_attestation_matches "$primary_root"; then
    rollback_session_lock
    echo "error: primary authorization no longer matches the session entry; operate read-only until resolved" >&2
    exit 1
  fi
fi
if [ "$SECOND_MATE_SESSION" -eq 0 ] && [ -z "${FM_PRIMARY_ATTESTATION:-}" ]; then
  rollback_session_lock
  echo "error: primary authorization was not established; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
case "$owner" in
  *'|codex:'*) echo "lock acquired: Codex session owner $owner" ;;
  *) echo "lock acquired: harness pid $owner" ;;
esac
