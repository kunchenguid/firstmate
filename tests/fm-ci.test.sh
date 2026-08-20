#!/usr/bin/env bash
# Characterization tests for fm-ci.sh's trusted-runner preflight contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-ci.sh"

test_requires_github_actions_runner() {
  local output rc=0
  output=$(env -i PATH="$PATH" LC_ALL=C LANG=C "$SCRIPT" 2>&1) || rc=$?
  expect_code 1 "$rc" "missing CI metadata must stop before host inspection"
  assert_contains "$output" "fm-ci: GITHUB_ACTIONS=true is required" \
    "preflight must identify the missing GitHub Actions marker"
  pass "fm-ci.sh rejects execution outside GitHub Actions"
}

test_requires_github_actions_runner
