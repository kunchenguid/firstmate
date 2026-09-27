#!/usr/bin/env bash
# tests/fm-jev-alert-correlator.test.sh - verify Jev Alert Correlator & Pager Fatigue Dampening
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CORRELATOR_SH="$ROOT/bin/fm-jev-alert-correlator.sh"
CORRELATOR_PY="$ROOT/bin/fm-jev-alert-correlator.py"

[ -x "$CORRELATOR_SH" ] || fail "bin/fm-jev-alert-correlator.sh missing or not executable"
[ -x "$CORRELATOR_PY" ] || fail "bin/fm-jev-alert-correlator.py missing or not executable"

TDIR=$(fm_test_tmproot fm-jev-alert-test)
MOCK_STATE="$TDIR/state"
export FM_ALERT_CACHE_OVERRIDE="$TDIR/cache.json"
mkdir -p "$MOCK_STATE"

# Setup active hold for email ingest
cat > "$MOCK_STATE/captain-hold-email-ingest.status" <<'EOF'
state: on-hold · hold: email_ingest paused intentionally for privacy filter
EOF

# 1. Alert matching active hold is absorbed (exit 0)
out_hold=$(FM_STATE_OVERRIDE="$MOCK_STATE" "$CORRELATOR_SH" \
  --alert "stack-monitor critical: email_ingest heartbeat stale (age_ms=88354348)" 2>&1)
rc_hold=$?
[ "$rc_hold" -eq 0 ] || fail "alert matching hold was not absorbed (exit $rc_hold)"
assert_contains "$out_hold" "absorb [active_email_ingest_hold]" "detected hold match"

# 2. Truly novel alert is escalated (exit 2)
set +e
out_novel=$(FM_STATE_OVERRIDE="$MOCK_STATE" "$CORRELATOR_SH" \
  --alert "database deadlock detected on primary postgres cluster" 2>&1)
rc_novel=$?
set -e
[ "$rc_novel" -eq 2 ] || fail "novel alert was not escalated (exit $rc_novel)"
assert_contains "$out_novel" "escalate" "novel alert escalated"

# 3. Telemetry is written
[ -f "$MOCK_STATE/.jev-alert-telemetry" ] || fail "telemetry file was not created"
telem_content=$(cat "$MOCK_STATE/.jev-alert-telemetry")
assert_contains "$telem_content" "absorb" "telemetry contains absorb"
assert_contains "$telem_content" "escalate" "telemetry contains escalate"

pass "all fm-jev-alert-correlator tests passed"
