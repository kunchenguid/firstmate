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
#   5. Non-ASCII blank PADDING (U+00A0 and friends, task composer-nbsp-fix) on an
#      otherwise-blank row is normalized before the trims, so a harness-padded
#      empty composer reads `empty` instead of a stable false `pending` - and
#      never at the cost of hiding real typed text.
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

# --- Non-ASCII blank padding (the NBSP wedge) -------------------------------
# Task composer-nbsp-fix. Real Claude Code 2.1.220 pads its EMPTY composer row
# with U+00A0: the captured row is exactly `\xe2\x9d\xaf\xc2\xa0` (`❯` + NBSP),
# byte-verified on four separate live panes and reproduced against real claude
# through tmux's independent reader. bash's [[:space:]] does not match U+00A0,
# so every trim left it in place and this owner read a genuinely idle pane as
# `pending` forever - and away-mode injection only ever proceeds on an
# affirmative `empty`, so escalations sat undelivered for ~9.5h at a stretch,
# three times. The literal byte pair below is the fixture that was missing:
# before the fix it appeared nowhere under tests/, which is precisely why every
# one of those wedges passed CI.

test_nbsp_padded_blank_rows_are_empty() {
  local out b
  # The exact captured shape, bordered and bare.
  out=$(classify 0 $'\xe2\x9d\xaf\xc2\xa0')
  [ "$out" = empty ] \
    || fail "the real-claude '❯'+NBSP idle row must read empty, got '$out' (regression: this read 'pending' forever and wedged away-mode delivery)"
  out=$(classify 1 $'\xe2\x9d\xaf\xc2\xa0')
  [ "$out" = empty ] || fail "a bordered '❯'+NBSP idle row must read empty, got '$out'"
  out=$(classify 0 $'\xe2\x80\xba\xc2\xa0')
  [ "$out" = empty ] || fail "a codex '›'+NBSP idle row must read empty, got '$out'"
  # The other padding blanks a TUI can emit, mapped or dropped by the same owner.
  for b in $'\xe2\x80\x87' $'\xe2\x80\xaf' $'\xe2\x80\x8b' $'\xef\xbb\xbf'; do
    out=$(classify 0 "❯$b")
    [ "$out" = empty ] || fail "a '❯' row padded with a non-ASCII blank must read empty, got '$out'"
  done
  # A row of padding alone, with no glyph left to strip.
  out=$(classify 1 $'\xc2\xa0\xc2\xa0')
  [ "$out" = empty ] || fail "a bordered row holding only NBSP padding must read empty, got '$out'"
  # The plain-content path (a ghost strip that consumed everything).
  out=$(classify 0 '' '' sensitive $'\xe2\x9d\xaf\xc2\xa0')
  [ "$out" = empty ] || fail "a stripped '❯'+NBSP row must remain empty, got '$out'"
  pass "fm_composer_classify_content: non-ASCII blank padding on an otherwise-blank row reads empty (real-claude '❯'+U+00A0)"
}

# The safety half: normalizing blanks must never make REAL typed text vanish.
# Only characters that render as blank are touched, so any visible glyph
# survives and the row stays non-empty.
test_non_ascii_blanks_never_hide_real_text() {
  local out
  out=$(classify 0 $'\xe2\x9d\xaf\xc2\xa0land pr 1234 now')
  [ "$out" = pending ] || fail "real text after '❯'+NBSP must read pending, got '$out'"
  out=$(classify 1 $'\xc2\xa0deploy staging now')
  [ "$out" = pending ] || fail "real text behind NBSP padding must read pending, got '$out'"
  out=$(classify 0 $'\xe2\x9d\xaf fix\xc2\xa0findings 1 and 3')
  [ "$out" = pending ] || fail "NBSP-joined real text must read pending, got '$out'"
  # The dead-shell rule still holds when the shell prompt is NBSP-padded.
  out=$(classify 0 $'$\xc2\xa0')
  [ "$out" != empty ] || fail "a bare NBSP-padded shell prompt must never read empty, got '$out'"
  out=$(classify 0 $'$\xc2\xa0rm -rf /')
  [ "$out" != empty ] || fail "an NBSP-padded shell prompt with a command must never read empty, got '$out'"
  pass "fm_composer_classify_content: blank normalization never turns real typed text (or a dead shell) into empty"
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
test_nbsp_padded_blank_rows_are_empty
test_non_ascii_blanks_never_hide_real_text
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
