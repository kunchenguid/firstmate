#!/usr/bin/env bash
# Regression test for package-first Pi typecheck probing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TARGET="$ROOT/tests/fm-pi-primary-types.test.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-primary-types-order.XXXXXX")

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat >"$FAKEBIN/npm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '/missing/npm/root'
SH

cat >"$FAKEBIN/tsc" <<'SH'
#!/usr/bin/env bash
printf 'tsc was probed\n' >"$FM_PI_TSC_PROBE_MARKER"
exit 91
SH

chmod +x "$FAKEBIN/npm" "$FAKEBIN/tsc"

marker="$TMP_ROOT/tsc-probed"
missing_package="$TMP_ROOT/missing-pi-package"
out=$(
  PATH="$FAKEBIN:$PATH" \
    FM_PI_PACKAGE_DIR="$missing_package" \
    FM_PI_TSC_PROBE_MARKER="$marker" \
    "$TARGET" 2>&1
) || fail "missing Pi package did not take the skip path: $out"

assert_contains "$out" "skip: Pi package not found at $missing_package" \
  "missing Pi package skip was not reported"
assert_absent "$marker" "tsc was probed before the Pi package was validated"
pass "Pi package detection precedes compiler probing"
