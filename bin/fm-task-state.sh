#!/usr/bin/env bash
# Provider-aware current-state reader above the existing local crew-state
# implementation.
#
# Usage:
#   fm-task-state.sh <task-id>
#   fm-task-state.sh --durable-only <task-id>
#   fm-task-state.sh progress <task-id>
#   fm-task-state.sh update-progress <task-id> --progress '<json>'
#   fm-task-state.sh progress-list
#
# Canonical identity and business state are read first. Missing/corrupt records
# refuse, and queued/done/archived return without execution reconciliation.
# In-flight local metadata delegates unchanged to fm-crew-state.sh.
# executor=cloud-worker/provider=aime is the permanent legacy AIME path.
# executor=remote-agent delegates to the explicitly recorded AIME or iDA
# provider. Unknown executor/provider records fail closed and never fall
# through to pane, worktree, harness, or runtime-backend semantics.
# `--durable-only` keeps remote-provider refresh off the caller's blocking path.
# It prints the validated local provider record and marks any freshness gap;
# ordinary calls retain provider-aware current-state reconciliation.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME
DURABLE_ONLY=0
if [ "${1:-}" = --durable-only ]; then
  DURABLE_ONLY=1
  shift
fi
# Compact progress reads and updates one canonical per-task record without
# backend refresh.
case "${1:-}" in
  progress-list)
    [ "$#" -eq 1 ] || exit 2
    # shellcheck source=bin/fm-task-progress-lib.sh
    . "$SCRIPT_DIR/fm-task-progress-lib.sh"
    fm_task_progress_list
    exit $?
    ;;
  progress)
    [ "$#" -eq 2 ] || exit 2
    # shellcheck source=bin/fm-task-progress-lib.sh
    . "$SCRIPT_DIR/fm-task-progress-lib.sh"
    fm_task_progress_read "$2"
    exit $?
    ;;
  update-progress)
    shift
    progress_id=${1:-}; [ -n "$progress_id" ] || exit 2
    shift
    task_progress_json=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --progress) task_progress_json=${2:-}; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$task_progress_json" ] || exit 2
    # shellcheck source=bin/fm-task-progress-lib.sh
    . "$SCRIPT_DIR/fm-task-progress-lib.sh"
    # shellcheck disable=SC2031 # The sourced implementation uses a subshell by design.
    fm_task_progress_update "$progress_id" "$task_progress_json"
    exit $?
    ;;
esac

id=${1-}
[ -n "$id" ] || { printf 'usage: fm-task-state.sh <task-id>\n' >&2; exit 2; }
# Ordinary current-state calls first resolve canonical identity/business state.
# Exact effect/resource owners retain their direct provider and endpoint APIs.
record=$(python3 "$SCRIPT_DIR/fm-task-record.py" --data "${FM_DATA_OVERRIDE:-$FM_HOME/data}" progress "$id") || exit $?
business_state=$(printf '%s' "$record" | jq -r '.state') || exit 1
case "$business_state" in
  done|archived|queued) printf 'state: %s · source: task-record · canonical business state\n' "$business_state"; exit 0 ;;
esac
meta="$STATE/$id.meta"

if [ ! -f "$meta" ] || [ -L "$meta" ]; then
  exec "$SCRIPT_DIR/fm-crew-state.sh" "$id"
fi

meta_value() {
  grep "^$1=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

executor=$(meta_value executor)
[ -n "$executor" ] || executor=local-agent
case "$executor" in
  local-agent)
    exec "$SCRIPT_DIR/fm-crew-state.sh" "$id"
    ;;
  cloud-worker)
    provider=$(meta_value provider)
    case "$provider" in
      aime)
        if [ "$DURABLE_ONLY" -eq 1 ]; then
          exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" state "$id" --durable-only
        fi
        exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" state "$id"
        ;;
      *) printf 'state: unknown · source: none · unsupported cloud provider=%s\n' "${provider:-missing}" ;;
    esac
    ;;
  remote-agent)
    provider=$(meta_value provider)
    case "$provider" in
      aime)
        if [ "$DURABLE_ONLY" -eq 1 ]; then
          exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" state "$id" --durable-only
        fi
        exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" state "$id"
        ;;
      ida)
        if [ "$DURABLE_ONLY" -eq 1 ]; then
          exec "$SCRIPT_DIR/fm-remote-agent-ida.sh" state "$id" --durable-only
        fi
        exec "$SCRIPT_DIR/fm-remote-agent-ida.sh" state "$id"
        ;;
      *) printf 'state: unknown · source: none · unsupported remote provider=%s\n' "${provider:-missing}" ;;
    esac
    ;;
  *)
    printf 'state: unknown · source: none · unsupported executor=%s\n' "$executor"
    ;;
esac
