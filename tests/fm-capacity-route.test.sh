#!/usr/bin/env bash
# Behavior tests for capacity route cooldown selection and wall handling.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTE="$ROOT/bin/fm-capacity-route.sh"
COOLDOWN="$ROOT/bin/fm-capacity-cooldown.sh"
FIXTURES="$ROOT/tests/fixtures/capacity-walls"
TMP_ROOT=$(fm_test_tmproot fm-capacity-route)

write_routes() {
  local file=$1
  shift
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$@" > "$file"
}

test_quota_wall_records_cooldown_and_selects_alternate_route() {
  local home routes out status active
  home="$TMP_ROOT/quota/home"
  routes="$home/config/capacity-failover"
  mkdir -p "$home/state" "$home/config"
  write_routes "$routes" \
    "route=codex|acct-a|gpt-5.5|gpt-5.5|xhigh" \
    "route=claude|acct-b|sonnet|sonnet|high"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_CAPACITY_NOW_EPOCH=2000 \
    "$ROUTE" handle-wall --task task-rate --harness codex --account acct-a --profile gpt-5.5 \
    --routes-file "$routes" --file "$FIXTURES/rate-limit-retry-after.txt")
  status=$?

  expect_code 0 "$status" "quota wall should record and select an alternate route"
  assert_contains "$out" "recorded_route_block=" "quota wall should record the blocked route"
  assert_contains "$out" "selected_harness=claude" "cooled-down codex route should be skipped"
  assert_contains "$out" "action=rehome_same_owner" "handle-wall should request same-owner rehome"
  assert_contains "$out" "task=task-rate" "handle-wall should preserve the task id"

  active=$(FM_STATE_OVERRIDE="$home/state" FM_CAPACITY_NOW_EPOCH=2001 "$COOLDOWN" active \
    --harness codex --account acct-a --profile gpt-5.5)
  assert_contains "$active" "reset_epoch=2120" "quota route should stay blocked until retry-after reset"
  assert_contains "$active" "remaining_secs=119" "quota route should expose remaining TTL"
  pass "quota output records cooldown and selects another verified route with headroom"
}

test_partial_wall_key_blocks_every_route_for_same_harness() {
  local home routes out status active
  home="$TMP_ROOT/partial/home"
  routes="$home/config/capacity-failover"
  mkdir -p "$home/state" "$home/config"
  write_routes "$routes" \
    "route=codex|acct-a|gpt-5.5|gpt-5.5|xhigh" \
    "route=codex|acct-b|gpt-5.6|gpt-5.6|high" \
    "route=claude|acct-c|sonnet|sonnet|high"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_CAPACITY_NOW_EPOCH=2000 \
    "$ROUTE" handle-wall --task task-rate --harness codex \
    --routes-file "$routes" --file "$FIXTURES/rate-limit-retry-after.txt")
  status=$?

  expect_code 0 "$status" "partial quota wall should still select an alternate route"
  assert_contains "$out" "route_1_status=blocked" "first codex route should be blocked by partial key"
  assert_contains "$out" "route_2_status=blocked" "second codex route should be blocked by partial key"
  assert_contains "$out" "selected_harness=claude" "partial codex wall should not reselect another codex route"
  assert_not_contains "$out" "selected_harness=codex" "partial codex wall should block every codex route"

  active=$(FM_STATE_OVERRIDE="$home/state" FM_CAPACITY_NOW_EPOCH=2001 "$COOLDOWN" active \
    --harness codex --profile default)
  assert_contains "$active" "account=" "partial cooldown should record the omitted account as empty"
  assert_contains "$active" "profile=default" "partial cooldown should record the default profile"
  pass "partial wall keys block every route for the walled harness"
}

test_expired_cooldown_route_becomes_selectable() {
  local home routes out status
  home="$TMP_ROOT/expiry/home"
  routes="$home/config/capacity-failover"
  mkdir -p "$home/state" "$home/config"
  write_routes "$routes" \
    "route=codex|acct-a|gpt-5.5|gpt-5.5|xhigh" \
    "route=claude|acct-b|sonnet|sonnet|high"
  FM_STATE_OVERRIDE="$home/state" FM_CAPACITY_NOW_EPOCH=1000 "$COOLDOWN" mark \
    --harness codex --account acct-a --profile gpt-5.5 --reset-epoch 1100 \
    --class quota --reason rate_limit >/dev/null

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_CAPACITY_NOW_EPOCH=1100 \
    "$ROUTE" select --routes-file "$routes")
  status=$?

  expect_code 0 "$status" "expired cooldown should not block route selection"
  assert_contains "$out" "selected_harness=codex" "expired cooldown route should be selectable again"
  pass "route selection skips cooled-down routes only until expiry"
}

test_auth_wall_records_manual_block_and_escalates_without_route() {
  local home routes out status active
  home="$TMP_ROOT/auth/home"
  routes="$home/config/capacity-failover"
  mkdir -p "$home/state" "$home/config"
  write_routes "$routes" "route=pi|codex|gpt-5.6-luna|gpt-5.6-luna|high"

  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROUTE" handle-wall --task task-auth --harness pi --routes-file "$routes" \
    --file "$FIXTURES/proxy-auth-unavailable.json" 2>&1)
  status=$?
  set +e

  expect_code 1 "$status" "auth-unavailable with no alternate route should escalate"
  assert_contains "$out" "reason=proxy_auth_unavailable" "auth wall should be classified"
  assert_contains "$out" "action=escalate" "no noninteractive route should escalate"
  assert_contains "$out" "blocked_account=codex" "escalation should include provider/account identity"
  assert_contains "$out" "blocked_profile=gpt-5.6-luna" "escalation should include model/profile"
  assert_contains "$out" "needed_action=wait for reset or complete the listed interactive auth/account action" \
    "escalation should name the required account action class"

  active=$(FM_STATE_OVERRIDE="$home/state" "$COOLDOWN" active \
    --harness pi --account codex --profile gpt-5.6-luna)
  assert_contains "$active" "reset_epoch=manual" "auth exhaustion should be a manual block, not invented TTL"
  assert_contains "$active" "requires_action=interactive_auth_required" "auth exhaustion should record the required login action"
  pass "auth-unavailable records auth exhaustion and escalates when no alternate route exists"
}

test_login_required_records_provider_action_and_escalates_without_route() {
  local home routes out status active
  home="$TMP_ROOT/login/home"
  routes="$home/config/capacity-failover"
  mkdir -p "$home/state" "$home/config"
  write_routes "$routes" "route=claude|claude|sonnet|sonnet|high"

  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROUTE" handle-wall --task task-login --harness claude --profile sonnet --routes-file "$routes" \
    --file "$FIXTURES/login-required.txt" 2>&1)
  status=$?
  set +e

  expect_code 1 "$status" "login-required with no alternate route should escalate"
  assert_contains "$out" "reason=login_required" "login-required should be classified"
  assert_contains "$out" "action=escalate" "no noninteractive route should escalate"
  assert_contains "$out" "blocked_harness=claude" "escalation should include exact harness"
  assert_contains "$out" "blocked_account=claude" "escalation should include extracted provider/account"
  assert_contains "$out" "blocked_model=sonnet" "escalation should include exact selected model/profile"
  assert_contains "$out" "blocked_reset_epoch=manual" "auth escalation should make the manual block explicit"
  assert_contains "$out" "blocked_requires_action=interactive_auth_required" "escalation should include the needed login action"

  active=$(FM_STATE_OVERRIDE="$home/state" "$COOLDOWN" active \
    --harness claude --account claude --profile sonnet)
  assert_contains "$active" "reset_epoch=manual" "login-required should be a manual auth block"
  assert_contains "$active" "requires_action=interactive_auth_required" "login-required should record the auth action"
  pass "login-required records provider-scoped auth exhaustion and exact escalation action"
}

test_every_route_exhausted_reports_reset_and_login_action() {
  local home routes out status
  home="$TMP_ROOT/exhausted/home"
  routes="$home/config/capacity-failover"
  mkdir -p "$home/state" "$home/config"
  write_routes "$routes" \
    "route=codex|acct-a|gpt-5.5|gpt-5.5|xhigh" \
    "route=pi|codex|gpt-5.6-luna|gpt-5.6-luna|high"
  FM_STATE_OVERRIDE="$home/state" FM_CAPACITY_NOW_EPOCH=3000 "$COOLDOWN" mark \
    --harness codex --account acct-a --profile gpt-5.5 --reset-epoch 3600 \
    --class quota --reason rate_limit >/dev/null
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-capacity-classify.sh" \
    --file "$FIXTURES/proxy-auth-unavailable.json" >/dev/null
  # Source the lib through the route helper path by recording the manual block via handle-wall's public behavior.
  set +e
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_CAPACITY_NOW_EPOCH=3000 \
    "$ROUTE" handle-wall --task task-luna --harness pi --routes-file "$routes" \
    --file "$FIXTURES/proxy-auth-unavailable.json" >/dev/null 2>&1
  set +e

  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_CAPACITY_NOW_EPOCH=3000 \
    "$ROUTE" select --routes-file "$routes" 2>&1)
  status=$?
  set +e

  expect_code 1 "$status" "every exhausted route should return non-zero"
  assert_contains "$out" "escalation=every_verified_route_exhausted" "selection should escalate when no route has headroom"
  assert_contains "$out" "route_1_harness=codex" "escalation should include exact first harness"
  assert_contains "$out" "route_1_account=acct-a" "escalation should include exact first account"
  assert_contains "$out" "route_1_model=gpt-5.5" "escalation should include exact first model"
  assert_contains "$out" "route_1_reset_epoch=3600" "escalation should include known reset time"
  assert_contains "$out" "route_2_harness=pi" "escalation should include exact second harness"
  assert_contains "$out" "route_2_account=codex" "escalation should include exact provider identity"
  assert_contains "$out" "route_2_requires_action=interactive_auth_required" "escalation should include login/account action"
  pass "every-route-exhausted escalation includes exact route, reset, and login action"
}

test_dispatch_profile_backstop_blocks_unapproved_selection() {
  local home routes out status
  home="$TMP_ROOT/dispatch/home"
  routes="$home/config/capacity-failover"
  mkdir -p "$home/state" "$home/config"
  write_routes "$routes" "route=codex|acct-a|gpt-5.5|gpt-5.5|xhigh"
  printf '{"rules":[{"when":"anything","use":{"harness":"codex"}}]}\n' > "$home/config/crew-dispatch.json"

  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROUTE" select --routes-file "$routes" 2>&1)
  status=$?
  set +e

  expect_code 1 "$status" "active dispatch profile should require approval"
  assert_contains "$out" "consult it first" "route helper should not bypass crew-dispatch rules"
  pass "route selection never bypasses active dispatch rules without approval"
}

test_quota_wall_records_cooldown_and_selects_alternate_route
test_partial_wall_key_blocks_every_route_for_same_harness
test_expired_cooldown_route_becomes_selectable
test_auth_wall_records_manual_block_and_escalates_without_route
test_login_required_records_provider_action_and_escalates_without_route
test_every_route_exhausted_reports_reset_and_login_action
test_dispatch_profile_backstop_blocks_unapproved_selection

echo "# all fm-capacity-route tests passed"
