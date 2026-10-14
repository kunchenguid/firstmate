#!/usr/bin/env bash
# fm-action.sh - the ONLY writer of the per-task action ledger owned by
# bin/fm-action-lib.sh (record format, authority classes and the fold live
# there; this script owns mutation mechanics and input validation only).
#
# Subcommands (state dir: FM_STATE_OVERRIDE, else $FM_HOME/state):
#   admit <task> --id ID --class authorized|human-decision|external-gate
#         --owner WHO --operation TEXT [--source GRANT] [--due EPOCH]
#         [--units N] [--inbox NNN.msg] [--ready-with IDS|none] [--at EPOCH]
#       Record one next action. `authorized` requires an exact --source (a
#       generic word such as yolo or auto is refused); the due time defaults to
#       FM_ACTION_START_SECS (300) after admission. A gate class requires
#       --ready-with, naming the independent ready actions or `none`.
#   ack <task> ID [--at EPOCH]
#   start <task> ID [--units N] [--at EPOCH]
#   result <task> ID ok|refused|failed|answered [--reason TEXT] [--at EPOCH]
#   accept <task> ID --receipt REF [--at EPOCH]
#   hold <task> ID --kind safe-boundary|resource-wait|running-job
#         --until EPOCH --reason TEXT [--at EPOCH]
#       A legitimate wait; it must carry a finite deadline.
#   show <task> [--now EPOCH]        every action, one tab-separated line each
#   incidents <task> [--now EPOCH]   only the lines the fold reports as incidents
#
# Reads never write. Nothing here interrupts, restarts, answers a captain hold,
# or closes a task; incidents are routed by the scheduler that polls them.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-action-lib.sh
. "$SCRIPT_DIR/fm-action-lib.sh"

die() { echo "error: $*" >&2; exit 1; }

usage() {
  sed -n '2,/^set -eu/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

token_valid() {  # <value>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

epoch_valid() {  # <value>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
}

[ $# -ge 2 ] || usage
CMD=$1
TASK=$2
shift 2
fm_pr_task_id_valid "$TASK" || die "invalid task id: $TASK"

ID='' CLASS='' OWNER='' OPERATION='' SOURCE='' DUE='' UNITS='' INBOX='' READY_WITH=''
AT='' NOW='' REASON='' RECEIPT='' KIND='' UNTIL=''
POSITIONAL='' POSITIONAL2=''
while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID=${2:-}; shift 2 || usage ;;
    --class) CLASS=${2:-}; shift 2 || usage ;;
    --owner) OWNER=${2:-}; shift 2 || usage ;;
    --operation) OPERATION=${2:-}; shift 2 || usage ;;
    --source) SOURCE=${2:-}; shift 2 || usage ;;
    --due) DUE=${2:-}; shift 2 || usage ;;
    --units) UNITS=${2:-}; shift 2 || usage ;;
    --inbox) INBOX=${2:-}; shift 2 || usage ;;
    --ready-with) READY_WITH=${2:-}; shift 2 || usage ;;
    --at) AT=${2:-}; shift 2 || usage ;;
    --now) NOW=${2:-}; shift 2 || usage ;;
    --reason) REASON=${2:-}; shift 2 || usage ;;
    --receipt) RECEIPT=${2:-}; shift 2 || usage ;;
    --kind) KIND=${2:-}; shift 2 || usage ;;
    --until) UNTIL=${2:-}; shift 2 || usage ;;
    --*) die "unknown option: $1" ;;
    *)
      if [ -z "$POSITIONAL" ]; then POSITIONAL=$1
      elif [ -z "$POSITIONAL2" ]; then POSITIONAL2=$1
      else die "unexpected argument: $1"; fi
      shift ;;
  esac
done

[ -n "$AT" ] || AT=$(date +%s)
[ -n "$NOW" ] || NOW=$(date +%s)
epoch_valid "$AT" || die "--at must be epoch seconds"
epoch_valid "$NOW" || die "--now must be epoch seconds"
[ -z "$UNITS" ] || { epoch_valid "$UNITS" && [ "$UNITS" -ge 1 ]; } || die "--units must be a positive integer"

require_existing() {  # <id>
  token_valid "$1" || die "invalid action id: ${1:-<empty>}"
  fm_action_exists "$STATE" "$TASK" "$1" || die "unknown action $1 for task $TASK"
}

case "$CMD" in
  admit)
    token_valid "$ID" || die "--id is required and must be a plain token"
    case "$CLASS" in authorized|human-decision|external-gate) : ;; *) die "--class must be authorized, human-decision or external-gate" ;; esac
    token_valid "$OWNER" || die "--owner is required and must be a plain token"
    [ -n "$OPERATION" ] || die "--operation is required (the exact action, or the pending question for a gate)"
    LOCK="$STATE/$TASK.actions.lock"
    mkdir -p "$STATE"
    fm_lock_try_acquire "$LOCK" || die "action ledger is locked by another writer"
    trap 'fm_lock_release "$LOCK" >/dev/null 2>&1 || true' EXIT
    ! fm_action_exists "$STATE" "$TASK" "$ID" || die "action $ID already admitted"
    FIELDS=("class=$CLASS" "owner=$OWNER" "operation=$(fm_action_clean "$OPERATION")")
    if [ "$CLASS" = authorized ]; then
      fm_action_source_generic "$SOURCE" && die "--source must name the exact grant, not a generic permission word"
      FIELDS+=("source=$(fm_action_clean "$SOURCE")")
      [ -n "$DUE" ] || DUE=$((AT + $(fm_action_start_secs)))
      [ -n "$UNITS" ] || UNITS=1
    else
      [ -n "$READY_WITH" ] || die "a gate must declare --ready-with (independent ready action ids, or none)"
      FIELDS+=("ready_with=$(fm_action_clean "$READY_WITH")")
    fi
    if [ -n "$DUE" ]; then
      epoch_valid "$DUE" || die "--due must be epoch seconds"
      FIELDS+=("due=$DUE")
    fi
    [ -z "$UNITS" ] || FIELDS+=("units=$UNITS")
    if [ -n "$INBOX" ]; then
      case "$INBOX" in [0-9][0-9][0-9]*.msg) : ;; *) die "--inbox must be a steering record name like 001.msg" ;; esac
      FIELDS+=("inbox=$INBOX")
    fi
    fm_action_append "$STATE" "$TASK" "$AT" "$ID" admit "${FIELDS[@]}"
    ;;
  ack)
    require_existing "$POSITIONAL"
    fm_action_append "$STATE" "$TASK" "$AT" "$POSITIONAL" ack
    ;;
  start)
    require_existing "$POSITIONAL"
    FIELDS=()
    [ -z "$UNITS" ] || FIELDS+=("units=$UNITS")
    fm_action_append "$STATE" "$TASK" "$AT" "$POSITIONAL" start ${FIELDS[@]+"${FIELDS[@]}"}
    ;;
  result)
    require_existing "$POSITIONAL"
    case "$POSITIONAL2" in ok|refused|failed|answered) : ;; *) die "result outcome must be ok, refused, failed or answered" ;; esac
    FIELDS=("outcome=$POSITIONAL2")
    [ -z "$REASON" ] || FIELDS+=("reason=$(fm_action_clean "$REASON")")
    [ "$POSITIONAL2" != refused ] && [ "$POSITIONAL2" != failed ] || [ -n "$REASON" ] || die "a refusal or failure needs a concrete --reason"
    fm_action_append "$STATE" "$TASK" "$AT" "$POSITIONAL" result "${FIELDS[@]}"
    ;;
  accept)
    require_existing "$POSITIONAL"
    [ -n "$RECEIPT" ] || die "--receipt is required: acceptance needs a native receipt"
    fm_action_append "$STATE" "$TASK" "$AT" "$POSITIONAL" accept "receipt=$(fm_action_clean "$RECEIPT")"
    ;;
  hold)
    require_existing "$POSITIONAL"
    case "$KIND" in safe-boundary|resource-wait|running-job) : ;; *) die "--kind must be safe-boundary, resource-wait or running-job" ;; esac
    epoch_valid "$UNTIL" || die "a hold needs a finite --until deadline (epoch seconds)"
    [ -n "$REASON" ] || die "--reason is required"
    fm_action_append "$STATE" "$TASK" "$AT" "$POSITIONAL" hold "kind=$KIND" "until=$UNTIL" "reason=$(fm_action_clean "$REASON")"
    ;;
  show)
    fm_action_fold "$STATE" "$TASK" "$NOW"
    ;;
  incidents)
    fm_action_incidents "$STATE" "$TASK" "$NOW"
    ;;
  *) usage ;;
esac
