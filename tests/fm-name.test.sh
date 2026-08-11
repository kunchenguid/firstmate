#!/usr/bin/env bash
# Behavior tests for fm-name.sh - readable crew names derived from task ids.
#
# The property that makes a derived name safe is DETERMINISM: the same id must
# yield the same name forever, with no stored state, so a name survives restart,
# recovery, teardown and re-spawn without anything having to maintain it.
# The property that makes it useful is SPREAD: ids that look alike must not all
# collapse onto one name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NAME="$ROOT/bin/fm-name.sh"
TMP_ROOT=$(fm_test_tmproot fm-name-tests)
mkdir -p "$TMP_ROOT"

test_deterministic_for_one_id() {
  local a b
  a=$("$NAME" herdr-sm-spaces-k4) || fail "fm-name failed on a normal id"
  b=$("$NAME" herdr-sm-spaces-k4) || fail "fm-name failed on the repeat call"
  [ "$a" = "$b" ] || fail "the same id produced two names: '$a' then '$b'"
  pass "the same task id always yields the same name"
}

test_shape_is_two_lowercase_words() {
  local out
  out=$("$NAME" some-task-id)
  case "$out" in
    *[!a-z-]*) fail "a name must be lowercase words joined by a dash, got '$out'" ;;
    *-*) ;;
    *) fail "a name must contain a dash, got '$out'" ;;
  esac
  pass "a name is two lowercase words joined by a dash"
}

test_different_ids_spread_across_names() {
  local i distinct
  : > "$TMP_ROOT/names"
  for i in $(seq 1 60); do "$NAME" "task-$i" >> "$TMP_ROOT/names"; done
  distinct=$(sort -u "$TMP_ROOT/names" | wc -l | tr -d ' ')
  # 60 ids over 1280 combinations: a correct spread gives ~59 distinct. Anything
  # below 50 means the two word slots are correlated and most of the space is
  # unreachable, which is the bug this guards.
  [ "$distinct" -ge 50 ] || fail "60 ids collapsed onto only $distinct names; the slots are correlated"
  pass "different ids spread across the name space ($distinct/60 distinct)"
}

test_similar_ids_do_not_collide() {
  local a b c
  a=$("$NAME" task-a); b=$("$NAME" task-b); c=$("$NAME" task-c)
  [ "$a" != "$b" ] || fail "adjacent ids task-a and task-b share the name '$a'"
  [ "$b" != "$c" ] || fail "adjacent ids task-b and task-c share the name '$b'"
  pass "ids differing by one character get different names"
}

# The point of deriving rather than assigning: no home owns a name, so two homes
# (and the same home before and after a restart) agree without coordinating.
test_same_name_in_every_home() {
  local h1 h2 a b
  h1="$TMP_ROOT/home-one"; h2="$TMP_ROOT/home-two"; mkdir -p "$h1" "$h2"
  a=$(FM_HOME="$h1" "$NAME" herdr-sm-spaces-k4)
  b=$(FM_HOME="$h2" "$NAME" herdr-sm-spaces-k4)
  [ "$a" = "$b" ] || fail "two homes derived different names ('$a' vs '$b'); a name must not be home-owned"
  [ -z "$(ls -A "$h1" 2>/dev/null)" ] || fail "deriving a name wrote into the home; names must hold no state"
  pass "every home derives the same name, and none of them stores it"
}

test_refuses_bad_input() {
  local code
  "$NAME" "" >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] || fail "an empty id must be refused"
  "$NAME" a b >/dev/null 2>&1; code=$?
  [ "$code" -ne 0 ] || fail "more than one id must be refused"
  pass "empty and multiple ids are refused"
}

test_help_works() {
  local out
  out=$("$NAME" --help 2>&1) || fail "--help must work"
  assert_contains "$out" "crew name" "help explains what a name is"
  out=$("$NAME" 2>&1) || fail "a bare call must print help rather than fail"
  pass "help works and a bare call prints it"
}

test_deterministic_for_one_id
test_shape_is_two_lowercase_words
test_different_ids_spread_across_names
test_similar_ids_do_not_collide
test_same_name_in_every_home
test_refuses_bad_input
test_help_works
echo "ALL PASS: fm-name"
