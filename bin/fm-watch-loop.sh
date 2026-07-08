#!/usr/bin/env bash
# Persistent present-mode watcher loop.
#
# This is the Codex-safe fallback for surfaces where a one-shot background
# watcher can exit without waking the assistant turn. It does not inject into the
# chat and it does not enable away-mode semantics. It owns only a local loop:
# run fm-watch.sh, drain any queued wake records it surfaces, immediately re-arm,
# and keep a loop liveness beacon fresh while the watcher child blocks.
#
# Usage: fm-watch-loop.sh
#   Run as one long-lived foreground/background command in the operator's
#   supervision surface. It prints only material events: startup, drained wake
#   records, watcher errors, and shutdown. Stop it with Ctrl-C/SIGTERM.
#
# State:
#   state/.watch-loop.lock   singleton lock for this present-mode loop
#   state/.watch-loop-beat   liveness beacon, touched while the loop is healthy
#   state/.watch-loop.log    event log
#   state/.watch-loop.err    watcher stderr
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

LOOP_PATH="$SCRIPT_DIR/fm-watch-loop.sh"
WATCH="$SCRIPT_DIR/fm-watch.sh"
DRAIN="$SCRIPT_DIR/fm-wake-drain.sh"
LOOP_LOCK="$STATE/.watch-loop.lock"
LOOP_BEAT="$STATE/.watch-loop-beat"
LOOP_LOG="$STATE/.watch-loop.log"
WATCH_ERR="$STATE/.watch-loop.err"
TICK=${FM_WATCH_LOOP_TICK:-2}
IDLE_SLEEP=${FM_WATCH_LOOP_IDLE_SLEEP:-5}
ERROR_SLEEP=${FM_WATCH_LOOP_ERROR_SLEEP:-5}

case "${1:-}" in
  '') ;;
  -h|--help)
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) echo "usage: $(basename "$0")" >&2; exit 2 ;;
esac

case "$TICK" in ''|*[!0-9.]*|0) TICK=2 ;; esac
case "$IDLE_SLEEP" in ''|*[!0-9.]*|0) IDLE_SLEEP=5 ;; esac
case "$ERROR_SLEEP" in ''|*[!0-9.]*|0) ERROR_SLEEP=5 ;; esac

[ -x "$WATCH" ] || { echo "watch-loop: FAILED - watcher not executable: $WATCH" >&2; exit 1; }
[ -x "$DRAIN" ] || { echo "watch-loop: FAILED - wake drain not executable: $DRAIN" >&2; exit 1; }

if [ -e "$STATE/.afk" ]; then
  echo "watch-loop: refused - state/.afk is present; away-mode daemon owns watcher supervision"
  exit 1
fi

if ! fm_lock_try_acquire "$LOOP_LOCK"; then
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    echo "watch-loop: already running pid=$FM_LOCK_HELD_PID"
  else
    echo "watch-loop: already running"
  fi
  exit 0
fi

printf '%s\n' "$FM_HOME" > "$LOOP_LOCK/fm-home" || true
printf '%s\n' "$LOOP_PATH" > "$LOOP_LOCK/loop-path" || true
fm_pid_identity "${BASHPID:-$$}" > "$LOOP_LOCK/pid-identity" 2>/dev/null || true

child=
child_out=
status=

log_event() {
  local msg=$1
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$msg" >> "$LOOP_LOG" 2>/dev/null || true
}

say() {
  local msg=$1
  log_event "$msg"
  printf 'watch-loop: %s\n' "$msg"
}

cleanup() {
  trap - TERM INT HUP
  if [ -n "${child:-}" ] && fm_pid_alive "$child"; then
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  [ -n "${child_out:-}" ] && rm -f "$child_out" 2>/dev/null || true
  fm_lock_release "$LOOP_LOCK" 2>/dev/null || true
  log_event "stopped"
  exit 0
}
trap cleanup TERM INT HUP

touch "$LOOP_BEAT"
say "started pid=${BASHPID:-$$} (present-mode persistent re-arm; no AFK injection)"

drain_if_pending() {
  [ -s "$FM_WAKE_QUEUE" ] || return 0
  say "draining queued wakes"
  "$DRAIN"
}

output_has_wake() {
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$1" 2>/dev/null
}

last_status=
while :; do
  if [ -e "$STATE/.afk" ]; then
    say "stopping because state/.afk appeared; away-mode daemon owns watcher supervision"
    cleanup
  fi

  touch "$LOOP_BEAT"
  drain_if_pending
  touch "$LOOP_BEAT"

  child_out=$(mktemp "$STATE/.watch-loop-output.XXXXXX") || {
    say "FAILED - mktemp could not create watcher output file; retrying in ${ERROR_SLEEP}s"
    sleep "$ERROR_SLEEP"
    continue
  }
  "$WATCH" >"$child_out" 2>>"$WATCH_ERR" &
  child=$!

  while fm_pid_alive "$child"; do
    touch "$LOOP_BEAT"
    sleep "$TICK"
  done

  rc=0
  wait "$child" || rc=$?
  child=
  touch "$LOOP_BEAT"

  if output_has_wake "$child_out"; then
    last_status=
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        signal:*|stale:*|check:*|heartbeat|heartbeat:*) say "wake $line" ;;
        '') ;;
        *) say "watcher status $line" ;;
      esac
    done < "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child_out=
    drain_if_pending
    continue
  fi

  status=$(cat "$child_out" 2>/dev/null || true)
  rm -f "$child_out" 2>/dev/null || true
  child_out=

  if [ "$rc" -ne 0 ]; then
    say "watcher exited rc=$rc${status:+ ($status)}; retrying in ${ERROR_SLEEP}s"
    sleep "$ERROR_SLEEP"
    continue
  fi

  if [ -n "$status" ] && [ "$status" != "$last_status" ]; then
    say "watcher status $status"
    last_status=$status
  fi
  sleep "$IDLE_SLEEP"
done
