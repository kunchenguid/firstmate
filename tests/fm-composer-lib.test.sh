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

# --- Non-ASCII composer padding (task fm-send-false-negative-herdr) ---------
#
# claude 2.x pads its EMPTY composer with U+00A0 NO-BREAK SPACE, not an ASCII
# space (verified live 2026-08-04 on herdr 0.7.x: the composer row's real typed
# content extracts to bytes `e2 9d af c2 a0`). Every trim here and in the
# adapters uses `[[:space:]]`, which under the fleet's C locale is ASCII-only,
# so the U+00A0 survived, the content never equalled the bare glyph, and an
# EMPTY claude composer classified as `pending`. That permanent false
# "unsubmitted text" made the away-mode injector defer every escalation on a
# claude pane and made every fm-send to a busy claude+herdr pane report a
# swallowed Enter that had in fact landed.
#
# The classifier must therefore read a blank-padded composer exactly as it reads
# an ASCII-padded one - in BOTH directions. Under-normalizing revives the false
# pending; over-normalizing would call a composer holding real text empty and
# let the injector type over it, so the padded-real-text cases below are the
# load-bearing half of this pin.
NBSP=$(printf '\xc2\xa0')

test_nbsp_padded_empty_composer_is_empty() {
  local g out
  for g in '❯' '›'; do
    out=$(classify 0 "$g$NBSP")
    [ "$out" = empty ] \
      || fail "a U+00A0-padded agent glyph '$g' must read empty (claude's real empty composer), got '$out'"
    out=$(classify 1 "$g$NBSP")
    [ "$out" = empty ] \
      || fail "a bordered U+00A0-padded agent glyph '$g' must read empty, got '$out'"
  done
  out=$(classify 0 "$NBSP")
  [ "$out" = empty ] || fail "a composer holding only U+00A0 must read empty, got '$out'"
  pass "fm_composer_classify_content: a U+00A0-padded empty composer reads empty, not pending"
}

test_nbsp_padded_real_text_is_still_pending() {
  local out
  out=$(classify 0 "❯${NBSP}fix findings 1 and 3")
  [ "$out" = pending ] || fail "U+00A0 between the glyph and real text must stay pending, got '$out'"
  out=$(classify 0 "❯ deploy${NBSP}staging")
  [ "$out" = pending ] || fail "real text containing U+00A0 must stay pending, got '$out'"
  out=$(classify 1 "${NBSP}rebase onto main$NBSP")
  [ "$out" = pending ] || fail "U+00A0-surrounded real text must stay pending, got '$out'"
  pass "fm_composer_classify_content: U+00A0 normalization never turns real typed text into empty"
}

test_nbsp_padding_preserves_dead_shell_refusal() {
  local g out
  # The dead-shell safety rule outranks blank normalization: a bare shell glyph
  # padded with U+00A0 is still a dead shell, never a safe injection target.
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g$NBSP")
    [ "$out" = unknown ] \
      || fail "a U+00A0-padded bare shell glyph '$g' must stay unknown, got '$out'"
  done
  pass "fm_composer_classify_content: U+00A0 padding does not weaken the bare-shell-glyph refusal"
}

test_nbsp_normalization_is_locale_independent() {
  # U+00A0 is multibyte, so a character-indexed implementation would split it
  # into its 0xC2 lead byte under LC_CTYPE=C and corrupt unrelated multibyte
  # text. Prove the verdict is identical in a C and a UTF-8 locale, and that a
  # row of other multibyte glyphs survives normalization as real text.
  local lc out first=
  for lc in C en_US.UTF-8 C.UTF-8; do
    out=$(LC_ALL=$lc bash -c '
      . "$1/bin/fm-composer-lib.sh"
      fm_composer_classify_content 0 "$2"' _ "$ROOT" "❯$NBSP" 2>/dev/null) || continue
    [ "$out" = empty ] \
      || fail "a U+00A0-padded empty composer must read empty under LC_ALL=$lc, got '$out'"
    out=$(LC_ALL=$lc bash -c '
      . "$1/bin/fm-composer-lib.sh"
      fm_composer_classify_content 0 "$2"' _ "$ROOT" "❯ ✻ résumé ── ok" 2>/dev/null)
    [ "$out" = pending ] \
      || fail "multibyte real text must stay pending under LC_ALL=$lc, got '$out'"
    first=ran
  done
  [ -n "$first" ] || fail "no locale could be exercised for the normalization check"
  pass "fm_composer_classify_content: U+00A0 normalization is locale-independent and leaves other multibyte text intact"
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
test_nbsp_padded_empty_composer_is_empty
test_nbsp_padded_real_text_is_still_pending
test_nbsp_padding_preserves_dead_shell_refusal
test_nbsp_normalization_is_locale_independent
