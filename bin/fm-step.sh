#!/usr/bin/env bash
# fm-step.sh - record which plan step a worker has started.
#
# Usage: fm-step.sh [--record <file>] <n> <m> <step name...>
#
# A worker writes a numbered plan of <m> steps first, then runs this command
# when it starts step <n>. The command appends one line to the task's step
# record and prints nothing on success.
# bin/fm-fleet-view.sh shows the current step in its STEP column and in its
# `--steps <task-id>` checklist.
#
# The record is state/<task-id>.step under the task's home. Without --record,
# the command finds it from FM_TASK_INBOX, the absolute state/<task-id>.inbox
# path that bin/fm-spawn.sh exports into every worker launch. --record names
# the record file directly; its name must end in `.step`.
# bin/fm-step-lib.sh owns the record format and the config/step-display switch.
#
# Writing the record never appends a status line, never queues a wake, and never
# touches any file the watcher reads, so firstmate is not woken. It is not a
# substitute for the status protocol: decisions, blockers, waits, and done
# still go to the status file.
#
# Exit codes: 0 recorded; 2 usage error or no record location; 1 write failed.
set -u

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

die_usage() {
  printf 'fm-step: %s\n' "$1" >&2
  printf 'usage: fm-step.sh [--record <file>] <n> <m> <step name...>\n' >&2
  exit 2
}

RECORD=
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --record)
    [ $# -ge 2 ] || die_usage "--record needs a file"
    RECORD=$2
    shift 2
    ;;
esac

[ $# -ge 3 ] || die_usage "expected <n> <m> <step name>"
N=$1
M=$2
shift 2
NAME="$*"

case "$N" in ''|*[!0-9]*) die_usage "<n> must be a positive whole number, not '$N'" ;; esac
case "$M" in ''|*[!0-9]*) die_usage "<m> must be a positive whole number, not '$M'" ;; esac
N=$((10#$N))
M=$((10#$M))
[ "$N" -ge 1 ] || die_usage "<n> must be at least 1"
[ "$M" -ge 1 ] || die_usage "<m> must be at least 1"
[ "$N" -le "$M" ] || die_usage "<n> ($N) must not be greater than <m> ($M)"

# One record line per step: control characters, tabs, and newlines become
# spaces, and the name is trimmed and capped so a reader never has to guard
# against an oversized line.
NAME=$(printf '%s' "$NAME" | tr '\000-\037\177' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-200)
[ -n "$NAME" ] || die_usage "<step name> must not be empty"

if [ -z "$RECORD" ]; then
  [ -n "${FM_TASK_INBOX:-}" ] || die_usage "FM_TASK_INBOX is not set; pass --record state/<task-id>.step"
  case "$FM_TASK_INBOX" in
    *.inbox) ;;
    *) die_usage "FM_TASK_INBOX does not name a state/<task-id>.inbox path: $FM_TASK_INBOX" ;;
  esac
  RECORD="${FM_TASK_INBOX%.inbox}.step"
fi
case "$RECORD" in
  *.step) ;;
  *) die_usage "the record name must end in .step: $RECORD" ;;
esac
[ -d "$(dirname -- "$RECORD")" ] || die_usage "the record directory does not exist: $(dirname -- "$RECORD")"

printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$N" "$M" "$NAME" >> "$RECORD" || {
  printf 'fm-step: could not write %s\n' "$RECORD" >&2
  exit 1
}
exit 0
