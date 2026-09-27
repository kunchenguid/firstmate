#!/usr/bin/env bash
# fm-jev-port-guard.sh - Wrapper for Jev Ephemeral Port & Socket Bind Exhaustion Guard (Pattern 41)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-port-guard.py" "$@"
