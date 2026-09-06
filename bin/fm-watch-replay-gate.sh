#!/usr/bin/env bash
# Verdict for re-presenting one persisted Pi replacement-session actionable wake.
#
# The Pi watch extension (.pi/extensions/fm-primary-pi-watch.ts) persists an
# actionable close across a same-process session replacement and re-sends it
# when the replacement activates. Re-presentation is bounded twice: a close Pi
# accepted once is never re-sent (the extension header owns that bound), and
# before a record's re-send this script compares the record's reason line
# against the home's durable wake records and issues the verdict:
#   drop empty-queue-acked-recovery
#       the wake queue holds no rows and the recovery episode marker is
#       retired (acked) or absent, so nothing in the home is unhandled and a
#       replay could only repeat an already-handled event
#   drop stale-window-task-gone
#       a stale replay whose window no state/<id>.meta records any more, so
#       the subject task was torn down and the watcher can never re-detect it
#   drop referenced-wake-acked
#       a stale replay whose queue row is gone; rows are consumed only by
#       acknowledgement, so the referenced wake was already handled
#   deliver
#       anything else, including unreadable or ambiguous durable state, a
#       non-stale reason, or an outstanding unacked recovery episode: the
#       safe direction is to let the bounded replay through
# Dropping a replay never consumes a durable row; it only suppresses one
# repeated presentation, and the live watcher still surfaces genuinely new
# events fresh.
#
# Usage: FM_STATE_OVERRIDE=<state-dir> fm-watch-replay-gate.sh "<reason line>"
# Prints exactly one line: "deliver" or "drop <reason>". Both verdicts exit 0;
# only a usage error exits non-zero, and the extension treats any non-zero or
# unreadable answer as "deliver".
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Window-to-meta resolution lives with the backend metadata contract.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

RECOVERY_MARKER="$STATE/.watcher-down"

usage() {
  echo "usage: $(basename "$0") REASON-LINE" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
reason=$1
[ -n "$reason" ] || usage

deliver() {
  printf 'deliver\n'
  exit 0
}

drop() {
  printf 'drop %s\n' "$1"
  exit 0
}

# A stale replay's window is the first token after the verb, the same parse the
# branch dispatcher applies to a stale trigger; the wake key equals that window.
reason_window() {
  local rest=${reason#stale:}
  rest=${rest#"${rest%%[! ]*}"}
  printf '%s' "${rest%% *}"
}

# Mirror the watcher's recorded_windows target derivation exactly, so a window
# the live watcher can still see is never declared gone.
window_recorded() {
  local meta target
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    [ "$target" = "$1" ] && return 0
  done
  return 1
}

# 0 when the queue holds an unacknowledged row of <kind> with key <key>.
row_queued() {
  local kind=$1 key=$2
  [ -s "$FM_WAKE_QUEUE" ] || return 1
  awk -F '\t' -v kind="$kind" -v key="$key" \
    'NF >= 5 && $3 == kind && $4 == key { found = 1 } END { exit !found }' \
    "$FM_WAKE_QUEUE"
}

# Nothing unhandled anywhere: an empty queue plus a retired or absent recovery
# episode proves every queued wake was acknowledged, so any replay is a repeat.
if [ ! -s "$FM_WAKE_QUEUE" ]; then
  if fm_recovery_marker_read "$RECOVERY_MARKER"; then
    case "$FM_RECOVERY_MARKER_TOKEN" in
      acked:*) drop empty-queue-acked-recovery ;;
      *) deliver ;;
    esac
  fi
  [ -e "$RECOVERY_MARKER" ] || [ -L "$RECOVERY_MARKER" ] || drop empty-queue-acked-recovery
  deliver
fi

case "$reason" in
  stale:*)
    window=$(reason_window)
    [ -n "$window" ] || deliver
    if ! window_recorded "$window"; then
      drop stale-window-task-gone
    fi
    if ! row_queued stale "$window"; then
      drop referenced-wake-acked
    fi
    deliver
    ;;
  *)
    # Non-stale reasons have no reliably parseable key, so only the global
    # empty-queue rule above applies; their replay count is bounded by the
    # extension's accept-once rule instead.
    deliver
    ;;
esac
