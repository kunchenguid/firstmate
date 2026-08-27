#!/usr/bin/env bash
# Behavioral coverage for the versioned crew-dispatch policy contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dispatch-policy)
POLICY="$ROOT/bin/fm-dispatch-policy.sh"
POLICY_FILE="$TMP_ROOT/crew-dispatch.json"

write_policy() {
  printf '%s\n' "$1" > "$POLICY_FILE"
}

expect_success() {
  "$@" >/dev/null 2>&1 || fail "expected success: $*"
}

expect_output() {
  local expected=$1 out
  shift
  out=$("$@") || fail "expected success: $*"
  [ "$out" = "$expected" ] || fail "expected '$expected', got '$out'"
}

expect_failure_contains() {
  local expected=$1 out rc
  shift
  set +e
  out=$("$@" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected failure: $*"
  assert_contains "$out" "$expected" "failure output"
}

test_v1_stays_valid() {
  write_policy '{"rules":[{"when":"anything","use":{"harness":"codex"}}]}'
  expect_success "$POLICY" validate "$POLICY_FILE"
  expect_output automatic "$POLICY" mode "$POLICY_FILE"
  pass "unversioned inline rules remain valid version 1 input"
}

test_v2_normalizes_named_profile() {
  write_policy '{"schemaVersion":2,"routing":{"mode":"simulate","limits":{"canary":3,"automatic":6,"burst":8,"perLane":2},"circuitBreaker":{"failures":3,"windowSeconds":900,"cooldownSeconds":1800},"transientRetries":1},"profiles":{"pi-grok":{"harness":"pi","model":"cliproxyapi/grok-4.6","provider":"xai","lane":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"]}},"rules":[{"when":"architecture","use":["pi-grok"]}]}'
  expect_success "$POLICY" validate "$POLICY_FILE"
  expect_output simulate "$POLICY" mode "$POLICY_FILE"
  "$POLICY" profile pi-grok "$POLICY_FILE" | jq -e '.id == "pi-grok" and .harness == "pi" and .lane == "pi-xai-1"' >/dev/null || fail "named version 2 profile was not normalized"
  pass "version 2 named profiles normalize through the public reader"
}

test_v2_rejects_secret_fields() {
  write_policy '{"schemaVersion":2,"routing":{"mode":"automatic"},"profiles":{"bad":{"harness":"pi","provider":"xai","lane":"pi-xai-1","apiKey":"secret"}}}'
  expect_failure_contains 'forbidden credential field: apiKey' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"profiles":{"bad":{"harness":"pi","provider":"xai","lane":"pi-xai-1","apiKey":{}}}}'
  expect_failure_contains 'forbidden credential field: apiKey' "$POLICY" validate "$POLICY_FILE"
  pass "credential-shaped fields are refused before dispatch"
}

test_v2_requires_safe_routing_bounds() {
  write_policy '{"schemaVersion":2,"routing":{"mode":"automatic","limits":{"canary":3,"automatic":6,"burst":8,"perLane":0}},"profiles":{}}'
  expect_failure_contains 'routing limit perLane must be 2' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"routing":{"mode":"automatic","circuitBreaker":{"failures":3,"windowSeconds":900,"cooldownSeconds":1800},"transientRetries":2},"profiles":{}}'
  expect_failure_contains 'transientRetries must be 1' "$POLICY" validate "$POLICY_FILE"
  pass "version 2 rejects routing bounds outside the fixed safe policy"
}

test_v2_requires_complete_safe_profiles() {
  write_policy '{"schemaVersion":2,"profiles":{"native":{"harness":"codex","provider":"openai","lane":"codex-primary","reasoningClass":"strong","workTypes":["implementation"]}}}'
  expect_failure_contains 'native claude and codex profiles need account' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"profiles":{"pi":{"harness":"pi","provider":"xai","lane":"pi-xai-1","account":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"]}}}'
  expect_failure_contains 'pi and pi-signed profiles cannot set account' "$POLICY" validate "$POLICY_FILE"
  write_policy '{"schemaVersion":2,"profiles":{"pi":{"harness":"pi","provider":"xai","lane":"pi-xai-1","reasoningClass":"strong","workTypes":["architecture"]}},"rules":[{"when":"architecture","use":["missing"]}]}'
  expect_failure_contains 'unknown named profile: missing' "$POLICY" validate "$POLICY_FILE"
  pass "version 2 requires safe accounts and existing named profile references"
}

test_v1_stays_valid
test_v2_normalizes_named_profile
test_v2_rejects_secret_fields
test_v2_requires_safe_routing_bounds
test_v2_requires_complete_safe_profiles
