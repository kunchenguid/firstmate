#!/usr/bin/env bash
# Delegate an approved local-only task merge to the one shared exact-candidate
# merge execution boundary.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
"$FM_ROOT/bin/fm-guard.sh" || true
exec "$SCRIPT_DIR/fm-merge-execute.sh" local "$@"
