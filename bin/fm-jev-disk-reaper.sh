#!/usr/bin/env bash
# bin/fm-jev-disk-reaper.sh - Wrapper for Jev Autonomous Worktree Disk Hygiene Reaper (Pattern 26)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REAPER_PY="$SCRIPT_DIR/fm-jev-disk-reaper.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-disk-reaper" >&2
  exit 1
fi

exec python3 "$REAPER_PY" "$@"
