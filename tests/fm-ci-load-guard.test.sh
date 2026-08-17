#!/usr/bin/env bash
# Contract tests for the self-hosted CI load ceiling.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-ci-load-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-load-guard)
LOAD_FILE="$TMP_ROOT/loadavg"

[ -x "$GUARD" ] || fail "bin/fm-ci-load-guard.sh must be executable"

printf '11.99 10.00 9.00 1/100 1\n' >"$LOAD_FILE"
"$GUARD" check --max-load 12 --load-file "$LOAD_FILE" >/dev/null \
  || fail "load below the ceiling was refused"
pass "load below the ceiling is admissible"

printf '12.01 10.00 9.00 1/100 1\n' >"$LOAD_FILE"
if "$GUARD" check --max-load 12 --load-file "$LOAD_FILE" >/dev/null 2>&1; then
  fail "load above the ceiling was accepted"
fi
pass "load above the ceiling is inadmissible"

printf 'not-a-load\n' >"$LOAD_FILE"
if "$GUARD" check --max-load 12 --load-file "$LOAD_FILE" >/dev/null 2>&1; then
  fail "malformed load evidence was accepted"
fi
pass "malformed load evidence fails closed"

printf '13.00 10.00 9.00 1/100 1\n' >"$LOAD_FILE"
if "$GUARD" wait --max-load 12 --timeout 0 --poll 1 --load-file "$LOAD_FILE" >/dev/null 2>&1; then
  fail "wait mode passed while the host stayed overloaded"
fi
pass "wait mode times out while load stays inadmissible"
