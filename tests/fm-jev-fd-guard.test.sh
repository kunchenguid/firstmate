#!/usr/bin/env bash
# tests/fm-jev-fd-guard.test.sh - Test suite for Pattern 36 Host File Descriptor Guard
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
GUARD_SH="$FM_ROOT/bin/fm-jev-fd-guard.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$GUARD_SH" || fail "shellcheck failed on fm-jev-fd-guard.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$GUARD_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

python3 "$SCRIPT_DIR/jev-resource-fixtures.py" fd
