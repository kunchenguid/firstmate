#!/usr/bin/env bash
# fm-wake-evidence.sh - evidence for the supervision-branch pre-branch classifier
# on either host (docs/claude-supervision-branch.md "Classifier";
# docs/pi-supervision-branch.md for the Pi extension).
#
# Usage:
#   fm-wake-evidence.sh <task>
#       Print the classifier's read-only evidence bundle for one wake: the
#       task's current state (bin/fm-crew-state.sh), the status lines appended
#       since the last classified wake marked NEW, and the last few earlier
#       lines marked HISTORY. The first line names the status byte range the
#       bundle judges: "## task <task> status bytes <from>-<to>". The bundle
#       is bounded (1500 bytes of state, 6000 bytes of new lines); a longer
#       new span is cut back to the last whole line inside the cap (at the cap
#       when one line is longer than it), named by the range it prints, and
#       marked with a "## truncated:" line, which the shared classifier core
#       reads as incomplete evidence and passes the wake to main.
#   fm-wake-evidence.sh --routine-covered <task>
#       Print every captain-facing status line of <task> that a ROUTINE branch
#       outcome covered and main has not been shown, as "<end-offset>\t<line>"
#       (the same lines the drain's STATUS OUTCOME BACKSTOP presents). Empty
#       output means nothing to re-present.
#
# OFFSET FILE (this header is the one owner). $STATE/.<task>.classifier-offset
# holds the status-log byte size after the last bundle, so each wake judges
# only what was appended since. The bundle form advances it to the full size -
# a truncated bundle never lets the branch take the wake, so main handles the
# whole span and no partial offset is ever kept; a size smaller than the
# offset (log replaced) resets it to zero. It is the only file this script
# writes, and bin/fm-teardown.sh removes it with the task's other per-task
# state. Exit 0 always for a readable task; exit 2 on usage errors.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
_fm_wake_require_classify
_fm_wake_require_timeout

mode=bundle
if [ "${1:-}" = --routine-covered ]; then
  mode=covered
  shift
fi
task=${1:-}
case "$task" in
  '' | *[!A-Za-z0-9._-]*)
    echo "usage: fm-wake-evidence.sh [--routine-covered] <task>" >&2
    exit 2
    ;;
esac
f="$STATE/$task.status"

if [ "$mode" = covered ]; then
  [ -f "$f" ] || exit 0
  receipt=$(status_outcome_backstop_cursor_offset "$f") || receipt=0
  backstop_routine_covered_lines "$STATE" "$task" "$receipt"
  exit 0
fi

off_file="$STATE/.$task.classifier-offset"
off=0
[ -f "$off_file" ] && off=$(cat "$off_file")
case "$off" in '' | *[!0-9]*) off=0 ;; esac
size=0
[ -f "$f" ] && size=$(wc -c <"$f" | tr -d ' ')
[ "$off" -le "$size" ] || off=0
new_cap=6000
shown=$((size - off))
if [ "$shown" -gt "$new_cap" ]; then
  shown=$(tail -c +$((off + 1)) "$f" | head -c "$new_cap" \
    | perl -0777 -ne 'print(/\A(.*\n)/s ? length($1) : length($_))')
  case "$shown" in '' | *[!0-9]*) shown=$new_cap ;; esac
  [ "$shown" -gt 0 ] || shown=$new_cap
fi
end=$((off + shown))
echo "## task $task status bytes $off-$end"
echo "## current state (bin/fm-crew-state.sh $task)"
fm_run_timed 20 "$SCRIPT_DIR/fm-crew-state.sh" "$task" 2>&1 | head -c 1500
echo
if [ -f "$f" ]; then
  echo "## status lines appended since the last classified wake (NEW - judge these)"
  tail -c +$((off + 1)) "$f" | head -c "$shown" | sed 's/^/  /'
  [ "$off" -lt "$size" ] || echo "  (none - this wake carries only a turn-end or pane signal)"
  if [ "$end" -lt "$size" ]; then
    [ -z "$(tail -c +"$end" "$f" | head -c 1)" ] || echo
    echo "## truncated: $((size - end)) further bytes of NEW lines are not in this bundle, so this evidence is incomplete"
  fi
  echo "## earlier lines, already handled by earlier wakes (HISTORY - never escalate these)"
  head -c "$off" "$f" | tail -n 4 | sed 's/^/  /'
  [ "$off" -gt 0 ] || echo "  (none)"
fi
printf '%s' "$size" >"$off_file"
