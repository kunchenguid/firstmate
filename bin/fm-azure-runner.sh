#!/usr/bin/env bash
# Package and run one exact clean committed repository snapshot on one private,
# disposable, identity-less Azure VM.
#
# This is an opt-in uncredentialed command substrate, not a remote Firstmate,
# Crosscheck reviewer, author worker, or browser node.
# It never falls back to local execution after a class is selected for Azure.
# Every billable run needs an exact subscription confirmation and the landed
# private Azure foundation described in docs/azure-pilot.md.
#
# Required environment:
#   FM_HOME
#   FM_AZURE_TENANT_ID
#   FM_AZURE_SUBSCRIPTION_ID
#   FM_AZURE_NAMING_PREFIX
#   FM_AZURE_STORAGE_NAME
#   FM_AZURE_DEPLOYMENT_GENERATION
#   FM_AZURE_BLOB_PE_NIC_RESOURCE_GUID
# Optional bounded policy:
#   FM_AZURE_RESOURCE_GROUP=rg-firstmate-pilot-eastus-001
#   FM_AZURE_RUNNER_STATE_DIR=$FM_HOME/state/azure-runner
#   FM_AZURE_RUNNER_MAX_CONCURRENCY=4            (1..16; live family quota still gates)
#   FM_AZURE_RUNNER_BUDGET_LIMIT_USD=1000        (1000 or 1500)
#   FM_AZURE_RUNNER_COST_ADMISSION_MODE=strict   (or commissioning-bounded with exact flag)
#   FM_AZURE_RUNNER_SKU=Standard_D4as_v6         (reviewed 4-vCPU current-family SKU)
#   FM_AZURE_RUNNER_CELL_ORDINAL=1               (commissioning only; exact shared slot 1..16)
#
# Usage:
#   fm-azure-runner.sh prepare --task <id> --generation <id> \
#     --resource-class <validation-standard|behavior-heavy|crosscheck-tool> -- <argv...>
#   fm-azure-runner.sh run --confirm-run --confirm-subscription <exact-id> \
#     [--confirm-cost-admission-mode commissioning-bounded] \
#     --task <id> --generation <id> --resource-class <class> \
#     [--source-ref refs/heads/<name>] [--private-snapshot-from-head] \
#     [--wall-seconds N] [--dependency <tracked-relative-path>]... \
#     [--artifact <relative-output>]... -- <argv...>
#   fm-azure-runner.sh resume --invocation <id>
#   fm-azure-runner.sh retry --invocation <id> --confirm-run \
#     --confirm-subscription <exact-id>
#   fm-azure-runner.sh cleanup --invocation <id>
#   fm-azure-runner.sh status --invocation <id>
#   fm-azure-runner.sh queue
#   fm-azure-runner.sh cost
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  help|-h|--help|"")
    usage
    ;;
  prepare|run|resume|retry|cleanup|status|queue|cost)
    exec python3 "$SCRIPT_DIR/fm-azure-runner.py" "$@"
    ;;
  *)
    printf 'AZURE RUNNER FAILED: unknown command: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
