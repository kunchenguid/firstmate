#!/usr/bin/env bash
# bin/fm-jev-dump-sweeper.sh - Wrapper for Jev Dump & Log Sweeper (Pattern 34)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SWEEPER_PY="$SCRIPT_DIR/fm-jev-dump-sweeper.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-dump-sweeper" >&2
  exit 1
fi

exec python3 "$SWEEPER_PY" "$@"
