#!/usr/bin/env bash
# tests/fm-jev-temp-sanitizer.test.sh - Verification suite for Pattern 6 Temp Root Sanitizer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SANITIZER="$FM_ROOT/bin/fm-jev-temp-sanitizer.sh"

TEST_TMP="/tmp/fm-test-sanitizer-$$"
mkdir -p "$TEST_TMP"
# Intentionally set group-writable permissions (0775)
chmod 775 "$TEST_TMP"
echo "sample content" > "$TEST_TMP/file.txt"

cleanup() {
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

echo "1. Verify --check detects group-writable directory..."
CHECK_OUTPUT=$("$SANITIZER" --target "test-sanitizer-$$" --check 2>&1 || true)
if [[ "$CHECK_OUTPUT" != *"violate mode 0700"* ]] && [[ "$CHECK_OUTPUT" != *"has mode"* ]]; then
  echo "FAIL: Expected check to report violation, got: $CHECK_OUTPUT" >&2
  exit 1
fi
echo "ok - check reported violation as expected"

echo "2. Verify --sanitize fixes permissions to 0700..."
SAN_OUTPUT=$("$SANITIZER" --target "test-sanitizer-$$" --sanitize)
if [[ "$SAN_OUTPUT" != *"Sanitized"* ]]; then
  echo "FAIL: Expected sanitize confirmation, got: $SAN_OUTPUT" >&2
  exit 1
fi

CURRENT_MODE=$(stat -c '%a' "$TEST_TMP")
if [[ "$CURRENT_MODE" != "700" ]]; then
  echo "FAIL: Expected mode 700, got: $CURRENT_MODE" >&2
  exit 1
fi
echo "ok - mode updated to 700"

echo "3. Verify fm-spawn.sh invariant check passes..."
# This is the exact check from fm-spawn.sh lines 4058-4060
if [ -L "$TEST_TMP" ] || [ ! -d "$TEST_TMP" ] || [ ! -O "$TEST_TMP" ] ||
   [ -n "$(find "$TEST_TMP" -prune \( -perm -g=w -o -perm -o=w \) -print 2>/dev/null)" ]; then
  echo "FAIL: fm-spawn invariant check failed on sanitized dir" >&2
  exit 1
fi
echo "ok - fm-spawn invariant check passed"

echo "4. Verify file contents preserved..."
if [[ "$(< "$TEST_TMP/file.txt")" != "sample content" ]]; then
  echo "FAIL: File content inside sanitized dir was altered" >&2
  exit 1
fi
echo "ok - file contents preserved"

echo "5. Verify JSON output format..."
JSON_OUTPUT=$("$SANITIZER" --target "test-sanitizer-$$" --check --json)
if ! printf '%s\n' "$JSON_OUTPUT" | grep -q '"total_scanned":'; then
  echo "FAIL: Expected JSON structure, got: $JSON_OUTPUT" >&2
  exit 1
fi
echo "ok - JSON format verified"

echo "ok - all fm-jev-temp-sanitizer tests passed"
