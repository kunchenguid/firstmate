#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
#
# state/.lock stays a bare pid for every other reader. Alongside it, each acquire
# records state/.lock-owner, which is what proves that pid belongs to a firstmate
# session started in THIS home rather than to any unrelated process that happens
# to carry a verified harness command name or to have inherited a recycled pid.
# bin/fm-session-lock-lib.sh owns that record's format and verification.
#
# A lock DISPROVED by that record - the record names this exact pid, and the
# process now at it is not the one the record pinned - is never fatal: it is
# reclaimed with a note naming the process that had been holding the home.
#
# A lock this home cannot vouch for either way is a different thing entirely,
# and is never reclaimed: no record at all is what a session which acquired its
# lock before owner records existed looks like while it is still genuinely
# running, and a record about some other pid says nothing about this one.
# Evicting either would put two sessions in one home. Both are refused with the
# process named, so the operator can see whether it is their own session (which
# repairs its own record the next time it touches the lock) or something to
# quit. fm_session_lock_reclaimable is the single predicate that decides.
#
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

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

# One line naming what actually holds the lock, so an operator inspecting a
# refusal can find that process instead of being handed a bare number.
owner_detail() {
  local detail=''
  [ -z "$FM_LOCK_OWNER_COMMAND" ] || detail=" ($FM_LOCK_OWNER_COMMAND)"
  [ -z "$FM_LOCK_OWNER_SINCE" ] || detail="$detail, holding this home since $FM_LOCK_OWNER_SINCE"
  printf '%s' "$detail"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ]; then echo "lock: free"; exit 0; fi
  if fm_session_lock_live_owner "$STATE"; then
    echo "lock: held by live harness pid $FM_LOCK_OWNER_PID$(owner_detail)"
    exit 0
  fi
  case "$FM_LOCK_OWNER_STATUS" in
    free) echo "lock: free" ;;
    malformed) echo "lock: unreadable" ;;
    dead) echo "lock: stale (pid $FM_LOCK_OWNER_PID dead or not a harness)" ;;
    reused)
      echo "lock: stale (pid $FM_LOCK_OWNER_PID was recycled and now belongs to an unrelated process$(owner_detail)); the next session start reclaims it" ;;
    unrecorded)
      echo "lock: unconfirmed (pid $FM_LOCK_OWNER_PID$(owner_detail) is a live harness process, but this home holds no ownership record for it); it is held, not reclaimed" ;;
    *)
      echo "lock: unconfirmed (pid $FM_LOCK_OWNER_PID$(owner_detail) is a live harness process, but this home's only ownership record is for a different pid); it is held, not reclaimed" ;;
  esac
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

refuse_live_owner() {
  echo "error: another live firstmate session holds the lock: pid $FM_LOCK_OWNER_PID$(owner_detail); operate read-only until resolved" >&2
  exit 1
}

# An owner this home cannot vouch for is still not evidence that it is not a
# session. Say what is actually known about the process now at that pid, name it
# so the operator can decide, and never take the home from it.
refuse_unconfirmed_owner() {
  local because
  case "$FM_LOCK_OWNER_STATUS" in
    unrecorded) because="this home holds no ownership record for it" ;;
    *) because="this home's only ownership record is for a different pid, which says nothing about this one" ;;
  esac
  echo "error: the session lock names live harness pid $FM_LOCK_OWNER_PID$(owner_detail), and $because, so it cannot be taken over safely: if that is a firstmate session it keeps the home and repairs its own record, and if it is not, quit it or remove $LOCK; operate read-only until resolved" >&2
  exit 1
}

refuse_blocking_owner() {
  case "$FM_LOCK_OWNER_STATUS" in
    unrecorded|unverified) refuse_unconfirmed_owner ;;
  esac
  refuse_live_owner
}

# Why this lock is being taken over, when it was held by something that failed
# verification. Reported after the claim so the operator can connect a home that
# had gone read-only to the process that was actually responsible.
RECLAIMED_FROM=''
note_reclaim() {
  case "$FM_LOCK_OWNER_STATUS" in
    reused)
      RECLAIMED_FROM="note: reclaimed the session lock from pid $FM_LOCK_OWNER_PID$(owner_detail): that pid was recycled and now belongs to an unrelated process." ;;
    *) RECLAIMED_FROM='' ;;
  esac
}

if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    # Our own lock, but only shortcut past the claim when its owner record backs
    # that up. A lock of ours carrying no verifiable record is republished below,
    # so a later session can tell this session apart from a pid collision.
    if fm_session_lock_live_owner "$STATE" && [ "$FM_LOCK_OWNER_PID" = "$me" ]; then
      echo "lock acquired: harness pid $me"
      exit 0
    fi
  elif ! fm_session_lock_reclaimable "$STATE"; then
    refuse_blocking_owner
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
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ]; then
    if ! fm_session_lock_reclaimable "$STATE"; then
      refuse_blocking_owner
    fi
    note_reclaim
  fi
fi
if ! fm_session_lock_record_owner "$STATE" "$me"; then
  echo "error: cannot record session-lock ownership; operate read-only until resolved" >&2
  exit 1
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
if ! fm_session_lock_live_owner "$STATE" || [ "$FM_LOCK_OWNER_PID" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
release_claim_lock
[ -z "$RECLAIMED_FROM" ] || printf '%s\n' "$RECLAIMED_FROM"
echo "lock acquired: harness pid $me"
