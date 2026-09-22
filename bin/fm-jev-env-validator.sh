#!/usr/bin/env bash
# bin/fm-jev-env-validator.sh - Wrapper for Jev Environment Validator (Pattern 28)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
VALIDATOR_PY="$SCRIPT_DIR/fm-jev-env-validator.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-env-validator" >&2
  exit 1
fi

exec python3 "$VALIDATOR_PY" "$@"
