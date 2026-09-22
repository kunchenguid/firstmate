#!/usr/bin/env bash
# fm-jev-pane-reaper.sh - Jev Harness Pane & Completed Seat Auto-Reconciler (Pattern 20)
#
# Shell wrapper for bin/fm-jev-pane-reaper.py.
# Supports dry-run previews, specific pane targeting, session overrides, and JSON telemetry.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PYTHON_BIN="python3"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "warning: python3 not available; skipping Jev pane reaper" >&2
  exit 0
fi

ENGINE="$SCRIPT_DIR/fm-jev-pane-reaper.py"
if [ ! -f "$ENGINE" ]; then
  echo "warning: $ENGINE not found; skipping Jev pane reaper" >&2
  exit 0
fi

exec "$PYTHON_BIN" "$ENGINE" "$@"
