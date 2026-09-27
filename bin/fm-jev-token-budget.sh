#!/usr/bin/env bash
# fm-jev-token-budget.sh - Shell wrapper for Jev Memory Token Budget Enforcer (Pattern 16)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(command -v python3 || true)"

if [[ -z "${PYTHON_BIN}" ]]; then
  echo "Jev Token Budget: python3 not found, failing open" >&2
  exit 0
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-token-budget.py" "$@"
