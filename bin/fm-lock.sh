#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process identity found by walking the shell's
# ancestry, or by reading a verified host marker when ancestry is sandboxed.
# A PID identity lives as long as the firstmate session - unlike the transient
# subshell PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh                     acquire; exit 1 unless ownership is verified
#        fm-lock.sh status              print holder and liveness; always exits 0
#        fm-lock.sh reclaim <identity>  take over a marker lock left behind by a
#                                       session that is confirmed gone
# A marker identity ("<harness>:<session-id>") can only be proven live by the
# session that owns it, so a marker lock left behind by a dead sandboxed session
# is otherwise unreclaimable. reclaim is the deliberate remediation: the caller
# must name the recorded holder exactly, and it never overrides a numeric holder
# that is provably a live harness process.
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

# Whole minutes since the lock was last written. Every acquire rewrites the
# file, so this is the holder's most recent proof of life. It is reported as a
# staleness hint only and never evicts a holder on its own.
lock_age_minutes() {
  local mtime now
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$LOCK" 2>/dev/null) || return 1
  else
    mtime=$(stat -c %Y "$LOCK" 2>/dev/null) || return 1
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$mtime" ] || return 1
  printf '%s\n' $(( (now - mtime) / 60 ))
}

marker_lock_hint() {  # <identity>
  local age
  if age=$(lock_age_minutes); then
    printf 'last refreshed %s min ago; if that session is confirmed gone, reclaim it with: bin/fm-lock.sh reclaim %s' "$age" "$1"
  else
    printf 'if that session is confirmed gone, reclaim it with: bin/fm-lock.sh reclaim %s' "$1"
  fi
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  case "$old" in
    *:*)
      if fm_harness_pid_alive "$old"; then echo "lock: held by current harness marker $old"; else echo "lock: held by different or unverifiable harness marker $old ($(marker_lock_hint "$old"))"; fi
      ;;
    *)
      if fm_harness_pid_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
      ;;
  esac
  exit 0
fi

RECLAIM_IDENT=
if [ "${1:-}" = "reclaim" ]; then
  RECLAIM_IDENT="${2:-}"
  case "$RECLAIM_IDENT" in
    *:*) ;;
    *)
      echo "usage: fm-lock.sh reclaim <recorded-marker-identity>; run bin/fm-lock.sh status to read the recorded holder" >&2
      exit 1
      ;;
  esac
fi

me=$(fm_harness_ancestry_pid) || { echo "error: cannot locate harness process in ancestry or verified host marker" >&2; exit 1; }
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
fm_lock_acquire_wait "$CLAIM_LOCK"
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
    case "$old" in
      *:*)
        if [ -n "$RECLAIM_IDENT" ] && [ "$RECLAIM_IDENT" = "$old" ]; then
          echo "reclaiming marker lock $old on the caller's confirmation that its session is gone"
        else
          echo "error: another firstmate session holds an unverifiable marker lock ($old); operate read-only until resolved ($(marker_lock_hint "$old"))" >&2
          exit 1
        fi
        ;;
      *)
        if fm_harness_pid_alive "$old"; then
          echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
          exit 1
        fi
        ;;
    esac
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
echo "lock acquired: harness identity $me"
