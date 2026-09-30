#!/usr/bin/env bash
# Backend-neutral Firstmate task retirement.
#
# Usage:
#   fm-task-retire.sh <task-id> [fm-teardown arguments...]
#   fm-task-retire.sh <task-id> --complete-only
#
# --complete-only closes an already accepted/delivered or explicitly archived
# business row while retaining every resource. MAIN only; no provider/backend
# calls. The existing cleanup receipt and backlog-close marker preserve the
# outstanding resource obligation and replay bookkeeping after interruption.
# Accepted scouts need their assessed report; accepted ships need the guarded
# merge owner's generation-bound receipt. Open/unknown goals refuse.
#
# Legacy/local tasks delegate unchanged to fm-teardown.sh.
# Remote tasks use provider-specific terminal/report/decision/source preflight,
# pair backlog closure or retention before volatile-record removal, and preserve
# the complete execution record when that transition cannot be confirmed.
# They never invoke local endpoint or worktree teardown. Legacy AIME
# executor=cloud-worker records remain supported without migration.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

id=${1-}
case "$id" in
  -h|--help)
    printf '%s\n' 'usage: fm-task-retire.sh <task-id> [fm-teardown arguments...]' \
      '       fm-task-retire.sh <task-id> --complete-only' \
      '--complete-only: MAIN records accepted/delivered or archived business completion; retains every resource.'
    exit 0
    ;;
esac
[ -n "$id" ] || { printf 'usage: fm-task-retire.sh <task-id> [fm-teardown arguments...]\n' >&2; exit 2; }
# shellcheck source=bin/fm-task-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
fm_task_lifecycle_forbid_delegated_control "$id" || exit 6
meta="$STATE/$id.meta"

if [ "${2:-}" = --complete-only ]; then
  [ "$#" -eq 2 ] || exit 2
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  # shellcheck source=bin/fm-lease-lib.sh
  . "$SCRIPT_DIR/fm-lease-lib.sh"
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
  # shellcheck source=bin/fm-teardown-endpoint-lib.sh
  . "$SCRIPT_DIR/fm-teardown-endpoint-lib.sh"
  # shellcheck source=bin/fm-gate-refuse-lib.sh
  . "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
  fm_refuse_if_gate_agent
  [ "$(fm_lease_actor)" = main ] || { echo 'REFUSED: business completion belongs to MAIN' >&2; exit 6; }
  fm_lease_valid_id "$id" || exit 2
  fm_lease_guard "$id" 'business completion' || exit $?
  retire_rc=0
  lock=$(fm_meta_lock_path "$meta") || exit 1
  trap 'retire_rc=$?; fm_lock_release "$lock"; fm_lease_guard_release; exit "$retire_rc"' EXIT
  fm_lock_acquire_wait "$lock" || exit 1
  lifecycle=$(fm_task_lifecycle completion-read "$id") || exit 1
  DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
  CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  ID=$id
  ENDPOINT_GENERATION=$(printf '%s' "$lifecycle" | jq -r '.execution_generation')
  ENDPOINT_GOAL=$(printf '%s' "$lifecycle" | jq -r '.goal_revision')
  ENDPOINT_RECEIPT="$STATE/$ID.cleanup.json"
  fm_backlog_transition_applies "$CONFIG" "$DATA" "$(grep '^kind=' "$meta" | tail -1 | cut -d= -f2-)" || {
    echo "REFUSED: automatic business completion unavailable: ${FM_BACKLOG_TRANSITION_ERROR:-$FM_BACKLOG_TRANSITION_SKIP}" >&2
    exit 1
  }
  marker=$(fm_backlog_close_marker_path "$STATE" "$ID") || exit 1
  if [ ! -e "$ENDPOINT_RECEIPT" ] && [ ! -L "$ENDPOINT_RECEIPT" ]; then
    teardown_endpoint_receipt directory_return retained business-complete-resources-retained || exit 1
  fi
  fm_task_lifecycle cleanup-read "$ID" >/dev/null || exit 1
  fm_task_lifecycle link-cleanup "$ID" >/dev/null || exit 1
  args=()
  report="$DATA/$ID/report.md"
  if [ -f "$report" ] && [ ! -L "$report" ]; then args=(--report "data/$ID/report.md"); fi
  delivery=$(printf '%s' "$lifecycle" | jq -r '.completion_delivery.facts.url // empty')
  case "$delivery" in
    https://*) args=(--pr "$delivery") ;;
    local:*) args=(--note 'local main') ;;
  esac
  if [ -e "$marker" ] || [ -L "$marker" ]; then
    fm_backlog_close_marker_validate "$marker" "$DATA" "$ID" "$STATE" || exit 1
    [ "$FM_BACKLOG_CLOSE_VALIDATED_MODE" = complete-only ] || {
      echo 'REFUSED: another pending retirement must be reconciled first' >&2; exit 1;
    }
  else
    fm_backlog_close_marker_write "$STATE" "$ID" "$DATA" "$ENDPOINT_GENERATION" --complete-only "${args[@]+"${args[@]}"}" || exit 1
  fi
  fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA" || exit 1
  printf 'business disposition recorded: %s; resources and cleanup obligation retained\n' "$ID"
  exit 0
fi

if [ ! -f "$meta" ] || [ -L "$meta" ]; then
  exec "$SCRIPT_DIR/fm-teardown.sh" "$@"
fi

meta_value() {
  grep "^$1=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

executor=$(meta_value executor)
[ -n "$executor" ] || executor=local-agent
case "$executor" in
  local-agent)
    exec "$SCRIPT_DIR/fm-teardown.sh" "$@"
    ;;
  cloud-worker)
    [ "$#" -eq 1 ] || {
      printf 'error: cloud task retirement accepts no local teardown flags\n' >&2
      exit 2
    }
    provider=$(meta_value provider)
    case "$provider" in
      aime) exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" retire "$id" ;;
      *) printf 'error: unsupported cloud provider: %s\n' "${provider:-missing}" >&2; exit 1 ;;
    esac
    ;;
  remote-agent)
    [ "$#" -eq 1 ] || {
      printf 'error: remote task retirement accepts no local teardown flags\n' >&2
      exit 2
    }
    provider=$(meta_value provider)
    case "$provider" in
      aime) exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" retire "$id" ;;
      ida) exec "$SCRIPT_DIR/fm-remote-agent-ida.sh" retire "$id" ;;
      *) printf 'error: unsupported remote provider: %s\n' "${provider:-missing}" >&2; exit 1 ;;
    esac
    ;;
  *)
    printf 'error: unsupported task executor: %s\n' "$executor" >&2
    exit 1
    ;;
esac
