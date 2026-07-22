#!/usr/bin/env bash
# Results-first teardown receipt test for bin/fm-teardown.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
PHASE="$ROOT/bin/fm-delivery-phase.sh"
EVIDENCE="$ROOT/bin/fm-evidence-run.sh"
RECEIPT="$ROOT/bin/fm-delivery-receipt.sh"
SHA=6815f216a8d24bce20a2c2fe6245fe3d270c64da

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/t1"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

# Create a fake meta pointing to a non-existent worktree so other safety checks
# report unknown rather than blocking on a real worktree.
cat > "$HOME_DIR/state/t1.meta" <<'EOF'
worktree=/nonexistent/worktree
window=fm-t1
project=/nonexistent/project
kind=ship
mode=direct-PR
candidateSha=6815f216a8d24bce20a2c2fe6245fe3d270c64da
EOF

# No delivery record: teardown proceeds through existing safety checks.
# With delivery record but no receipt: teardown must refuse.
cat > "$HOME_DIR/state/t1.delivery.json" <<'EOF'
{"schemaVersion":"firstmate.delivery-receipt.v1","task":{"id":"t1"},"phase":"implementing","phases":[],"updatedAt":"2026-07-22T00:00:00Z"}
EOF
chmod 600 "$HOME_DIR/state/t1.delivery.json"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$TEARDOWN" t1 2>/tmp/td.err; code=$?
[ "$code" -ne 0 ] || fail "teardown allowed without receipt"
grep -q "no finalized receipt" /tmp/td.err || fail "teardown did not cite missing receipt"
pass "teardown refuses results-first task without finalized receipt"

# A present but invalid receipt must still refuse cleanup.
printf '%s\n' '{}' > "$HOME_DIR/data/t1/delivery-receipt.json"
chmod 600 "$HOME_DIR/data/t1/delivery-receipt.json"
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$TEARDOWN" t1 2>"$TMP/td-invalid.err"; code=$?
[ "$code" -ne 0 ] || fail "teardown accepted invalid receipt"
grep -q "valid exact-identity receipt" "$TMP/td-invalid.err" || fail "teardown did not identify invalid receipt"
pass "teardown rejects a present but invalid receipt"

rm -f "$HOME_DIR/state/t1.delivery.json" "$HOME_DIR/data/t1/delivery-receipt.json"
phase() { FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" "$@"; }
phase init t1 --project x --delivery-mode direct-PR --yolo off >/dev/null || fail "init failed"
phase start t1 implementing >/dev/null; phase complete t1 implementing --result passed >/dev/null
phase start t1 validating >/dev/null
evidence_out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$EVIDENCE" run t1 validating 1 deterministic-validation '["true"]') || fail "evidence failed"
evidence_hash=$(printf '%s\n' "$evidence_out" | sed -n 's/^manifestSha256=//p')
phase complete t1 validating --result passed --evidence "$evidence_hash" >/dev/null
for ph in landing landed; do phase start t1 "$ph" >/dev/null; phase complete t1 "$ph" --result passed >/dev/null; done
for ph in released deployed smoke_verified; do phase start t1 "$ph" >/dev/null; phase complete t1 "$ph" --result not_applicable >/dev/null; done
phase start t1 receipt_finalized >/dev/null; phase complete t1 receipt_finalized --result passed >/dev/null
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$RECEIPT" finalize t1 --branch fm/t1 --candidate-sha "$SHA" --merge-sha "$SHA" >/dev/null || fail "receipt finalize failed"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$TEARDOWN" t1 2>/tmp/td2.err; code=$?
# It will likely fail later because worktree is fake, but should pass the receipt gate.
grep -q "no finalized receipt" /tmp/td2.err && fail "teardown still blocked after receipt created"
pass "teardown proceeds past receipt gate only after exact validation"

pass "all fm-teardown-results-first tests passed"
