#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
#
# A live holder keeps the helm. Acquisition never takes it: this file measures
# nothing about how busy the other session is, and it never stops one. What it
# does guarantee is that the refusal names the holder and the one command that
# clears the recorded helm, so the captain can act on it without guessing.
#
# Usage: fm-lock.sh                 acquire; exit 1 unless ownership is verified
#        fm-lock.sh status          print holder and liveness; always exits 0
#        fm-lock.sh release         release the helm, but only if this session
#                                   holds it; already-free is success
#        fm-lock.sh clear --pid N   captain override: drop the helm recorded for
#                                   pid N without touching that session. Refuses
#                                   unless N is the recorded holder.
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

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_pid_alive "$old"; then
    echo "lock: held by live harness pid $old"
    printf 'clear it with: %s clear --pid %s\n' "$0" "$old"
  else
    echo "lock: stale (pid $old dead or not a harness)"
  fi
  exit 0
fi

if [ "${1:-}" = "release" ]; then
  if [ ! -e "$LOCK" ]; then echo "lock: already free"; exit 0; fi
  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "error: this session does not hold the lock, so it cannot release it; run 'fm-lock.sh status' to see what does" >&2
    exit 1
  fi
  rm -f "$LOCK" 2>/dev/null || {
    echo "error: cannot remove the session lock $LOCK" >&2
    exit 1
  }
  echo "lock released: this session no longer holds the helm"
  exit 0
fi

# The captain override. It drops the RECORDED helm and nothing else: the other
# session keeps running, which is why the message says to quit it. Requiring the
# holder pid means a stale reading of "status" cannot clear a helm that has since
# changed hands.
if [ "${1:-}" = "clear" ]; then
  shift
  want=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --pid) shift; want=${1:-} ;;
      *) echo "usage: fm-lock.sh clear --pid <holder-pid>" >&2; exit 2 ;;
    esac
    shift
  done
  case "$want" in
    ''|*[!0-9]*) echo "usage: fm-lock.sh clear --pid <holder-pid>" >&2; exit 2 ;;
  esac
  if [ ! -f "$LOCK" ]; then echo "lock: already free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; remove $LOCK by hand after checking what holds it" >&2
    exit 1
  }
  if [ "$old" != "$want" ]; then
    echo "error: pid $want does not hold the lock (pid $old does); re-read 'fm-lock.sh status' before clearing" >&2
    exit 1
  fi
  rm -f "$LOCK" 2>/dev/null || {
    echo "error: cannot remove the session lock $LOCK" >&2
    exit 1
  }
  printf 'lock cleared: pid %s no longer holds the helm. That session is still running and was not touched - quit it so two sessions do not work the same fleet.\n' "$old"
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
  old=$(cat "$LOCK" 2>/dev/null || true)
  if [ "$old" = "$me" ]; then
    echo "lock acquired: harness pid $me"
    exit 0
  fi
  if fm_harness_pid_alive "$old"; then
    {
      echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved"
      printf 'clear it with: %s clear --pid %s - that drops the recorded helm without touching the other session, so quit that session too.\n' "$0" "$old"
    } >&2
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
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old"; then
    {
      echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved"
      printf 'clear it with: %s clear --pid %s - that drops the recorded helm without touching the other session, so quit that session too.\n' "$0" "$old"
    } >&2
    exit 1
  fi
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
release_claim_lock
echo "lock acquired: harness pid $me"
