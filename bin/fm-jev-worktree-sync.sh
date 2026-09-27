#!/usr/bin/env bash
# fm-jev-worktree-sync.sh - Shell wrapper for Jev Cross-Seat Worktree Convergence Engine (Pattern 15)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$(command -v python3 || true)"

if [[ -z "${PYTHON_BIN}" ]]; then
  echo "Jev Worktree Sync: python3 not found, failing open" >&2
  exit 0
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/fm-jev-worktree-sync.py" "$@"
