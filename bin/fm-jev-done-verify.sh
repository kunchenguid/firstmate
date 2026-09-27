#!/usr/bin/env bash
# fm-jev-done-verify.sh - Shell wrapper for Jev Definition of Done Verifier.
#
# Inspects declared task completion (`done:`) to prevent fake-done states,
# unpushed branches, missing PRs, and ephemeral host dependencies.
#
# Usage:
#   fm-jev-done-verify.sh --task <task-id> [--worktree <path>] [--status-line <str>] [--json]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

VERIFY_PY="$FM_ROOT/bin/fm-jev-done-verify.py"

if [ ! -x "$VERIFY_PY" ]; then
  # Fail-open if python engine missing
  exit 0
fi

# Run python engine, passing through all arguments
exec python3 "$VERIFY_PY" "$@"
