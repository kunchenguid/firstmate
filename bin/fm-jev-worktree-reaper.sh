#!/usr/bin/env bash
# fm-jev-worktree-reaper.sh - Jev Git Worktree Stale Prune & Detached Branch Reaper (Pattern 19)
#
# Shell wrapper for bin/fm-jev-worktree-reaper.py.
# Supports repo directory overrides, base branch specifications, dry-run previews, and JSON telemetry.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

PYTHON_BIN="python3"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "warning: python3 not available; skipping Jev worktree reaper" >&2
  exit 0
fi

ENGINE="$SCRIPT_DIR/fm-jev-worktree-reaper.py"
if [ ! -f "$ENGINE" ]; then
  echo "warning: $ENGINE not found; skipping Jev worktree reaper" >&2
  exit 0
fi

exec "$PYTHON_BIN" "$ENGINE" "$@"
