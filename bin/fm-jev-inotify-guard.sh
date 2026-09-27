#!/usr/bin/env bash
# fm-jev-inotify-guard.sh - Wrapper for Jev Inotify Watch Limit & Saturation Guard (Pattern 40)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-inotify-guard.py" "$@"
