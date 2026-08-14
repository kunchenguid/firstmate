#!/usr/bin/env bash
# Provider-aware current-state reader above the existing local crew-state
# implementation.
#
# Usage:
#   fm-task-state.sh <task-id>
#
# Legacy metadata and explicit executor=local-agent records delegate unchanged
# to fm-crew-state.sh.
# executor=cloud-worker requires provider=aime and delegates only to AIME's
# durable phase plus authoritative provider readback.
# Unknown executor/provider records fail closed and never fall through to pane,
# worktree, harness, or runtime-backend semantics.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

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
      aime) exec "$SCRIPT_DIR/fm-cloud-research-aime.sh" state "$id" ;;
      *) printf 'state: unknown · source: none · unsupported cloud provider=%s\n' "${provider:-missing}" ;;
    esac
    ;;
  *)
    printf 'state: unknown · source: none · unsupported executor=%s\n' "$executor"
    ;;
esac
