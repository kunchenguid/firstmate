#!/usr/bin/env bash
# bin/fm-jev-redis-watchdog.sh - Wrapper for Jev Redis/DB Leaked Connection Watchdog (Pattern 29)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WATCHDOG_PY="$SCRIPT_DIR/fm-jev-redis-watchdog.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-redis-watchdog" >&2
  exit 1
fi

exec python3 "$WATCHDOG_PY" "$@"
