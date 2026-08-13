#!/usr/bin/env bash
# Queue-driven provider-neutral lifecycle for one-task elastic workers.
#
# This wrapper never decides that work is landed and never deletes ambiguous
# work. The exact lifecycle, Azure setup, release receipt, recovery, cost, and
# acceptance contracts live in docs/azure-workers.md.
#
# Required environment:
#   FM_HOME
#   FM_AZURE_SUBSCRIPTION_ID
#   FM_AZURE_DEPLOYMENT_GENERATION
#   FM_AZURE_OWNER_TAG
#   FM_AZURE_NAMING_PREFIX
#   FM_AZURE_STORAGE_NAME (Azure adapter)
#
# Optional policy:
#   FM_AZURE_WORKER_POLICY_PHASE=commissioning|steady
#   FM_AZURE_WORKER_STEADY_TARGET_USD=1000
#   FM_AZURE_WORKER_COMMISSIONING_CEILING_USD=1500
#   FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD=3500
#   FM_AZURE_WORKER_ADMISSION_HOURS=24
#   FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=300
#   FM_AZURE_WORKER_MAX=16
#   FM_AZURE_WORKER_WARM_IDLE=0
#   FM_WORKER_PROVIDER_COMMAND='python3 <provider-adapter>'
#
# Usage:
#   fm-worker-lifecycle.sh request <exact identity flags> --eligible
#   fm-worker-lifecycle.sh reconcile [--apply --confirm-subscription <uuid>]
#   fm-worker-lifecycle.sh capacity-reserve <exact specialized reservation flags>
#   fm-worker-lifecycle.sh capacity-reserve-shape <exact complete-shape constituents>
#   fm-worker-lifecycle.sh capacity-release <exact fence and cleanup receipt>
#   fm-worker-lifecycle.sh execute <exact assignment flags> -- <argv...>
#   fm-worker-lifecycle.sh authority-receipt <exact assignment flags> --output <json>
#   fm-worker-lifecycle.sh proof-template --task <id> --task-generation <id>
#   fm-worker-lifecycle.sh release --task <id> --task-generation <id> --proof-file <json>
#   fm-worker-lifecycle.sh resume <exact recovery flags>
#   fm-worker-lifecycle.sh steer <exact assignment flags>
#   fm-worker-lifecycle.sh status [--live] [--json]
#   fm-worker-lifecycle.sh acceptance-plan
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

case "${1:-}" in
  request|release|resume|steer|execute|authority-receipt|capacity-reserve|capacity-reserve-shape|capacity-release)
    fm_refuse_if_gate_agent
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  reconcile)
    for argument in "$@"; do
      if [ "$argument" = --apply ]; then
        fm_refuse_if_gate_agent
        break
      fi
    done
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  proof-template|status|acceptance-plan)
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" "$@"
    ;;
  help|-h|--help|"")
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" --help
    ;;
  *)
    printf 'ELASTIC WORKER REFUSED: unknown command: %s\n' "$1" >&2
    exec python3 "$SCRIPT_DIR/fm-worker-lifecycle.py" --help
    ;;
esac
