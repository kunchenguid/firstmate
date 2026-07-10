#!/usr/bin/env bash
# tests/fm-backlog-handoff.test.sh - full item-block handoff (header + indented body).
#
# The happy single-line path and safety refusals live in the secondmate lifecycle
# and safety suites. This file owns the multi-line body contract: the full block
# moves byte-exact, nothing orphans in the source, and re-running is a no-op.
set -u

# shellcheck source=tests/secondmate-helpers.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

# The move is delegated to `tasks-axi mv`, so this suite exercises the real
# binary. Skip cleanly when it is absent (matching the backend smoke suites).
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found (required by the delegated handoff path)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backlog-handoff)

setup_homes() {
  local home=$1 subhome=$2 id=${3:-design}
  mkdir -p "$home/data" "$home/state"
  seed_secondmate_home_marker "$subhome" "$id"
  local sub_abs
  sub_abs=$(cd "$subhome" && pwd -P)
  printf -- '- %s - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' \
    "$id" "$sub_abs" > "$home/data/secondmates.md"
}

# Exact multi-line block extract: header matching key plus following body lines
# (indented lines and blank separators between paragraphs), stopping at the next
# item header or unindented section heading (column-0 ##).
extract_item_block() {
  local file=$1 key=$2
  awk -v key="$key" '
    /^- \[[ x]\] / {
      rest = $0
      sub(/^- \[[ x]\] +/, "", rest)
      id = rest
      sub(/[ \t].*/, "", id)
      if (capturing) exit
      if (id == key) { print; capturing = 1; next }
      next
    }
    capturing && /^## / { exit }
    capturing && /^- \[[ x]\] / { exit }
    capturing && /^([ \t].*)?$/ { print; next }
    capturing { exit }
  ' "$file"
}

assert_block_equals() {
  local label=$1 expected=$2 actual=$3
  if [ "$expected" != "$actual" ]; then
    printf 'expected block:\n%s\nactual block:\n%s\n' "$expected" "$actual" >&2
    fail "$label"
  fi
}

test_body_moves_when_followed_by_another_item() {
  local home="$TMP_ROOT/body-next-item-main"
  local sub="$TMP_ROOT/body-next-item-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] keep-a - stays first (repo: alpha)
  keep-a body line
- [ ] body-item - has a body (repo: alpha)
  Spec detail one.
  ## Intent
  Move the full block.
  trailing body line
- [ ] keep-b - stays after (repo: beta)
  keep-b body stays

## Done
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" body-item)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design body-item >/dev/null \
    || fail "handoff of body-followed-by-item failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" body-item)
  assert_block_equals "destination body block mismatch after item-boundary handoff" \
    "$expected_block" "$dest_block"

  assert_no_grep 'body-item' "$home/data/backlog.md" "body-item header still in source"
  assert_no_grep 'Spec detail one' "$home/data/backlog.md" "orphaned body line stayed in source"
  assert_no_grep 'Move the full block' "$home/data/backlog.md" "orphaned body line stayed in source"
  assert_no_grep 'trailing body line' "$home/data/backlog.md" "orphaned trailing body stayed in source"
  # Indented heading must move with the item, not be left or treated as a section.
  assert_no_grep '## Intent' "$home/data/backlog.md" "indented ## Intent left in source as if a section"
  assert_grep '  ## Intent' "$sub/data/backlog.md" "indented ## Intent did not arrive at destination"

  assert_grep 'keep-a' "$home/data/backlog.md" "keep-a was wrongly removed"
  assert_grep '  keep-a body line' "$home/data/backlog.md" "keep-a body was disturbed"
  assert_grep 'keep-b' "$home/data/backlog.md" "keep-b was wrongly removed"
  assert_grep '  keep-b body stays' "$home/data/backlog.md" "keep-b body was disturbed"

  # keep-a's body must not have grown the orphaned lines of body-item.
  local keep_a_block
  keep_a_block=$(extract_item_block "$home/data/backlog.md" keep-a)
  assert_block_equals "keep-a block must not absorb orphaned body-item lines" \
    $'- [ ] keep-a - stays first (repo: alpha)\n  keep-a body line' \
    "$keep_a_block"

  pass "body followed by another item moves intact with no source orphans"
}

test_body_moves_when_followed_by_section_heading() {
  local home="$TMP_ROOT/body-section-main"
  local sub="$TMP_ROOT/body-section-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] section-tail - body ends at section (repo: alpha)
  last queued body
  ## Intent
  still body until column-0 section

## Done
- [x] old-task - shipped - local main (merged 2026-07-01)
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" section-tail)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design section-tail >/dev/null \
    || fail "handoff of body-followed-by-section failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" section-tail)
  assert_block_equals "destination body block mismatch after section-boundary handoff" \
    "$expected_block" "$dest_block"

  assert_no_grep 'section-tail' "$home/data/backlog.md" "section-tail still in source"
  assert_no_grep 'last queued body' "$home/data/backlog.md" "body orphaned before ## Done"
  assert_no_grep 'still body until' "$home/data/backlog.md" "body after ## Intent orphaned"
  assert_grep 'old-task' "$home/data/backlog.md" "Done section item was disturbed"
  assert_grep '## Done' "$home/data/backlog.md" "Done section heading was disturbed"

  pass "body followed by section heading moves intact; section stays"
}

test_body_moves_when_last_lines_of_file() {
  local home="$TMP_ROOT/body-eof-main"
  local sub="$TMP_ROOT/body-eof-sub"
  setup_homes "$home" "$sub"

  # A source item that ends the file with no trailing newline is a valid shape;
  # printf builds that deliberately. It must move whole, indented ## line
  # included, into the destination the handoff seeds.
  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  eof body line one'
    printf '%s\n' '  ## Intent'
    printf '%s' '  eof body line two'
  } > "$home/data/backlog.md"
  # tasks-axi owns the destination format: the moved block lands under ## Queued
  # in the standard three-section scaffold the handoff seeds for a fresh home.
  local expected_destination="$TMP_ROOT/body-eof-expected.md"
  {
    printf '%s\n' '## In flight'
    printf '%s\n' ''
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  eof body line one'
    printf '%s\n' '  ## Intent'
    printf '%s\n' '  eof body line two'
    printf '%s\n' ''
    printf '%s\n' '## Done'
  } > "$expected_destination"

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" eof-item)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design eof-item >/dev/null \
    || fail "handoff of EOF body item failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" eof-item)
  assert_block_equals "destination body block mismatch for EOF item" \
    "$expected_block" "$dest_block"
  cmp -s "$expected_destination" "$sub/data/backlog.md" \
    || fail "EOF item did not land byte-exact under the seeded destination scaffold"

  # Source should have no item residual - only the section heading remains.
  if grep -E 'eof-item|eof body|## Intent' "$home/data/backlog.md" >/dev/null; then
    fail "EOF item left residual header or body lines in source"
  fi
  assert_grep '## Queued' "$home/data/backlog.md" "Queued section heading was lost"

  pass "body as last lines of the file moves intact"
}

test_eof_body_before_seeded_destination_section_keeps_boundary() {
  local home="$TMP_ROOT/body-eof-seeded-main"
  local sub="$TMP_ROOT/body-eof-seeded-sub"
  setup_homes "$home" "$sub"

  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] seeded-eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  seeded eof body one'
    printf '%s' '  seeded eof body two'
  } > "$home/data/backlog.md"
  # tasks-axi owns the destination whitespace: the moved block sits directly
  # under ## Queued with the section separator before the following ## Done, and
  # the EOF body stays a clean line above that heading (its boundary is kept).
  local expected_destination="$TMP_ROOT/body-eof-seeded-expected.md"
  {
    printf '%s\n' '## In flight'
    printf '%s\n' ''
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] seeded-eof-item - ends the file (repo: alpha)'
    printf '%s\n' '  seeded eof body one'
    printf '%s\n' '  seeded eof body two'
    printf '%s\n' ''
    printf '%s\n' '## Done'
  } > "$expected_destination"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design seeded-eof-item >/dev/null \
    || fail "handoff of EOF body into seeded backlog failed"

  cmp -s "$expected_destination" "$sub/data/backlog.md" \
    || fail "EOF body did not remain separate from the seeded ## Done heading"

  pass "EOF body before a seeded destination section keeps its boundary"
}

test_untouched_eof_line_preserves_terminator() {
  local home="$TMP_ROOT/untouched-eof-main"
  local sub="$TMP_ROOT/untouched-eof-sub"
  setup_homes "$home" "$sub"

  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] move-item - remove this block (repo: alpha)'
    printf '%s\n' '  move body'
    printf '%s\n' '- [ ] keep-item - retain this block (repo: beta)'
    printf '%s' '  keep body without a final newline'
  } > "$home/data/backlog.md"
  local expected_source="$TMP_ROOT/untouched-eof-expected.md"
  {
    printf '%s\n' '## Queued'
    printf '%s\n' '- [ ] keep-item - retain this block (repo: beta)'
    printf '%s' '  keep body without a final newline'
  } > "$expected_source"

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design move-item >/dev/null \
    || fail "handoff before untouched EOF preservation check failed"

  cmp -s "$expected_source" "$home/data/backlog.md" \
    || fail "handoff changed an untouched final-record terminator"

  pass "untouched EOF line preserves its original terminator"
}

test_body_handoff_is_idempotent() {
  local home="$TMP_ROOT/body-idem-main"
  local sub="$TMP_ROOT/body-idem-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] neighbor - untouched (repo: alpha)
  neighbor body
- [ ] idem-item - multi-line for re-run (repo: alpha)
  ## Intent
  Idempotent body must not duplicate.
  final note

## Done
EOF

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design idem-item >/dev/null \
    || fail "first handoff of body-carrying item failed"

  local main_after dest_after
  main_after=$(cat "$home/data/backlog.md")
  dest_after=$(cat "$sub/data/backlog.md")

  local out
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design idem-item 2>&1) \
    || fail "idempotent re-run of body-carrying item failed"
  assert_contains "$out" "already present" "re-run did not report skip of already-present key"

  [ "$main_after" = "$(cat "$home/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the main backlog"
  [ "$dest_after" = "$(cat "$sub/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the secondmate backlog"

  local count
  count=$(grep -cF -- '- [ ] idem-item - multi-line for re-run (repo: alpha)' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated the item header (count=$count)"
  count=$(grep -cF -- 'Idempotent body must not duplicate.' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated a body line (count=$count)"
  count=$(grep -cF -- '  ## Intent' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated indented ## Intent (count=$count)"

  assert_grep 'neighbor' "$home/data/backlog.md" "neighbor item was disturbed by re-run"
  assert_grep '  neighbor body' "$home/data/backlog.md" "neighbor body was disturbed by re-run"

  pass "body-carrying handoff is idempotent: re-run changes nothing"
}

test_noncanonical_indented_continuations_refuse_without_changes() {
  local home="$TMP_ROOT/noncanonical-main"
  local sub="$TMP_ROOT/noncanonical-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] malformed-body - must not orphan continuations (repo: alpha)
 one-space continuation
EOF
  printf '\ttab continuation\n' >> "$home/data/backlog.md"
  cat >> "$home/data/backlog.md" <<'EOF'
- [ ] untouched-item - remains in the main backlog (repo: beta)
  canonical body
EOF
  cat > "$sub/data/backlog.md" <<'EOF'
## Queued
- [ ] resident-item - remains in the secondmate backlog (repo: alpha)
  resident body
EOF

  local source_before="$TMP_ROOT/noncanonical-source-before.md"
  local destination_before="$TMP_ROOT/noncanonical-destination-before.md"
  local out
  cp "$home/data/backlog.md" "$source_before"
  cp "$sub/data/backlog.md" "$destination_before"

  if out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design malformed-body 2>&1); then
    fail "handoff accepted a noncanonical indented continuation"
  fi

  assert_contains "$out" "malformed-body" "refusal did not name the selected item"
  assert_contains "$out" "one-space continuation" "refusal did not name the one-space continuation"
  assert_contains "$out" "tab continuation" "refusal did not name the tab continuation"
  cmp -s "$source_before" "$home/data/backlog.md" \
    || fail "noncanonical-continuation refusal changed the main backlog"
  cmp -s "$destination_before" "$sub/data/backlog.md" \
    || fail "noncanonical-continuation refusal changed the secondmate backlog"

  pass "noncanonical one-space and tab continuations refuse without changes"
}

test_indented_heading_is_not_section_boundary() {
  # Standalone focus on the tokenizer trap that caused the live incident.
  local home="$TMP_ROOT/intent-trap-main"
  local sub="$TMP_ROOT/intent-trap-sub"
  setup_homes "$home" "$sub" design

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] ha-codex-fast-default-4e - harness default work (repo: firstmate)
  Context for the secondmate.
  ## Intent
  Deliver the full spec, not the title alone.
  ## Acceptance
  - body survives handoff
  - ## headings inside body stay body
- [ ] next-item - after the trap (repo: firstmate)
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" ha-codex-fast-default-4e)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design ha-codex-fast-default-4e >/dev/null \
    || fail "handoff of ## Intent body item failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" ha-codex-fast-default-4e)
  assert_block_equals "tokenizer trap: indented ## lines must move with the item" \
    "$expected_block" "$dest_block"

  # Source must not treat ## Intent / ## Acceptance as new sections that split the file.
  if grep -E 'ha-codex-fast-default-4e|Deliver the full spec|body survives handoff' \
    "$home/data/backlog.md" >/dev/null; then
    fail "tokenizer trap left item fragments in the source backlog"
  fi
  assert_grep 'next-item' "$home/data/backlog.md" "following item was lost after ## Intent body"
  # Exactly one real Queued section; no spurious column-0 ## Intent section invented.
  local heading_count
  heading_count=$(grep -cE '^## ' "$home/data/backlog.md")
  [ "$heading_count" -eq 1 ] || fail "source gained extra column-0 ## headings (count=$heading_count)"
  heading_count=$(grep -cE '^## ' "$sub/data/backlog.md")
  # sub scaffold has In flight / Queued / Done
  [ "$heading_count" -eq 3 ] || fail "destination has unexpected ## section count (count=$heading_count)"

  pass "indented ## Intent / ## Acceptance are body, not section boundaries"
}

test_multi_paragraph_body_with_internal_blanks_moves_whole() {
  # The live re-orphan risk: a blank line inside a multi-paragraph body must not
  # terminate the block and strand the paragraphs after it. Blank lines are body
  # content and move with the item; only the next item header or a column-0
  # section heading ends the block. Includes an indented ## after a blank.
  local home="$TMP_ROOT/multi-para-main"
  local sub="$TMP_ROOT/multi-para-sub"
  setup_homes "$home" "$sub"

  cat > "$home/data/backlog.md" <<'EOF'
## Queued
- [ ] before-multi - stays put (repo: alpha)
  before body
- [ ] multi-para - multi-paragraph body (repo: alpha)
  First paragraph line.

  Second paragraph after a blank.
  ## Intent

  Indented heading then blank then more.
  final line
- [ ] after-multi - subsequent item (repo: alpha)
  after body

## Done
EOF

  local expected_block
  expected_block=$(extract_item_block "$home/data/backlog.md" multi-para)

  FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design multi-para >/dev/null \
    || fail "handoff of multi-paragraph body failed"

  local dest_block
  dest_block=$(extract_item_block "$sub/data/backlog.md" multi-para)
  assert_block_equals "multi-paragraph body with internal blanks must move whole" \
    "$expected_block" "$dest_block"

  # Every body line, including the ones after each internal blank, must leave the source.
  assert_no_grep 'multi-para' "$home/data/backlog.md" "multi-para header still in source"
  assert_no_grep 'First paragraph line' "$home/data/backlog.md" "first paragraph orphaned in source"
  assert_no_grep 'Second paragraph after a blank' "$home/data/backlog.md" "post-blank paragraph orphaned in source"
  assert_no_grep 'Indented heading then blank then more' "$home/data/backlog.md" "post-blank body orphaned in source"
  assert_no_grep 'final line' "$home/data/backlog.md" "trailing body orphaned in source"
  assert_no_grep '## Intent' "$home/data/backlog.md" "indented ## Intent left in source as if a section"

  # The post-blank paragraphs must actually arrive at the destination.
  assert_grep '  Second paragraph after a blank.' "$sub/data/backlog.md" "post-blank paragraph did not arrive"
  assert_grep '  Indented heading then blank then more.' "$sub/data/backlog.md" "post-blank body did not arrive"
  assert_grep '  ## Intent' "$sub/data/backlog.md" "indented ## Intent did not arrive at destination"

  # Neighbors on both sides stay intact.
  assert_grep 'before-multi' "$home/data/backlog.md" "before-multi was wrongly removed"
  assert_grep '  before body' "$home/data/backlog.md" "before-multi body was disturbed"
  assert_grep 'after-multi' "$home/data/backlog.md" "after-multi was wrongly removed"
  assert_grep '  after body' "$home/data/backlog.md" "after-multi body was disturbed"

  # Idempotent re-run: already present, no duplication, no mutation.
  local main_after dest_after
  main_after=$(cat "$home/data/backlog.md")
  dest_after=$(cat "$sub/data/backlog.md")
  local out
  out=$(FM_HOME="$home" "$ROOT/bin/fm-backlog-handoff.sh" design multi-para 2>&1) \
    || fail "idempotent re-run of multi-paragraph body failed"
  assert_contains "$out" "already present" "re-run did not report skip of already-present key"
  [ "$main_after" = "$(cat "$home/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the main backlog"
  [ "$dest_after" = "$(cat "$sub/data/backlog.md")" ] \
    || fail "idempotent re-run mutated the secondmate backlog"
  local count
  count=$(grep -cF -- '  Second paragraph after a blank.' "$sub/data/backlog.md")
  [ "$count" -eq 1 ] || fail "idempotent re-run duplicated a post-blank paragraph (count=$count)"

  pass "multi-paragraph body with internal blank lines moves whole and is idempotent"
}

test_body_moves_when_followed_by_another_item
test_body_moves_when_followed_by_section_heading
test_multi_paragraph_body_with_internal_blanks_moves_whole
test_body_moves_when_last_lines_of_file
test_eof_body_before_seeded_destination_section_keeps_boundary
test_untouched_eof_line_preserves_terminator
test_body_handoff_is_idempotent
test_noncanonical_indented_continuations_refuse_without_changes
test_indented_heading_is_not_section_boundary

echo "ALL TESTS PASSED"
