#!/usr/bin/env bash
# bin/fm-jev-worktree-pruner.sh - Wrapper for Jev Worktree Pruner (Pattern 27)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
PRUNER_PY="$SCRIPT_DIR/fm-jev-worktree-pruner.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-worktree-pruner" >&2
  exit 1
fi

exec python3 "$PRUNER_PY" "$@"
