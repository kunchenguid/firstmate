#!/usr/bin/env bash
# Characterization tests for fm-ci.sh's trusted-runner preflight contract.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-ci.sh"

test_requires_github_actions_runner() {
  local config output rc=0
  config=$(fm_test_tmproot fm-ci-config)
  mkdir -p "$config"
  output=$(env -i PATH="$PATH" LC_ALL=C LANG=C FM_CONFIG_OVERRIDE="$config" "$SCRIPT" 2>&1) || rc=$?
  expect_code 1 "$rc" "missing CI metadata must stop before host inspection"
  assert_contains "$output" "fm-ci: GITHUB_ACTIONS=true is required" \
    "preflight must identify the missing GitHub Actions marker"
  pass "fm-ci.sh rejects execution outside GitHub Actions"
}

test_disabled_platform_workflows_remain_disabled() {
  local output rc=0
  grep -Fqx windows "$ROOT/config/disabled-adapters" || fail "Windows must remain disabled"
  grep -Fqx water7 "$ROOT/config/disabled-adapters" || fail "Water 7 must remain disabled"
  [ -f "$ROOT/.github/workflows/windows-herdr-spike.yml.disabled" ] \
    || fail "disabled Windows workflow must be retained"
  [ ! -e "$ROOT/.github/workflows/windows-herdr-spike.yml" ] \
    || fail "Windows workflow must not be runnable"
  [ -f "$ROOT/.github/workflows/ci-water7-fallback.yml.disabled" ] \
    || fail "disabled Water 7 workflow must be retained"
  [ ! -e "$ROOT/.github/workflows/ci-water7-fallback.yml" ] \
    || fail "Water 7 workflow must not be runnable"
  output=$(GITHUB_ACTIONS=true FM_CONFIG_OVERRIDE="$ROOT/config" "$SCRIPT" 2>&1) || rc=$?
  expect_code 1 "$rc" "disabled Water 7 must stop before CI host inspection"
  assert_contains "$output" "Water 7 is disabled by config/disabled-adapters" \
    "disabled Water 7 must name the policy"
  pass "platform workflows and Water 7 runner remain disabled"
}

test_requires_github_actions_runner
test_disabled_platform_workflows_remain_disabled
