#!/usr/bin/env bash
# fm-jev-artifact-dedup.sh - Jev Cross-Seat Asset & Artifact Cache De-Duplicator (Pattern 21)
#
# Shell wrapper for bin/fm-jev-artifact-dedup.py.
# Supports custom root directories, size thresholds, dry-run previews, and JSON telemetry.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

PYTHON_BIN="python3"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "warning: python3 not available; skipping Jev artifact dedup" >&2
  exit 0
fi

ENGINE="$SCRIPT_DIR/fm-jev-artifact-dedup.py"
if [ ! -f "$ENGINE" ]; then
  echo "warning: $ENGINE not found; skipping Jev artifact dedup" >&2
  exit 0
fi

exec "$PYTHON_BIN" "$ENGINE" "$@"
