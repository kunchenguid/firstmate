#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
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

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if fm_harness_pid_alive "$old" "$STATE"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
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
# Set the moment $LOCK is written with $me, cleared only once the whole
# publication contract (ownership verification and, for an omp holder, the
# fm_harness_record_omp_claude marker) has completed. If this script is
# interrupted anywhere in between - a signal, an unexpected error, a crash -
# the EXIT trap below still fires and must not leave that half-published
# $LOCK behind: a foreign checker has no way to tell a genuinely interrupted
# write apart from a legitimately live one, and for an omp holder specifically
# it cannot verify liveness at all without the marker this invocation never
# got to write (see fm_harness_pid_alive). Rolling the write back makes an
# interrupted acquisition look exactly like one that never started.
LOCK_PUBLISHED_BY_ME=0
LOCK_PUBLISH_COMPLETE=0
release_claim_lock() {
  if [ "$LOCK_PUBLISHED_BY_ME" -eq 1 ] && [ "$LOCK_PUBLISH_COMPLETE" -ne 1 ]; then
    rm -f "$LOCK" 2>/dev/null || true
    LOCK_PUBLISHED_BY_ME=0
  fi
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
  if fm_harness_pid_alive "$old" "$STATE"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
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
  if [ "$old" != "$me" ] && fm_harness_pid_alive "$old" "$STATE"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
LOCK_PUBLISHED_BY_ME=1
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
# A foreign session cannot later read $me's own $CLAUDECODE to verify an omp
# identity (see fm_harness_pid_alive), so persist that verification now, in
# the one context - the writer's own environment, immediately after winning
# the lock - where it is sound evidence. Runs on every acquisition, omp or
# not, so a non-omp session correctly clears any stale prior record. A write
# failure here means no foreign session can ever prove $me alive, so it must
# fail the whole acquisition rather than leave $LOCK claiming an identity
# nothing else can verify. LOCK_PUBLISH_COMPLETE stays unset on this path, so
# the EXIT trap's rollback removes $LOCK - the same rollback that also covers
# a signal or crash landing anywhere between the write above and here - and a
# later invocation from this same session cannot short-circuit past the
# broken marker write via the "$old" = "$me" fast path above.
if ! fm_harness_record_omp_claude "$STATE" "$me"; then
  echo "error: cannot persist omp session-lock identity marker; operate read-only until resolved" >&2
  exit 1
fi
LOCK_PUBLISH_COMPLETE=1
release_claim_lock
echo "lock acquired: harness pid $me"
