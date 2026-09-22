#!/usr/bin/env bash
# tests/fm-jev-rpc-buffer-guard.test.sh - Test suite for Pattern 39 RPC Buffer Guard
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
GUARD_SH="$FM_ROOT/bin/fm-jev-rpc-buffer-guard.sh"

pass() { echo "ok - $*"; }
fail() { echo "not ok - $*" >&2; exit 1; }

TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT
mkdir -p "$TDIR/worker.inbox"
for index in 1 2 3 4 5 6; do
  printf 'fixture message\n' > "$TDIR/worker.inbox/$index.msg"
done

# 1. ShellCheck validation
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$GUARD_SH" || fail "shellcheck failed on fm-jev-rpc-buffer-guard.sh"
  pass "shellcheck clean"
else
  echo "skip: shellcheck not found"
fi

# 2. Help flag verification
"$GUARD_SH" --state-dir "$TDIR" --help >/dev/null 2>&1 || fail "--help failed"
pass "--help works"

# 3. JSON schema verification
json_out=$("$GUARD_SH" --state-dir "$TDIR" --json)
[ -n "$json_out" ] || fail "empty json output"

healthy=$(echo "$json_out" | jq -r '.healthy')
[ "$healthy" = "true" ] || [ "$healthy" = "false" ] || fail "unexpected healthy boolean: $healthy"
pass "healthy field is valid boolean ($healthy)"

inboxes_count=$(echo "$json_out" | jq -r '.total_active_inboxes')
[ "$inboxes_count" -eq 1 ] || fail "expected positive active inboxes count"
pass "total_active_inboxes is positive ($inboxes_count)"

msgs_count=$(echo "$json_out" | jq -r '.total_pending_messages')
[ "$msgs_count" -eq 6 ] || fail "expected positive pending messages count"
pass "total_pending_messages is positive ($msgs_count)"

# 4. Normal check mode
"$GUARD_SH" --state-dir "$TDIR" --check || fail "expected check to pass on healthy queues"
pass "--check passed cleanly"

# 5. Artificial low threshold test
low_thresh_out=$("$GUARD_SH" --state-dir "$TDIR" --max-inbox-msgs 5 --json)
flagged_count=$(echo "$low_thresh_out" | jq -r '.flagged_inboxes_count')
[ "$flagged_count" -eq 1 ] || fail "expected flagged inboxes with low threshold"
pass "low threshold correctly flags inboxes ($flagged_count flagged)"

pass "all Pattern 39 RPC buffer guard tests passed"
