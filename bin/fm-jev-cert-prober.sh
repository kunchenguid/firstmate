#!/usr/bin/env bash
# bin/fm-jev-cert-prober.sh - Wrapper for Jev SSL/TLS Certificate Prober (Pattern 38)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PROBER_PY="$SCRIPT_DIR/fm-jev-cert-prober.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-cert-prober" >&2
  exit 1
fi

exec python3 "$PROBER_PY" "$@"
