#!/usr/bin/env bash
# bin/fm-jev-rebase-healer.sh - Wrapper for Jev Git Lock Auto-Healer (Pattern 33)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
HEALER_PY="$SCRIPT_DIR/fm-jev-rebase-healer.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-rebase-healer" >&2
  exit 1
fi

exec python3 "$HEALER_PY" "$@"
