#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Structural guard for the sealed suite's ambient and cloud seals.
#
# WHAT HAPPENED. On 2026-08-20 a real, billable Standard_D4as_v6 VM
# (vm-fm7c799d-wkr-01) was found running in the pilot resource group. Its tags
# named it: task-binding `cloud-noenv-c7` - a hardcoded fixture id that exists
# only in tests/fm-spawn-cloud.test.sh - and a repository-generation
# (096ed1a9f4d7204045191afdddaa2c73cf52a3b7) that is not a commit that exists.
# No controller queue entry, no worker record, no state/<task>.meta. The sealed
# suite had provisioned untracked cloud compute that nothing would ever release.
#
# WHY. The unit deliberately omits FM_WORKER_PROVIDER_COMMAND and the FM_AZURE_*
# identity, to prove the lifecycle REFUSES such a request. Run in a shell with
# the operator's fleet.env sourced, the ambient identity satisfied the check the
# unit asserts is missing, and bin/fm-worker-lifecycle.py's default resolved the
# REAL Azure adapter. The request was served.
#
# THE SHAPE OF THE FIX. Fail closed on the provider, never fall through:
#   1. tests/run.sh drops every ambient name in tests/ambient-seal.tsv before it
#      admits a test, so a test sees only what it sets for itself.
#   2. tests/run.sh binds FM_WORKER_PROVIDER_COMMAND to a REFUSING fixture
#      provider, so a test that names no provider gets a refusal, not Azure.
#   3. tests/cloud-guard-bin/az sits on every admitted test's PATH, so even a
#      path that reconstructs the real adapter cannot reach the control plane.
#   4. Every refusal is RECORDED, and tests/run.sh fails the suite over any
#      recorded reach. A guard that only refused could be scrolled past.
#
# This file pins all four, both as facts about the process it is running in and
# as pins on the wiring in tests/run.sh, so the seal cannot be removed or
# narrowed without a visible diff.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TESTS="$ROOT/tests"
RUN_SH="$TESTS/run.sh"
SEAL_REGISTRY="$TESTS/ambient-seal.tsv"
TMP_ROOT=$(fm_test_tmproot fm-cloud-provider-seal)

FAILED=0
soft_fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }

# The declared seal, pinned literally. Adding or removing a name here without
# editing this list is the diff a reviewer must see.
EXPECTED_EXACT=(FM_HOME FM_WORKER_PROVIDER_COMMAND FM_SPAWN_CLOUD)
EXPECTED_PREFIX=(FM_AZURE_ AZURE_ ARM_)
EXPECTED_RECORD_COUNT=6

# --- 1. the registry is exactly what is declared ----------------------------

unit_registry_is_pinned() {
  local records count name
  records=$(python3 "$TESTS/ambient-seal.py" records "$SEAL_REGISTRY") \
    || { soft_fail "ambient-seal.py could not read the registry"; return; }
  count=$(printf '%s\n' "$records" | grep -c .)
  [ "$count" -eq "$EXPECTED_RECORD_COUNT" ] \
    || soft_fail "the ambient seal declares $count records, not the pinned $EXPECTED_RECORD_COUNT; update EXPECTED_* here in the same diff"
  for name in "${EXPECTED_EXACT[@]}"; do
    printf '%s\n' "$records" | grep -qx "exact	$name" \
      || soft_fail "the ambient seal no longer drops the exact name $name"
  done
  for name in "${EXPECTED_PREFIX[@]}"; do
    printf '%s\n' "$records" | grep -qx "prefix	$name" \
      || soft_fail "the ambient seal no longer drops the prefix $name"
  done
  [ "$FAILED" -eq 0 ] && pass "the ambient seal registry is exactly the declared set"
}

# A malformed or empty registry must REFUSE, not silently seal nothing: "no
# names matched" and "the seal did not load" must never look the same.
unit_registry_failures_refuse() {
  local bad status out
  bad="$TMP_ROOT/bad-seal.tsv"
  printf 'exact\tFM_HOME\n' > "$bad"
  out=$(python3 "$TESTS/ambient-seal.py" names "$bad" 2>&1); status=$?
  [ "$status" -eq 97 ] || soft_fail "a malformed seal record did not refuse with 97 (got $status: $out)"
  printf '# only a comment\n' > "$bad"
  out=$(python3 "$TESTS/ambient-seal.py" names "$bad" 2>&1); status=$?
  [ "$status" -eq 97 ] || soft_fail "an empty seal did not refuse with 97 (got $status: $out)"
  out=$(python3 "$TESTS/ambient-seal.py" names "$TMP_ROOT/does-not-exist.tsv" 2>&1); status=$?
  [ "$status" -eq 97 ] || soft_fail "an unreadable seal did not refuse with 97 (got $status: $out)"
  pass "a malformed, empty, or unreadable ambient seal refuses instead of sealing nothing"
}

# --- 2. run.sh actually consumes the seal -----------------------------------

# The greps below are deliberately literal: they pin the exact text in
# tests/run.sh, including its dollar signs, so single quotes are correct here.
# shellcheck disable=SC2016
unit_run_sh_wires_the_seal() {
  grep -q 'ambient-seal.py" names' "$RUN_SH" \
    || soft_fail "tests/run.sh no longer evaluates the ambient seal"
  grep -q 'unset "\$sealed_name"' "$RUN_SH" \
    || soft_fail "tests/run.sh no longer unsets the sealed names"
  # Both admission lanes, not just the hermetic one.
  [ "$(grep -c 'FM_WORKER_PROVIDER_COMMAND="\$provider_refusal"' "$RUN_SH")" -eq 2 ] \
    || soft_fail "tests/run.sh does not bind the refusing provider on BOTH admission lanes"
  [ "$(grep -c 'FM_TEST_CLOUD_REACH_LOG="\$cloud_reach_log"' "$RUN_SH")" -eq 2 ] \
    || soft_fail "tests/run.sh does not export the reach log on BOTH admission lanes"
  [ "$(grep -c 'herdr-guard-bin:\$cloud_guard_bin:\$original_path' "$RUN_SH")" -eq 2 ] \
    || soft_fail "tests/run.sh does not put the cloud guard on BOTH admission lanes' PATH"
  # Three dispatch arms run a test (hermetic, skip-herdr mixed, real lab); each
  # must be followed by the reach check.
  [ "$(grep -c 'check_cloud_reach || result=1' "$RUN_SH")" -eq 3 ] \
    || soft_fail "tests/run.sh does not check for a cloud reach after every lane that runs a test"
  pass "tests/run.sh wires the ambient seal, the refusing provider, the guard PATH, and the reach check"
}

# --- 3. live facts about THIS admitted process ------------------------------

unit_this_process_is_sealed() {
  local name resolved
  for name in "${EXPECTED_EXACT[@]}"; do
    [ "$name" = FM_WORKER_PROVIDER_COMMAND ] && continue
    [ -z "${!name:-}" ] || soft_fail "$name is set inside an admitted test; the ambient seal did not run"
  done
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    soft_fail "sealed-prefix variable $name is set inside an admitted test"
  done < <(env | sed -n 's/^\(FM_AZURE_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(ARM_[A-Za-z0-9_]*\)=.*/\1/p')
  # The provider is bound, and bound to the REFUSAL, not to the real adapter.
  case "${FM_WORKER_PROVIDER_COMMAND:-}" in
    *tests/cloud-provider-refusal.py) ;;
    *) soft_fail "FM_WORKER_PROVIDER_COMMAND is '${FM_WORKER_PROVIDER_COMMAND:-<unset>}', not the refusing fixture provider" ;;
  esac
  [ -n "${FM_TEST_CLOUD_REACH_LOG:-}" ] || soft_fail "FM_TEST_CLOUD_REACH_LOG is not exported to an admitted test"
  # AZURE_CONFIG_DIR is the one AZURE_-prefixed name the runner SETS rather than
  # drops: the ambient one is sealed away and replaced by an empty suite-owned
  # directory, so a real CLI reached by any route finds no credentials.
  [ -n "${AZURE_CONFIG_DIR:-}" ] && [ -d "${AZURE_CONFIG_DIR:-}" ] \
    || soft_fail "AZURE_CONFIG_DIR is not bound to a suite-owned directory"
  case "${AZURE_CONFIG_DIR:-}" in
    "${FM_TEST_SUITE_ROOT:-/nonexistent}"/*) ;;
    *) soft_fail "AZURE_CONFIG_DIR '${AZURE_CONFIG_DIR:-}' is not inside the suite root; it may be the operator's own" ;;
  esac
  [ -z "$(ls -A "${AZURE_CONFIG_DIR:-/nonexistent}" 2>/dev/null)" ] \
    || soft_fail "the suite's AZURE_CONFIG_DIR is not empty"
  resolved=$(command -v az || true)
  [ "$resolved" = "$TESTS/cloud-guard-bin/az" ] \
    || soft_fail "az resolves to '$resolved', not the suite's refusing guard; a real control-plane call is reachable"
  [ "$FAILED" -eq 0 ] && pass "an admitted test sees no operator identity, a refusing provider, and a refusing az"
}

# --- 4. the refusals actually refuse, and actually record -------------------

unit_provider_refusal_refuses_and_records() {
  local log out status
  log="$TMP_ROOT/provider-reach.log"
  : > "$log"
  out=$(printf '{"action":"create","task":"cloud-noenv-c7"}' \
    | FM_TEST_CLOUD_REACH_LOG="$log" FM_TEST_CURRENT_TEST=tests/fake.test.sh \
      python3 "$TESTS/cloud-provider-refusal.py" 2>&1); status=$?
  [ "$status" -eq 97 ] || soft_fail "the refusing provider exited $status, not 97"
  case "$out" in
    *"reached a worker provider without naming one"*) ;;
    *) soft_fail "the refusing provider did not name the wiring mistake: $out" ;;
  esac
  grep -q 'FM_CLOUD_REACH test=fake.test.sh via=provider action=create task=cloud-noenv-c7' "$log" \
    || soft_fail "the refusing provider did not record the reach: $(cat "$log")"
  pass "the fixture provider refuses a request it was never named for, and records the reach"
}

unit_az_guard_refuses_and_records() {
  local log out status
  log="$TMP_ROOT/az-reach.log"
  : > "$log"
  out=$(FM_TEST_CLOUD_REACH_LOG="$log" FM_TEST_CURRENT_TEST=tests/fake.test.sh \
    "$TESTS/cloud-guard-bin/az" vm create --name vm-should-never-exist 2>&1); status=$?
  [ "$status" -eq 97 ] || soft_fail "the az guard exited $status, not 97"
  case "$out" in
    *"attempted a real Azure control-plane call"*) ;;
    *) soft_fail "the az guard did not name the attempt: $out" ;;
  esac
  grep -q 'FM_CLOUD_REACH test=fake.test.sh via=az argv=vm create --name vm-should-never-exist' "$log" \
    || soft_fail "the az guard did not record the attempt: $(cat "$log")"
  pass "the az guard refuses a control-plane call and records the exact argv"
}

# --- 5. a recorded reach FAILS the suite ------------------------------------

unit_recorded_reach_fails_the_suite() {
  local log out status
  log="$TMP_ROOT/reach-check.log"
  : > "$log"
  "$TESTS/cloud-reach-check.sh" "$log"; status=$?
  [ "$status" -eq 0 ] || soft_fail "an empty reach log failed the check (exit $status)"
  printf 'FM_CLOUD_REACH test=x.test.sh via=az argv=vm create\n' > "$log"
  out=$("$TESTS/cloud-reach-check.sh" "$log" 2>&1); status=$?
  [ "$status" -eq 1 ] || soft_fail "a recorded reach did not fail the check (exit $status)"
  case "$out" in
    *"test isolation violation"*"via=az argv=vm create"*) ;;
    *) soft_fail "the reach check did not print what was reached: $out" ;;
  esac
  [ -s "$log" ] && soft_fail "the reach check did not truncate the log; the next test would inherit this reach"
  out=$("$TESTS/cloud-reach-check.sh" 2>&1); status=$?
  [ "$status" -eq 97 ] || soft_fail "the reach check accepted a missing argument (exit $status)"
  pass "a recorded cloud reach fails the run, prints what was reached, and does not leak into the next test"
}

# --- 6. no unit above may have polluted the REAL log ------------------------

unit_this_test_reached_nothing() {
  fm_assert_no_cloud_reach "the cloud seal guard itself reached a cloud seam"
  pass "the guard proved the refusals against its own logs and reached nothing itself"
}

unit_registry_is_pinned
unit_registry_failures_refuse
unit_run_sh_wires_the_seal
unit_this_process_is_sealed
unit_provider_refusal_refuses_and_records
unit_az_guard_refuses_and_records
unit_recorded_reach_fails_the_suite
unit_this_test_reached_nothing

exit "$FAILED"
