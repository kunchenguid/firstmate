#!/usr/bin/env bash
# fm-status-report.sh - append one generated-worker status event safely.
#
# Usage:
#   fm-status-report.sh <absolute-state/<task>.status> <one-line-status-event>
#
# This is the producer boundary for status events emitted by generated briefs
# and fm-secondmate-report.sh.
# It appends every event except an unchanged keyed paused event whose latest
# event for the same key is that exact paused line.
# A changed event for that key, including any non-paused transition, always
# appends and makes a later pause observable again.
# Unkeyed events always append.
# The status log remains the append-only source of deduplication state.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  printf '%s\n' "Usage: fm-status-report.sh <absolute-state/<task>.status> <one-line-status-event>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
STATUS_FILE=$1
LINE=$2

case "$STATUS_FILE" in
  /*/state/*.status) ;;
  *)
    printf '%s\n' 'fm-status-report: status file must be an absolute state/<task>.status path' >&2
    exit 2
    ;;
esac
case "$LINE" in
  ''|*$'\n'*|*$'\r'*)
    printf '%s\n' 'fm-status-report: status event must be one non-empty line' >&2
    exit 2
    ;;
esac

STATE_DIR=$(cd "$(dirname "$STATUS_FILE")" 2>/dev/null && pwd -P) || {
  printf 'fm-status-report: cannot resolve status directory for %s\n' "$STATUS_FILE" >&2
  exit 1
}
TASK=${STATUS_FILE##*/}
TASK=${TASK%.status}
case "$TASK" in
  ''|*[!A-Za-z0-9._-]*)
    printf 'fm-status-report: invalid task id in status file %s\n' "$STATUS_FILE" >&2
    exit 2
    ;;
esac

# Use the status vocabulary and portable owner-directory lock shared by the
# watcher path so concurrent reporters make the scan-and-append decision as one
# operation.
export FM_STATE_OVERRIDE="$STATE_DIR"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

LOCK_DIR="$STATE_DIR/.status-report-locks/$TASK.lock"
mkdir -p "$(dirname "$LOCK_DIR")"
fm_lock_acquire_wait "$LOCK_DIR"
trap 'fm_lock_release "$LOCK_DIR"' EXIT HUP INT TERM

append_event() {
  printf '%s\n' "$LINE" >> "$STATUS_FILE"
}

status_line_key() {
  local line=$1
  if _fm_key_before_colon "$line"; then
    :
  elif _fm_key_at_note_head "$line" >/dev/null; then
    :
  else
    return 1
  fi
  _fm_decision_key "$line"
}

PAUSE_VERB=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
if [ "$(status_line_verb "$LINE")" != "$PAUSE_VERB" ]; then
  append_event
  printf '%s\n' appended
  exit 0
fi

KEY=$(status_line_key "$LINE") || {
  append_event
  printf '%s\n' appended
  exit 0
}

LATEST_FOR_KEY=
if [ -r "$STATUS_FILE" ]; then
  while IFS= read -r event || [ -n "$event" ]; do
    event_key=$(status_line_key "$event") || continue
    [ "$event_key" = "$KEY" ] && LATEST_FOR_KEY=$event
  done < "$STATUS_FILE"
fi

if [ "$LATEST_FOR_KEY" = "$LINE" ]; then
  printf '%s\n' suppressed
  exit 0
fi

append_event
printf '%s\n' appended
