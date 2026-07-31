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

if [ -f config/crew-dispatch.json ] && jq empty config/crew-dispatch.json 2>/dev/null; then
  test_pass "config/crew-dispatch.json is valid JSON"
else
  test_fail "config/crew-dispatch.json invalid"
fi

if jq -r '.profiles[].name' config/crew-dispatch.json 2>/dev/null | grep -q "sonnet-balanced"; then
  test_pass "Default sonnet-balanced profile exists"
else
  test_fail "sonnet-balanced profile missing"
fi

if [ -x bin/fm-format-task-cost.sh ]; then
  test_pass "bin/fm-format-task-cost.sh is executable"
else
  test_fail "Not executable"
fi

mkdir -p state && cat > state/test-task.meta << 'EOF'
model=sonnet effort=high harness=claude
EOF
COST=$(bin/fm-format-task-cost.sh test-task 2>/dev/null || echo "")
if echo "$COST" | grep -qE '^\$[0-9]+$'; then
  test_pass "Cost formatter: $COST"
else
  test_fail "Invalid output"
fi
rm -f state/test-task.meta

if [ -x bin/fm-dispatch-with-cost.sh ]; then
  test_pass "Dispatcher script executable"
else
  test_fail "Not executable"
fi

if [ -x bin/fm-cost-monitor.sh ]; then
  test_pass "Monitor script executable"
else
  test_fail "Not executable"
fi

if timeout 1 bin/fm-cost-monitor.sh 1 json 2>/dev/null | jq empty; then
  test_pass "Monitor JSON output valid"
else
  test_fail "Monitor JSON invalid"
fi

if [ -f .lavish/cost-dashboard.html ]; then
  test_pass "Dashboard exists"
else
  test_fail "Missing"
fi
if grep -q "time-cost-display" .lavish/cost-dashboard.html; then
  test_pass "Dashboard has cost display element"
else
  test_fail "Missing element"
fi

if [ -f docs/cost-monitoring.md ]; then
  test_pass "Documentation exists"
else
  test_fail "Missing"
fi

PROFILES=$(jq '.profiles | length' config/crew-dispatch.json 2>/dev/null || echo "0")
if [ "$PROFILES" -ge 3 ]; then
  test_pass "Configured $PROFILES profiles"
else
  test_fail "Need 3+ profiles"
fi

echo
echo "=== Results ==="
echo "Passed: $PASS | Failed: $FAIL"
echo
if [ $FAIL -eq 0 ]; then
  echo "✓ All tests passed!"
else
  echo "✗ Some tests failed"
fi
exit $FAIL
