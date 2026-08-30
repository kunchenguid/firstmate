#!/usr/bin/env bash
# Routing and fail-closed checks for scripts/test-changed.sh, the Artemis
# pre-push Vitest driver (not Firstmate's behavior-suite runner).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/scripts/test-changed.sh"

make_repo() {
  local root=$1
  mkdir -p "$root/packages/frontend/src/__tests__"
  git -C "$root" init -q -b main
  git -C "$root" config user.email "test@example.com"
  git -C "$root" config user.name "test"
  : >"$root/packages/frontend/src/mod.ts"
  : >"$root/packages/frontend/src/__tests__/iso.test.ts"
  : >"$root/packages/frontend/src/shared.test.ts"
  : >"$root/packages/frontend/src/x.browser.test.tsx"
  cat >"$root/packages/frontend/src/fail.test.ts" <<'EOF'
import { expect, test } from "vitest";

test("refuses a genuine assertion failure", () => {
  expect(true).toBe(false);
});
EOF
}

TMP=$(fm_test_tmproot test-changed)
make_repo "$TMP"

out=$(cd "$TMP" && bash "$SCRIPT" --dry-run packages/frontend/src/__tests__/iso.test.ts)
assert_contains "$out" "vitest run --project unit --project unit-isolated src/__tests__/iso.test.ts" \
  "named unit test uses both unit projects"
assert_not_contains "$out" "--project browser" \
  "named unit test does not use the browser project"
pass "named unit test uses both unit projects and not the browser project"

out=$(cd "$TMP" && bash "$SCRIPT" --dry-run packages/frontend/src/x.browser.test.tsx)
assert_contains "$out" "vitest run --project browser src/x.browser.test.tsx" \
  "browser test uses the browser project"
assert_not_contains "$out" "--project unit" \
  "browser test does not use unit projects"
pass "browser test uses the browser project and not unit projects"

out=$(cd "$TMP" && bash "$SCRIPT" --dry-run \
  packages/frontend/src/__tests__/iso.test.ts \
  packages/frontend/src/x.browser.test.tsx)
assert_contains "$out" "vitest run --project unit --project unit-isolated src/__tests__/iso.test.ts" \
  "mixed set still runs the unit file on both unit projects"
assert_contains "$out" "vitest run --project browser src/x.browser.test.tsx" \
  "mixed set still runs the browser file on the browser project"
pass "mixed unit and browser files keep separate project invocations"

out=$(cd "$TMP" && bash "$SCRIPT" --dry-run packages/frontend/src/mod.ts)
assert_contains "$out" "vitest related --run --project unit --passWithNoTests src/mod.ts" \
  "source files still use related on unit only"
pass "source files still use related on unit only"

FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/pnpm" <<'EOF'
#!/bin/bash
filter=''
while [ $# -gt 0 ]; do
  if [ "$1" = "--filter" ]; then
    filter=$2
    shift 2
    continue
  fi
  if [ "$1" = "exec" ]; then
    shift
    [ "$filter" = "frontend" ] && cd packages/frontend || exit 1
    exec "$@"
  fi
  shift
done
echo "pnpm: missing exec" >&2
exit 1
EOF
cat >"$FAKEBIN/vitest" <<'EOF'
#!/bin/bash
failed=0
for arg in "$@"; do
  case ",${FAKE_VITEST_FAIL_FILES:-}," in
    *,"$arg",*)
      echo "FAIL  src/fail.test.ts > refuses a genuine assertion"
      echo "AssertionError: expected true to be false"
      failed=1
      ;;
  esac
done
if [ "$failed" -eq 1 ]; then
  exit 1
fi
exit 0
EOF
chmod +x "$FAKEBIN/pnpm" "$FAKEBIN/vitest"

set +e
out=$(cd "$TMP" && FAKE_VITEST_FAIL_FILES=src/fail.test.ts PATH="$FAKEBIN:$PATH" \
  bash "$SCRIPT" packages/frontend/src/fail.test.ts 2>&1)
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "genuine failing test was not refused: $out"
assert_contains "$out" "AssertionError: expected true to be false" \
  "refusal output includes the failing assertion"
pass "genuine failing test is refused"

set +e
out=$(cd "$TMP" && PATH="$FAKEBIN:$PATH" bash "$SCRIPT" packages/frontend/src/shared.test.ts 2>&1)
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "passing named unit test was refused (exit $rc): $out"
pass "passing named unit test is not refused"
