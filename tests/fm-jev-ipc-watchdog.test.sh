#!/usr/bin/env bash
# tests/fm-jev-ipc-watchdog.test.sh - Test suite for Pattern 32 IPC Socket Leak Watchdog
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
WATCHDOG_SH="$FM_ROOT/bin/fm-jev-ipc-watchdog.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

TDIR=$(mktemp -d "/tmp/fm-jev-ipc-test.XXXXXX")
cleanup() { rm -rf "$TDIR"; }
trap cleanup EXIT

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$WATCHDOG_SH" || fail "shellcheck failed on fm-jev-ipc-watchdog.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$WATCHDOG_SH" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. Create a dead mock socket and test detection
MOCK_SOCK="$TDIR/dead.sock"
python3 -c "import socket; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind('$MOCK_SOCK'); s.close()"

json_out=$("$WATCHDOG_SH" --patterns "$MOCK_SOCK" --json)
[ -n "$json_out" ] || fail "empty json output"

found=$(echo "$json_out" | jq -r '.summary.total_sockets_found')
[ "$found" -eq 1 ] || fail "expected 1 socket found, got $found"
pass "discovered mock dead socket ($found found)"

abandoned=$(echo "$json_out" | jq -r '.summary.abandoned_sockets_count')
[ "$abandoned" -eq 1 ] || fail "expected 1 abandoned socket, got $abandoned"
pass "correctly classified mock dead socket as abandoned ($abandoned)"

healthy=$(echo "$json_out" | jq -r '.summary.healthy')
[ "$healthy" = "false" ] || fail "expected healthy=false when abandoned socket present"
pass "healthy flag is false on abandoned socket"

pass "all Pattern 32 IPC watchdog tests passed"
