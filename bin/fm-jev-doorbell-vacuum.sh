#!/usr/bin/env bash
# fm-jev-doorbell-vacuum.sh - Jev Cross-Seat Doorbell & Stale Notification Vacuum (Pattern 18)
#
# Shell wrapper for bin/fm-jev-doorbell-vacuum.py.
# Supports state-dir overrides, retention periods, dry-run previews, and JSON output.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

PYTHON_BIN="python3"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "warning: python3 not available; skipping Jev doorbell vacuum" >&2
  exit 0
fi

ENGINE="$SCRIPT_DIR/fm-jev-doorbell-vacuum.py"
if [ ! -f "$ENGINE" ]; then
  echo "warning: $ENGINE not found; skipping Jev doorbell vacuum" >&2
  exit 0
fi

export FM_STATE="$STATE"
exec "$PYTHON_BIN" "$ENGINE" "$@"
