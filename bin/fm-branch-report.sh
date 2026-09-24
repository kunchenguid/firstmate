#!/usr/bin/env bash
# fm-branch-report.sh - the supervision branch's report surface off Pi: the
# command twin of the Pi branch extension's fm_branch_report tool, for a
# branch session run by the supervision host (docs/supervision-host.md).
#
# It records exactly one handled fleet event in the durable outcome store
# (bin/fm-branch-outcome.sh owns the store) and gives the host the receipt it
# requires before it counts a wake handled. It enforces the same scoping the
# Pi tool does (docs/pi-supervision-branch.md "Components and their owners"):
# while the host's current turn claims signal or stale rows, only the tasks
# those rows resolve to may be reported - `fleet` and any remembered task are
# refused before the store is touched - and a claim that names no task (a
# heartbeat review, or a claimed heartbeat or check row) is unscoped. The
# claimed task set comes from .pi/extensions/lib/fm-branch-dispatch.ts through
# the host's turn record; this script only compares against it.
#
# Usage:
#   fm-branch-report.sh --task <id|fleet> --verdict routine|captain \
#       --summary <text> [--silent true|false] [--wake <text>]
#
# The verdict criteria are owned by bin/fm-branch-prompt.sh ("Verdict: routine
# or captain"); --silent true is legal only for a routine fleet outcome.
# --wake defaults to the wake reason the host recorded for the turn.
#
# Only the branch actor of a live host turn may report: FM_SUPERVISION_ACTOR
# must be "branch" and FM_BRANCH_REPORT_TURN must name the host's current turn
# record ($STATE/.supervision-host-turn), so a report typed after its turn
# ended, or from any other shell, is refused. Exit codes: 0 recorded, 1 the
# store refused or failed (nothing recorded), 2 usage, 3 refused (actor, turn,
# or scope).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
TURN_FILE="$STATE/.supervision-host-turn"
RECEIPTS="$STATE/.supervision-host-receipts"

usage() {
  sed -n '/^# Usage:/,/^# --wake/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

refuse() {
  printf 'report refused: %s\n' "$1" >&2
  exit 3
}

TASK='' VERDICT='' SUMMARY='' SILENT=false WAKE='' WAKE_SET=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) TASK=${2:-}; shift 2 || usage ;;
    --verdict) VERDICT=${2:-}; shift 2 || usage ;;
    --summary) SUMMARY=${2:-}; shift 2 || usage ;;
    --silent) SILENT=${2:-}; shift 2 || usage ;;
    --wake) WAKE=${2:-}; WAKE_SET=1; shift 2 || usage ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

TASK=$(printf '%s' "$TASK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
SUMMARY=$(printf '%s' "$SUMMARY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
case "$VERDICT" in routine|captain) ;; *) VERDICT= ;; esac
case "$SILENT" in true|false) ;; *) usage ;; esac
if [ -z "$TASK" ] || [ -z "$SUMMARY" ] || [ -z "$VERDICT" ]; then
  echo "invalid report: --task, --verdict (routine|captain), and --summary are required" >&2
  exit 2
fi
if [ "$SILENT" = true ] && { [ "$TASK" != fleet ] || [ "$VERDICT" != routine ]; }; then
  echo "invalid report: --silent true is only for a routine fleet outcome" >&2
  exit 2
fi

[ "${FM_SUPERVISION_ACTOR:-}" = branch ] \
  || refuse "only the supervision branch reports outcomes; MAIN acts on them instead"
TURN=${FM_BRANCH_REPORT_TURN:-}
case "$TURN" in
  ''|*[!A-Za-z0-9._-]*) refuse "no supervision wake is being handled by this shell" ;;
esac

turn_field() {  # <name>
  sed -n "s/^$1=//p" "$TURN_FILE" 2>/dev/null | head -n 1
}

[ -f "$TURN_FILE" ] && [ ! -L "$TURN_FILE" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"
[ "$(turn_field turn)" = "$TURN" ] \
  || refuse "the wake this shell was handling is over; report only while handling a wake"

if [ "$(turn_field unscoped)" != 1 ]; then
  TASKS=$(turn_field tasks)
  case " $TASKS " in
    *" $TASK "*) ;;
    *)
      refuse "the wake being handled (row $(turn_field rows)) names ${TASKS:-no task}, not $TASK; report only that task, never fleet or a task from memory"
      ;;
  esac
fi

[ "$WAKE_SET" -eq 1 ] || WAKE=$(turn_field wake)

set -- append --task "$TASK" --verdict "$VERDICT" --summary "$SUMMARY" --silent "$SILENT"
[ -z "$WAKE" ] || set -- "$@" --wake "$WAKE"
if ! SEQ=$("$SCRIPT_DIR/fm-branch-outcome.sh" "$@"); then
  echo "outcome store append failed (nothing recorded)" >&2
  exit 1
fi
printf '%s\t%s\t%s\t%s\n' "$TURN" "$SEQ" "$VERDICT" "$TASK" >> "$RECEIPTS" || {
  echo "recorded seq $SEQ, but the host receipt could not be written; the host will hand this wake to MAIN" >&2
  exit 1
}
printf 'recorded seq %s [%s]; it waits in the outcome store for MAIN\n' "$SEQ" "$VERDICT"
