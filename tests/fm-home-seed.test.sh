#!/usr/bin/env bash
# Characterization tests for fm-home-seed.sh's public validation interface.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEED="$ROOT/bin/fm-home-seed.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-seed)

test_help_reports_seed_contract() {
  local out
  out=$("$SEED" --help 2>&1) || fail "fm-home-seed --help should succeed"
  assert_contains "$out" "usage: fm-home-seed.sh <id> <home|->" \
    "help should describe the seed command"
  assert_contains "$out" "fm-home-seed.sh validate" \
    "help should describe validation"
  pass "fm-home-seed help exposes both public modes"
}

test_validate_accepts_absent_registry() {
  local home
  home="$TMP_ROOT/absent"
  mkdir -p "$home/data" "$home/state"
  FM_HOME="$home" "$SEED" validate || fail "absent registry should validate"
  pass "fm-home-seed validate accepts an absent registry"
}

test_validate_rejects_malformed_registry() {
  local home err rc
  home="$TMP_ROOT/malformed"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' '- broken registry entry' > "$home/data/secondmates.md"
  err="$TMP_ROOT/malformed.err"
  set +e
  FM_HOME="$home" "$SEED" validate 2>"$err"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "malformed registry should exit 1, got $rc"
  assert_contains "$(cat "$err")" "error: malformed secondmate registry entry" \
    "malformed registry should identify the parse failure"
  pass "fm-home-seed validate rejects malformed registry entries"
}

test_help_reports_seed_contract
test_validate_accepts_absent_registry
test_validate_rejects_malformed_registry
