#!/usr/bin/env bash
# tests/fm-branch-prefix-lib.test.sh - the single owner of the home-local
# task-branch prefix (bin/fm-branch-prefix-lib.sh), resolved by every script
# that names, lands, reviews, or maps a crewmate task branch so none of them
# can disagree about the branch name.
#
# The load-bearing contract:
#   1. An absent config file (or absent config dir) is the unconfigured
#      default "fm" - never an error.
#   2. A valid value is one line of letters, digits, and dashes, with or
#      without a single trailing newline.
#   3. Anything else - a slash anywhere (including a trailing "ardy/"),
#      whitespace, a second line, CRLF, a NUL byte, an empty file - fails
#      loudly on stderr rather than silently falling back, because a brief
#      that names one branch while the landing helper resolves another is
#      worse than a stopped helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-branch-prefix-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-branch-prefix-lib-tests)
CFG="$TMP_ROOT/config"

resolve() {
  fm_branch_prefix_resolve "$1"
}

make_config() {
  mkdir -p "$CFG"
  rm -rf -- "$CFG/branch-prefix"
  printf '%s' "$1" > "$CFG/branch-prefix"
}

test_absent_config_is_the_default() {
  local out
  out=$(resolve "$TMP_ROOT/no-such-config") \
    || fail "absent config dir must resolve to the default, not fail"
  [ "$out" = fm ] || fail "absent config dir resolved to '$out', expected 'fm'"
  mkdir -p "$CFG"
  out=$(resolve "$CFG") || fail "empty config dir must resolve to the default, not fail"
  [ "$out" = fm ] || fail "empty config dir resolved to '$out', expected 'fm'"
  pass "absent branch-prefix config resolves to the default 'fm'"
}

test_valid_prefix_with_and_without_trailing_newline() {
  local out
  make_config 'ardy'
  out=$(resolve "$CFG") || fail "'ardy' without a trailing newline must resolve"
  [ "$out" = ardy ] || fail "expected 'ardy', got '$out'"
  make_config 'ardy
'
  out=$(resolve "$CFG") || fail "'ardy\\n' with one trailing newline must resolve"
  [ "$out" = ardy ] || fail "expected 'ardy' from the newline-terminated form, got '$out'"
  make_config 'a1-b2'
  out=$(resolve "$CFG") || fail "'a1-b2' must resolve"
  [ "$out" = a1-b2 ] || fail "expected 'a1-b2', got '$out'"
  pass "a one-line letters/digits/dashes prefix resolves, with or without one trailing newline"
}

test_invalid_shapes_are_refused_loudly() {
  local bad out err
  for bad in 'ardy/' 'ar/dy' 'ardy//x' '' ' ' ' ' 'ar dy' ' ardy' 'ardy ' 'ard_y' 'ardy.
' 'ardy
more' 'ล̇ardy' 'Ａrdy'; do
    make_config "$bad"
    out=$(resolve "$CFG" 2> "$TMP_ROOT/err") && \
      fail "invalid prefix $(printf '%q' "$bad") resolved to '$out' instead of being refused"
    err=$(cat "$TMP_ROOT/err")
    [ -n "$err" ] || fail "invalid prefix $(printf '%q' "$bad") refused without a stderr reason"
    assert_contains "$err" 'branch-prefix' \
      "refusal for $(printf '%q' "$bad") must name the config file"
    assert_contains "$err" 'error:' \
      "refusal for $(printf '%q' "$bad") must be an error line"
  done
  pass "every invalid prefix shape is refused loudly on stderr with no fallback"
}

test_nul_byte_in_config_is_refused() {
  local out err
  mkdir -p "$CFG"
  rm -rf -- "$CFG/branch-prefix"
  printf 'ard\0dy' > "$CFG/branch-prefix"
  out=$(resolve "$CFG" 2> "$TMP_ROOT/err") && \
    fail "a prefix containing an embedded NUL byte must be refused, not truncated to '$out'"
  err=$(cat "$TMP_ROOT/err")
  assert_contains "$err" 'branch-prefix' "embedded-NUL refusal must name the config file"
  assert_contains "$err" 'error:' "embedded-NUL refusal must be an error line"
  assert_contains "$err" 'NUL' "embedded-NUL refusal must say so"
  printf 'ardy\0' > "$CFG/branch-prefix"
  out=$(resolve "$CFG" 2> "$TMP_ROOT/err") && \
    fail "a prefix ending in a NUL byte must be refused, not truncated to '$out'"
  err=$(cat "$TMP_ROOT/err")
  assert_contains "$err" 'NUL' "trailing-NUL refusal must say so"
  pass "a config containing a NUL byte is refused loudly instead of silently truncated"
}

test_symlinked_config_file_is_refused() {
  local out err
  mkdir -p "$TMP_ROOT/real-config"
  make_config 'ardy'
  mkdir -p "$TMP_ROOT/link-config"
  ln -s "$CFG/branch-prefix" "$TMP_ROOT/link-config/branch-prefix"
  out=$(resolve "$TMP_ROOT/link-config" 2> "$TMP_ROOT/err") && \
    fail "a symlinked branch-prefix must be refused"
  err=$(cat "$TMP_ROOT/err")
  assert_contains "$err" 'symlink' "symlink refusal must say so"
  pass "a symlinked branch-prefix file is refused"
}

test_directory_in_place_of_file_is_refused() {
  local out err
  rm -rf "$CFG/branch-prefix"
  mkdir -p "$CFG/branch-prefix"
  out=$(resolve "$CFG" 2> "$TMP_ROOT/err") && \
    fail "a directory named branch-prefix must be refused"
  err=$(cat "$TMP_ROOT/err")
  assert_contains "$err" 'not a regular file' "directory refusal must say so"
  pass "a branch-prefix that is a directory is refused"
}

test_refusal_returns_nonzero_and_records_the_error() {
  local rc
  make_config 'ar/dy'
  set +e
  resolve "$CFG" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "a refused prefix must exit 1, got $rc"
  [ -s "$TMP_ROOT/out" ] && fail "a refused prefix must print nothing on stdout"
  [ -n "$FM_BRANCH_PREFIX_ERROR" ] || fail "the resolver must record its reason in FM_BRANCH_PREFIX_ERROR"
  pass "a refused prefix exits nonzero, prints nothing on stdout, and records its reason"
}

test_absent_config_is_the_default
test_valid_prefix_with_and_without_trailing_newline
test_invalid_shapes_are_refused_loudly
test_nul_byte_in_config_is_refused
test_symlinked_config_file_is_refused
test_directory_in_place_of_file_is_refused
test_refusal_returns_nonzero_and_records_the_error
