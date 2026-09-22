#!/usr/bin/env bash
# fm-jev-ref-aligner.sh - Wrapper for Jev Cross-Seat Git Ref & Divergence Auto-Realigner (Pattern 24).
#
# Scans git worktrees across treehouse checkouts and project repositories,
# detects branches tracking origin/main or origin/master that are behind upstream,
# and safely fast-forwards clean tracking branches or reports divergence metrics.
#
# Usage:
#   fm-jev-ref-aligner.sh [--roots <dir1,dir2>] [--auto-ff] [--dry-run] [--json]
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
ALIGNER_PY="$FM_ROOT/bin/fm-jev-ref-aligner.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required for fm-jev-ref-aligner.sh" >&2
  exit 1
fi

if [ ! -f "$ALIGNER_PY" ]; then
  echo "error: $ALIGNER_PY not found" >&2
  exit 1
fi

exec python3 "$ALIGNER_PY" "$@"
