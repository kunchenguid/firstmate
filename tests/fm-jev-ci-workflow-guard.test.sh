#!/usr/bin/env bash
# tests/fm-jev-ci-workflow-guard.test.sh - Test suite for Pattern 10 CI Landing Gate Verifier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$FM_ROOT/bin/fm-jev-ci-workflow-guard.sh"
TMP_DIR=$(mktemp -d /tmp/fm-jev-ci-test-XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok - %s\n' "$1"; }

printf '1. Verify help flag...\n'
"$GUARD" --help >/dev/null 2>&1 || fail "guard --help failed"
ok "help flag works"

printf '2. Verify Zero-CI repository detection...\n'
ZERO_REPO="$TMP_DIR/zero-repo"
mkdir -p "$ZERO_REPO/src"
out=$("$GUARD" --repo-dir "$ZERO_REPO" --json) || fail "failed inspecting zero-ci repo"
echo "$out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
st = data["workflows"]["status"]
assert st == "ZERO_CI", "Expected ZERO_CI, got " + st
assert data["evaluation"]["verdict"] == "APPROVED_FOR_LANDING"
assert data["evaluation"]["can_merge"] is True
' || fail "zero-ci assertion failed"
ok "zero-ci repo correctly identified and approved"

printf '3. Verify CI-Active repository detection...\n'
CI_REPO="$TMP_DIR/ci-repo"
mkdir -p "$CI_REPO/.github/workflows"
cat << 'EOF' > "$CI_REPO/.github/workflows/ci.yml"
name: CI
on:
  pull_request:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo test
EOF
ci_out=$("$GUARD" --repo-dir "$CI_REPO" --json) || fail "failed inspecting ci repo"
echo "$ci_out" | python3 -c '
import json, sys
data = json.load(sys.stdin)
st = data["workflows"]["status"]
assert st == "CI_ACTIVE", "Expected CI_ACTIVE, got " + st
assert data["workflows"]["pr_trigger_count"] == 1
assert data["evaluation"]["decision"] == "REQUIRE_CI"
' || fail "ci-active assertion failed"
ok "ci-active repo correctly identified with require-ci decision"

printf '4. Verify pytest output parsing and pass verification...\n'
PYTEST_LOG="$TMP_DIR/pytest-pass.log"
cat << 'EOF' > "$PYTEST_LOG"
============================= test session starts ==============================
rootdir: /tmp/sample
collected 42 items

test_sample.py ..........................................                [100%]

============================== 42 passed in 1.23s ==============================
EOF
pass_eval=$("$GUARD" --repo-dir "$ZERO_REPO" --test-output "$PYTEST_LOG" --json) || fail "failed evaluating passed test log"
echo "$pass_eval" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["tests"]["framework"] == "pytest"
assert data["tests"]["passed"] == 42
assert data["tests"]["failed"] == 0
assert data["tests"]["success"] is True
assert data["evaluation"]["verdict"] == "APPROVED_FOR_LANDING"
' || fail "pytest pass verification failed"
ok "pytest pass correctly recognized"

printf '5. Verify pytest failure blocking under --strict...\n'
PYTEST_FAIL_LOG="$TMP_DIR/pytest-fail.log"
cat << 'EOF' > "$PYTEST_FAIL_LOG"
============================= test session starts ==============================
rootdir: /tmp/sample
collected 42 items

test_sample.py ........................................F.                [100%]

=================================== FAILURES ===================================
_________________________________ test_broken __________________________________
>       assert 1 == 2
E       assert 1 == 2
=========================== 1 failed, 41 passed in 1.45s ===========================
EOF
if "$GUARD" --repo-dir "$ZERO_REPO" --test-output "$PYTEST_FAIL_LOG" --strict >/dev/null 2>&1; then
  fail "guard should have exited non-zero with failing tests under --strict"
fi
fail_eval=$("$GUARD" --repo-dir "$ZERO_REPO" --test-output "$PYTEST_FAIL_LOG" --json) || true
echo "$fail_eval" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["tests"]["failed"] == 1
assert data["tests"]["passed"] == 41
assert data["evaluation"]["verdict"] == "BLOCKED_TESTS_FAILING"
assert data["evaluation"]["can_merge"] is False
' || fail "failed tests block assertion failed"
ok "failing test blocks landing under --strict"

printf '6. Verify Markdown attestation generation...\n'
md_out=$("$GUARD" --repo-dir "$ZERO_REPO" --test-output "$PYTEST_LOG" --format markdown)
echo "$md_out" | grep -q "Jev Landing Gate Attestation" || fail "missing header in markdown"
echo "$md_out" | grep -q "APPROVED_FOR_LANDING" || fail "missing approved verdict in markdown"
echo "$md_out" | grep -q "42 passed" || fail "missing test counts in markdown"
ok "markdown attestation format verified"

printf '7. Verify live detection on Zeta repository...\n'
if [ -d "/home/jon/code/Zeta" ]; then
  zeta_eval=$("$GUARD" --repo-dir /home/jon/code/Zeta --json)
  echo "$zeta_eval" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["workflows"]["status"] == "ZERO_CI"
assert data["evaluation"]["can_merge"] is True
' || fail "Zeta live inspection failed"
  ok "live Zeta repo confirmed ZERO_CI and approved for +yolo landing"
fi

printf '8. Verify live detection on Firstmate repository...\n'
fm_eval=$("$GUARD" --repo-dir "$FM_ROOT" --json)
echo "$fm_eval" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["workflows"]["status"] == "CI_ACTIVE"
assert data["workflows"]["total_workflows"] >= 2
' || fail "Firstmate live inspection failed"
ok "live Firstmate repo confirmed CI_ACTIVE"

printf 'ok - all fm-jev-ci-workflow-guard tests passed\n'
