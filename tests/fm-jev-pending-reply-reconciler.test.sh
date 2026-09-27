#!/usr/bin/env bash
# tests/fm-jev-pending-reply-reconciler.test.sh - verify Jev Pending-Reply Auto-Reconciler
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECONCILER_SH="$ROOT/bin/fm-jev-pending-reply-reconciler.sh"
RECONCILER_PY="$ROOT/bin/fm-jev-pending-reply-reconciler.py"

[ -x "$RECONCILER_SH" ] || fail "bin/fm-jev-pending-reply-reconciler.sh missing or not executable"
[ -x "$RECONCILER_PY" ] || fail "bin/fm-jev-pending-reply-reconciler.py missing or not executable"

TDIR=$(fm_test_tmproot fm-jev-reconcile-test)
MOCK_STATE="$TDIR/state"
mkdir -p "$MOCK_STATE"

export FM_STATE_OVERRIDE="$MOCK_STATE"

# Create mock seat status file with 1 routine reread, 1 agents.md reread, and 1 actionable work order
MOCK_SEAT="$MOCK_STATE/test-seat.status"
cat <<'EOF' > "$MOCK_SEAT"
done: corr=111 initial setup done
blocked [key=pending-reply-aaa111]: pending-reply-missed: task=test-seat pending-reply-id=aaa111 request=CONFIG_REREAD: /opt/ra/firstmate/state/.fm-inherited-config-reread.20260910.001
blocked [key=pending-reply-bbb222]: pending-reply-missed: task=test-seat pending-reply-id=bbb222 request=firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.
blocked [key=pending-reply-ccc333]: pending-reply-missed: task=test-seat pending-reply-id=ccc333 request=P0 urgent directive: Deploy hotfix for prescription e-sign webhook failure immediately
EOF

# 1. Dry run inspection
out_dry=$("$RECONCILER_SH" --seat test-seat)
assert_contains "$out_dry" "Total open blocked keys inspected: 3" "inspected 3 open blocks"
assert_contains "$out_dry" "Superseded bookkeeping identified: 2" "identified 2 routine bookkeeping items"
assert_contains "$out_dry" "Actionable instructions preserved:  1" "preserved 1 actionable work order"
assert_contains "$out_dry" "[RECONCILE] test-seat (aaa111)" "marked config reread for reconcile"
assert_contains "$out_dry" "[RECONCILE] test-seat (bbb222)" "marked agents reread for reconcile"
assert_contains "$out_dry" "[PRESERVE] test-seat (ccc333)" "preserved hotfix directive"

# Verify status file was NOT modified in dry run
[ "$(grep -c '^resolved ' "$MOCK_SEAT")" -eq 0 ] || fail "dry run should not modify status file"

# 2. JSON output mode
json_out=$("$RECONCILER_SH" --seat test-seat --json)
assert_contains "$json_out" '"reconciled": 2' "json reports 2 reconciled"
assert_contains "$json_out" '"preserved": 1' "json reports 1 preserved"

# 3. Live reconciliation execution
out_apply=$("$RECONCILER_SH" --seat test-seat --reconcile)
assert_contains "$out_apply" "Reconcile applied to status logs:  YES" "applied flag set"

# Verify status file was modified with compliant resolution lines
[ "$(grep -c '^resolved ' "$MOCK_SEAT")" -eq 2 ] || fail "applied reconcile should append 2 resolution lines"
assert_contains "$(cat "$MOCK_SEAT")" "resolved [key=pending-reply-aaa111]: pending-reply-resolved: task=test-seat pending-reply-id=aaa111 via=jev-auto-reconcile" "appended aaa111 resolution"
assert_contains "$(cat "$MOCK_SEAT")" "resolved [key=pending-reply-bbb222]: pending-reply-resolved: task=test-seat pending-reply-id=bbb222 via=jev-auto-reconcile" "appended bbb222 resolution"

# 4. Subsequent run should now only find 1 remaining open block (the preserved hotfix)
out_after=$("$RECONCILER_SH" --seat test-seat)
assert_contains "$out_after" "Total open blocked keys inspected: 1" "only 1 open block remains"
assert_contains "$out_after" "Superseded bookkeeping identified: 0" "0 bookkeeping remaining"
assert_contains "$out_after" "[PRESERVE] test-seat (ccc333)" "ccc333 remains preserved"

# 5. Telemetry verification
[ -f "$MOCK_STATE/.jev-pending-reply-telemetry" ] || fail "telemetry log missing"
telem=$(cat "$MOCK_STATE/.jev-pending-reply-telemetry")
assert_contains "$telem" "reconcile" "telemetry recorded reconcile"
assert_contains "$telem" "preserve" "telemetry recorded preserve"

pass "all fm-jev-pending-reply-reconciler tests passed"
