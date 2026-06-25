#!/usr/bin/env bash
# Persistent firstmate watcher loop.
#
# bin/fm-watch.sh is intentionally one-shot: it exits after one wake reason.
# bin/fm-watch-arm.sh preserves that contract for harnesses that re-arm tracked
# background tasks after exit. This loop is the explicit fallback for harnesses
# that do not: run this script as one long-lived harness-tracked background task
# and it will restart the one-shot watcher after each wake.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

WATCH="$SCRIPT_DIR/fm-watch.sh"
LOOP_LOCK="$STATE/.watch-loop.lock"
LOG="$STATE/.watch-loop.log"
WATCHER_PID=
CUR_TMP=

is_wake_reason() {
  case "$1" in
    signal:*|stale:*|check:*|heartbeat|heartbeat:*) return 0 ;;
    *) return 1 ;;
  esac
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null || true
}

cleanup() {
  trap - TERM INT HUP
  if [ -n "${WATCHER_PID:-}" ] && fm_pid_alive "$WATCHER_PID"; then
    kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  [ -n "${CUR_TMP:-}" ] && rm -f "$CUR_TMP" 2>/dev/null || true
  fm_lock_release "$LOOP_LOCK" 2>/dev/null || true
  log "loop stopped"
  exit 0
}
trap cleanup TERM INT HUP

if ! fm_lock_try_acquire "$LOOP_LOCK"; then
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    echo "watch-loop: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watch-loop: already running"
  fi
  exit 0
fi

echo "watch-loop: started pid=${BASHPID:-$$}"
log "loop started pid ${BASHPID:-$$}"

while :; do
  CUR_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-watch-loop.XXXXXX") || {
    echo "watch-loop: mktemp failed; retrying" >&2
    sleep 5
    continue
  }

  "$WATCH" >"$CUR_TMP" &
  WATCHER_PID=$!
  if wait "$WATCHER_PID"; then
    rc=0
  else
    rc=$?
  fi
  WATCHER_PID=

  reason=""
  [ -e "$CUR_TMP" ] && reason=$(<"$CUR_TMP")
  rm -f "$CUR_TMP" 2>/dev/null || true
  CUR_TMP=

  if [ "$rc" -ne 0 ]; then
    echo "watch-loop: watcher exited rc=$rc; retrying" >&2
    log "watcher exited rc=$rc reason='$reason'"
    sleep "${FM_WATCH_LOOP_RETRY_SLEEP:-5}"
    continue
  fi

  if [ -z "$reason" ]; then
    echo "watch-loop: watcher exited without a wake; retrying" >&2
    log "watcher exited without a wake"
    sleep "${FM_WATCH_LOOP_RETRY_SLEEP:-5}"
    continue
  fi

  if is_wake_reason "$reason"; then
    printf '%s\n' "$reason"
    log "wake: $reason"
    continue
  fi

  # A singleton status line means another watcher currently owns the one-shot
  # lock. Stay alive and retry instead of treating it as a wake.
  echo "watch-loop: $reason" >&2
  log "non-wake watcher output: $reason"
  sleep "${FM_WATCH_LOOP_RETRY_SLEEP:-5}"
done
