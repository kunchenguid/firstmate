#!/usr/bin/env bash
# fm-jev-seat-reconciler.sh - Shell wrapper for Jev Pattern 11 Dormant Seat Reconciler.
#
# Usage:
#   bin/fm-jev-seat-reconciler.sh [--session firstmate] [--dry-run] [--json]
#   bin/fm-jev-seat-reconciler.sh --reconcile [--json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PYTHON_EXEC="${FM_PYTHON:-python3}"

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-seat-reconciler.py" "$@"
