#!/usr/bin/env bash
# bin/fm-jev-fd-guard.sh - Wrapper for Jev File Descriptor Guard (Pattern 36)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
GUARD_PY="$SCRIPT_DIR/fm-jev-fd-guard.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-fd-guard" >&2
  exit 1
fi

exec python3 "$GUARD_PY" "$@"
