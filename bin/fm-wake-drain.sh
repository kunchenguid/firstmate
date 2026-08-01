#!/usr/bin/env bash
# Atomically drain durable watcher wake records, preserve the consumed queue and
# its digest-bound receipt, reconcile verified terminal status signals, optionally
# annotate validated status keys after raw consumption commits, then assert
# liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-custody-lib.sh
. "$SCRIPT_DIR/fm-custody-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

DRAIN_TMP=
DRAIN_LOCK_HELD=false
RAW_ROWS=

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert watcher liveness here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's existing graced, beacon-based alarm (FM_GUARD_GRACE) - do
# not duplicate the beacon math. Because the watcher touches its beacon every
# poll cycle, a normal fire leaves a recent beacon well inside grace and stays
# silent; only a genuine stale-beyond-grace lapse with work in flight warns. Call
# after the queue is emptied so guard never re-prints its own queued-wakes notice
# for the records this run just drained, and never let a guard hiccup change the
# drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# A terminal status wake is the ordinary completion path, so reconcile its
# structured row in the same turn rather than waiting for session restart.
# Status keys are structurally mapped and read without following symlinks; queue
# payload prose never supplies a path. Nonterminal signals remain read-only.
reconcile_terminal_status_wakes() {  # <deduped-raw-rows>
  local rows=$1 epoch seq kind key payload receipt
  while IFS=$(printf '\t') read -r epoch seq kind key payload; do
    [ "$kind" = signal ] || continue
    fm_wake_status_key_map "$key" || continue
    fm_wake_latest_event "$STATE/$FM_WAKE_STATUS_KEY" 65536 || continue
    if status_is_done "$FM_WAKE_EVENT_LINE" || status_is_awaiting_captain "$FM_WAKE_EVENT_LINE"; then
      receipt=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
        "$SCRIPT_DIR/fm-record-reconcile.sh") || return 1
      [ -z "$receipt" ] || printf 'record reconciliation: %s\n' "$receipt"
      return 0
    fi
  done <<EOF
$rows
EOF
  return 0
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

if [ ! -s "$FM_WAKE_QUEUE" ]; then
  : > "$FM_WAKE_QUEUE"
  assert_watcher_liveness
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(fm_current_pid)"
rm -f "$DRAIN_TMP"
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$FM_WAKE_QUEUE" || exit 1

RAW_ROWS=$(fm_wake_print_deduped "$DRAIN_TMP") || exit "$?"
case "${FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT:-0}" in
  0) ;;
  ''|*[!0-9]*) ;;
  *) sleep "$FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT" ;;
esac
if [ -n "$RAW_ROWS" ]; then
  # Print-before-delete is the deliberate at-least-once no-loss boundary: a
  # crash in this micro-gap may replay a wake, and annotations stay outside it.
  printf '%s\n' "$RAW_ROWS" || exit "$?"
fi
source_ref=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf 'unversioned-firstmate-root')
fm_custody_preserve "$DRAIN_TMP" "$DATA/wake-receipts" \
  "$source_ref:$(basename "$FM_WAKE_QUEUE")" consumed-wake-queue >/dev/null || exit 1
rm -f "$DRAIN_TMP" || exit "$?"
DRAIN_TMP=
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false

# Raw output, custody, and queue retirement are authoritative. Reconciliation
# below may fail the command visibly but can never restore, duplicate, or hide
# the already receipt-bound consumed rows. Annotation and liveness remain
# best-effort even after reconciliation failure.
reconcile_status=0
reconcile_terminal_status_wakes "$RAW_ROWS" || reconcile_status=$?
(fm_wake_print_annotations "$RAW_ROWS") || true
assert_watcher_liveness
exit "$reconcile_status"
