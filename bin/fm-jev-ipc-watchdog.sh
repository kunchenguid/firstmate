#!/usr/bin/env bash
# bin/fm-jev-ipc-watchdog.sh - Wrapper for Jev IPC Socket Leak Watchdog (Pattern 32)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WATCHDOG_PY="$SCRIPT_DIR/fm-jev-ipc-watchdog.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-ipc-watchdog" >&2
  exit 1
fi

exec python3 "$WATCHDOG_PY" "$@"
