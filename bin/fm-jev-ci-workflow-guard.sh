#!/usr/bin/env bash
# fm-jev-ci-workflow-guard.sh - Shell wrapper for Jev Pattern 10 CI & Workflow Landing Gate Verifier.
#
# Usage:
#   bin/fm-jev-ci-workflow-guard.sh [--repo-dir <path>] [--format text|json|markdown]
#   bin/fm-jev-ci-workflow-guard.sh --repo-dir <path> --test-output <file> [--json]
#   bin/fm-jev-ci-workflow-guard.sh --pr <pr-url-or-number> [--repo <owner/repo>] [--strict]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PYTHON_EXEC="${FM_PYTHON:-python3}"

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-ci-workflow-guard.py" "$@"
