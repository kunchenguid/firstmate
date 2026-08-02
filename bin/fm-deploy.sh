#!/usr/bin/env bash
# Guarded, default-off task deployment capability.
#
# docs/configuration.md owns the operator-facing capability and schema.
# This entrypoint's usage block owns the command spelling, while fm-deploy.js
# owns the grant, subprocess, receipt, recovery, and cleanup mechanics.
# This shell entrypoint deliberately delegates the file-identity-sensitive work
# to Node so deployment never depends on shell parsing or word splitting.
#
# Usage:
#   fm-deploy.sh validate-config
#   fm-deploy.sh issue <task-id> <profile> --authority-ref <safe-slug>
#   fm-deploy.sh run <grant-id>
#   fm-deploy.sh deploy <task-id> <profile> --authority-ref <safe-slug>
#   fm-deploy.sh revoke <grant-id>
#   fm-deploy.sh recover <task-id>
#   fm-deploy.sh recover-stale
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "$SCRIPT_DIR/fm-deploy.js" "$@"
