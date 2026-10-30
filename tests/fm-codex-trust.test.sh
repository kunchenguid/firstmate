#!/usr/bin/env bash
# Behavior tests for Codex's exact workspace trust registration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRUST="$ROOT/bin/fm-codex-trust.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-trust)
PYTHON=
for candidate in python3 python3.14 python3.13 python3.12 python3.11; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import tomllib' >/dev/null 2>&1; then
    PYTHON=$(command -v "$candidate")
    break
  fi
done
[ -n "$PYTHON" ] || fail "Python 3.11+ with tomllib is required to read Codex config.toml"

make_case() {
  local dir="$TMP_ROOT/$1" project="$TMP_ROOT/$1/project" worktree="$TMP_ROOT/$1/worktree"
  mkdir -p "$dir/codex"
  git init -q "$project"
  git -C "$project" config user.email test@example.invalid
  git -C "$project" config user.name test
  touch "$project/README"
  git -C "$project" add README
  git -C "$project" commit -qm init
  git -C "$project" worktree add -q "$worktree"
  printf '%s|%s|%s|%s\n' "$dir" "$project" "$worktree" "$dir/codex"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJECT WORKTREE CODEX_HOME_DIR <<EOF
$1
EOF
  : "$CASE_DIR"
}

trust_value() {
  "$PYTHON" - "$1/config.toml" "$2" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as handle:
    print(tomllib.load(handle)["projects"][sys.argv[2]]["trust_level"])
PY
}

project_field() {
  "$PYTHON" - "$1/config.toml" "$2" "$3" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as handle:
    print(tomllib.load(handle)["projects"][sys.argv[2]][sys.argv[3]])
PY
}

config_value() {
  "$PYTHON" - "$1/config.toml" "$2" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as handle:
    value = tomllib.load(handle)
for key in sys.argv[2].split('.'):
    value = value[key]
print(value)
PY
}

test_registers_exact_worktree() {
  local rec
  rec=$(make_case fresh)
  read_case "$rec"
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "fresh linked worktree trust registration failed"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "fresh registration did not trust the exact worktree"
  [ ! -e "$CODEX_HOME_DIR/config.toml.fm-codex-trust" ] \
    || fail "trust registration left a staging file"
  pass "fm-codex-trust: registers a fresh linked worktree"
}

test_preserves_existing_config_and_updates_entry() {
  local rec
  rec=$(make_case update)
  read_case "$rec"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
model = "gpt-5"

[projects.'$WORKTREE']
trust_level = "untrusted"
note = "preserve"

[profiles.review]
trust_level = "unrelated"
EOF
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "existing Codex config trust update failed"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "existing worktree entry was not updated to trusted"
  [ "$(project_field "$CODEX_HOME_DIR" "$WORKTREE" note)" = preserve ] \
    || fail "existing project fields were not preserved"
  [ "$(config_value "$CODEX_HOME_DIR" model)" = "gpt-5" ] \
    || fail "unrelated Codex configuration was not preserved"
  [ "$(config_value "$CODEX_HOME_DIR" "profiles.review.trust_level")" = unrelated ] \
    || fail "unrelated table fields were not preserved"
  pass "fm-codex-trust: preserves and updates an existing project entry"
}

test_inserts_before_following_table() {
  local rec
  rec=$(make_case missing)
  read_case "$rec"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
[projects.'$WORKTREE']
note = "preserve"

[profiles.review]
trust_level = "unrelated"
EOF
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "missing trust value registration failed"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "missing trust value was not inserted"
  [ "$(project_field "$CODEX_HOME_DIR" "$WORKTREE" note)" = preserve ] \
    || fail "project fields were not preserved when trust was missing"
  [ "$(config_value "$CODEX_HOME_DIR" "profiles.review.trust_level")" = unrelated ] \
    || fail "following table was modified when trust was missing"
  pass "fm-codex-trust: inserts trust before a following table"
}

test_ignores_multiline_string_structure() {
  local rec note
  rec=$(make_case multiline)
  read_case "$rec"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
[projects.'$WORKTREE']
note = """
A multiline note may contain a fake table header.
[projects.'$WORKTREE']
trust_level = "untrusted"
"""
trust_level = "untrusted"

[profiles.review]
trust_level = "unrelated"
EOF
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "multiline TOML trust update failed"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "multiline TOML update did not change the real trust value"
  note=$(project_field "$CODEX_HOME_DIR" "$WORKTREE" note)
  assert_contains "$note" "trust_level = \"untrusted\"" \
    "multiline project text was modified instead of preserved"
  [ "$(config_value "$CODEX_HOME_DIR" "profiles.review.trust_level")" = unrelated ] \
    || fail "multiline TOML update changed a following table"
  pass "fm-codex-trust: ignores table-like text inside multiline strings"
}

test_ignores_escaped_delimiter_in_multiline_basic_string() {
  local rec note
  rec=$(make_case escaped)
  read_case "$rec"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
[projects.'$WORKTREE']
note = """
An escaped \""" delimiter keeps this string open.
[projects.'$WORKTREE']
trust_level = "untrusted"
"""
trust_level = "untrusted"
EOF
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "escaped multiline delimiter trust update failed"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "escaped multiline delimiter hid the real trust value"
  note=$(project_field "$CODEX_HOME_DIR" "$WORKTREE" note)
  assert_contains "$note" "trust_level = \"untrusted\"" \
    "text after an escaped multiline delimiter was modified"
  pass "fm-codex-trust: keeps a multiline basic string open across an escaped delimiter"
}

test_ignores_multiline_literal_string_structure() {
  local rec note
  rec=$(make_case literal)
  read_case "$rec"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
[projects.'$WORKTREE']
note = '''
[projects.'$WORKTREE']
trust_level = "untrusted"
'''
trust_level = "untrusted"
EOF
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "multiline literal string trust update failed"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "multiline literal string hid the real trust value"
  note=$(project_field "$CODEX_HOME_DIR" "$WORKTREE" note)
  assert_contains "$note" "trust_level = \"untrusted\"" \
    "multiline literal text was modified instead of preserved"
  pass "fm-codex-trust: ignores table-like text inside a multiline literal string opened mid-line"
}

test_inserts_after_final_header_without_newline() {
  local rec
  rec=$(make_case final-header)
  read_case "$rec"
  printf 'model = "gpt-5"\n[projects.\x27%s\x27]' "$WORKTREE" > "$CODEX_HOME_DIR/config.toml"
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "final header without a newline could not be registered"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "trust was not added under a final header without a newline"
  [ "$(config_value "$CODEX_HOME_DIR" model)" = "gpt-5" ] \
    || fail "unrelated configuration was not preserved"
  pass "fm-codex-trust: adds trust under a final header that has no newline"
}

test_updates_spaced_header_and_quoted_key() {
  local rec
  rec=$(make_case spaced)
  read_case "$rec"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
[ projects . "$WORKTREE" ]
"trust_level" = "untrusted"
note = "preserve"
EOF
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "spaced header with a quoted trust_level key was refused"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "quoted trust_level key under a spaced header was not updated"
  [ "$(project_field "$CODEX_HOME_DIR" "$WORKTREE" note)" = preserve ] \
    || fail "spaced header project fields were not preserved"

  rec=$(make_case spaced-literal)
  read_case "$rec"
  cat > "$CODEX_HOME_DIR/config.toml" <<EOF
[projects. '$WORKTREE']
'trust_level' = "untrusted"
EOF
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "spaced dotted header with a literal-quoted trust_level key was refused"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "literal-quoted trust_level key was not updated"
  pass "fm-codex-trust: updates a whitespace header and a quoted trust_level key in place"
}

test_concurrent_registrations_keep_every_entry() {
  local rec i pids=() status=0
  rec=$(make_case concurrent)
  read_case "$rec"
  printf 'model = "gpt-5"\n' > "$CODEX_HOME_DIR/config.toml"
  for i in 1 2 3 4 5 6 7 8; do
    git -C "$PROJECT" worktree add -q "$CASE_DIR/wt-$i"
  done
  for i in 1 2 3 4 5 6 7 8; do
    CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$CASE_DIR/wt-$i" "$PROJECT" >/dev/null 2>&1 &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do
    wait "$i" || status=1
  done
  [ "$status" -eq 0 ] || fail "a concurrent trust registration failed"
  for i in 1 2 3 4 5 6 7 8; do
    [ "$(trust_value "$CODEX_HOME_DIR" "$(cd -P "$CASE_DIR/wt-$i" && pwd -P)")" = trusted ] \
      || fail "concurrent registration dropped worktree wt-$i"
  done
  pass "fm-codex-trust: concurrent registrations into one store keep every entry"
}

test_selects_python_with_tomllib() {
  local rec fakebin
  rec=$(make_case python)
  read_case "$rec"
  fakebin="$CASE_DIR/bin"
  mkdir -p "$fakebin"
  printf '#!/bin/sh\necho "ModuleNotFoundError: No module named tomllib" >&2\nexit 1\n' > "$fakebin/python3"
  chmod +x "$fakebin/python3"
  ln -s "$PYTHON" "$fakebin/python3.11"
  PATH="$fakebin:$PATH" CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null \
    || fail "trust registration did not fall back to a Python with tomllib"
  [ "$(trust_value "$CODEX_HOME_DIR" "$WORKTREE")" = trusted ] \
    || fail "fallback Python did not register the worktree"
  pass "fm-codex-trust: selects a Python with tomllib when python3 lacks it"
}

test_refuses_without_codex_home_or_home() {
  local rec out status=0
  rec=$(make_case no-home)
  read_case "$rec"
  out=$(cd "$CASE_DIR" && env -u CODEX_HOME -u HOME "$TRUST" "$WORKTREE" "$PROJECT" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "trust registration without CODEX_HOME or HOME was accepted"
  assert_contains "$out" "neither CODEX_HOME nor HOME is set" \
    "missing config context was not named in the refusal"
  [ ! -e "$CASE_DIR/.codex" ] || fail "missing config context created a relative Codex store"
  pass "fm-codex-trust: refuses when neither CODEX_HOME nor HOME is set"
}

test_refuses_invalid_config_without_replacement() {
  local rec before after status=0
  rec=$(make_case invalid)
  read_case "$rec"
  printf '[projects.\x27%s\x27\n' "$WORKTREE" > "$CODEX_HOME_DIR/config.toml"
  before=$(sha256sum "$CODEX_HOME_DIR/config.toml")
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$WORKTREE" "$PROJECT" >/dev/null 2>&1 || status=$?
  after=$(sha256sum "$CODEX_HOME_DIR/config.toml")
  [ "$status" -ne 0 ] || fail "invalid TOML was accepted"
  [ "$before" = "$after" ] || fail "invalid TOML was modified"
  pass "fm-codex-trust: refuses malformed TOML without replacement"
}

test_rejects_primary_checkout() {
  local rec status=0
  rec=$(make_case primary)
  read_case "$rec"
  CODEX_HOME="$CODEX_HOME_DIR" "$TRUST" "$PROJECT" "$PROJECT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "primary checkout was accepted as an isolated worktree"
  pass "fm-codex-trust: rejects a primary checkout"
}

test_registers_exact_worktree
test_preserves_existing_config_and_updates_entry
test_inserts_before_following_table
test_ignores_multiline_string_structure
test_ignores_escaped_delimiter_in_multiline_basic_string
test_ignores_multiline_literal_string_structure
test_inserts_after_final_header_without_newline
test_updates_spaced_header_and_quoted_key
test_concurrent_registrations_keep_every_entry
test_selects_python_with_tomllib
test_refuses_without_codex_home_or_home
test_refuses_invalid_config_without_replacement
test_rejects_primary_checkout

echo "all fm-codex-trust tests passed"
