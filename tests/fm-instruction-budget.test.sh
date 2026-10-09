#!/usr/bin/env bash
# Regression check for the measured Firstmate AGENTS.md byte ceiling.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAX_BYTES=48198
TMP_ROOT=$(fm_test_tmproot fm-instruction-budget)

file_bytes() {
  local bytes
  bytes=$(wc -c < "$1") || return 1
  printf '%s' "$bytes" | tr -d '[:space:]'
}

within_budget() {
  local file=$1 bytes
  bytes=$(file_bytes "$file") || return 1
  if [ "$bytes" -le "$MAX_BYTES" ]; then
    return 0
  fi
  printf 'instruction-size-budget: %s bytes exceeds %s-byte limit\n' \
    "$bytes" "$MAX_BYTES" >&2
  return 1
}

current_bytes=$(file_bytes "$ROOT/AGENTS.md") || fail "could not measure AGENTS.md"
within_budget "$ROOT/AGENTS.md" \
  || fail "AGENTS.md is ${current_bytes} bytes, over the ${MAX_BYTES}-byte ceiling"
pass "AGENTS.md is ${current_bytes} bytes within the ${MAX_BYTES}-byte ceiling"

printf '%*s' "$MAX_BYTES" '' > "$TMP_ROOT/at-limit.md"
within_budget "$TMP_ROOT/at-limit.md" \
  || fail "a file exactly at the ${MAX_BYTES}-byte ceiling should pass"
pass "a compliant file exactly at the byte ceiling passes"

printf '%*s' "$((MAX_BYTES + 1))" '' > "$TMP_ROOT/over-limit.md"
if within_budget "$TMP_ROOT/over-limit.md"; then
  fail "a file one byte over the ${MAX_BYTES}-byte ceiling should fail"
fi
pass "a deliberately over-budget file is rejected"
