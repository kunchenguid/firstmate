#!/usr/bin/env bash
# fm-jev-stall-guard.sh - Shell wrapper for Jev Long-Run Task Activity Prober (Pattern 14)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(command -v python3 || true)"

if [[ -z "${PYTHON_BIN}" ]]; then
  echo "Jev Stall Guard: python3 not found, failing open" >&2
  exit 0
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 --seat SEAT [--worktree WT] [--suppress] [--json]" >&2
  exit 2
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-stall-guard.py" "$@"
