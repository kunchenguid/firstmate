#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude) and `›` (codex) are a genuine empty
#      agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  for plain in '❯' '›'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  # Placeholder with no prompt glyph (grok's bordered empty composer).
  out=$(classify 1 'Type a message...' "$idle")
  [ "$out" = empty ] || fail "the grok idle placeholder should read empty, got '$out'"
  # Placeholder after an agent glyph (post-strip match).
  out=$(classify 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "the idle placeholder after a glyph should read empty, got '$out'"
  # Without the idle regex it is just text -> pending.
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: a known idle placeholder reads empty, before and after glyph stripping"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle")
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive)
  [ "$out" = empty ] || fail "an explicitly insensitive idle placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- recurring-deferral diagnostic sink -------------------------------------
# Task composer-defer-diagnostic-fallback: a systematic misclassification defers
# away-mode delivery forever, so the sink records WHICH verdict recurred and WHAT
# the offending row held. These cover the record contract the daemon depends on.

diag_tmp() { mktemp "${TMPDIR:-/tmp}/fm-composer-diag.XXXXXX"; }

test_diag_record_is_a_noop_without_the_env_var() {
  local out
  # Unset is the production condition; empty is the daemon's own unarmed value.
  out=$(unset FM_COMPOSER_DIAG_FILE; fm_composer_diag_record reader 'row' 'content' 2>&1)
  [ -z "$out" ] || fail "the diagnostic sink wrote something with FM_COMPOSER_DIAG_FILE unset: '$out'"
  out=$(FM_COMPOSER_DIAG_FILE='' fm_composer_diag_record reader 'row' 'content' 2>&1)
  [ -z "$out" ] || fail "the diagnostic sink wrote something with an empty FM_COMPOSER_DIAG_FILE: '$out'"
  fm_composer_diag_record reader 'row' 'content' \
    || fail "the diagnostic sink must succeed as a no-op when unarmed"
  pass "fm_composer_diag_record: inert unless FM_COMPOSER_DIAG_FILE is set"
}

test_diag_record_captures_the_offending_row_bytes() {
  # The exact shape that wedged away mode for 9.5 hours: '❯' + U+00A0.
  local file row content
  file=$(diag_tmp)
  row=$(printf '\xe2\x9d\xaf\xc2\xa0\r')
  content=$(printf '\xe2\x9d\xaf\xc2\xa0')
  FM_COMPOSER_DIAG_FILE="$file" fm_composer_diag_record my_reader "$row" "$content"
  grep -Fq 'reader=my_reader' "$file" || fail "record omitted the reader: $(cat "$file")"
  grep -Fq 'raw_len=6 raw_hex=e2 9d af c2 a0 0d' "$file" \
    || fail "record did not carry the raw row's bytes: $(cat "$file")"
  grep -Fq 'content_len=5 content_hex=e2 9d af c2 a0' "$file" \
    || fail "record did not carry the classified content's bytes: $(cat "$file")"
  [ "$(wc -l < "$file")" -eq 1 ] || fail "one row must produce exactly one record line"
  rm -f "$file"
  pass "fm_composer_diag_record: records the reader plus the offending row and content bytes"
}

test_diag_record_renders_no_replayable_escape() {
  # A record is read with `cat`, and a composer row can carry the terminal's own
  # escapes, so no raw ESC or control byte may survive into the record.
  local file row esc
  file=$(diag_tmp)
  esc=$(printf '\033')
  row="${esc}[31m> rm -rf x${esc}[0m$(printf '\a\b')"
  FM_COMPOSER_DIAG_FILE="$file" fm_composer_diag_record r "$row" '> rm -rf x'
  grep -q "$esc" "$file" && fail "a raw ESC byte survived into the record"
  grep -Fq '1b 5b 33 31 6d' "$file" || fail "the escape was not preserved as hex: $(cat "$file")"
  grep -Fq 'raw_text=.[31m> rm -rf x.[0m..' "$file" \
    || fail "printable rendering did not neutralize control bytes: $(cat "$file")"
  rm -f "$file"
  pass "fm_composer_diag_record: bytes are recorded as hex, so no escape can replay into a reader's terminal"
}

test_diag_record_bounds_a_long_row() {
  # The row can hold the captain's own draft, so both fields are bounded and the
  # truncation is explicit rather than silent.
  local file long hex rendered
  file=$(diag_tmp)
  long=$(printf 'x%.0s' $(seq 1 200))
  FM_COMPOSER_DIAG_FILE="$file" FM_COMPOSER_DIAG_MAX_BYTES=120 \
    fm_composer_diag_record r "$long" "$long"
  grep -Fq 'raw_len=200' "$file" || fail "record lost the true row length: $(cat "$file")"
  grep -Fq '(+80_more)' "$file" || fail "record truncated silently: $(cat "$file")"
  hex=$(grep -o 'raw_hex=[0-9a-f ]*' "$file" | head -1 | sed 's/raw_hex=//')
  [ "$(printf '%s' "$hex" | wc -w)" -eq 120 ] \
    || fail "expected 120 bounded hex bytes, got $(printf '%s' "$hex" | wc -w)"
  rendered=$(grep -o 'raw_text=x*' "$file" | head -1 | sed 's/raw_text=//')
  [ "${#rendered}" -eq 120 ] \
    || fail "expected the printable rendering bounded to 120 bytes, got ${#rendered}"
  rm -f "$file"
  pass "fm_composer_diag_record: bounds each field and marks the truncation explicitly"
}

test_diag_record_appends_one_line_per_row() {
  # A bordered box makes the reader evaluate several rows; the daemon reports the
  # LAST record, which is the deciding row.
  local file
  file=$(diag_tmp)
  FM_COMPOSER_DIAG_FILE="$file" fm_composer_diag_record r 'first row' ''
  FM_COMPOSER_DIAG_FILE="$file" fm_composer_diag_record r 'second row' 'deciding'
  [ "$(wc -l < "$file")" -eq 2 ] || fail "expected one record line per evaluated row"
  tail -1 "$file" | grep -Fq 'content_text=deciding' \
    || fail "the last record is not the deciding row: $(tail -1 "$file")"
  head -1 "$file" | grep -Fq 'content_hex=none' \
    || fail "an empty field should read 'none', not blank: $(head -1 "$file")"
  rm -f "$file"
  pass "fm_composer_diag_record: appends one line per evaluated row, last is the deciding one"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_diag_record_is_a_noop_without_the_env_var
test_diag_record_captures_the_offending_row_bytes
test_diag_record_renders_no_replayable_escape
test_diag_record_bounds_a_long_row
test_diag_record_appends_one_line_per_row
