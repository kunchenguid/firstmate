#!/usr/bin/env bash
# Atomically drain durable watcher wake records, optionally annotate validated
# signal status keys after raw consumption commits, then assert liveness.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false
RAW_ROWS=

# Defense in depth for the supervision chain: this script runs at the top of
# every wake-handling and recovery turn, so assert supervision health here too. A
# lapsed supervision chain then surfaces on a plain drain-and-handle turn, not
# only when a guarded supervision script (fm-peek/fm-send/...) happens to run.
# Reuse fm-guard.sh's model-aware alarm and FM_GUARD_GRACE instead of duplicating
# its supervision verdict. Under Claude's between-turns auto-arm model, a normal
# fire leaves a recent beacon well inside grace and stays silent mid-turn. Under
# persistent-watcher models, the guard also requires the live identity-matched
# watcher. Call after the queue is emptied so guard never re-prints its own
# queued-wakes notice for the records this run just drained, and never let a
# guard hiccup change the drain's exit status.
assert_watcher_liveness() {
  "$SCRIPT_DIR/fm-guard.sh" || true
}

# Print the consolidated OPEN DECISIONS section: every still-open
# needs-decision/blocked, fleet-wide, folded from the durable status logs by
# fm-classify-lib.sh's status_open_decisions fold (via its cursor-backed
# scan_open_decisions_incremental wrapper) rather than from the latest-line
# annotations above, so a decision buried under later unrelated appends cannot
# be silently missed. Runs on every drain - including the empty-queue fast path
# - because the decision can still be open even when nothing new is queued for
# its task this turn. The incremental wrapper bounds this scan's cost to bytes
# appended to each task's status log since the LAST drain, not that log's whole
# lifetime, while still never dropping an old buried decision (see
# fm-classify-lib.sh's "incremental (cursor-backed) open-decisions fold").
# Bounded and silent: prints nothing when no decision is open, which is the
# common case.
print_open_decisions_section() {
  local open task key verb note line item_bytes=220 global_bytes=4000
  local output='' used=0 shown=0 omitted=0 bytes suffix keep

  open=$(scan_open_decisions_incremental "$STATE") || return 0
  [ -n "$open" ] || return 0

  while IFS=$(printf '\t') read -r task key verb note; do
    [ -n "$task" ] || continue
    line="$task"
    [ "$key" = default ] || line="$line [key=$key]"
    line="$line $verb: $note"
    if [ $(( ${#line} + 1 )) -gt "$item_bytes" ]; then
      suffix=' [truncated]'
      keep=$((item_bytes - ${#suffix} - 1))
      line="${line:0:$keep}$suffix"
    fi
    bytes=$(( ${#line} + 1 ))
    if [ $((used + bytes)) -gt "$global_bytes" ]; then
      omitted=$((omitted + 1))
      continue
    fi
    output="$output$line
"
    used=$((used + bytes))
    shown=$((shown + 1))
  done <<EOF
$open
EOF

  [ "$shown" -gt 0 ] || [ "$omitted" -gt 0 ] || return 0
  printf 'OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):\n'
  printf '%s' "$output"
  if [ "$omitted" -gt 0 ]; then
    printf 'OPEN DECISIONS: %d more omitted (byte cap)\n' "$omitted"
  fi
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
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  DRAIN_LOCK_HELD=false
  (print_open_decisions_section) || true
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
rm -f "$DRAIN_TMP" || exit "$?"
DRAIN_TMP=
fm_lock_release "$FM_WAKE_QUEUE_LOCK"
DRAIN_LOCK_HELD=false

# Raw output and queue deletion are authoritative. Everything below is
# best-effort and cannot restore, duplicate, hide, or fail the consumed rows.
(fm_wake_print_annotations "$RAW_ROWS") || true
(print_open_decisions_section) || true
assert_watcher_liveness
exit 0
