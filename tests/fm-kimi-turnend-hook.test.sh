#!/usr/bin/env bash
# Characterization tests for fm-kimi-turnend-hook.sh's CLI contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOOK="$ROOT/bin/fm-kimi-turnend-hook.sh"

test_help_describes_install_and_remove() {
  local output
  output=$(env HOME= "$HOOK" --help 2>&1) || fail "--help should succeed"
  assert_contains "$output" "Install or remove Firstmate's guarded Kimi crew turn-end hook." \
    "--help should describe the hook manager"
  assert_contains "$output" "fm-kimi-turnend-hook.sh install" \
    "--help should list install"
  assert_contains "$output" "fm-kimi-turnend-hook.sh remove" \
    "--help should list remove"
  pass "fm-kimi-turnend-hook.sh: --help describes install and remove"
}

test_invalid_action_is_rejected_before_environment_checks() {
  local output rc=0
  output=$(env HOME= "$HOOK" unexpected 2>&1) || rc=$?
  expect_code 2 "$rc" "an unsupported action must be a usage error"
  assert_contains "$output" "usage: fm-kimi-turnend-hook.sh install|remove" \
    "invalid actions must print the compact usage line"
  pass "fm-kimi-turnend-hook.sh: invalid actions are rejected with usage"
}

test_help_describes_install_and_remove
test_invalid_action_is_rejected_before_environment_checks
