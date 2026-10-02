#!/usr/bin/env bash
# Provider-aware current-state reader above the existing local crew-state
# implementation.
#
# Usage:
#   fm-task-state.sh <task-id>
#   fm-task-state.sh --durable-only <task-id>
#   fm-task-state.sh progress <task-id>
#   fm-task-state.sh update-progress <task-id> --expected-token TOKEN --progress '<json>'
#   fm-task-state.sh progress-list
#   fm-task-state.sh lifecycle|observe|enroll <task-id>   # historical/safety records
#   fm-task-state.sh inspect <task-id> [--evidence <path>]...
#   fm-task-state.sh assess <task-id> --basis <inspect-token> --judgment '<semantic-json>'
#   fm-task-state.sh refresh <task-id>
# Native authenticated route updates use update-brief; see the canonical help.
#   fm-task-state.sh reconcile <task-id> --expected-revision N --record private.json
#   fm-task-state.sh coordinate <task-id> --expected-revision N --record receipt.json
#   fm-task-state.sh branch-patch <task-id> --expected-revision N --record patch.json
#   fm-task-state.sh continuation-policy [--expected-revision N --record policy.json]
#   fm-task-state.sh readback <task-id>
#   fm-task-state.sh action <task-id> --action-id ID --phase PHASE [receipt flags]
# Canonical schema and flags: bin/fm-task-lifecycle.py --help.
#
# Legacy metadata and explicit executor=local-agent records delegate unchanged
# to fm-crew-state.sh.
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
# shellcheck source=bin/fm-task-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
DURABLE_ONLY=0
if [ "${1:-}" = --durable-only ]; then
  DURABLE_ONLY=1
  shift
fi
# Compact progress reads the existing task row without enrollment.
# The historical rich lifecycle owner remains opt-in and independent of the
# provider/process state below; no historical task is enrolled by a state read.
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
    task_progress_expected=''
    task_progress_json=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --expected-token) task_progress_expected=${2:-}; shift 2 ;;
        --progress) task_progress_json=${2:-}; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    [ -n "$task_progress_expected" ] && [ -n "$task_progress_json" ] || exit 2
    # shellcheck source=bin/fm-task-progress-lib.sh
    . "$SCRIPT_DIR/fm-task-progress-lib.sh"
    # shellcheck disable=SC2031 # The sourced implementation uses a subshell by design.
    fm_task_progress_update "$progress_id" "$task_progress_expected" "$task_progress_json"
    exit $?
    ;;
  continuation-policy)
    shift
    if [ "$#" -gt 0 ]; then
      [ "${FM_SUPERVISION_ACTOR:-main}" = main ] || { echo 'REFUSED: continuation policy belongs to MAIN' >&2; exit 6; }
    fi
    policy_home=${FM_HOME:?}
    policy_data=${FM_DATA_OVERRIDE:-${DATA:-$policy_home/data}}
    policy_state=${FM_STATE_OVERRIDE:-${STATE:-$policy_home/state}}
    policy_config=${FM_CONFIG_OVERRIDE:-$policy_home/config}
    FM_HOME="$policy_home" FM_DATA_OVERRIDE="$policy_data" \
      FM_STATE_OVERRIDE="$policy_state" FM_CONFIG_OVERRIDE="$policy_config" \
      python3 "$SCRIPT_DIR/fm-task-lifecycle.py" policy "$@"
    exit $?
    ;;
  lifecycle|inspect|assess|intent-plan|update-brief|refresh|observe|enroll|init|reconcile|action|coordinate|branch-patch|observe-receipt|readback|modes)
    operation=$1; shift
    id=${1:-}; [ -n "$id" ] || exit 2
    shift
    # shellcheck source=bin/fm-task-lifecycle-lib.sh
    . "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
    case "$operation" in
      modes)
        . "$SCRIPT_DIR/fm-timeout-lib.sh"
        fm_run_timed 2 python3 "$SCRIPT_DIR/fm-task-lifecycle.py" modes "$id" ;;
      lifecycle) fm_task_lifecycle read "$id" "$@" ;;
      observe) fm_task_lifecycle observe "$id" "$@" ;;
      inspect)
        if [ "${FM_SUPERVISION_ACTOR:-main}" = branch ]; then
          fm_task_lifecycle_mutate inspect "$id" "$@"
        else
          fm_task_lifecycle inspect "$id" "$@"
        fi
        ;;
      enroll|init) fm_task_lifecycle_mutate init "$id" "$@" ;;
      *) fm_task_lifecycle_mutate "$operation" "$id" "$@" ;;
    esac
    exit $?
    ;;
esac

id=${1-}
[ -n "$id" ] || { printf 'usage: fm-task-state.sh <task-id>\n' >&2; exit 2; }
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
