#!/usr/bin/env bash
# Atomically drain durable watcher wake records.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

DRAIN_TMP=
DRAIN_LOCK_HELD=false

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
  exit 0
fi

DRAIN_TMP="$STATE/.wake-queue.drain.$(fm_current_pid)"
rm -f "$DRAIN_TMP"
mv "$FM_WAKE_QUEUE" "$DRAIN_TMP" || exit 1
: > "$FM_WAKE_QUEUE" || exit 1

fm_wake_print_deduped "$DRAIN_TMP" || exit "$?"

# Loop observability (spec: docs/specs/2026-07-03-loop-conformance.md):
# append one run-log JSON line and stamp STATE.md's Last run. Best-effort and
# fully guarded - a failed log write must NEVER perturb the drain contract
# (locking, dedup output, exit codes). Disable with FM_LOOP_LOG=0.
if [ "${FM_LOOP_LOG:-1}" != 0 ]; then
  {
    items=$(grep -c . "$DRAIN_TMP") || items=0
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '{"run_id":"drain-%s","pattern":"firstmate-watch","duration_s":0,"items_found":%s,"actions_taken":0,"escalations":0,"tokens_estimate":0,"outcome":"report-only","ts":"%s"}\n' \
      "$(fm_current_pid)" "$items" "$ts" >> "$FM_HOME/loop-run-log.md"
    if [ -f "$FM_HOME/STATE.md" ]; then
      stamp_tmp="$FM_HOME/.state-md.stamp.$(fm_current_pid)"
      sed "s/^Last run:.*/Last run: $ts/" "$FM_HOME/STATE.md" > "$stamp_tmp" \
        && mv "$stamp_tmp" "$FM_HOME/STATE.md"
      rm -f "$stamp_tmp"
    fi
  } 2>/dev/null || true
fi

rm -f "$DRAIN_TMP"
DRAIN_TMP=
exit 0
