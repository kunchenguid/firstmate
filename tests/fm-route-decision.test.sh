#!/usr/bin/env bash
# Behavioral regressions for the strict, advisory-only model route decision contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VALIDATOR="$ROOT/bin/fm-route-decision.sh"
TMP_ROOT=$(fm_test_tmproot fm-route-decision)

route_json() {
  jq -cn --arg route "$1" --arg provider "$2" --arg model "$3" \
    --argjson confidence "$4" --arg privacy "$5" --arg source "$6" \
    --arg reason "$7" --argjson override "${8:-null}" '{
      schema: "fm-route-decision.v1",
      route: $route,
      provider: $provider,
      model: $model,
      confidence: $confidence,
      privacy: $privacy,
      source: $source,
      reason: $reason,
      override: $override
    }'
}

expect_valid() {
  local label=$1 payload=$2 out
  out=$(printf '%s\n' "$payload" | "$VALIDATOR" validate - 2>"$TMP_ROOT/error") \
    || fail "$label was rejected: $(cat "$TMP_ROOT/error")"
  printf '%s' "$out" | jq -e '.schema == "fm-route-decision.v1"' >/dev/null \
    || fail "$label did not return the versioned decision"
}

expect_rejected() {
  local label=$1 payload=$2
  if printf '%s\n' "$payload" | "$VALIDATOR" validate - >"$TMP_ROOT/output" 2>"$TMP_ROOT/error"; then
    fail "$label was accepted"
  fi
}

test_valid_decisions() {
  local local_decision cloud_decision
  local_decision=$(route_json local-qwen-14b local qwen-14b 0.9 local-only advisory local-safe null)
  cloud_decision=$(route_json cloud-opus-4-8 cloud opus-4-8 0.8 cloud-allowed advisory cloud-capable null)
  expect_valid "local advisory decision" "$local_decision"
  expect_valid "cloud advisory decision" "$cloud_decision"
  pass "valid local and cloud advisory decisions are accepted"
}

test_strict_json_and_allowlists() {
  local valid extra unknown_route unknown_provider unknown_model
  valid=$(route_json cloud-luna cloud luna 0.8 cloud-allowed advisory cloud-safe null)
  extra=$(printf '%s' "$valid" | jq '.unexpected = true')
  unknown_route=$(printf '%s' "$valid" | jq '.route = "cloud-unknown"')
  unknown_provider=$(printf '%s' "$valid" | jq '.provider = "unverified-provider"')
  unknown_model=$(printf '%s' "$valid" | jq '.model = "unverified-model"')
  expect_rejected "malformed JSON" '{"schema":'
  expect_rejected "extra field" "$extra"
  expect_rejected "unknown route" "$unknown_route"
  expect_rejected "unknown provider" "$unknown_provider"
  expect_rejected "unknown model" "$unknown_model"
  pass "malformed JSON, extra fields, and unknown route values are rejected"
}

test_privacy_and_cross_field_invariants() {
  local cloud_local local_cloud bad_local bad_cloud low
  cloud_local=$(route_json cloud-luna cloud luna 0.8 local-only advisory privacy-conflict null)
  local_cloud=$(route_json local-qwen-14b local qwen-14b 0.8 cloud-allowed advisory local-route-cloud-safe null)
  bad_local=$(route_json local-qwen-14b cloud qwen-14b 0.8 local-only advisory wrong-provider null)
  bad_cloud=$(route_json cloud-luna cloud qwen-14b 0.8 cloud-allowed advisory wrong-model null)
  low=$(route_json cloud-luna cloud luna 0.49 cloud-allowed advisory too-uncertain null)
  expect_rejected "cloud route with local-only privacy" "$cloud_local"
  expect_valid "local route with cloud-allowed privacy" "$local_cloud"
  expect_rejected "local route with cloud provider" "$bad_local"
  expect_rejected "cloud route with local model" "$bad_cloud"
  expect_rejected "low-confidence non-escalation" "$low"
  pass "privacy, profile, and confidence invariants are deterministic"
}

test_escalation_and_explicit_override() {
  local escalation explicit mismatch
  escalation=$(route_json escalate none none 0.1 local-only advisory uncertain-escalation null)
  explicit=$(route_json local-qwen-14b local qwen-14b 0.2 local-only explicit operator-override \
    '{"route":"local-qwen-14b","reason":"operator requires local processing"}')
  mismatch=$(route_json cloud-luna cloud luna 0.9 cloud-allowed explicit stale-effective-route \
    '{"route":"local-qwen-14b","reason":"operator requires local processing"}')
  expect_valid "escalation decision" "$escalation"
  expect_valid "explicit local override" "$explicit"
  expect_rejected "override that does not match the effective route" "$mismatch"
  pass "escalation permits uncertainty and an explicit override controls the effective route"
}

test_profile_contract() {
  local profile
  profile=$("$VALIDATOR" profile local-qwen-14b)
  printf '%s' "$profile" | jq -e '
    .route == "local-qwen-14b" and
    .provider == "local" and
    .model == "qwen-14b" and
    .endpoint == "operator-configured"
  ' >/dev/null || fail "local Qwen profile lost its operator-configured endpoint contract"
  if "$VALIDATOR" profile unknown-route >/dev/null 2>"$TMP_ROOT/error"; then
    fail "unknown profile route was accepted"
  fi
  pass "allowlisted profiles preserve logical IDs without provider endpoint assumptions"
}

test_valid_decisions
test_strict_json_and_allowlists
test_privacy_and_cross_field_invariants
test_escalation_and_explicit_override
test_profile_contract
