#!/usr/bin/env bash
# fm-jev-temp-sanitizer.sh - Shell wrapper for Jev Pattern 6 Temp Root Sanitizer.
#
# Inspects and repairs /tmp/fm-* directories so fm-spawn.sh never fails with
# "error: task temp root ... already exists and is not a private directory".
#
# Usage:
#   bin/fm-jev-temp-sanitizer.sh --check
#   bin/fm-jev-temp-sanitizer.sh --sanitize [--target <id>]
#   bin/fm-jev-temp-sanitizer.sh --target <id>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_EXEC="python3"

exec "$PYTHON_EXEC" "$SCRIPT_DIR/fm-jev-temp-sanitizer.py" "$@"
