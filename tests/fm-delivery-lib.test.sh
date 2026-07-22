#!/usr/bin/env bash
# Contract tests for bin/fm-delivery-lib.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-delivery-lib.sh
. "$ROOT/bin/fm-delivery-lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "not ok - $1"; exit 1; }
pass() { echo "ok - $1"; }

phases=$(fm_delivery_phase_list)
[ "$phases" = "accepted implementing validating landing landed released deployed smoke_verified receipt_finalized cleanup_eligible" ] || fail "phase list mismatch"

sub=$(fm_delivery_landing_substates direct-PR)
[ "$sub" = "pr_open ci_green merged" ] || fail "direct-PR landing substates mismatch"

sub=$(fm_delivery_landing_substates local-only)
[ "$sub" = "branch_ready landing_approved fast_forwarded" ] || fail "local-only landing substates mismatch"

[ -z "$(fm_delivery_landing_substates unknown)" ] || fail "unknown mode should have empty substates"
pass "phases and landing substates are canonical"

fm_delivery_validate_sha "6815f216a8d24bce20a2c2fe6245fe3d270c64da" || fail "valid SHA rejected"
fm_delivery_validate_sha "INVALID" && fail "invalid SHA accepted"
fm_delivery_validate_sha "" && fail "empty SHA accepted"
[ "$(fm_delivery_sha_lower 'ABCDEF')" = "abcdef" ] || fail "SHA lowercasing failed"
pass "SHA validation and normalization work"

tmp=$(mktemp "$TMP/atomic.XXXXXX")
echo "payload" > "$tmp"
fm_delivery_atomic_replace "$tmp" "$TMP/final" 0644 || fail "atomic replace failed"
[ "$(cat "$TMP/final")" = "payload" ] || fail "atomic replace content mismatch"
mode=$(stat -f %Lp "$TMP/final" 2>/dev/null || stat -c %a "$TMP/final")
[ "$mode" = "644" ] || fail "atomic replace mode mismatch: $mode"
[ ! -e "$tmp" ] || fail "temp file not removed after replace"
pass "atomic replace writes content, mode, and removes temp"

mkdir -p "$TMP/ev/a"
echo "one" > "$TMP/ev/a.txt"
echo "two" > "$TMP/ev/a/b.txt"
h1=$(fm_delivery_manifest_hash "$TMP/ev") || fail "manifest hash failed"
[ "${#h1}" -eq 64 ] || fail "manifest hash not 64 hex chars"
echo "three" > "$TMP/ev/c.txt"
h2=$(fm_delivery_manifest_hash "$TMP/ev") || fail "manifest hash failed after add"
[ "$h1" != "$h2" ] || fail "manifest hash unchanged after file add"
pass "manifest hash is stable and content-sensitive"

receipt_ok='{
  "schemaVersion": "firstmate.delivery-receipt.v1",
  "task": {"id": "t1", "project": "firstmate", "kind": "ship", "lane": "primary", "supports": null, "deliveryMode": "direct-PR", "yolo": true},
  "capability": {"summary": "x", "acceptanceCriteria": ["a"], "authorityClass": "routine"},
  "source": {"branch": "fm/t1", "candidateSha": "6815f216a8d24bce20a2c2fe6245fe3d270c64da", "mergeSha": "6815f216a8d24bce20a2c2fe6245fe3d270c64da"},
  "phases": [],
  "validation": {"commands": [], "ci": {"requiredChecks": [], "headSha": "6815f216a8d24bce20a2c2fe6245fe3d270c64da", "result": "green"}, "security": {"result": "passed", "evidence": []}},
  "release": {"applicability": "not_applicable", "mode": "none", "version": null, "artifact": {"uri": null, "digest": null, "sourceSha": "6815f216a8d24bce20a2c2fe6245fe3d270c64da"}, "receipt": null},
  "deployment": {"applicability": "not_applicable", "environment": null, "target": null, "artifactDigest": null, "receipt": null},
  "smoke": {"command": [], "result": "not_applicable", "observations": []},
  "rollback": {"mode": "not_applicable", "previewCommand": [], "result": "not_applicable", "receipt": null},
  "provider": {"applicability": "not_used", "receipt": null},
  "outcome": {"status": "delivered", "completedAt": "2026-07-22T00:00:00Z"}
}'
fm_delivery_validate_receipt "$receipt_ok" || fail "valid receipt rejected"

receipt_bad=$(printf '%s' "$receipt_ok" | sed 's/"mergeSha"/"xmergeSha"/')
fm_delivery_validate_receipt "$receipt_bad" && fail "receipt without landed identity accepted"

receipt_bad2=$(printf '%s' "$receipt_ok" | sed 's/"delivered"/"incomplete"/')
fm_delivery_validate_receipt "$receipt_bad2" && fail "non-delivered outcome accepted"
pass "receipt validation enforces landed identity and delivered outcome"

fm_delivery_validate_phase_transition accepted implementing || fail "forward transition rejected"
fm_delivery_validate_phase_transition implementing accepted && fail "backward transition accepted"
fm_delivery_validate_phase_transition landed landed || fail "same-phase transition rejected"
fm_delivery_validate_phase_transition bogus landed && fail "unknown phase accepted"
pass "phase transitions are monotonic and phase-aware"

echo "session_pct=50" > "$TMP/volatile"
fm_delivery_redact_volatile_provider_fields "$TMP/volatile" && fail "volatile percentage allowed"
echo "clean" > "$TMP/clean"
fm_delivery_redact_volatile_provider_fields "$TMP/clean" || fail "clean evidence rejected"
pass "volatile provider fields are refused"

pass "all fm-delivery-lib tests passed"
