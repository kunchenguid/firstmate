#!/usr/bin/env bash
# fm-jev-worker-reaper.sh - Shell wrapper for Jev Pattern 8 Worker Reaper.
#
# Inspects and reaps dead/halted child workers whose Herdr panes and worktree
# records remain allocated, preventing endpoint collisions during replacement dispatches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-worker-reaper.py" "$@"
