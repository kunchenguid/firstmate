#!/bin/bash
set -euo pipefail

PASS=0
FAIL=0

test_pass() {
  echo "✓ $1"
  PASS=$((PASS + 1))
}

test_fail() {
  echo "✗ $1"
  FAIL=$((FAIL + 1))
}

echo "=== Cost Monitoring Test Suite ==="
echo

[ -f config/crew-dispatch.json ] && jq empty config/crew-dispatch.json 2>/dev/null && \
  test_pass "config/crew-dispatch.json is valid JSON" || \
  test_fail "config/crew-dispatch.json invalid"

jq -r '.profiles[].name' config/crew-dispatch.json 2>/dev/null | grep -q "sonnet-balanced" && \
  test_pass "Default sonnet-balanced profile exists" || \
  test_fail "sonnet-balanced profile missing"

[ -x bin/fm-cost-format.sh ] && test_pass "bin/fm-cost-format.sh is executable" || test_fail "Not executable"

mkdir -p state && cat > state/test-task.meta << 'EOF'
model=sonnet effort=high harness=claude
EOF
COST=$(bin/fm-cost-format.sh test-task 2>/dev/null || echo "")
echo "$COST" | grep -q '\$.*\/min' && test_pass "Cost formatter: $COST" || test_fail "Invalid output"
rm -f state/test-task.meta

[ -x bin/fm-dispatch-with-cost.sh ] && test_pass "Dispatcher script executable" || test_fail "Not executable"

[ -x bin/fm-cost-monitor.sh ] && test_pass "Monitor script executable" || test_fail "Not executable"

timeout 1 bin/fm-cost-monitor.sh 1 json 2>/dev/null | jq empty && \
  test_pass "Monitor JSON output valid" || \
  test_fail "Monitor JSON invalid"

[ -f .lavish/cost-dashboard.html ] && test_pass "Dashboard exists" || test_fail "Missing"
grep -q "time-cost-display" .lavish/cost-dashboard.html && \
  test_pass "Dashboard has cost display element" || test_fail "Missing element"

[ -f docs/cost-monitoring.md ] && test_pass "Documentation exists" || test_fail "Missing"

PROFILES=$(jq '.profiles | length' config/crew-dispatch.json 2>/dev/null || echo "0")
[ "$PROFILES" -ge 3 ] && test_pass "Configured $PROFILES profiles" || test_fail "Need 3+ profiles"

echo
echo "=== Results ==="
echo "Passed: $PASS | Failed: $FAIL"
echo
[ $FAIL -eq 0 ] && echo "✓ All tests passed!" || echo "✗ Some tests failed"
exit $FAIL
