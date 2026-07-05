#!/usr/bin/env bash
# no-mistakes-agy-shim times out hung headless agy -p calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHIM="$ROOT/bin/no-mistakes-agy-shim"
TMP_ROOT=$(fm_test_tmproot no-mistakes-agy-shim)
fakebin=$(fm_fakebin "$TMP_ROOT/fake")

cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
sleep 30
printf 'should not finish\n'
SH
chmod +x "$fakebin/agy"

if ! command -v timeout >/dev/null 2>&1; then
  pass "skip timeout test: timeout(1) not on PATH"
  exit 0
fi

out=$(FM_AGY_SHIM_TIMEOUT=1 NO_MISTAKES_AGY_BIN="$fakebin/agy" PATH="$fakebin:$PATH" \
  "$SHIM" -p 'say hi' 2>&1) || status=$?
status=${status:-0}
expect_code 124 "$status" "shim should exit 124 on agy timeout"
assert_contains "$out" 'timed out' "shim timeout stderr missing"
pass "no-mistakes-agy-shim honors FM_AGY_SHIM_TIMEOUT"