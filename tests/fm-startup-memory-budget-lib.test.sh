#!/usr/bin/env bash
# Characterization coverage for startup-memory budget file and measurement primitives.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-startup-memory-budget-lib-tests)
CONFIG="$TMP_ROOT/config"
DATA="$TMP_ROOT/data"
mkdir -p "$DATA"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh disable=SC1091
. "$ROOT/bin/fm-startup-memory-budget-lib.sh"

fm_startup_memory_budget_materialize "$CONFIG" \
  || fail "materialize should create the default budget"
[ "$(cat "$CONFIG/startup-memory-budget")" = 7500 ] \
  || fail "materialize should publish the 7500 default"
[ "$(fm_startup_memory_budget_read "$CONFIG")" = 7500 ] \
  || fail "read should return the materialized budget"

printf 'abcdefg' > "$DATA/memory.md"
[ "$(fm_startup_memory_estimated_tokens_for_bytes 7)" = 3 ] \
  || fail "seven bytes should estimate to three tokens"
[ "$(fm_startup_memory_measure_file "$DATA/memory.md")" = '7 3 present' ] \
  || fail "measure should report bytes, tokens, and presence"
[ "$(fm_startup_memory_measure_file "$DATA/missing.md")" = '0 0 absent' ] \
  || fail "measure should report an absent file without creating it"

printf '7500' > "$CONFIG/startup-memory-budget"
if fm_startup_memory_budget_read "$CONFIG" >/dev/null; then
  fail "read should reject a budget without a terminating newline"
fi

pass "startup-memory-budget-lib validates defaults, measurements, and exact file format"
echo "# fm-startup-memory-budget-lib.test.sh: all assertions passed"
