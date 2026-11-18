#!/usr/bin/env bash
# fm-step.sh - record a worker's plan, the step it started, and scenario results.
#
# Usage: fm-step.sh [--record <file>] --plan <step 1 name> <step 2 name> ...
#        fm-step.sh [--record <file>] <n> <m> <step name...>
#        fm-step.sh [--record <file>] --scenario pass|fail|run <scenario name...>
#
# A worker writes a numbered plan of <m> steps first and records it with
# --plan, one argument per step name, before it starts step 1. A later --plan
# replaces the earlier plan. Then the worker runs `fm-step.sh <n> <m> <name>`
# when it starts step <n>.
# A verifier records each scenario it checks with --scenario: `run` when the
# scenario starts, then `pass` or `fail`. The last result for a name wins.
# Each call appends to the task's step record and prints nothing on success.
# bin/fm-fleet-view.sh shows the current step in its STEP column and in its
# `--steps <task-id>` checklist, and bin/fm-crew-panel.sh shows the full plan
# and the scenario results.
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
  printf 'usage: fm-step.sh [--record <file>] --plan <step name>...\n' >&2
  printf '       fm-step.sh [--record <file>] <n> <m> <step name...>\n' >&2
  printf '       fm-step.sh [--record <file>] --scenario pass|fail|run <name...>\n' >&2
  exit 2
}

# One record line per name: control characters, tabs, and newlines become
# spaces, and the name is trimmed and capped so a reader never has to guard
# against an oversized line.
clean_name() {
  printf '%s' "$1" | tr '\000-\037\177' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | cut -c1-200
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

NOW=$(date +%s)
LINES=
case "${1:-}" in
  --plan)
    shift
    [ $# -ge 1 ] || die_usage "--plan needs at least one step name"
    M=$#
    K=0
    for raw in "$@"; do
      K=$((K + 1))
      NAME=$(clean_name "$raw")
      [ -n "$NAME" ] || die_usage "plan step $K must have a name"
      LINES="$LINES$(printf '%s\tplan\t%s\t%s\t%s' "$NOW" "$K" "$M" "$NAME")"$'\n'
    done
    ;;
  --scenario)
    shift
    [ $# -ge 2 ] || die_usage "--scenario needs a result and a scenario name"
    RESULT=$1
    shift
    case "$RESULT" in pass|fail|run) ;; *) die_usage "the scenario result must be pass, fail, or run, not '$RESULT'" ;; esac
    NAME=$(clean_name "$*")
    [ -n "$NAME" ] || die_usage "<scenario name> must not be empty"
    LINES=$(printf '%s\tscenario\t%s\t%s' "$NOW" "$RESULT" "$NAME")$'\n'
    ;;
  *)
    [ $# -ge 3 ] || die_usage "expected <n> <m> <step name>"
    N=$1
    M=$2
    shift 2
    case "$N" in ''|*[!0-9]*) die_usage "<n> must be a positive whole number, not '$N'" ;; esac
    case "$M" in ''|*[!0-9]*) die_usage "<m> must be a positive whole number, not '$M'" ;; esac
    N=$((10#$N))
    M=$((10#$M))
    [ "$N" -ge 1 ] || die_usage "<n> must be at least 1"
    [ "$M" -ge 1 ] || die_usage "<m> must be at least 1"
    [ "$N" -le "$M" ] || die_usage "<n> ($N) must not be greater than <m> ($M)"
    NAME=$(clean_name "$*")
    [ -n "$NAME" ] || die_usage "<step name> must not be empty"
    LINES=$(printf '%s\t%s\t%s\t%s' "$NOW" "$N" "$M" "$NAME")$'\n'
    ;;
esac

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

# One write call per invocation, so a plan lands as one append.
printf '%s' "$LINES" >> "$RECORD" || {
  printf 'fm-step: could not write %s\n' "$RECORD" >&2
  exit 1
}
exit 0
