#!/usr/bin/env bash
# Behavioral checks for the shared bin stdlib.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STDLIB="$ROOT/bin/fm-stdlib.sh"
TMP_ROOT=$(fm_test_tmproot fm-stdlib)

test_sha256_file_requires_a_hasher() {
  local file fakebin bash_path out rc
  file="$TMP_ROOT/payload"
  fakebin="$TMP_ROOT/no-hasher-bin"
  bash_path=$(command -v bash)
  printf 'payload\n' > "$file"
  mkdir -p "$fakebin"
  set +e
  # shellcheck disable=SC2016
  out=$(PATH="$fakebin" "$bash_path" -c \
    '. "$1"; sha256_file "$2"' _ "$STDLIB" "$file" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "sha256_file succeeded without a SHA-256 tool"
  assert_contains "$out" "error: shasum or sha256sum is required" \
    "sha256_file did not report the missing SHA-256 tool"
  pass "sha256_file fails explicitly when no SHA-256 tool is available"
}

test_sha256_file_requires_a_hasher
