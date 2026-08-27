#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior tests for the captain-facing risk and decision item gate.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-captain-item-check.sh"
FIXTURES="$ROOT/tests/fixtures/captain-item-check"
TMP_ROOT=$(fm_test_tmproot captain-item-check)

run_check() {
  local mode=$1 file=$2 rc
  : > "$TMP_ROOT/output"
  set +e
  "$CHECK" "$mode" "$file" > "$TMP_ROOT/output" 2>&1
  rc=$?
  set -e
  printf '%s\n' "$rc"
}

assert_required_failures() {
  local item=$1 rc element
  rc=$(run_check risk "$FIXTURES/negative/$item.txt")
  [ "$rc" -eq 1 ] || fail "$item returned $rc instead of rejecting the draft"
  for element in system-purpose business-impact decision; do
    grep -F "missing: $element" "$TMP_ROOT/output" >/dev/null \
      || fail "$item did not report missing $element"
  done
  pass "$item: FAIL; missing system-purpose, business-impact, decision"
}

assert_positive_clear() {
  local item=$1 rc
  rc=$(run_check risk "$FIXTURES/positive/$item.md")
  if [ "$rc" -ne 0 ]; then
    cat "$TMP_ROOT/output" >&2
    fail "$item positive control returned $rc instead of clearing"
  fi
  grep -F 'captain-item-check: CLEAR' "$TMP_ROOT/output" >/dev/null \
    || fail "$item positive control did not print CLEAR"
  pass "$item rewrite: CLEAR"
}

test_negative_controls() {
  local item
  for item in risk-billing risk-privacy risk-delete risk-cron; do
    assert_required_failures "$item"
  done
}

test_positive_controls() {
  local item
  for item in risk-billing risk-privacy risk-delete risk-cron; do
    assert_positive_clear "$item"
  done
}

test_decision_mode() {
  local rc
  rc=$(run_check decision "$FIXTURES/positive/risk-billing.md")
  [ "$rc" -eq 0 ] || fail "decision mode rejected a complete item"
  grep -F 'mode=decision' "$TMP_ROOT/output" >/dev/null \
    || fail "decision mode was not reported"
  pass "decision mode accepts a complete item"
}

test_note_mode_needs_no_structure() {
  local rc item
  for item in note-welcome-timing note-quiet-hours; do
    rc=$(run_check note "$FIXTURES/positive/$item.md")
    if [ "$rc" -ne 0 ]; then
      cat "$TMP_ROOT/output" >&2
      fail "$item returned $rc instead of clearing without a mandated wrapper"
    fi
    grep -F 'mode=note' "$TMP_ROOT/output" >/dev/null \
      || fail "$item did not report note mode"
  done

  # The same headingless prose must still be refused as a decision item, so the
  # new mode is an addition rather than a hole in the structured gate.
  rc=$(run_check decision "$FIXTURES/positive/note-welcome-timing.md")
  [ "$rc" -eq 1 ] || fail "decision mode accepted an item with no required sections"
  pass "note mode clears plain prose with and without headings; decision mode still refuses it"
}

test_note_mode_keeps_the_opaque_gate() {
  local rc
  rc=$(run_check note "$FIXTURES/negative/note-jargon.txt")
  [ "$rc" -eq 1 ] || fail "note mode accepted internal vocabulary"
  grep -F "opaque: internal term 'ClickHouse'" "$TMP_ROOT/output" >/dev/null \
    || fail "note mode did not name the internal term"
  grep -F 'opaque: engineering reference' "$TMP_ROOT/output" >/dev/null \
    || fail "note mode did not refuse implementation evidence"

  # Dropping the wrapper must not drop the length floor into nothing at all.
  rc=$(run_check note "$FIXTURES/negative/note-empty.txt")
  [ "$rc" -eq 1 ] || fail "note mode accepted an empty item"
  grep -F 'missing: content' "$TMP_ROOT/output" >/dev/null \
    || fail "note mode did not report empty content"
  pass "note mode still refuses internal vocabulary and empty items"
}

test_note_mode_drops_the_padding_heuristics() {
  local rc
  printf 'The nightly report is late.\n' > "$TMP_ROOT/terse-note.md"
  rc=$(run_check note "$TMP_ROOT/terse-note.md")
  [ "$rc" -eq 0 ] || fail "note mode refused a single plain sentence"
  for element in system-purpose business-impact decision structure; do
    grep -F "$element" "$TMP_ROOT/output" >/dev/null \
      && fail "note mode still enforces $element"
  done
  pass "note mode drops word counts, required headings, and the impact and decision heuristics"
}

test_opaque_mechanism_fails() {
  local rc
  cp "$FIXTURES/positive/risk-billing.md" "$TMP_ROOT/opaque.md"
  printf '\nThe ClickHouse pointer guard passed 97 tests on main at worker.py:97.\n' >> "$TMP_ROOT/opaque.md"
  rc=$(run_check risk "$TMP_ROOT/opaque.md")
  [ "$rc" -eq 1 ] || fail "opaque engineering language did not fail"
  grep -F "opaque: internal term 'ClickHouse'" "$TMP_ROOT/output" >/dev/null \
    || fail "opaque engineering language did not identify ClickHouse"
  grep -F "opaque: engineering reference" "$TMP_ROOT/output" >/dev/null \
    || fail "opaque engineering evidence did not get a specific failure"
  pass "opaque mechanism and engineering evidence fail specifically"
}

test_unchecked_wrapper_prose_fails() {
  local rc
  {
    printf 'Unchecked introduction.\n\n'
    cat "$FIXTURES/positive/risk-billing.md"
  } > "$TMP_ROOT/unchecked-introduction.md"
  rc=$(run_check risk "$TMP_ROOT/unchecked-introduction.md")
  [ "$rc" -eq 1 ] || fail "prose before the wrapper did not fail"
  grep -F 'invalid: structure' "$TMP_ROOT/output" >/dev/null \
    || fail "prose before the wrapper did not get a structure failure"

  cp "$FIXTURES/positive/risk-billing.md" "$TMP_ROOT/unchecked-epilogue.md"
  printf '\nUnchecked epilogue.\n' >> "$TMP_ROOT/unchecked-epilogue.md"
  rc=$(run_check risk "$TMP_ROOT/unchecked-epilogue.md")
  [ "$rc" -eq 1 ] || fail "prose after the decision question did not fail"
  grep -F 'invalid: structure' "$TMP_ROOT/output" >/dev/null \
    || fail "prose after the decision question did not get a structure failure"
  pass "unchecked prose outside the wrapper fails"
}

test_verbatim_block_preserves_technical_detail() {
  local rc
  cp "$FIXTURES/positive/risk-billing.md" "$TMP_ROOT/verbatim.md"
  {
    printf '\n## Verbatim technical finding\n\n'
    printf '<!-- fm-verbatim:start -->\n'
    printf '%s\n' 'worker.py:97 kept the ClickHouse pointer guard green on main.'
    printf '<!-- fm-verbatim:end -->\n'
  } >> "$TMP_ROOT/verbatim.md"
  cp "$TMP_ROOT/verbatim.md" "$TMP_ROOT/verbatim.before"

  rc=$(run_check decision "$TMP_ROOT/verbatim.md")
  [ "$rc" -eq 0 ] || fail "technical terms inside the verbatim block did not clear"
  cmp -s "$TMP_ROOT/verbatim.before" "$TMP_ROOT/verbatim.md" \
    || fail "the checker changed the verbatim finding"
  pass "plain-language wrapper clears while verbatim technical detail stays exact"
}

test_request_assembly() {
  local rc
  {
    printf '<!-- fm-captain-item: risk -->\n'
    cat "$FIXTURES/positive/risk-billing.md"
    printf '<!-- /fm-captain-item -->\n\n'
    printf '<!-- fm-captain-item: decision -->\n'
    cat "$FIXTURES/positive/risk-privacy.md"
    printf '<!-- /fm-captain-item -->\n\n'
    printf '<!-- fm-captain-item: note -->\n'
    cat "$FIXTURES/positive/note-welcome-timing.md"
    printf '<!-- /fm-captain-item -->\n'
  } > "$TMP_ROOT/request.md"

  rc=$(run_check request "$TMP_ROOT/request.md")
  [ "$rc" -eq 0 ] || fail "complete three-item request did not clear"
  grep -F 'mode=request' "$TMP_ROOT/output" >/dev/null \
    || fail "request mode did not report its verdict"
  grep -F 'items=3' "$TMP_ROOT/output" >/dev/null \
    || fail "request mode did not report every checked item"

  {
    printf '<!-- fm-captain-item: note -->\n'
    cat "$FIXTURES/negative/note-jargon.txt"
    printf '<!-- /fm-captain-item -->\n'
  } > "$TMP_ROOT/request-bad-note.md"
  rc=$(run_check request "$TMP_ROOT/request-bad-note.md")
  [ "$rc" -eq 1 ] || fail "request mode accepted a note item full of internal vocabulary"
  grep -F 'item 1 (note) failed' "$TMP_ROOT/output" >/dev/null \
    || fail "request mode did not attribute the failure to the note item"

  printf 'Unchecked introduction.\n%s' "$(cat "$TMP_ROOT/request.md")" \
    > "$TMP_ROOT/request-unchecked.md"
  rc=$(run_check request "$TMP_ROOT/request-unchecked.md")
  [ "$rc" -eq 1 ] || fail "request mode accepted prose outside checked items"
  grep -F 'invalid: request-assembly - unchecked prose outside item markers' \
    "$TMP_ROOT/output" >/dev/null \
    || fail "unchecked request prose did not get the assembly failure"
  pass "request mode checks multi-item assembly and refuses unchecked prose"
}

test_usage_and_file_errors() {
  local rc
  rc=$(run_check invalid "$FIXTURES/positive/risk-billing.md")
  [ "$rc" -eq 2 ] || fail "invalid mode returned $rc instead of 2"
  rc=$(run_check risk "$TMP_ROOT/missing.md")
  [ "$rc" -eq 2 ] || fail "missing file returned $rc instead of 2"
  grep -F 'unreadable item file' "$TMP_ROOT/output" >/dev/null \
    || fail "missing file did not report the exact error"
  pass "invalid usage and unreadable files return 2"
}

test_negative_controls
test_positive_controls
test_decision_mode
test_note_mode_needs_no_structure
test_note_mode_keeps_the_opaque_gate
test_note_mode_drops_the_padding_heuristics
test_opaque_mechanism_fails
test_unchecked_wrapper_prose_fails
test_verbatim_block_preserves_technical_detail
test_request_assembly
test_usage_and_file_errors
