#!/usr/bin/env bash
# Smoke the firstmate MCP auth broker against its committed mock upstream.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

free_port() {
  node -e "const net = require('node:net'); const server = net.createServer(); server.listen(0, '127.0.0.1', () => { console.log(server.address().port); server.close(); });"
}

e2e_mock_port=$(free_port)
out=$(
  BROKER_MOCK_PORT="$e2e_mock_port" node "$ROOT/bin/mcp-broker/demo/e2e.ts" 2>&1
)
status=$?
expect_code 0 "$status" "mcp broker e2e should pass"
assert_contains "$out" "ALL ASSERTIONS PASSED" "mcp broker e2e did not reach the success step"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/mcp-broker-call.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$tmp")
broker_home="$tmp/broker-home"
empty_home="$tmp/empty-home"
mock_log="$tmp/mock.log"
slack_secret="xoxb-call-secret"
mock_port=$(free_port)
mock_base="http://127.0.0.1:$mock_port"
mock_pid=""

cleanup_mcp_broker_call() {
  if [ -n "$mock_pid" ]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_mcp_broker_call EXIT

BROKER_MOCK_PORT="$mock_port" BROKER_MOCK_SLACK_TOKEN="$slack_secret" \
  node "$ROOT/bin/mcp-broker/mock/upstream.ts" >"$mock_log" 2>&1 &
mock_pid=$!

i=0
while [ "$i" -lt 50 ]; do
  grep -F "mock upstream" "$mock_log" >/dev/null 2>&1 && break
  sleep 0.1
  i=$((i + 1))
done
assert_contains "$(cat "$mock_log")" "mock upstream on :$mock_port" "mock upstream did not start"

out=$(
  env BROKER_HOME="$broker_home" BROKER_MOCK_BASE="$mock_base" \
    "$ROOT/bin/fm-mcp-broker" connect linear --api-key lin_api_mock 2>&1
)
status=$?
expect_code 0 "$status" "linear mock connect should pass"

out=$(
  env BROKER_HOME="$broker_home" BROKER_MOCK_BASE="$mock_base" \
    "$ROOT/bin/fm-mcp-broker" connect slack --token "$slack_secret" 2>&1
)
status=$?
expect_code 0 "$status" "slack mock connect should pass"

out=$(
  env BROKER_HOME="$broker_home" BROKER_MOCK_BASE="$mock_base" \
    "$ROOT/bin/fm-mcp-broker" call linear linear_viewer 2>&1
)
status=$?
expect_code 0 "$status" "linear one-shot call should pass"
assert_contains "$out" '"viewer"' "linear call should print tool result"
assert_contains "$out" '"email": "tim@lindy.ai"' "linear call should include viewer data"
assert_not_contains "$out" "linear-access-" "linear call output must not leak access token"
assert_not_contains "$out" "lin_api_mock" "linear call output must not leak API key"

out=$(
  env BROKER_HOME="$broker_home" BROKER_MOCK_BASE="$mock_base" \
    "$ROOT/bin/fm-mcp-broker" call linear linear_search_issues --args '{"query":"intake"}' 2>&1
)
status=$?
expect_code 0 "$status" "linear call with args should pass"
assert_contains "$out" '"issues"' "linear call should pass JSON args"
assert_contains "$out" '"Mock issue"' "linear call should return mock search results"

out=$(
  env BROKER_HOME="$broker_home" BROKER_MOCK_BASE="$mock_base" \
    "$ROOT/bin/fm-mcp-broker" call linear linear_missing 2>&1
)
status=$?
expect_code 1 "$status" "unknown linear tool should fail"
assert_contains "$out" "unknown tool: linear_missing" "unknown linear tool should explain failure"

out=$(
  env BROKER_HOME="$broker_home" BROKER_MOCK_BASE="$mock_base" \
    "$ROOT/bin/fm-mcp-broker" call slack auth.test 2>&1
)
status=$?
expect_code 0 "$status" "slack one-shot call should pass"
assert_contains "$out" '"method": "auth.test"' "slack call should print upstream result"
assert_contains "$out" '"servedWithToken": "[REDACTED]"' "slack call should redact token-bearing fields"
assert_not_contains "$out" "$slack_secret" "slack call output must not leak token"

out=$(
  env BROKER_HOME="$broker_home" BROKER_MOCK_BASE="$mock_base" \
    "$ROOT/bin/fm-mcp-broker" call slack admin.users.list 2>&1
)
status=$?
expect_code 1 "$status" "slack allowlist rejection should fail"
assert_contains "$out" "not allowed by broker allowlist" "slack allowlist rejection should explain failure"

out=$(
  env BROKER_HOME="$empty_home" BROKER_MOCK_BASE="$mock_base" \
    "$ROOT/bin/fm-mcp-broker" call slack auth.test 2>&1
)
status=$?
expect_code 1 "$status" "missing slack credentials should fail"
assert_contains "$out" "no token" "missing credentials failure should be clear"

pass "fm-mcp-broker mock e2e and one-shot call pass"
