#!/usr/bin/env bash
# Queue and control one exact-head no-mistakes run per isolated Azure cell.
#
# Submission is local and non-billable: it binds a clean pushed head, a
# secret-free credential-lease descriptor, and a credential-free runtime
# bundle, then adds one durable queue record. It never executes a repository
# validation command on the control machine.
#
# Every mutation of Azure capacity requires the exact subscription plus an
# explicit confirmation. Saturation leaves work queued. A failed or ambiguous
# run retains its encrypted worktree and credential lease; close removes only
# exact verified resources after CI-green/current-head proof.
#
# Required for submit:
#   FM_HOME
# Required for Azure control commands:
#   FM_AZURE_TENANT_ID FM_AZURE_SUBSCRIPTION_ID
#   FM_AZURE_NAMING_PREFIX FM_AZURE_STORAGE_NAME
#   FM_AZURE_DEPLOYMENT_GENERATION
# Required only when starting/responding/replacing a cell:
#   FM_AZURE_VALIDATION_WORKTREE_KEY_FILE
#   FM_AZURE_VALIDATION_CREDENTIAL_KEY_FILE
#
# Usage:
#   fm-azure-validation.sh submit --task <id> --task-generation <id> \
#     --validation-generation <id> --intent-file <path> \
#     --credential-lease <secret-free.json> --runtime-bundle <runtime.tar.gz> \
#     [--resource-class validation-heavy|validation-standard] [--repo <path>]
#   fm-azure-validation.sh dispatch --confirm-dispatch \
#     --confirm-subscription <exact-id>
#   fm-azure-validation.sh drive --cell <azv-id> [--wait-seconds 0..300]
#   fm-azure-validation.sh observe|collect|status --cell <azv-id>
#   fm-azure-validation.sh respond --cell <azv-id> --response-file <path>
#   fm-azure-validation.sh replace --cell <azv-id> --confirm-replace \
#     --confirm-subscription <exact-id>
#   fm-azure-validation.sh close --cell <azv-id> --confirm-close \
#     --confirm-subscription <exact-id> --confirm-head <exact-sha>
#   fm-azure-validation.sh retain-failure --cell <azv-id> --confirm-retain \
#     --confirm-subscription <exact-id>
#   fm-azure-validation.sh queue
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

usage() {
  sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  help|-h|--help|"")
    usage
    ;;
  submit|dispatch|drive|observe|collect|status|respond|replace|close|retain-failure|queue)
    exec python3 "$SCRIPT_DIR/fm-azure-validation.py" "$@"
    ;;
  *)
    printf 'AZURE VALIDATION FAILED: unknown command: %s\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
