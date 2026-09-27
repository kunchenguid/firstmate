#!/usr/bin/env bash
# Operator entrypoint for landed-work cost: what a task cost, and what each
# project has cost so far. bin/fm-cost-lib.sh is the one owner of the accounting
# contract, the usage sources, the three-state honesty rule, and the ledger
# format; this script only exposes it.
#
# Usage:
#   fm-cost.sh show <task-id>             read this task's cost without recording
#   fm-cost.sh record <task-id> <landing> <ref>
#                                         record a landing exactly once; landing
#                                         is pr or local, ref is the merged PR
#                                         URL or the landed local head
#   fm-cost.sh projects                   per-project recorded spend, plus a total
#   fm-cost.sh ledger                     the raw private ledger lines
#
# Both landing paths already record themselves (bin/fm-pr-merge.sh and a merge
# this home's poll detected through bin/fm-merge-outcome-lib.sh, and
# bin/fm-merge-local.sh), so `record` is the repair path for a landing whose
# accounting failed or was interrupted, and re-running it on an already-recorded
# landing is a safe no-op.
#
# USD is reported only as measured or estimated; anything else prints
# unavailable with the reason. Prices come from this home's optional
# config/model-prices.json (docs/configuration.md owns that schema); with no
# price table the token counts still print and the amount stays unavailable.
# Exit status: 0 on success, 2 on an invalid request, 1 on a failure to read or
# write the records.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-cost-lib.sh
. "$SCRIPT_DIR/fm-cost-lib.sh"

usage() {
  cat <<'USAGE'
usage:
  fm-cost.sh show <task-id>                 read this task's cost, record nothing
  fm-cost.sh record <task-id> <pr|local> <ref>
                                            record one landing exactly once
  fm-cost.sh projects                       per-project recorded spend and total
  fm-cost.sh ledger                         the raw private ledger lines
USAGE
}

die() {
  echo "error: $1" >&2
  exit "${2:-1}"
}

print_task_cost() {  # <task-id>
  local id=$1 amount detail
  amount=$(fm_cost_amount_text)
  detail=$(fm_cost_detail_text)
  printf 'cost: task %s %s %s%s\n' "$id" "$FM_COST_STATUS" "$amount" "$detail"
  fm_cost_project_total_line "$FM_HOME" "$FM_COST_PROJECT"
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
COMMAND=$1
shift

case "$COMMAND" in
  show)
    [ "$#" -eq 1 ] || die 'usage: fm-cost.sh show <task-id>' 2
    # A recorded landing is the authoritative answer and outlives the task's own
    # local records, so it is preferred over reading the runtime again.
    if ! fm_cost_task_recorded_lines "$FM_HOME" "$1"; then
      fm_cost_usage "$FM_HOME" "$STATE" "$1" || die "invalid cost request for $1" 2
      print_task_cost "$1"
    fi
    ;;
  record)
    [ "$#" -eq 3 ] || die 'usage: fm-cost.sh record <task-id> <pr|local> <ref>' 2
    record_status=0
    fm_cost_record "$FM_HOME" "$STATE" "$1" "$2" "$3" || record_status=$?
    case "$record_status" in
      0) ;;
      2) die "invalid cost record request for $1" 2 ;;
      *) die "could not record the landing cost for $1" ;;
    esac
    if [ "$FM_COST_ALREADY_RECORDED" = true ]; then
      printf 'cost: task %s already recorded for this landing\n' "$1"
    fi
    print_task_cost "$1"
    ;;
  projects)
    [ "$#" -eq 0 ] || die 'usage: fm-cost.sh projects' 2
    fm_cost_projects "$FM_HOME"
    ;;
  ledger)
    [ "$#" -eq 0 ] || die 'usage: fm-cost.sh ledger' 2
    LEDGER=$(fm_cost_ledger_path "$FM_HOME")
    if [ ! -f "$LEDGER" ]; then
      echo 'no recorded spend yet'
      exit 0
    fi
    cat "$LEDGER"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
