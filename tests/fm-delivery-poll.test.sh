#!/usr/bin/env bash
# Tests for bin/fm-delivery-poll.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLL="$ROOT/bin/fm-delivery-poll.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/t1"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

run_poll() { FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$POLL" t1; }

out=$(run_poll)
[ "$out" = "delivery:t1 none" ] || fail "no record: $out"
pass "poll reports none when no delivery record exists"

FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$POLL" .. 2>/dev/null \
  && fail "poll accepted path-traversing task id"
pass "poll rejects unsafe task ids"

cat > "$HOME_DIR/state/t1.delivery.json" <<'EOF'
{"schemaVersion":"firstmate.delivery-receipt.v1","task":{"id":"t1"},"phase":"implementing","phases":[],"updatedAt":"2026-07-22T00:00:00Z"}
EOF
chmod 600 "$HOME_DIR/state/t1.delivery.json"
out=$(run_poll)
[ "$out" = "delivery:t1 phase:implementing" ] || fail "phase poll: $out"
pass "poll reports current phase"

cat > "$HOME_DIR/data/t1/delivery-receipt.json" <<'EOF'
{"schemaVersion":"firstmate.delivery-receipt.v1","task":{"id":"t1","project":"x","kind":"ship","lane":"primary","supports":null,"deliveryMode":"direct-PR","yolo":true},"capability":{"summary":"x","acceptanceCriteria":[],"authorityClass":"routine"},"source":{"branch":"fm/t1","candidateSha":"6815f216a8d24bce20a2c2fe6245fe3d270c64da","mergeSha":"6815f216a8d24bce20a2c2fe6245fe3d270c64da"},"phases":[],"validation":{"commands":[],"ci":{"requiredChecks":[],"headSha":"6815f216a8d24bce20a2c2fe6245fe3d270c64da","result":"green"},"security":{"result":"passed","evidence":[]}},"release":{"applicability":"not_applicable","mode":"none","version":null,"artifact":{"uri":null,"digest":null,"sourceSha":"6815f216a8d24bce20a2c2fe6245fe3d270c64da"},"receipt":null},"deployment":{"applicability":"not_applicable","environment":null,"target":null,"artifactDigest":null,"receipt":null},"smoke":{"command":[],"result":"not_applicable","observations":[]},"rollback":{"mode":"not_applicable","previewCommand":[],"result":"not_applicable","receipt":null},"provider":{"applicability":"not_used","receipt":null},"outcome":{"status":"delivered","completedAt":"2026-07-22T00:00:00Z"}}
EOF
chmod 600 "$HOME_DIR/data/t1/delivery-receipt.json"
out=$(run_poll)
[ "$out" = "delivery:t1 receipt:delivered" ] || fail "receipt poll: $out"
pass "poll reports finalized receipt outcome"

pass "all fm-delivery-poll tests passed"
