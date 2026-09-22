#!/usr/bin/env bash
# bin/fm-jev-db-pool-probe.sh - Wrapper for Jev DB Pool Health Probe (Pattern 31)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PROBE_PY="$SCRIPT_DIR/fm-jev-db-pool-probe.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-db-pool-probe" >&2
  exit 1
fi

exec python3 "$PROBE_PY" "$@"
