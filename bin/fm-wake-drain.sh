#!/usr/bin/env bash
# Atomically drain durable watcher wake records, then assert watcher liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false

# Intake answers before draining their redundant wake pointers.
# The intake command scans only durable answer files without receipts, writes
# each declared destination first, then writes its receipt.
# Failure is visible but cannot block unrelated fleet wakes from draining.
LAVISH_INTAKE_OUT=$("$SCRIPT_DIR/fm-lavish-intake.sh" 2>&1)
LAVISH_INTAKE_RC=$?
if [ -n "$LAVISH_INTAKE_OUT" ]; then
  printf 'LAVISH_INTAKE:\n%s\n' "$LAVISH_INTAKE_OUT"
fi
if [ "$LAVISH_INTAKE_RC" -ne 0 ]; then
  printf 'LAVISH_INTAKE: failed with status %s; durable answers remain unreceipted\n' \
    "$LAVISH_INTAKE_RC" >&2
fi

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's existing graced, beacon-based banner (FM_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local status=$?
  if [ "$status" -ne 0 ] && [ "$DRAIN_LOCK_HELD" = true ] && [ -n "$DRAIN_TMP" ] && [ -e "$DRAIN_TMP" ]; then
    fm_wake_restore_queue "$DRAIN_TMP" || true
  fi
  if [ "$DRAIN_LOCK_HELD" = true ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=true

if ! fm_wake_safe_file_destination "$FM_WAKE_QUEUE"; then
  echo "error: unsafe wake queue destination: $FM_WAKE_QUEUE" >&2
  exit 1
fi

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP=$(mktemp "$STATE/.wake-queue.drain.XXXXXX") || exit 1
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
if ! fm_wake_safe_file_destination "$FM_WAKE_QUEUE"; then
  exit 1
fi
: > "$FM_WAKE_QUEUE" || exit 1

fm_wake_print_deduped "$DRAIN_TMP" || exit "$?"
rm -f "$DRAIN_TMP"
DRAIN_TMP=
assert_watcher_liveness
exit 0
