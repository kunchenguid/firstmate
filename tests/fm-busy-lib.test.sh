#!/usr/bin/env bash
# Characterization coverage for the pure busy-state trust helpers.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

test_busy_tokens_and_adapter_sources() {
  fm_busy_token_valid 'claude-hook_1.2' \
    || fail "valid busy token was rejected"
  if fm_busy_token_valid 'bad token'; then
    fail "busy token containing whitespace was accepted"
  fi

  [ "$(fm_busy_sources_for_harness claude)" = \
    'claude-hook fm-spawn fm-interrupt fm-recovery' ] \
    || fail "claude trust sources changed"
  fm_busy_source_trusted pi pi-ext \
    || fail "pi-ext should be trusted for pi"
  if fm_busy_source_trusted claude pi-ext; then
    fail "pi-ext should not be trusted for claude"
  fi

  pass "busy-lib: validates tokens and isolates adapter trust sources"
}

test_busy_tokens_and_adapter_sources
