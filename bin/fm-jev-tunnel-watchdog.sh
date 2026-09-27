#!/usr/bin/env bash
# bin/fm-jev-tunnel-watchdog.sh - Wrapper for Jev Idle SSH & Tunnel Watchdog (Pattern 35)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WATCHDOG_PY="$SCRIPT_DIR/fm-jev-tunnel-watchdog.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-tunnel-watchdog" >&2
  exit 1
fi

exec python3 "$WATCHDOG_PY" "$@"
