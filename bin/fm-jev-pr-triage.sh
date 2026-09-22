#!/usr/bin/env bash
# fm-jev-pr-triage.sh - Shell wrapper for Jev Pattern 12 PR Root-Cause Triage Engine.
#
# Usage:
#   bin/fm-jev-pr-triage.sh --pr <pr-url-or-number> [--repo <owner/repo>] [--json]
#   bin/fm-jev-pr-triage.sh --pr <pr-url-or-number> [--format markdown|summary|json]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PYTHON_EXEC="${FM_PYTHON:-python3}"

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-pr-triage.py" "$@"
