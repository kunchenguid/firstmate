#!/usr/bin/env bash
# Behavioral tests for the isolation-proof and test-run public interfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF="$ROOT/bin/fm-test-isolation-proof.sh"
RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$PROOF" "bin/fm-test-isolation-proof.sh is missing"
[ -x "$PROOF" ] || fail "bin/fm-test-isolation-proof.sh must be executable"

test_unknown_pool_is_refused() {
  local tmp rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-isolation-proof-pool.XXXXXX")
  set +e
  "$PROOF" --pool unknown-family --list >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unknown --pool must be refused with exit 2, got $rc"
  [ ! -s "$tmp/out" ] || fail "unknown --pool unexpectedly listed candidates: $(cat "$tmp/out")"
  rm -rf "$tmp"
  pass "unknown candidate pools are refused"
}

test_family_pool_json_identifies_admission() {
  local tmp repo proof json admitted_json capped_json skipped_json rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-isolation-proof-json.XXXXXX")
  repo="$tmp/repo"
  proof="$repo/bin/fm-test-isolation-proof.sh"
  json="$tmp/proof.json"
  admitted_json="$tmp/admitted-proof.json"
  capped_json="$tmp/capped-proof.json"
  skipped_json="$tmp/skipped-proof.json"
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$PROOF" "$proof"
  # The harness isolates itself from the ambient fleet environment at startup, so
  # the fixture repo must carry that owner as well as the harness itself.
  cp "$ROOT/bin/fm-test-env-lib.sh" "$repo/bin/fm-test-env-lib.sh"
  cat >"$repo/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
if { [ "$1" = --list ] || [ "$1" = --list-scheduled ]; } && [ "$2" = --family ]; then
  case "$3" in
    fixture-family)
      printf '%s\n' tests/fm-proof-fixture-a.test.sh tests/fm-proof-fixture-b.test.sh
      exit 0
      ;;
    admitted-family)
      printf '%s\n' tests/fm-proof-slow.test.sh tests/fm-proof-fast.test.sh tests/fm-proof-replacement.test.sh
      exit 0
      ;;
    skipped-family)
      printf '%s\n' tests/fm-proof-skipped.test.sh
      exit 0
      ;;
  esac
fi
if [ "$1" = --list-concurrent-safe-families ]; then
  printf '%s\n' admitted-family skipped-family
  exit 0
fi
if [ "$1" = --concurrent-safe-family-jobs-max ]; then
  case "$2" in
    admitted-family|skipped-family)
      printf '2\n'
      exit 0
      ;;
  esac
fi
exit 2
SH
  for fixture in fm-proof-fixture-a.test.sh fm-proof-fixture-b.test.sh; do
    cat >"$repo/tests/$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - proof fixture"
SH
    chmod +x "$repo/tests/$fixture"
  done
  cat >"$repo/tests/fm-proof-slow.test.sh" <<'SH'
#!/usr/bin/env bash
waited=0
while [ ! -e "$PROOF_SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 200 ]; do
  sleep 0.05
  waited=$((waited + 1))
done
touch "$PROOF_SCHED_EVIDENCE/slow-done"
echo "ok - slow proof fixture"
SH
  cat >"$repo/tests/fm-proof-fast.test.sh" <<'SH'
#!/usr/bin/env bash
echo "ok - fast proof fixture"
SH
  cat >"$repo/tests/fm-proof-replacement.test.sh" <<'SH'
#!/usr/bin/env bash
if [ -e "$PROOF_SCHED_EVIDENCE/slow-done" ]; then
  echo "not ok - proof scheduler waited for oldest worker"
  exit 1
fi
touch "$PROOF_SCHED_EVIDENCE/replacement-started"
echo "ok - replacement proof fixture"
SH
  cat >"$repo/tests/fm-proof-skipped.test.sh" <<'SH'
#!/usr/bin/env bash
echo
echo "skip: herdr not found"
SH
  chmod +x "$proof" "$repo/bin/fm-test-run.sh" "$repo/tests/fm-proof-"*.test.sh
  set +e
  "$proof" --pool fixture-family --jobs 1 --json "$json" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "family pool proof fixture failed: $(cat "$tmp/out") $(cat "$tmp/err")"
  python3 -c '
import json, sys
artifact = json.load(open(sys.argv[1], encoding="utf-8"))
assert artifact["kind"] == "isolation-proof"
assert artifact["pool"] == "fixture-family"
assert artifact["fm_test_run_jobs_enabled"] is False
assert artifact["production_sharding_enabled"] is False
assert artifact["summary"]["total"] == 2
assert artifact["summary"]["failed"] == 0
' "$json" || fail "serial family pool artifact metadata is incorrect"
  set +e
  PROOF_SCHED_EVIDENCE="$tmp" "$proof" --pool admitted-family --jobs 2 --json "$admitted_json" >"$tmp/admitted.out" 2>"$tmp/admitted.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "admitted family proof fixture failed: $(cat "$tmp/admitted.out") $(cat "$tmp/admitted.err")"
  python3 -c '
import json, sys
artifact = json.load(open(sys.argv[1], encoding="utf-8"))
assert artifact["pool"] == "admitted-family"
assert artifact["concurrency"] == 2
assert artifact["fm_test_run_jobs_enabled"] is True
assert artifact["summary"]["total"] == 3
assert artifact["summary"]["failed"] == 0
' "$admitted_json" || fail "admitted family pool artifact metadata is incorrect"
  mkdir "$tmp/capped-evidence"
  set +e
  PROOF_SCHED_EVIDENCE="$tmp/capped-evidence" "$proof" --pool admitted-family --jobs 3 --json "$capped_json" >"$tmp/capped.out" 2>"$tmp/capped.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "over-cap family proof fixture failed: $(cat "$tmp/capped.out") $(cat "$tmp/capped.err")"
  python3 -c '
import json, sys
artifact = json.load(open(sys.argv[1], encoding="utf-8"))
assert artifact["pool"] == "admitted-family"
assert artifact["concurrency"] == 3
assert artifact["fm_test_run_jobs_enabled"] is False
assert artifact["summary"]["failed"] == 0
' "$capped_json" || fail "over-cap family pool artifact metadata is incorrect"
  set +e
  "$proof" --pool skipped-family --jobs 2 --json "$skipped_json" >"$tmp/skipped.out" 2>"$tmp/skipped.err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "gate-skipped family proof must fail, got $rc"
  grep -Fq 'pool skipped-family candidate gate-skipped' "$tmp/skipped.err" \
    || fail "gate-skipped proof did not name its pool: $(cat "$tmp/skipped.err")"
  grep -Fq 'tests/fm-proof-skipped.test.sh: skip: herdr not found' "$tmp/skipped.err" \
    || fail "gate-skipped proof did not name its candidate and prerequisite: $(cat "$tmp/skipped.err")"
  python3 -c '
import json, sys
artifact = json.load(open(sys.argv[1], encoding="utf-8"))
assert artifact["pool"] == "skipped-family"
assert artifact["fm_test_run_jobs_enabled"] is False
assert artifact["summary"]["total"] == 1
assert artifact["summary"]["failed"] == 1
assert artifact["scripts"][0]["exit"] == 1
' "$skipped_json" || fail "gate-skipped family artifact was admitted"
  rm -rf "$tmp"
  pass "family pool JSON scopes jobs admission to proven concurrency"
}

test_list_candidates_nonempty_and_stable() {
  local listed count sorted
  listed=$("$PROOF" --list)
  [ -n "$listed" ] || fail "--list printed nothing"
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 10 ] || fail "expected a bounded non-trivial candidate set, got $count"
  sorted=$(printf '%s\n' "$listed" | LC_ALL=C sort)
  [ "$listed" = "$sorted" ] || fail "--list must be sorted for a stable matrix"
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
  for banned in \
    tests/fm-test-isolation-proof.test.sh \
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
  pass "audited fake-backend and stub-network extras are candidates"
}

test_list_exclusions_documents_reasons() {
  local out
  out=$("$PROOF" --list-exclusions)
  [ -n "$out" ] || fail "--list-exclusions printed nothing"
  printf '%s\n' "$out" | grep -Fq 'fm-watcher-lock.test.sh' \
    || fail "exclusions must document watcher-lock serial reason"
  printf '%s\n' "$out" | grep -Fq 'fm-backend-herdr-smoke.test.sh' \
    || fail "exclusions must document real-herdr serial reason"
  pass "exclusion list documents serial reasons"
}

test_family_map_labels_this_contract() {
  local fam safe safe_max scheduled_first
  fam=$("$RUNNER" --list --family pure-contract-unit)
  printf '%s\n' "$fam" | grep -Fq 'tests/fm-test-isolation-proof.test.sh' \
    || fail "fm-test-isolation-proof.test.sh must map to pure-contract-unit"
  safe=$("$RUNNER" --list-concurrent-safe-families)
  printf '%s\n' "$safe" | grep -Fxq watcher-wake-lock \
    || fail "runner must expose the admitted watcher concurrent-safe family"
  printf '%s\n' "$safe" | grep -Fxq pure-contract-unit \
    || fail "runner must expose the admitted contract-unit concurrent-safe family"
  safe_max=$("$RUNNER" --concurrent-safe-family-jobs-max watcher-wake-lock)
  [ "$safe_max" -eq 4 ] || fail "runner exposed the wrong watcher family worker cap: $safe_max"
  safe_max=$("$RUNNER" --concurrent-safe-family-jobs-max pure-contract-unit)
  [ "$safe_max" -eq 4 ] || fail "runner exposed the wrong contract-unit family worker cap: $safe_max"
  scheduled_first=$("$RUNNER" --list-scheduled --family watcher-wake-lock | head -n 1)
  [ "$scheduled_first" = tests/fm-watch-triage.test.sh ] \
    || fail "runner scheduled the watcher family out of longest-hint order: $scheduled_first"
  pass "isolation-proof contract test is family-mapped"
}

test_parallel_shards_consume_the_proven_set() {
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
  pass "parallel shards consume the proven-isolated set only"
}

test_unknown_pool_is_refused
test_family_pool_json_identifies_admission
test_list_candidates_nonempty_and_stable
test_candidates_exclude_serial_classes
test_extra_hermetic_candidates_present
test_list_exclusions_documents_reasons
test_family_map_labels_this_contract
test_parallel_shards_consume_the_proven_set
