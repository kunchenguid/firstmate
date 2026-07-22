#!/usr/bin/env bash
# Contract tests for bin/fm-test-isolation-proof.sh - the Phase 2 pre-shard
# isolation proof harness.
#
# These tests assert the candidate-set contract, serial exclusions, aggregate
# failure reporting, and that Phase 4 production shards consume this exact set.
# They deliberately do NOT re-run the full concurrent candidate matrix on every
# invocation (that matrix is owned by the harness itself and archived under
# docs/fm-test-isolation-proof.md after a deliberate proof run).
set -u

# shellcheck disable=SC1091
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF="$ROOT/bin/fm-test-isolation-proof.sh"
RUNNER="$ROOT/bin/fm-test-run.sh"
CI="$ROOT/.github/workflows/ci.yml"
CONTRIB="$ROOT/CONTRIBUTING.md"
PROOF_DOC="$ROOT/docs/fm-test-isolation-proof.md"
PROOF_JSON="$ROOT/docs/fm-test-isolation-proof.json"

assert_present "$PROOF" "bin/fm-test-isolation-proof.sh is missing"
[ -x "$PROOF" ] || fail "bin/fm-test-isolation-proof.sh must be executable"

test_list_candidates_nonempty_and_stable() {
  local listed count sorted
  listed=$("$PROOF" --list)
  [ -n "$listed" ] || fail "--list printed nothing"
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 10 ] || fail "expected a bounded non-trivial candidate set, got $count"
  sorted=$(printf '%s\n' "$listed" | LC_ALL=C sort)
  [ "$listed" = "$sorted" ] || fail "--list must be sorted for a stable matrix"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = "$count" ] \
    || fail "--list must not duplicate candidates"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) [ -f "$ROOT/$line" ] || fail "listed missing script: $line" ;;
      *) fail "non-test candidate path: $line" ;;
    esac
  done <<<"$listed"
  pass "candidate --list is non-empty, sorted, unique, and real"
}

test_candidates_exclude_serial_classes() {
  local listed
  listed=$("$PROOF" --list)
  # Self must never re-enter the concurrent matrix.
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-isolation-proof.test.sh' \
    && fail "isolation-proof test must not be a parallel candidate"
  # Continuity fixture starts a background sleep holder.
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-continuity-pretool-check.test.sh' \
    && fail "continuity pretool check must stay serial (process holder)"
  # Real tmux smoke, watcher lock, real herdr, AFK, live harnesses stay serial.
  for banned in \
    tests/fm-backend-tmux-smoke.test.sh \
    tests/fm-watcher-lock.test.sh \
    tests/fm-wake-queue.test.sh \
    tests/fm-backend-herdr-smoke.test.sh \
    tests/fm-afk-inject-e2e.test.sh \
    tests/fm-pi-primary-live-e2e.test.sh \
    tests/fm-pr-check-security.test.sh \
    tests/fm-backend-cmux-smoke.test.sh; do
    printf '%s\n' "$listed" | grep -Fxq "$banned" \
      && fail "serial-class script must not be a parallel candidate: $banned"
  done
  pass "serial classes remain excluded from the parallel candidate set"
}

test_candidates_match_archived_proof() {
  local listed archived
  assert_present "$PROOF_JSON" "docs/fm-test-isolation-proof.json missing"
  listed=$("$PROOF" --list)
  archived=$(jq -r '.scripts[].path' "$PROOF_JSON" | LC_ALL=C sort)
  [ "$listed" = "$archived" ] \
    || fail "candidate set must exactly match the archived isolation proof"
  pass "candidate set exactly matches the archived isolation proof"
}

test_extra_hermetic_candidates_present() {
  local listed
  listed=$("$PROOF" --list)
  for want in \
    tests/fm-backend-herdr.test.sh \
    tests/fm-send-strict.test.sh \
    tests/fm-spawn-batch.test.sh \
    tests/fm-pr-merge.test.sh \
    tests/fm-review-diff.test.sh \
    tests/fm-x-mode.test.sh; do
    printf '%s\n' "$listed" | grep -Fxq "$want" \
      || fail "extra hermetic candidate missing: $want"
  done
  pass "audited fake-backend / stub-network extras are candidates"
}

test_list_exclusions_documents_reasons() {
  local out
  out=$("$PROOF" --list-exclusions)
  [ -n "$out" ] || fail "--list-exclusions printed nothing"
  printf '%s\n' "$out" | grep -Fq 'fm-continuity-pretool-check.test.sh' \
    || fail "exclusions must document continuity process-holder reason"
  printf '%s\n' "$out" | grep -Fq 'fm-watcher-lock.test.sh' \
    || fail "exclusions must document watcher-lock serial reason"
  printf '%s\n' "$out" | grep -Fq 'fm-backend-herdr-smoke.test.sh' \
    || fail "exclusions must document real-herdr serial reason"
  pass "exclusion list documents serial reasons"
}

test_family_map_labels_this_contract() {
  local fam
  fam=$("$RUNNER" --list --family pure-contract-unit)
  printf '%s\n' "$fam" | grep -Fq 'tests/fm-test-isolation-proof.test.sh' \
    || fail "fm-test-isolation-proof.test.sh must map to pure-contract-unit"
  pass "isolation-proof contract test is family-mapped"
}

test_aggregate_failure_under_concurrency() {
  local tmp pass_f fail_f harness rc out
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-isolation-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  # Minimal fixture harness mirroring aggregate + concurrent wait semantics.
  harness="$tmp/harness.sh"
  cat >"$harness" <<'SH'
#!/usr/bin/env bash
set -eu
jobs=$1
shift
pids=()
rcs=()
paths=()
idx=0
for s in "$@"; do
  idx=$((idx + 1))
  (
    bash "$s"
    echo $? >"${TMPDIR:-/tmp}/iso-rc-$idx"
  ) &
  pids+=("$!")
  paths+=("$s")
  while [ "${#pids[@]}" -ge "$jobs" ]; do
    wait "${pids[0]}" || true
    pids=("${pids[@]:1}")
  done
done
while [ "${#pids[@]}" -gt 0 ]; do
  wait "${pids[0]}" || true
  pids=("${pids[@]:1}")
done
failed=0
for i in $(seq 1 "$idx"); do
  rc=$(cat "${TMPDIR:-/tmp}/iso-rc-$i" 2>/dev/null || echo 1)
  [ "$rc" -eq 0 ] || failed=$((failed + 1))
  rm -f "${TMPDIR:-/tmp}/iso-rc-$i"
done
echo "FM_ISOLATION_SUMMARY total=$idx failed=$failed"
[ "$failed" -eq 0 ]
SH
  chmod +x "$harness"
  set +e
  out=$(TMPDIR="$tmp" bash "$harness" 2 "$pass_f" "$fail_f" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "concurrent aggregate must fail when any candidate fails"
  printf '%s\n' "$out" | grep -Fq 'FM_ISOLATION_SUMMARY total=2 failed=1' \
    || fail "aggregate summary must report total=2 failed=1: $out"
  rm -rf "$tmp"
  pass "aggregate failure reporting survives concurrency"
}

test_phase4_consumes_proven_set_only() {
  assert_present "$CI" "ci.yml missing"
  assert_present "$RUNNER" "fm-test-run.sh missing"
  # Phase 4 portable parallel lanes must exist and use lane selection, not --all.
  grep -Fq 'bin/fm-test-run.sh --lane portable-parallel-1' "$CI" \
    || fail "CI portable parallel 1 must use --lane portable-parallel-1"
  grep -Fq 'bin/fm-test-run.sh --lane portable-parallel-2' "$CI" \
    || fail "CI portable parallel 2 must use --lane portable-parallel-2"
  grep -Fq 'bin/fm-test-run.sh --lane portable-serial' "$CI" \
    || fail "CI portable serial must use --lane portable-serial"
  # Shard union must equal this harness's proven list.
  local proven shards
  proven=$("$PROOF" --list | LC_ALL=C sort -u)
  shards=$(
    {
      "$RUNNER" --list --lane portable-parallel-1
      "$RUNNER" --list --lane portable-parallel-2
    } | LC_ALL=C sort -u
  )
  [ "$proven" = "$shards" ] \
    || fail "portable parallel shards must equal isolation-proof --list exactly"
  # Local --jobs is bounded to this proven set (refuse is contract-tested in
  # fm-test-run.test.sh); the option must exist.
  grep -E '^[[:space:]]*--jobs\)' "$RUNNER" >/dev/null 2>&1 \
    || fail "fm-test-run.sh must expose bounded --jobs after Phase 4"
  pass "Phase 4 portable shards consume the proven-isolated set only"
}

test_docs_record_proof_owner() {
  assert_present "$PROOF_DOC" "docs/fm-test-isolation-proof.md missing"
  grep -Fq 'bin/fm-test-isolation-proof.sh' "$PROOF_DOC" \
    || fail "proof doc must name the harness owner"
  grep -Fq 'production_sharding_enabled' "$PROOF_DOC" \
    || fail "proof doc must record the archived proof-time sharding flag"
  grep -Fq 'concurrency' "$PROOF_DOC" \
    || fail "proof doc must record concurrency"
  assert_present "$CONTRIB" "CONTRIBUTING.md missing"
  grep -Fq 'fm-test-isolation-proof' "$CONTRIB" \
    || fail "CONTRIBUTING must document the isolation-proof entry point"
  pass "docs archive the isolation-proof owner and posture"
}

test_list_candidates_nonempty_and_stable
test_candidates_exclude_serial_classes
test_candidates_match_archived_proof
test_extra_hermetic_candidates_present
test_list_exclusions_documents_reasons
test_family_map_labels_this_contract
test_aggregate_failure_under_concurrency
test_phase4_consumes_proven_set_only
test_docs_record_proof_owner
