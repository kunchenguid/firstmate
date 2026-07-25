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

# --- Empty composer rendered with U+00A0 (claude 2.1.220, 2026-07-25) -------
#
# claude renders an EMPTY composer as the prompt glyph followed by a NON-BREAKING
# space, so every row below is an idle composer, not typed input. Before
# fm_composer_trim_ws they all read `pending`: fm-send reported a swallowed Enter
# for steers that had landed, and the away-mode daemon never injected.

NBSP=$(printf '\302\240')

test_agent_glyph_with_nbsp_is_empty() {
  local out
  out=$(classify 0 "❯$NBSP"); [ "$out" = empty ] || fail "bare claude '❯'+NBSP is an empty composer, got '$out'"
  out=$(classify 1 "❯$NBSP"); [ "$out" = empty ] || fail "bordered claude '❯'+NBSP is an empty composer, got '$out'"
  out=$(classify 0 "›$NBSP"); [ "$out" = empty ] || fail "bare codex '›'+NBSP is an empty composer, got '$out'"
  out=$(classify 0 "$NBSP"); [ "$out" = empty ] || fail "a lone NBSP is an empty composer, got '$out'"
  # A mixed whitespace run must collapse completely, not one layer per call.
  out=$(classify 0 "❯$NBSP $NBSP"); [ "$out" = empty ] || fail "glyph + mixed NBSP/space run is empty, got '$out'"
  pass "fm_composer_classify_content: an agent glyph followed by U+00A0 reads empty (claude's real empty composer)"
}

test_nbsp_stripped_unbordered_content_stays_empty() {
  # The ghost-stripped path: content empties out and plain_content carries the row.
  local out
  out=$(classify 0 '' '' sensitive "❯$NBSP")
  [ "$out" = empty ] || fail "a stripped agent glyph carrying NBSP must remain empty, got '$out'"
  pass "fm_composer_classify_content: the stripped-content path also tolerates a trailing U+00A0"
}

test_nbsp_does_not_swallow_real_text() {
  local out
  out=$(classify 0 "❯${NBSP}fix findings 1 and 3")
  [ "$out" = pending ] || fail "real text after a glyph+NBSP must stay pending, got '$out'"
  out=$(classify 0 "${NBSP}fix findings 1 and 3")
  [ "$out" = pending ] || fail "real text behind a leading NBSP must stay pending, got '$out'"
  out=$(classify 1 "deploy staging${NBSP}")
  [ "$out" = pending ] || fail "real text with a trailing NBSP must stay pending, got '$out'"
  pass "fm_composer_classify_content: trimming U+00A0 never swallows real unsubmitted text"
}

test_nbsp_preserves_dead_shell_safety() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g$NBSP")
    [ "$out" = unknown ] \
      || fail "a bare shell glyph '$g' with NBSP is still a dead shell, got '$out'"
    out=$(classify 1 "$g$NBSP")
    [ "$out" = empty ] \
      || fail "a bordered shell glyph '$g' with NBSP is the harness prompt, got '$out'"
  done
  out=$(classify 0 '' '' sensitive "\$$NBSP")
  [ "$out" = unknown ] || fail "a stripped bare shell prompt with NBSP must stay unknown, got '$out'"
  pass "fm_composer_classify_content: U+00A0 trimming does not weaken the dead-shell safety rule"
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

test_bare_shell_glyphs_are_unknown
test_agent_glyph_with_nbsp_is_empty
test_nbsp_stripped_unbordered_content_stays_empty
test_nbsp_does_not_swallow_real_text
test_nbsp_preserves_dead_shell_safety
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
