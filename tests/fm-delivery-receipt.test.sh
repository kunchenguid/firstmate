#!/usr/bin/env bash
# Tests for bin/fm-delivery-receipt.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC="$ROOT/bin/fm-delivery-receipt.sh"
PHASE="$ROOT/bin/fm-delivery-phase.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

run() { FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$RC" "$@"; }

# --- validate inflight ---
cat > "$HOME_DIR/state/t1.delivery.json" <<'EOF'
{"schemaVersion":"firstmate.delivery-receipt.v1","task":{"id":"t1"},"phase":"implementing","phases":[],"updatedAt":"2026-07-22T00:00:00Z"}
EOF
run validate t1 inflight >/dev/null || fail "validate inflight failed"

# --- finalize requires receipt_finalized ---
run finalize t1 --branch fm/t1 --candidate-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da 2>/dev/null && fail "finalize allowed before receipt_finalized"

# --- finalize after phases complete ---
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 accepted >/dev/null
for ph in implementing validating landing landed released deployed smoke_verified receipt_finalized; do
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t1 "$ph" >/dev/null
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t1 "$ph" --result not_applicable >/dev/null
done
run finalize t1 --branch fm/t1 --candidate-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da --merge-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da >/dev/null || fail "finalize failed"
[ -f "$HOME_DIR/data/t1/delivery-receipt.json" ] || fail "receipt missing"
run validate t1 receipt >/dev/null || fail "validate receipt failed"
pass "finalize publishes and validate confirms schema-valid receipt"

# --- local landed identity ---
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t2 accepted >/dev/null
for ph in implementing validating landing landed released deployed smoke_verified receipt_finalized; do
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" start t2 "$ph" >/dev/null
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" complete t2 "$ph" --result not_applicable >/dev/null
done
run finalize t2 --branch fm/t2 --candidate-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da --local-landed-sha 6815f216a8d24bce20a2c2fe6245fe3d270c64da >/dev/null || fail "local-only finalize failed"
grep -q '"localLandedSha"' "$HOME_DIR/data/t2/delivery-receipt.json" || fail "local landed sha missing"
pass "finalize supports local-only landed identity"

pass "all fm-delivery-receipt tests passed"
