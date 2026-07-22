#!/usr/bin/env bash
# Delivery-record integration test for bin/fm-crew-state.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ST="$ROOT/bin/fm-crew-state.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/t1"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

cat > "$HOME_DIR/state/t1.meta" <<'EOF'
worktree=/nonexistent/wtree
window=fm-t1
project=x
kind=ship
mode=direct-PR
EOF

cat > "$HOME_DIR/state/t1.delivery.json" <<'EOF'
{"schemaVersion":"firstmate.delivery-receipt.v1","task":{"id":"t1"},"phase":"implementing","phases":[],"updatedAt":"2026-07-22T00:00:00Z"}
EOF
chmod 600 "$HOME_DIR/state/t1.delivery.json"

out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$ST" t1)
echo "$out" | grep -q "state: unknown" || fail "stale delivery record masked dead worker: $out"
echo "$out" | grep -q "source: none" || fail "dead worker should have no liveness source: $out"
pass "delivery record does not fabricate worker liveness"

chmod 644 "$HOME_DIR/state/t1.delivery.json"
out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$ST" t1)
echo "$out" | grep -q "state: failed" || fail "unsafe delivery record did not fail closed: $out"
echo "$out" | grep -q "source: delivery-trust" || fail "unsafe delivery record did not surface trust source: $out"
pass "delivery trust failures surface instead of degrading"

pass "all fm-crew-state-delivery tests passed"
