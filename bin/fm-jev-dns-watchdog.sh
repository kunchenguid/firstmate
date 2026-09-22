#!/usr/bin/env bash
# bin/fm-jev-dns-watchdog.sh - Wrapper for Jev DNS Watchdog (Pattern 37)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
WATCHDOG_PY="$SCRIPT_DIR/fm-jev-dns-watchdog.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-dns-watchdog" >&2
  exit 1
fi

exec python3 "$WATCHDOG_PY" "$@"
