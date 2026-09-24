#!/usr/bin/env bash
# Behavior tests for bin/fm-jev.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-jev.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"

run() {
  FM_HOME="$HOME_DIR" "$TOOL" "$@"
}

out=$(run status)
assert_equals 'jev: mode=off key=missing transport=openrouter model=~typesafe/jev-latest' "$out" "absent config defaults to off without a key"

for mode in shadow on off; do
  out=$(OPENROUTER_API_KEY=test-secret run "$mode")
  assert_equals "jev: mode=$mode key=configured transport=openrouter model=~typesafe/jev-latest" "$out" "$mode reports the new mode without exposing the key"
  assert_equals "$mode" "$(cat "$HOME_DIR/config/jev-mode")" "$mode is persisted"
  [ "$(stat -f '%Lp' "$HOME_DIR/config/jev-mode" 2>/dev/null || stat -c '%a' "$HOME_DIR/config/jev-mode")" = 600 ] \
    || fail "$mode did not protect config/jev-mode with mode 600"
  assert_not_contains "$out" 'test-secret' "$mode output does not expose the key"
done
pass "mode changes are atomic, private, and inspectable"

printf '%s\n' 'OPENROUTER_API_KEY=env-file-secret' > "$HOME_DIR/.env"
out=$(run)
assert_equals 'jev: mode=off key=configured transport=openrouter model=~typesafe/jev-latest' "$out" "default status reads the home .env key"
assert_not_contains "$out" 'env-file-secret' "status never prints the .env key"
pass "status reports key presence without disclosing the credential"

printf '%s\n' invalid > "$HOME_DIR/config/jev-mode"
set +e
out=$(run status 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "invalid mode exited $rc instead of 1"
assert_contains "$out" "accepted values are: off, shadow, on" "invalid mode is actionable"

rm -f "$HOME_DIR/config/jev-mode"
ln -s "$TMP_ROOT/outside" "$HOME_DIR/config/jev-mode"
set +e
out=$(run status 2>&1)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "symlink mode exited $rc instead of 1"
assert_contains "$out" 'config/jev-mode must be a readable regular file' "symlink mode is refused"
assert_absent "$TMP_ROOT/outside" "refused symlink did not create its target"
pass "unsafe or invalid mode files are refused"

set +e
out=$(run maybe 2>&1)
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unknown command exited $rc instead of 2"
assert_contains "$out" 'Usage:' "unknown command prints usage"

printf '# all fm-jev tests passed\n'
