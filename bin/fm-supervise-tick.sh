#!/usr/bin/env bash
# One supervision tick: fleet status, wake drain, and a CONDITIONAL
# acknowledgement - in one call, for the quiet-checkpoint turns that would
# otherwise spend three or four tool calls repeating the same shape.
#
# Usage: fm-supervise-tick.sh
#
# What it does:
#   1. Prints the last status line of every live task (state/*.status).
#   2. Runs bin/fm-wake-drain.sh once.
#   3. When the drain shows an EMPTY queue (nothing but the ack line with
#      --ack-through 0 and at most informational annotations), it runs the
#      printed ack command itself and reports `tick: quiet, acked`.
#      When the queue holds real wakes (any ack-through greater than 0), it
#      prints them and exits WITHOUT acknowledging: the invariant that
#      acknowledgement follows handling is preserved, and the turn continues
#      with the exact WAKE_ACK_REQUIRED line the drain printed.
#
# The watcher re-arm is deliberately NOT here: the checkpoint must run as the
# agent's own background command so the harness resumes the turn when it
# completes; a script-spawned watcher would orphan that resume. Run
# bin/fm-watch-checkpoint.sh yourself after this script.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# 1. Fleet status: one line per RECENTLY ACTIVE task (status written within
#    the last day), so finished history stays out of every quiet turn.
now=$(date +%s)
for status_file in "$STATE"/*.status; do
  [ -f "$status_file" ] || continue
  mtime=$(stat -c %Y "$status_file" 2>/dev/null) || continue
  [ "$((now - mtime))" -lt 86400 ] || continue
  task=$(basename "$status_file" .status)
  printf 'task %s: %s\n' "$task" "$(tail -1 "$status_file")"
done

# 2. Drain once and capture.
drain_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)
printf '%s\n' "$drain_out"

# 3. Conditional ack. Three drain shapes exist:
#      a) a full presentation ending in `--ack-through <n>` with n greater
#         than 0 - real wakes; print them (done above) and let the turn handle
#         them, never ack from here;
#      b) a presentation ending in `--ack-through 0` - nothing new; ack it;
#      c) an early exit with no WAKE_ACK_REQUIRED line at all - an empty queue
#         whose recovery state needs no ack; that is also quiet.
#    The invariant that acknowledgement follows handling is preserved: this
#    script only ever acks a drain that itself says there is nothing to handle.
if printf '%s\n' "$drain_out" | grep -qE 'WAKE_ACK_REQUIRED: .*--ack-through 0 '; then
  ack_cmd=$(printf '%s\n' "$drain_out" | grep -oE 'bin/fm-wake-drain\.sh --ack-through 0 --recovery-generation [^ ]+' | head -1)
  if [ -n "$ack_cmd" ]; then
    if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-wake-drain.sh" --ack-through 0 --recovery-generation "${ack_cmd##*--recovery-generation }" >/dev/null 2>&1; then
      echo "tick: quiet, acked"
    else
      echo "tick: quiet, but the ack failed - run the printed WAKE_ACK_REQUIRED command by hand"
    fi
  else
    echo "tick: quiet, but no ack command could be parsed - run the printed WAKE_ACK_REQUIRED command by hand"
  fi
elif printf '%s\n' "$drain_out" | grep -q 'WAKE_ACK_REQUIRED:'; then
  echo "tick: actionable wakes above - handle them, then run the printed WAKE_ACK_REQUIRED command"
else
  echo "tick: quiet (empty queue, nothing pending)"
fi
