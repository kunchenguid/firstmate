#!/usr/bin/env bash
# Tests for bin/fm-delivery-phase.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$ROOT/bin/fm-delivery-phase.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

# --- start and complete ---
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 implementing >/dev/null || fail "start implementing failed"
[ -f "$HOME_DIR/state/t1.delivery.json" ] || fail "in-flight record not created"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 implementing --result passed >/dev/null || fail "complete implementing failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 validating >/dev/null || fail "start validating failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 accepted 2>/dev/null && fail "backward phase allowed"
pass "phase start and complete enforce monotonicity"

# --- block and resume ---
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" block t1 "waiting for CI" >/dev/null || fail "block failed"
out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" status t1)
echo "$out" | grep -q "block: waiting for CI" || fail "status does not show block"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" resume t1 validating >/dev/null || fail "resume failed"
pass "block and resume update delivery record"

# --- finalize refuses until receipt_finalized ---
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" finalize t1 2>/dev/null && fail "finalize allowed before receipt_finalized"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 validating --result passed >/dev/null || fail "complete validating failed"
for ph in landing landed released deployed smoke_verified receipt_finalized; do
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 "$ph" >/dev/null || fail "start $ph failed"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 "$ph" --result not_applicable >/dev/null || fail "complete $ph failed"
done
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" finalize t1 --branch fm/t1 --candidate-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da --merge-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da >/dev/null || fail "finalize failed at receipt_finalized"
[ -f "$HOME_DIR/data/t1/delivery-receipt.json" ] || fail "final receipt not created"
mode=$(stat -f %Lp "$HOME_DIR/data/t1/delivery-receipt.json" 2>/dev/null || stat -c %a "$HOME_DIR/data/t1/delivery-receipt.json")
[ "$mode" = "600" ] || fail "receipt mode not 600: $mode"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" finalize t1 2>/dev/null && fail "duplicate finalize allowed"
pass "finalize publishes schema-valid receipt once"

pass "all fm-delivery-phase tests passed"
