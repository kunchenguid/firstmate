#!/usr/bin/env bash
# Guarded, default-off task deployment capability.
#
# The private config/deployment-capabilities.json schema, grant, subprocess,
# receipt, recovery, and cleanup contracts are owned by docs/configuration.md.
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
