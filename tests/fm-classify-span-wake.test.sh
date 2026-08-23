#!/usr/bin/env bash
# tests/fm-classify-span-wake.test.sh - the content wake rule
# (bin/fm-classify-lib.sh: status_span_wake_class + status_lines_from_offset).
# A span of newly appended status lines wakes the supervisor on CONTENT, never
# on the last line's verb alone: a decision opened and still open at span end
# wakes even when buried under later routine appends, a decision opened and
# closed inside one span is routine, terminal and legacy captain-relevant
# lines wake, routine lines bundle, and a secondmate stream wakes on any
# content. These tests drive the REAL library functions over crafted spans and
# files; the watcher wiring lives in tests/fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-span-wake-tests)

span_class() {  # <kind>; span lines on stdin
  status_span_wake_class "$1"
}

assert_class() {  # <expected> <kind> <label>; span on stdin
  local expected=$1 kind=$2 label=$3 got
  got=$(span_class "$kind")
  [ "$got" = "$expected" ] || fail "$label: expected $expected, got ${got:-<empty>}"
}

test_span_classes() {
  printf 'working: making progress\n' | { assert_class bundle ship 'a routine working line'; }
  printf 'note: a routed informational note\n' | { assert_class bundle ship 'an informational note'; }
  printf 'paused: waiting on a vendor window\n' | { assert_class bundle ship 'a declared pause'; }
  printf '' | { assert_class none ship 'an empty span'; }
  printf '   \n\n' | { assert_class none ship 'a blank-only span'; }
  printf 'done: PR https://example.test/pr/1 checks green\n' | { assert_class wake ship 'a terminal done line'; }
  printf 'failed: the build broke\n' | { assert_class wake ship 'a terminal failed line'; }
  printf 'needs-decision [key=a]: pick a shape\n' | { assert_class wake ship 'an open decision'; }
  printf 'blocked [key=b]: firstmate must refresh a token\n' | { assert_class wake ship 'an open blocker'; }
  printf 'PR ready in branch fm/x\n' | { assert_class wake ship 'a legacy captain-relevant free-text line'; }
  pass "span classes: routine bundles, terminal and decision content wakes"
}

test_buried_decision_still_wakes() {
  printf 'needs-decision [key=a]: pick a shape\nworking: moved on to other work\nworking: still busy\n' \
    | { assert_class wake ship 'a decision buried under routine appends'; }
  pass "a decision buried under later routine appends still wakes"
}

test_decision_closed_inside_span_is_routine() {
  printf 'blocked [key=a]: transient hiccup\nresolved [key=a]: cleared itself\nworking: onward\n' \
    | { assert_class bundle ship 'a decision opened and closed inside one span'; }
  printf 'needs-decision [key=a]: pick\ncaptain-held [key=a]: transferred to the captain register\n' \
    | { assert_class bundle ship 'a decision transferred to a captain hold inside one span'; }
  pass "a decision opened and closed inside one span is routine"
}

test_resolution_of_an_older_decision_is_routine() {
  printf 'resolved [key=old]: answered: closed by the supervisor\n' \
    | { assert_class bundle ship 'a resolution of a decision opened before the span'; }
  pass "a resolution alone never wakes"
}

test_secondmate_stream_wakes_on_any_content() {
  printf 'note: corr=abc a routed reply\n' | { assert_class wake secondmate 'a secondmate note'; }
  printf 'working: even routine mate content\n' | { assert_class wake secondmate 'a secondmate working line'; }
  printf '' | { assert_class none secondmate 'an empty secondmate span'; }
  pass "a secondmate stream wakes on any non-blank content"
}

test_lines_from_offset() {
  local d f lines size
  d="$TMP_ROOT/offset"
  mkdir -p "$d"
  f="$d/task.status"
  printf 'working: first\n' > "$f"
  size=$(wc -c < "$f" | tr -d '[:space:]')
  printf 'needs-decision [key=a]: pick\n' >> "$f"
  lines=$(status_lines_from_offset "$f" "$size")
  [ "$lines" = 'needs-decision [key=a]: pick' ] \
    || fail "offset read did not return exactly the appended span: $lines"
  lines=$(status_lines_from_offset "$f" 999999)
  printf '%s\n' "$lines" | grep -Fq 'working: first' \
    || fail "a beyond-EOF offset did not re-read the recreated file from byte 0"
  lines=$(status_lines_from_offset "$f" '')
  printf '%s\n' "$lines" | grep -Fq 'working: first' \
    || fail "an invalid offset did not fall back to byte 0"
  [ -z "$(status_lines_from_offset "$d/missing.status" 0)" ] \
    || fail "a missing file did not read as empty"
  pass "status_lines_from_offset reads exactly the appended span and fails open to byte 0"
}

test_span_rule_agrees_with_the_fold() {
  # The rule folds decision lines through the same _fm_decision_fold_line the
  # OPEN DECISIONS fold uses; a span that leaves the fold empty must be routine
  # and one that leaves it non-empty must wake, on the same crafted input.
  local d f span class open
  d="$TMP_ROOT/agree"
  mkdir -p "$d"
  f="$d/task.status"
  span='needs-decision [key=x]: choose
resolved [key=x]: chosen
blocked [key=y]: still stuck'
  printf '%s\n' "$span" > "$f"
  class=$(printf '%s\n' "$span" | span_class ship)
  open=$(status_open_decisions "$f")
  [ -n "$open" ] || fail "fixture fold unexpectedly empty"
  [ "$class" = wake ] || fail "a span the fold reads as open did not wake"
  span='needs-decision [key=x]: choose
resolved [key=x]: chosen'
  printf '%s\n' "$span" > "$f"
  class=$(printf '%s\n' "$span" | span_class ship)
  open=$(status_open_decisions "$f")
  [ -z "$open" ] || fail "fixture fold unexpectedly non-empty"
  [ "$class" = bundle ] || fail "a span the fold reads as closed still woke"
  pass "the span rule and the open-decisions fold agree on the same input"
}

test_span_classes
test_buried_decision_still_wakes
test_decision_closed_inside_span_is_routine
test_resolution_of_an_older_decision_is_routine
test_secondmate_stream_wakes_on_any_content
test_lines_from_offset
test_span_rule_agrees_with_the_fold
