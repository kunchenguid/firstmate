#!/usr/bin/env bash
# Behavioral regressions for fm_dod_block's generated Definition of done.
# The no-mistakes arm must send the worker straight from its implementation
# commit into the pipeline: no pre-validation done instruction, and exactly one
# terminal `done [at=<epoch>]:` form (`done [at=<epoch>]: PR {url} checks green`).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dod-lib)

test_no_mistakes_arm_has_no_pre_validation_done() {
  local block="$TMP_ROOT/no-mistakes.block"
  fm_dod_block no-mistakes dod-fixture > "$block" \
    || fail "fm_dod_block refused the no-mistakes mode"
  grep -qx 'Delivery contract: mode=no-mistakes' "$block" \
    || fail "no-mistakes arm lost its machine-readable contract line"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_no_grep 'done: {summary}' "$block" \
    "no-mistakes arm still tells the worker to report done before validation"
  assert_no_grep 'Firstmate will then instruct' "$block" \
    "no-mistakes arm still parks the worker to wait for a firstmate instruction"
  [ "$(grep -Fc 'done [at=<epoch>]:' "$block")" -eq 1 ] \
    || fail "no-mistakes arm must carry exactly one terminal done: form"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'append `done [at=<epoch>]: PR {url} checks green` and stop' "$block" \
    "no-mistakes arm lost its terminal CI-green done: form"
  # shellcheck disable=SC2016 # Backticks are literal generated Markdown.
  assert_grep 'pass `--intent`' "$block" \
    "no-mistakes arm no longer carries the --intent contract in the same block"
  pass "no-mistakes arm goes straight into validation with one terminal done: form"
}

test_no_mistakes_arm_has_no_pre_validation_done
