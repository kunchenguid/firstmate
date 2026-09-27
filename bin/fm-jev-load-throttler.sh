#!/usr/bin/env bash
# bin/fm-jev-load-throttler.sh - Wrapper for Jev Load & Memory Throttler (Pattern 30)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
THROTTLER_PY="$SCRIPT_DIR/fm-jev-load-throttler.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-load-throttler" >&2
  exit 1
fi

exec python3 "$THROTTLER_PY" "$@"
