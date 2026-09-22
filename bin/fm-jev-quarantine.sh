#!/usr/bin/env bash
# fm-jev-quarantine.sh - Shell wrapper for Jev Test Flake Quarantine Engine (Pattern 17)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(command -v python3 || true)"

if [[ -z "${PYTHON_BIN}" ]]; then
  echo "Jev Flake Quarantine: python3 not found, failing open" >&2
  exit 0
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-quarantine.py" "$@"
