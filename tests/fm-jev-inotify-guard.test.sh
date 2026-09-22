#!/usr/bin/env bash
# tests/fm-jev-inotify-guard.test.sh - Regression tests for Pattern 40
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SH="$SCRIPT_DIR/../bin/fm-jev-inotify-guard.sh"

echo "Running Pattern 40 regression tests..."

# 1. ShellCheck
shellcheck "$GUARD_SH"
echo "ok - shellcheck clean"

# 2. Help works
"$GUARD_SH" --help >/dev/null
echo "ok - --help works"

python3 "$SCRIPT_DIR/jev-resource-fixtures.py" inotify
