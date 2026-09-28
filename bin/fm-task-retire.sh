#!/usr/bin/env bash
# Backend-neutral Firstmate task retirement.
#
# Usage:
#   fm-task-retire.sh <task-id> [fm-teardown arguments...]
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
[ -n "$id" ] || { printf 'usage: fm-task-retire.sh <task-id> [fm-teardown arguments...]\n' >&2; exit 2; }
# shellcheck source=bin/fm-task-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-task-lifecycle-lib.sh"
fm_task_lifecycle_forbid_delegated_control "$id" || exit 6
meta="$STATE/$id.meta"

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
