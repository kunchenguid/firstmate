#!/usr/bin/env bash
# Results-first teardown receipt test for bin/fm-teardown.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT/bin/fm-teardown.sh"

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

# Create the receipt and verify teardown proceeds past the receipt gate.
cat > "$HOME_DIR/data/t1/delivery-receipt.json" <<'EOF'
{"schemaVersion":"firstmate.delivery-receipt.v1","task":{"id":"t1","project":"x","kind":"ship","lane":"primary","supports":null,"deliveryMode":"direct-PR","yolo":true},"capability":{"summary":"x","acceptanceCriteria":[],"authorityClass":"routine"},"source":{"branch":"fm/t1","candidateSha":"6815f216a8d24bce20a2c2fe6245fe3d270c64da","mergeSha":"6815f216a8d24bce20a2c2fe6245fe3d270c64da"},"phases":[],"validation":{"commands":[],"ci":{"requiredChecks":[],"headSha":"6815f216a8d24bce20a2c2fe6245fe3d270c64da","result":"green"},"security":{"result":"passed","evidence":[]}},"release":{"applicability":"not_applicable","mode":"none","version":null,"artifact":{"uri":null,"digest":null,"sourceSha":"6815f216a8d24bce20a2c2fe6245fe3d270c64da"},"receipt":null},"deployment":{"applicability":"not_applicable","environment":null,"target":null,"artifactDigest":null,"receipt":null},"smoke":{"command":[],"result":"not_applicable","observations":[]},"rollback":{"mode":"not_applicable","previewCommand":[],"result":"not_applicable","receipt":null},"provider":{"applicability":"not_used","receipt":null},"outcome":{"status":"delivered","completedAt":"2026-07-22T00:00:00Z"}}
EOF
chmod 600 "$HOME_DIR/data/t1/delivery-receipt.json"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$TEARDOWN" t1 2>/tmp/td2.err; code=$?
# It will likely fail later because worktree is fake, but should pass the receipt gate.
grep -q "no finalized receipt" /tmp/td2.err && fail "teardown still blocked after receipt created"
pass "teardown proceeds past receipt gate once receipt exists"

pass "all fm-teardown-results-first tests passed"
