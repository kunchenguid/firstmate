#!/usr/bin/env bash
# bin/fm-quota-preflight.sh: the advisory quota pre-flight a spawn prints.
#
# What these pin, against captured quota-axi --json snapshots:
#   1. A candidate whose applicable scope is exhausted_now gets one notice
#      naming the candidate, provider, and scope; a healthy one gets nothing.
#   2. The provider comes from the profile config/crew-dispatch.json declares
#      for exactly that harness and model, and a declared quota_scope applies.
#   3. It is advisory and quiet whenever it cannot speak with evidence: no
#      provider, shared quota, FM_QUOTA_PREFLIGHT=off, or a bad snapshot all
#      print nothing, and every case exits 0.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFLIGHT="$ROOT/bin/fm-quota-preflight.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-preflight)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

SNAP="$TMP_ROOT/quota.json"
cat > "$SNAP" <<'EOF'
{"schemaVersion":5,"providers":[
 {"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":40,"runway":{"status":"through_reset"}},
   {"scope":"model:fable","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}},
 {"provider":"zai","quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"all_models","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}}]}},
 {"provider":"agy","quotaSemantics":{"status":"known","effectiveAvailability":[
   {"scope":"gemini","status":"known","effectivePercentRemaining":0,"runway":{"status":"exhausted_now"}},
   {"scope":"claude_gpt","status":"known","effectivePercentRemaining":60,"runway":{"status":"through_reset"}}]}}
]}
EOF

CONFIG="$TMP_ROOT/config"
mkdir -p "$CONFIG"
cat > "$CONFIG/crew-dispatch.json" <<'EOF'
{"rules":[{"when":"simple","use":[
  {"harness":"pi","model":"zai/glm-5.3-flash","effort":"high","provider":"zai"},
  {"harness":"pi","model":"antigravity/gemini-3.8-flash","effort":"high","provider":"agy","quota_scope":"gemini"},
  {"harness":"pi","model":"antigravity/claude-sonnet-5-5","effort":"high","provider":"agy","quota_scope":"claude_gpt"}]}],
 "default":[{"harness":"claude","model":"sonnet","effort":"high"}]}
EOF

preflight() {  # <args...>
  env FM_QUOTA_PREFLIGHT=on FM_CONFIG_OVERRIDE="$CONFIG" bash "$PREFLIGHT" "$@" --snapshot "$SNAP"
}

test_exhausted_candidate_gets_one_notice() {
  local out rc
  out=$(preflight claude fable); rc=$?
  expect_code 0 "$rc" "the pre-flight is advisory and always exits 0"
  assert_contains "$out" "quota-preflight: claude:fable provider claude is exhausted_now at model:fable (0% left)" \
    "an exhausted model scope should be named"
  out=$(preflight claude sonnet)
  [ -z "$out" ] || fail "a candidate with applicable headroom must get no notice, got: $out"
  pass "fm-quota-preflight: an exhausted candidate gets one notice, a healthy one none"
}

test_declared_provider_and_scope_apply() {
  local out
  out=$(preflight pi zai/glm-5.3-flash)
  assert_contains "$out" "provider zai is exhausted_now at all_models" "the declared provider should bind the zai row"
  out=$(preflight pi antigravity/gemini-3.8-flash)
  assert_contains "$out" "provider agy is exhausted_now at gemini" "the declared quota_scope should apply"
  out=$(preflight pi antigravity/claude-sonnet-5-5)
  [ -z "$out" ] || fail "another scope of the same provider must not be blamed, got: $out"
  pass "fm-quota-preflight: the declared provider and quota_scope bind the right row"
}

test_quiet_without_evidence() {
  local out rc
  out=$(preflight pi some/unknown-model); rc=$?
  expect_code 0 "$rc" "no provider still exits 0"
  [ -z "$out" ] || fail "a launch with no resolvable provider must stay quiet, got: $out"
  out=$(env FM_QUOTA_PREFLIGHT=off FM_CONFIG_OVERRIDE="$CONFIG" bash "$PREFLIGHT" claude fable --snapshot "$SNAP")
  [ -z "$out" ] || fail "FM_QUOTA_PREFLIGHT=off must silence the notice, got: $out"
  printf 'not json\n' > "$TMP_ROOT/bad.json"
  out=$(env FM_QUOTA_PREFLIGHT=on FM_CONFIG_OVERRIDE="$CONFIG" bash "$PREFLIGHT" claude fable --snapshot "$TMP_ROOT/bad.json"); rc=$?
  expect_code 0 "$rc" "a bad snapshot still exits 0"
  [ -z "$out" ] || fail "an invalid snapshot must stay quiet, got: $out"
  mkdir -p "$TMP_ROOT/shared"
  jq '.shared_quota = true' "$CONFIG/crew-dispatch.json" > "$TMP_ROOT/shared/crew-dispatch.json"
  out=$(env FM_QUOTA_PREFLIGHT=on FM_CONFIG_OVERRIDE="$TMP_ROOT/shared" bash "$PREFLIGHT" claude fable --snapshot "$SNAP")
  [ -z "$out" ] || fail "a shared-quota home must get no quota notice, got: $out"
  pass "fm-quota-preflight: quiet and successful whenever it has no evidence to speak from"
}

test_exhausted_candidate_gets_one_notice
test_declared_provider_and_scope_apply
test_quiet_without_evidence
