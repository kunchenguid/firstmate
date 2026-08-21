#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes a three-field record whose numeric first line is the verified harness
# process PID found by walking the shell's ancestry, followed by the harness name
# and a stable session identity when the harness exposes one to both hooks and
# ordinary commands.
# A legacy bare numeric record remains valid and keeps the ancestry-only path.
# A record whose bytes are readable but do not parse claims no owner, so it is
# reclaimed like a dead one rather than leaving the home permanently read-only,
# unless its first line still names a live harness process outside this session's
# ancestry - that is a competing owner and keeps the existing refusal.
# An identity-matched reparented session refreshes the PID under the same
# acquisition lock used here; any other case falls back to the ancestry test, so
# a live PID outside this session's ancestry keeps the existing competing-session
# refusal and wording.
# When ancestry proves ownership but the record's identity no longer names this
# session - an in-process /clear or /compact re-identification - this script is
# the ONLY writer that republishes the record, under that same acquisition lock.
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

# The portable claim lock is shared with identity-matched PID refreshes.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Harness, record, identity, ancestry, refresh, and holder liveness are owned by
# the shared session-lock lib so every caller applies the exact same contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# True when the current record already names this session's harness and identity,
# so no republish is owed. A record with no identity, or a session with none, is
# the legacy ancestry contract and is deliberately left byte-for-byte alone.
record_needs_republish() {
  [ -n "$me_identity" ] || return 1
  fm_session_lock_read "$STATE" || return 1
  [ -n "$FM_SESSION_LOCK_IDENTITY" ] || return 1
  [ "$FM_SESSION_LOCK_HARNESS" = "$me_harness" ] || return 1
  [ "$FM_SESSION_LOCK_IDENTITY" != "$me_identity" ]
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  if ! fm_session_lock_read "$STATE"; then
    echo "lock: unreadable"
    exit 0
  fi
  old=$FM_SESSION_LOCK_PID
  if fm_session_lock_owned_by_self "$STATE"; then
    old=$(fm_session_lock_pid "$STATE" 2>/dev/null || printf '%s' "$old")
    echo "lock: held by this session (live harness pid $old)"
  elif fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old"
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
me_harness=$(fm_harness_pid_name "$me") || { echo "error: cannot identify harness process in ancestry" >&2; exit 1; }
me_identity=$(fm_current_session_identity "$me_harness" 2>/dev/null || true)
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
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
  # An owed republish takes the claim lock below rather than writing here, so
  # every structured-record write stays under the single acquisition owner.
  if fm_session_lock_owned_by_self "$STATE"; then
    if ! record_needs_republish; then
      me=$(fm_session_lock_pid "$STATE" 2>/dev/null || printf '%s' "$me")
      echo "lock acquired: harness pid $me"
      exit 0
    fi
  elif fm_session_lock_read "$STATE"; then
    old=$FM_SESSION_LOCK_PID
    if fm_harness_pid_alive "$old"; then
      echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
      exit 1
    fi
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
  if ! cat "$LOCK" >/dev/null 2>&1; then
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  fi
  # Readable bytes that are not a valid record are reclaimed by the fresh write
  # below, under this same claim lock, exactly like a dead recorded owner - but
  # only once they name no owner at all. A mangled record whose first line still
  # names a live harness process outside this session's ancestry names a
  # genuinely competing owner, so it keeps the existing refusal instead.
  if fm_session_lock_read "$STATE"; then
    old=$FM_SESSION_LOCK_PID
    if fm_session_lock_owned_by_self "$STATE"; then
      # Ownership is confirmed and the claim lock is held, so this is where a
      # record whose identity no longer names its live owner - an in-process
      # /clear or /compact re-identification - is republished, and the only place
      # any such write happens.
      if record_needs_republish && ! fm_session_lock_write "$STATE" "$me" "$me_harness" "$me_identity"; then
        echo "error: cannot republish session lock identity; operate read-only until resolved" >&2
        exit 1
      fi
      me=$(fm_session_lock_pid "$STATE" 2>/dev/null || printf '%s' "$me")
      release_claim_lock
      echo "lock acquired: harness pid $me"
      exit 0
    fi
    if fm_harness_pid_alive "$old"; then
      echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
      exit 1
    fi
  elif old=$(fm_session_lock_foreign_live_pid "$STATE"); then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! fm_session_lock_write "$STATE" "$me" "$me_harness" "$me_identity"; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
if ! fm_session_lock_read "$STATE" \
  || [ "$FM_SESSION_LOCK_PID" != "$me" ] \
  || [ "$FM_SESSION_LOCK_HARNESS" != "$me_harness" ] \
  || [ "$FM_SESSION_LOCK_IDENTITY" != "$me_identity" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
echo "lock acquired: harness pid $me"
