#!/usr/bin/env bash
# Tests for evidence-bound delivery receipt finalization.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC="$ROOT/bin/fm-delivery-receipt.sh"
PHASE="$ROOT/bin/fm-delivery-phase.sh"
EVIDENCE="$ROOT/bin/fm-evidence-run.sh"
SHA=6815f216a8d24bce20a2c2fe6245fe3d270c64da

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }
run() { FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$RC" "$@"; }
phase() { FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" "$PHASE" "$@"; }

build_ready_lifecycle() { # <id> <mode>
  local id=$1 mode=$2 evidence_out evidence_hash ph
  phase init "$id" --project firstmate --delivery-mode "$mode" --yolo off >/dev/null || return 1
  phase start "$id" implementing >/dev/null || return 1
  phase complete "$id" implementing --result passed >/dev/null || return 1
  phase start "$id" validating >/dev/null || return 1
  printf 'candidateSha=%s\n' "$SHA" > "$HOME_DIR/state/$id.meta"
  evidence_out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$EVIDENCE" run "$id" validating 1 deterministic-validation '["printf","validated"]') || return 1
  evidence_hash=$(printf '%s\n' "$evidence_out" | sed -n 's/^manifestSha256=//p')
  phase complete "$id" validating --result passed --evidence "$evidence_hash" >/dev/null || return 1
  for ph in landing landed; do
    phase start "$id" "$ph" >/dev/null || return 1
    phase complete "$id" "$ph" --result passed >/dev/null || return 1
  done
  for ph in released deployed smoke_verified; do
    phase start "$id" "$ph" >/dev/null || return 1
    phase complete "$id" "$ph" --result not_applicable >/dev/null || return 1
  done
  phase start "$id" receipt_finalized >/dev/null || return 1
  phase complete "$id" receipt_finalized --result passed >/dev/null || return 1
}

build_ready_lifecycle t1 direct-PR || fail "could not build direct-PR lifecycle"
run finalize t1 --branch fm/t1 --candidate-sha "$SHA" --local-landed-sha "$SHA" 2>/dev/null \
  && fail "direct-PR accepted local-only landing identity"
run finalize t1 --branch fm/t1 --candidate-sha "$SHA" --merge-sha "$SHA" >/dev/null || fail "direct-PR finalize failed"
run validate t1 receipt --expected-mode direct-PR --expected-candidate-sha "$SHA" >/dev/null || fail "exact receipt validation failed"
grep -q '"result": "not_assessed"' "$HOME_DIR/data/t1/delivery-receipt.json" || fail "receipt fabricated security success"
pass "direct-PR receipt is mode-specific, evidence-bound, and truthful"

cp "$HOME_DIR/data/t1/delivery-receipt.json" "$HOME_DIR/data/t1/delivery-receipt.valid"
python3 - "$HOME_DIR/data/t1/delivery-receipt.json" <<'PYEOF'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
doc["phases"][2]["evidence"] = ["0" * 64]
open(path, "w").write(json.dumps(doc))
PYEOF
chmod 600 "$HOME_DIR/data/t1/delivery-receipt.json"
run validate t1 receipt --expected-mode direct-PR --expected-candidate-sha "$SHA" 2>/dev/null \
  && fail "fabricated evidence digest validated"
mv "$HOME_DIR/data/t1/delivery-receipt.valid" "$HOME_DIR/data/t1/delivery-receipt.json"
chmod 600 "$HOME_DIR/data/t1/delivery-receipt.json"
pass "receipt validation rejects fabricated evidence"

build_ready_lifecycle t2 local-only || fail "could not build local-only lifecycle"
run finalize t2 --branch fm/t2 --candidate-sha "$SHA" --merge-sha "$SHA" 2>/dev/null \
  && fail "local-only accepted PR merge identity"
run finalize t2 --branch fm/t2 --candidate-sha "$SHA" --local-landed-sha "$SHA" >/dev/null || fail "local-only finalize failed"
run validate t2 receipt --expected-mode local-only --expected-candidate-sha "$SHA" >/dev/null || fail "local-only receipt validation failed"
grep -q '"deliveryMode": "local-only"' "$HOME_DIR/data/t2/delivery-receipt.json" || fail "local-only mode was misrecorded"
pass "local-only receipt records only local landing identity"

pass "all fm-delivery-receipt tests passed"
