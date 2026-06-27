#!/usr/bin/env bash
# Behavior tests for the Retell AXI safety surface.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

assert_contains() {
  local label=$1 haystack=$2 needle=$3
  printf '%s\n' "$haystack" | grep -F "$needle" >/dev/null || fail "$label: missing '$needle' in: $haystack"
}

test_auth_missing_is_structured() {
  local out status
  set +e
  out=$(RETELL_API_KEY= RETELL_AXI_NO_OP=1 "$ROOT/bin/retell-axi" auth check 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "auth missing should exit nonzero"
  assert_contains "auth missing" "$out" "type: auth_missing"
  assert_contains "auth missing" "$out" '1Password item "Recall.it API Key"'
  printf '%s\n' "$out" | grep -F 'Bearer ' >/dev/null && fail "auth missing leaked a bearer header"
  pass "retell-axi auth missing output is structured and secret-free"
}

test_home_auth_missing_is_structured() {
  local out status
  set +e
  out=$(RETELL_API_KEY= RETELL_AXI_NO_OP=1 "$ROOT/bin/retell-axi" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "home auth missing should exit nonzero"
  assert_contains "home auth missing" "$out" "type: auth_missing"
  assert_contains "home auth missing" "$out" '1Password item "Recall.it API Key"'
  printf '%s\n' "$out" | grep -F 'Bearer ' >/dev/null && fail "home auth missing leaked a bearer header"
  pass "retell-axi home auth missing output is structured and secret-free"
}

test_invalid_id_is_structured() {
  local out status
  set +e
  out=$(RETELL_API_KEY= RETELL_AXI_NO_OP=1 "$ROOT/bin/retell-axi" calls view 'bad/id' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "invalid id should exit nonzero"
  assert_contains "invalid id" "$out" "type: invalid_id"
  pass "retell-axi rejects unsafe IDs before HTTP"
}

test_mcp_config_uses_env_placeholder() {
  local out
  out=$(RETELL_API_KEY= RETELL_AXI_NO_OP=1 "$ROOT/bin/retell-axi" mcp-config)
  assert_contains "mcp config" "$out" "https://mcp.retellai.com"
  assert_contains "mcp config" "$out" 'Bearer ${RETELL_API_KEY}'
  printf '%s\n' "$out" | grep -F 'Recall.it API Key' >/dev/null && fail "mcp config should not mention the 1Password item as a config secret"
  pass "retell-axi MCP config uses safe placeholders"
}

test_auth_missing_is_structured
test_home_auth_missing_is_structured
test_invalid_id_is_structured
test_mcp_config_uses_env_placeholder
