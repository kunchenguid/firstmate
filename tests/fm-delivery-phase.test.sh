#!/usr/bin/env bash
# Tests for bin/fm-delivery-phase.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$ROOT/bin/fm-delivery-phase.sh"
EVIDENCE="$ROOT/bin/fm-evidence-run.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

# --- start and complete ---
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" init t1 --project firstmate --delivery-mode direct-PR --yolo on >/dev/null || fail "init failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 validating 2>/dev/null && fail "phase skip allowed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 implementing >/dev/null || fail "start implementing failed"
[ -f "$HOME_DIR/state/t1.delivery.json" ] || fail "in-flight record not created"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 implementing --result passed >/dev/null || fail "complete implementing failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 validating >/dev/null || fail "start validating failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 accepted 2>/dev/null && fail "backward phase allowed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 validating --result passed 2>/dev/null && fail "evidence-free validation allowed"
pass "phase start and complete enforce contiguous evidence-aware progression"

# --- block and resume ---
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" block t1 "waiting for CI" >/dev/null || fail "block failed"
out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" status t1)
echo "$out" | grep -q "block: waiting for CI" || fail "status does not show block"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" resume t1 validating >/dev/null || fail "resume failed"
pass "block and resume update delivery record"

# --- finalize refuses until receipt_finalized ---
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" finalize t1 --branch fm/t1 --candidate-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da --merge-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da 2>/dev/null && fail "finalize allowed before receipt_finalized"
cat > "$HOME_DIR/state/t1.meta" <<'EOF'
candidateSha=6815f216a8d24bce20a2c2fe6245fe3d270c64da
EOF
evidence_out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EVIDENCE" run t1 validating 1 deterministic-validation '["printf","validated"]') || fail "validation evidence failed"
evidence_hash=$(printf '%s\n' "$evidence_out" | sed -n 's/^manifestSha256=//p')
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 validating --result passed --evidence "$evidence_hash" >/dev/null || fail "complete validating failed"
for ph in landing landed; do
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 "$ph" >/dev/null || fail "start $ph failed"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 "$ph" --result passed >/dev/null || fail "complete $ph failed"
done
for ph in released deployed smoke_verified; do
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 "$ph" >/dev/null || fail "start $ph failed"
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 "$ph" --result not_applicable >/dev/null || fail "complete $ph failed"
done
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 receipt_finalized >/dev/null || fail "start receipt_finalized failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 receipt_finalized --result passed >/dev/null || fail "complete receipt_finalized failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" finalize t1 --branch fm/t1 --candidate-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da --merge-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da >/dev/null || fail "finalize failed at receipt_finalized"
[ -f "$HOME_DIR/data/t1/delivery-receipt.json" ] || fail "final receipt not created"
mode=$(stat -f %Lp "$HOME_DIR/data/t1/delivery-receipt.json" 2>/dev/null || stat -c %a "$HOME_DIR/data/t1/delivery-receipt.json")
[ "$mode" = "600" ] || fail "receipt mode not 600: $mode"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" finalize t1 --branch fm/t1 --candidate-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da --merge-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da 2>/dev/null && fail "duplicate finalize allowed"
pass "finalize publishes schema-valid receipt once"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" init t2 --project firstmate --delivery-mode direct-PR --yolo off >/dev/null || fail "init t2 failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t2 implementing >/dev/null || fail "start t2 failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t2 implementing --result failed >/dev/null || fail "record failed phase failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t2 validating 2>/dev/null && fail "progression after failed phase allowed"
pass "failed phases block later progression"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" init t3 --project firstmate --delivery-mode direct-PR --yolo off >/dev/null || fail "init t3 failed"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t3 implementing >"$TMP/t3-a" 2>&1 & p1=$!
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t3 implementing >"$TMP/t3-b" 2>&1 & p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
if [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ]; then fail "concurrent phase starts both succeeded"; fi
if [ "$r1" -ne 0 ] && [ "$r2" -ne 0 ]; then fail "concurrent phase starts both failed"; fi
python3 - "$HOME_DIR/state/t3.delivery.json" <<'PYEOF' || fail "concurrent phase mutation corrupted lifecycle"
import json, sys
doc = json.load(open(sys.argv[1]))
assert [phase["name"] for phase in doc["phases"]] == ["accepted", "implementing"]
PYEOF
pass "concurrent phase mutation is serialized without lost updates"

pass "all fm-delivery-phase tests passed"
