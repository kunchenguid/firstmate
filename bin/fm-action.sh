#!/usr/bin/env bash
# fm-action.sh - the manual writer CLI of the per-task action ledger owned by
# bin/fm-action-lib.sh (record format, authority classes and the fold live
# there; this script owns CLI input validation).
#
# Subcommands (state dir: FM_STATE_OVERRIDE, else $FM_HOME/state):
#   admit <task> --id ID --class authorized|human-decision|external-gate
#         --owner WHO --operation TEXT [--source GRANT] [--due EPOCH]
#         [--units N] [--inbox NNN.msg] [--ready-with IDS|none] [--at EPOCH]
#         [--head SHA --run ID --attempt ID]
#       Record one next action. `authorized` requires an exact --source (a
#       generic word such as yolo or auto is refused); the due time defaults to
#       FM_ACTION_START_SECS (300) after admission. A gate class requires
#       --ready-with, naming the independent ready actions or `none`.
#   consume <task> ID --reason TEXT [--at EPOCH]
#       Consume or report a returned validation call within FM_ACTION_START_SECS.
#   ack <task> ID [--at EPOCH]
#   start <task> ID [--units N] [--at EPOCH]
#   result <task> ID ok|refused|failed|answered [--reason TEXT] [--at EPOCH]
#   accept <task> ID --evidence PATH [--at EPOCH]
#       Requires the native producer receipt under state/<task>.action-receipts/ID
#       with successful outcome and exact admitted head/run/attempt identity.
#       Missing, inaccessible, stale or unbound evidence never certifies acceptance.
#   probe PATH
#       Print present, absent, or unknown with the blocked directory and a
#       read-only fallback route; an access failure is never reported as absent.
#   hold <task> ID --kind safe-boundary|resource-wait|running-job
#         --until EPOCH --reason TEXT [--at EPOCH]
#       A legitimate wait; it must carry a finite deadline.
#   show <task> [--now EPOCH]        every action, one tab-separated line each
#   incidents <task> [--now EPOCH]   only ledger-fold incidents; checkpoint and
#       stale-blocker conditions are reported separately by the watcher
#   register [<task>] [--now EPOCH]  one line per local live non-secondmate task (all
#       when no task is given), from files alone: task, owner, state, last
#       progress epoch, its source, next checkpoint epoch, verdict (ok or MISSED)
#       and evidence. FM_ACTION_CHECKPOINT_SECS (3600) bounds the checkpoint.
#       Only a task its worker owns can be MISSED; tasks waiting on firstmate
#       or in a declared wait are listed with their owner and never missed here.
#       The all-tasks form leads with an `observer` line: check cadence
#       (FM_CHECK_CADENCE_BOUND_SECS, 360) and beat liveness reported
#       separately; acceptance=FAILED keeps every over-bound interval the
#       watcher poll recorded in state/.check-cadence-misses until cleared by hand.
#   progress <task> --reason TEXT [--at EPOCH]
#       A supervisor's inspected observation that the worker is genuinely
#       progressing; renews the task's checkpoint with source supervisor:TEXT.
#       It is evidence the supervisor saw, so name what was seen.
#   A `triage-*` action opened by the escalation ladder accepts
#   `result ... ok` only once its incident is gone.
#
# Reads never write. Nothing here interrupts, restarts, answers a captain hold,
# or closes a task; fm-watch routes incidents through its existing check queue.
# Ordinary inbox steers, launch/control events and watcher incidents are wired.
# Internal fire-and-forget nudges are excluded; other execution owners must
# record their own native start/result and validation-return consumption.
# Live adoption is PENDING on scheduler PR https://github.com/kunchenguid/firstmate/pull/7234.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
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

if [ "${1:-}" = probe ]; then
  [ $# -eq 2 ] || usage
  fm_action_probe_evidence "$2"
  exit 0
fi
if [ "${1:-}" = register ]; then
  shift
  REG_TASK='' REG_NOW=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --now) REG_NOW=${2:-}; shift 2 || usage ;;
      --*) die "unknown option: $1" ;;
      *) [ -z "$REG_TASK" ] || die "unexpected argument: $1"; REG_TASK=$1; shift ;;
    esac
  done
  [ -n "$REG_NOW" ] || REG_NOW=$(date +%s)
  epoch_valid "$REG_NOW" || die "--now must be epoch seconds"
  if [ -n "$REG_TASK" ]; then
    fm_pr_task_id_valid "$REG_TASK" || die "invalid task id: $REG_TASK"
    fm_action_register "$STATE" "$REG_TASK" "$REG_NOW"
  else
    fm_action_observer "$STATE" "$REG_NOW"
    for REG_META in "$STATE"/*.meta; do
      [ -f "$REG_META" ] || continue
      REG_TASK=${REG_META##*/}; REG_TASK=${REG_TASK%.meta}
      fm_action_register "$STATE" "$REG_TASK" "$REG_NOW"
    done
  fi
  exit 0
fi
[ $# -ge 2 ] || usage
CMD=$1
TASK=$2
shift 2
fm_pr_task_id_valid "$TASK" || die "invalid task id: $TASK"

ID='' CLASS='' OWNER='' OPERATION='' SOURCE='' DUE='' UNITS='' INBOX='' READY_WITH=''
HEAD='' RUN='' ATTEMPT=''
AT='' NOW='' REASON='' EVIDENCE='' KIND='' UNTIL=''
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
    --head) HEAD=${2:-}; shift 2 || usage ;;
    --run) RUN=${2:-}; shift 2 || usage ;;
    --attempt) ATTEMPT=${2:-}; shift 2 || usage ;;
    --evidence) EVIDENCE=${2:-}; shift 2 || usage ;;
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
    for VALUE in "$HEAD" "$RUN" "$ATTEMPT"; do
      [ -z "$VALUE" ] || token_valid "$VALUE" || die "head, run and attempt must be plain tokens"
    done
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
    FIELDS+=("head=$HEAD" "run=$RUN" "attempt=$ATTEMPT")
    fm_action_append "$STATE" "$TASK" "$AT" "$ID" admit "${FIELDS[@]}"
    ;;
  consume)
    require_existing "$POSITIONAL"
    [ -n "$REASON" ] || die "--reason is required: name the consumed or reported return"
    fm_action_append "$STATE" "$TASK" "$AT" "$POSITIONAL" consume "reason=$(fm_action_clean "$REASON")"
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
    case "$POSITIONAL" in
      triage-*) [ "$POSITIONAL2" != ok ] || fm_action_triage_verified "$STATE" "$TASK" "$POSITIONAL" "$AT" \
        || die "triage result not verified: the incident it targets is still present" ;;
    esac
    fm_action_append "$STATE" "$TASK" "$AT" "$POSITIONAL" result "${FIELDS[@]}"
    ;;
  accept)
    require_existing "$POSITIONAL"
    [ -n "$EVIDENCE" ] || die "--evidence is required: acceptance needs native evidence"
    PROBE=$(fm_action_probe_evidence "$EVIDENCE")
    [ "$PROBE" = present ] || die "acceptance evidence is not confirmed: $PROBE"
    fm_action_verify_receipt "$STATE" "$TASK" "$POSITIONAL" "$EVIDENCE" || die "acceptance evidence is unknown: native identity or successful outcome not confirmed"
    fm_action_append "$STATE" "$TASK" "$AT" "$POSITIONAL" accept "receipt=$(fm_action_clean "$EVIDENCE")"
    ;;
  hold)
    require_existing "$POSITIONAL"
    case "$KIND" in safe-boundary|resource-wait|running-job) : ;; *) die "--kind must be safe-boundary, resource-wait or running-job" ;; esac
    epoch_valid "$UNTIL" || die "a hold needs a finite --until deadline (epoch seconds)"
    [ -n "$REASON" ] || die "--reason is required"
    fm_action_append "$STATE" "$TASK" "$AT" "$POSITIONAL" hold "kind=$KIND" "until=$UNTIL" "reason=$(fm_action_clean "$REASON")"
    ;;
  progress)
    [ -n "$REASON" ] || die "--reason is required: name the progress that was inspected"
    [ -f "$STATE/$TASK.meta" ] || die "unknown live task $TASK"
    fm_action_note_progress "$STATE" "$TASK" "$AT" "supervisor:$REASON"
    ;;
  show)
    fm_action_fold "$STATE" "$TASK" "$NOW"
    ;;
  incidents)
    fm_action_incidents "$STATE" "$TASK" "$NOW"
    ;;
  *) usage ;;
esac
