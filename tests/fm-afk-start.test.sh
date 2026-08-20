#!/usr/bin/env bash
# Characterization coverage for fm-afk-start's direct command-line contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

START="$ROOT/bin/fm-afk-start.sh"
TMP_ROOT=$(fm_test_tmproot fm-afk-start-tests)
mkdir -p "$TMP_ROOT/home"

test_help_and_invalid_argument_contract() {
  local out rc

  out=$(FM_HOME="$TMP_ROOT/home" "$START" --help 2>&1) \
    || fail "--help should exit successfully"
  assert_contains "$out" "Usage: fm-afk-start.sh" \
    "--help should print the script usage"
  pass "--help prints the fm-afk-start usage"

  set +e
  out=$(FM_HOME="$TMP_ROOT/home" "$START" unexpected 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unexpected argument should exit 2 (rc=$rc): $out"
  assert_contains "$out" "usage: fm-afk-start.sh" \
    "unexpected argument should print the command usage"
  pass "unexpected arguments are rejected with usage and exit 2"
}

test_help_and_invalid_argument_contract
