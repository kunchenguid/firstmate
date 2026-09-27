#!/usr/bin/env bash
# fm-jev-alert-silencer.sh - Wrapper for Jev Multi-Agent Alert Storm & Webhook Throttler (Pattern 43)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/fm-jev-alert-silencer.py" "$@"
