#!/usr/bin/env bash
# tests/fm-jev-privacy-guard.test.sh - verify Jev Inline Privacy & PII Ingestion Guardrail
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD_SH="$ROOT/bin/fm-jev-privacy-guard.sh"
GUARD_PY="$ROOT/bin/fm-jev-privacy-guard.py"

[ -x "$GUARD_SH" ] || fail "bin/fm-jev-privacy-guard.sh missing or not executable"
[ -x "$GUARD_PY" ] || fail "bin/fm-jev-privacy-guard.py missing or not executable"

TDIR=$(fm_test_tmproot fm-jev-privacy-test)
QDIR="$TDIR/quarantine"
MOCK_STATE="$TDIR/state"
mkdir -p "$QDIR" "$MOCK_STATE"

export FM_STATE_OVERRIDE="$MOCK_STATE"

# 1. Tier 1: SSN detection
set +e
out_ssn=$("$GUARD_SH" --text "Candidate record: John Doe, SSN: 123-45-6789, address: 123 Main St" 2>&1)
rc_ssn=$?
set -e
[ "$rc_ssn" -eq 1 ] || fail "SSN was not quarantined (got exit $rc_ssn)"
assert_contains "$out_ssn" "quarantine [ssn_detected]" "detected SSN"

# 2. Tier 1: Bank routing & account number detection
set +e
out_bank=$("$GUARD_SH" --text "Wire instructions: Routing number: 021000021, Account: 123456789012" 2>&1)
rc_bank=$?
set -e
[ "$rc_bank" -eq 1 ] || fail "Bank routing was not quarantined (got exit $rc_bank)"
assert_contains "$out_bank" "quarantine [banking_routing_detected]" "detected bank routing"

# 3. Tier 1: Tax / W-2 form markers
set +e
out_tax=$("$GUARD_SH" --text "Attached: Form W-2 Wage and Tax Statement 2025 for employee" 2>&1)
rc_tax=$?
set -e
[ "$rc_tax" -eq 1 ] || fail "Form W-2 marker was not quarantined (got exit $rc_tax)"
assert_contains "$out_tax" "quarantine [tax_w2_marker_detected]" "detected tax W-2 marker"

# 4. Tier 1: Private key detection
set +e
out_key=$("$GUARD_SH" --text "-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0Y1
-----END RSA PRIVATE KEY-----" 2>&1)
rc_key=$?
set -e
[ "$rc_key" -eq 1 ] || fail "Private key was not quarantined (got exit $rc_key)"
assert_contains "$out_key" "quarantine [private_key_detected]" "detected private key"

# 5. Clean standard text passes
out_clean=$("$GUARD_SH" --text "Implemented unit tests for redis cache reconnection logic in session store" 2>&1)
assert_contains "$out_clean" "VERDICT: allow" "clean text allowed"

# 6. Quarantine moving & sidecar metadata
LEAK_FILE="$TDIR/personal_taxes.txt"
cat <<'EOF' > "$LEAK_FILE"
Confidential Personal Tax Record
Form 1040 U.S. Individual Income Tax Return
Adjusted Gross Income: $150,000
Taxable Income: $120,000
EOF

set +e
out_q=$("$GUARD_SH" --file "$LEAK_FILE" --quarantine --quarantine-dir "$QDIR" 2>&1)
rc_q=$?
set -e
[ "$rc_q" -eq 1 ] || fail "tax file was not quarantined (got exit $rc_q)"
[ ! -f "$LEAK_FILE" ] || fail "quarantined source file was not removed from source location"
assert_contains "$out_q" "quarantined to" "reported quarantine location"

# Verify quarantine dir contains file and meta
q_count=$(find "$QDIR" -name "*_personal_taxes.txt" | wc -l)
[ "$q_count" -ge 1 ] || fail "quarantined file missing from quarantine dir"
q_meta_count=$(find "$QDIR" -name "*_personal_taxes.txt.meta.json" | wc -l)
[ "$q_meta_count" -ge 1 ] || fail "quarantine metadata JSON sidecar missing"

# 7. JSON output mode
json_out=$("$GUARD_SH" --json --text "SSN: 987-65-4321")
assert_contains "$json_out" '"verdict": "quarantine"' "json output contains quarantine verdict"
assert_contains "$json_out" '"code": "ssn_detected"' "json output contains ssn_detected code"

# 8. Live Tier 3 Semantic Evaluation (if TYPESAFE_API_KEY available)
if sudo -n /opt/ra/firstmate/bin/jev-typesafe-run.py -- env | grep -q "TYPESAFE_API_KEY"; then
  # Semantic personal tax return detection
  set +e
  out_sem_tax=$("$GUARD_SH" --text "Personal tax filing recap: Adjusted income from clinic distributions was \$450k with schedule C deductions, paid estimated tax payments to Treasury" 2>&1)
  rc_sem_tax=$?
  set -e
  [ "$rc_sem_tax" -eq 1 ] || fail "semantic tax record was not quarantined (got exit $rc_sem_tax)"
  assert_contains "$out_sem_tax" "quarantine [semantic_" "detected semantic personal tax PII"

  # Semantic clean engineering note
  out_sem_clean=$("$GUARD_SH" --text "Refactored PostgreSQL connection pooling parameters in backend API service to improve query throughput" 2>&1)
  assert_contains "$out_sem_clean" "VERDICT: allow" "semantic clean engineering note allowed"
fi

# 9. Telemetry file verification
[ -f "$MOCK_STATE/.jev-privacy-telemetry" ] || fail "telemetry file not created"
telem_content=$(cat "$MOCK_STATE/.jev-privacy-telemetry")
assert_contains "$telem_content" "ssn_detected" "telemetry recorded ssn_detected"
assert_contains "$telem_content" "allow" "telemetry recorded allow"

pass "all fm-jev-privacy-guard tests passed"

python3 "$(dirname "${BASH_SOURCE[0]}")/jev-safety-fixtures.py" privacy-guard
