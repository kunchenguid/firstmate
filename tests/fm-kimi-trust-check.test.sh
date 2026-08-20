#!/usr/bin/env bash
# Characterization tests for Kimi workspace trust validation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "$0")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-kimi-trust-check)
CHECK="$ROOT/bin/fm-kimi-trust-check.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

cleanup() {
  rm -rf "$TMP_ROOT"
  fm_test_cleanup
}
trap cleanup EXIT

ROOT_DIR="$TMP_ROOT/root"
OTHER_ROOT="$TMP_ROOT/other"
mkdir -p "$ROOT_DIR" "$OTHER_ROOT"

expect_rejected() {
  local label=$1 expected=$2; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "$label was accepted"
  [ "$rc" -eq "$expected" ] || fail "$label returned $rc, expected $expected"
}

valid="$TMP_ROOT/valid.json"
printf '{"root":"%s","trustedAt":1}\n' "$ROOT_DIR" > "$valid"
[ "$("$CHECK" "$ROOT_DIR" "$valid")" = "" ] || fail "valid trust record produced output"

wrong_root="$TMP_ROOT/wrong-root.json"
printf '{"root":"%s","trustedAt":1}\n' "$OTHER_ROOT" > "$wrong_root"
expect_rejected wrong-root 1 "$CHECK" "$ROOT_DIR" "$wrong_root"

zero_timestamp="$TMP_ROOT/zero-timestamp.json"
printf '{"root":"%s","trustedAt":0}\n' "$ROOT_DIR" > "$zero_timestamp"
expect_rejected zero-timestamp 1 "$CHECK" "$ROOT_DIR" "$zero_timestamp"

symlink_target="$TMP_ROOT/symlink-target.json"
printf '{"root":"%s","trustedAt":1}\n' "$ROOT_DIR" > "$symlink_target"
symlink_record="$TMP_ROOT/symlink.json"
ln -s "$symlink_target" "$symlink_record"
expect_rejected symlink-record 1 "$CHECK" "$ROOT_DIR" "$symlink_record"

expect_rejected bad-usage 2 "$CHECK" "$ROOT_DIR"

fm_test_hide_host_commands "$TMP_ROOT" jq
expect_rejected missing-jq 2 "$CHECK" "$ROOT_DIR" "$valid"

pass "Kimi trust checker accepts only a concrete positive trust grant"
