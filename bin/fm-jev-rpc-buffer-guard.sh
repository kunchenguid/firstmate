#!/usr/bin/env bash
# bin/fm-jev-rpc-buffer-guard.sh - Wrapper for Jev RPC Buffer Guard (Pattern 39)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
GUARD_PY="$SCRIPT_DIR/fm-jev-rpc-buffer-guard.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-rpc-buffer-guard" >&2
  exit 1
fi

exec python3 "$GUARD_PY" "$@"
