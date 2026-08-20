#!/usr/bin/env bash
# Characterization tests for fm-config-push.sh's CLI contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-config-push.sh"

test_help_describes_local_material_push() {
  local output rc=0
  output=$("$SCRIPT" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help must succeed"
  assert_contains "$output" "Push the primary firstmate home's declared inherited local material" \
    "--help must describe the push operation"
  assert_contains "$output" "does not fast-forward tracked files" \
    "--help must state the tracked-file safety boundary"
  pass "fm-config-push.sh: --help describes its local-material contract"
}

test_invalid_argument_is_rejected() {
  local output rc=0
  output=$("$SCRIPT" --unexpected 2>&1) || rc=$?
  expect_code 2 "$rc" "an unsupported argument must be a usage error"
  assert_contains "$output" "usage: fm-config-push.sh [--help]" \
    "invalid arguments must print the compact usage line"
  pass "fm-config-push.sh: invalid arguments are rejected with usage"
}

test_help_describes_local_material_push
test_invalid_argument_is_rejected
