#!/usr/bin/env bash
# tests/fm-jev-cache-watchdog.test.sh - Regression tests for Pattern 22
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="$FM_ROOT/bin"
WATCHDOG_PY="$BIN_DIR/fm-jev-cache-watchdog.py"
WATCHDOG_SH="$BIN_DIR/fm-jev-cache-watchdog.sh"

echo "=== Running fm-jev-cache-watchdog test suite ==="

# Test 1: Python syntax check
python3 -m py_compile "$WATCHDOG_PY"
echo "PASS: Test 1 - py_compile syntax valid"

# Test 2: ShellCheck on wrapper
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$WATCHDOG_SH"
  echo "PASS: Test 2 - ShellCheck clean on wrapper"
else
  bash -n "$WATCHDOG_SH"
  echo "PASS: Test 2 - bash -n syntax valid (shellcheck not installed)"
fi

# Setup mock sessions directory
TEST_TMP=$(mktemp -d "/tmp/fm-jev-cache-test.XXXXXX")
trap 'rm -rf "$TEST_TMP"' EXIT

mkdir -p "$TEST_TMP/sessions"

# Create mock session 1: Healthy (99.5% cache hit rate, 10% context)
cat <<'EOF' > "$TEST_TMP/sessions/healthy_session.jsonl"
{"type": "message", "message": {"role": "user", "content": "hello"}}
{"type": "message", "message": {"role": "assistant", "model": "grok-4.5", "usage": {"input": 100, "output": 50, "cacheRead": 19900, "totalTokens": 20050}}}
EOF

# Create mock session 2: Degraded cache (80.0% cache hit rate < 95%)
cat <<'EOF' > "$TEST_TMP/sessions/degraded_cache.jsonl"
{"type": "message", "message": {"role": "user", "content": "wake"}}
{"type": "message", "message": {"role": "assistant", "model": "grok-4.5", "usage": {"input": 2000, "output": 100, "cacheRead": 8000, "totalTokens": 10100}}}
EOF

# Create mock session 3: Context bloat (65% context on claude-3-5-sonnet: 130k / 200k)
cat <<'EOF' > "$TEST_TMP/sessions/bloated_context.jsonl"
{"type": "message", "message": {"role": "user", "content": "long task"}}
{"type": "message", "message": {"role": "assistant", "model": "claude-3-5-sonnet", "usage": {"input": 200, "output": 500, "cacheRead": 129300, "totalTokens": 130000}}}
EOF

# Test 3: Scan mock sessions and verify detection
OUTPUT=$("$WATCHDOG_SH" --roots "$TEST_TMP/sessions" --json)

# Validate healthy session parsed
echo "$OUTPUT" | grep -q '"sessions_inspected": 3'
echo "PASS: Test 3 - Correctly inspected all 3 mock sessions"

# Validate cache degradation alert on degraded_cache.jsonl
echo "$OUTPUT" | grep -q '"cache_hit_rate_pct": 80.0'
echo "$OUTPUT" | grep -q '"deficit_pct": 15.0'
echo "PASS: Test 4 - Correctly detected and measured prompt cache degradation"

# Validate context bloat alert on bloated_context.jsonl
echo "$OUTPUT" | grep -q '"context_usage_pct": 65.0'
echo "$OUTPUT" | grep -q '"remedy": "trigger_session_compaction_or_cycle_seat"'
echo "PASS: Test 5 - Correctly detected context window bloat and issued compaction remedy"

# Test 6: Human-readable CLI formatting
CLI_OUTPUT=$("$WATCHDOG_SH" --roots "$TEST_TMP/sessions")
echo "$CLI_OUTPUT" | grep -q "Cache Degradation Warnings:"
echo "$CLI_OUTPUT" | grep -q "Context Bloat Warnings:"
echo "PASS: Test 6 - Human-readable summary output verified"

echo "=== All 6 fm-jev-cache-watchdog tests passed successfully! ==="
