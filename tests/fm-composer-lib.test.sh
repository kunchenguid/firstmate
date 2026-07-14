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

# shellcheck source=bin/fm-composer-lib.sh
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

# classify_in_c_locale: same as classify, but under a genuinely exported C
# locale. The locale MUST be pinned in a child process, never as an assignment
# prefix on the `classify` shell FUNCTION: bash does not re-run setlocale for a
# function-call prefix, so `LC_ALL=C classify ...` keeps bash's own `case` and
# ${var#pat} matching multibyte-aware and the resulting test passes against the
# very byte-strip bug it is meant to catch. Repo precedent: the locale-pinned
# child in tests/fm-watcher-lock.test.sh.
classify_in_c_locale() {  # <bordered> <content> [idle_re] [idle_case] [plain_content] [glyphs]
  LC_ALL=C bash -c '. "$1"; shift; fm_composer_classify_content "$@"' _ "$ROOT/bin/fm-composer-lib.sh" "$@"
}

# Locale-invariance regression, guarded at the owner rather than only at a
# single adapter: bin/fm-supervise-daemon.sh runs under a C/POSIX locale, where
# a byte-count strip (${content#?}) removes ONE BYTE of the 3-byte ❯ and leaves
# two stray bytes behind, so the idle placeholder no longer matches and an idle
# composer reads pending. The glyph strip must match the literal glyph instead.
# Every adapter (tmux, herdr, orca, cmux) routes its verdict through here, so
# this one case covers them all.
test_glyph_strip_is_locale_invariant() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify_in_c_locale 0 '❯ Type a message...' "$idle")
  [ "$out" = empty ] || fail "under LC_ALL=C the idle placeholder after a '❯' glyph must still read empty, got '$out'"
  out=$(classify_in_c_locale 0 '❯')
  [ "$out" = empty ] || fail "under LC_ALL=C a bare '❯' agent glyph must still read empty, got '$out'"
  out=$(classify_in_c_locale 0 '› Type a message...' "$idle")
  [ "$out" = empty ] || fail "under LC_ALL=C the idle placeholder after a '›' glyph must still read empty, got '$out'"
  # Real input must stay protected under the same locale.
  out=$(classify_in_c_locale 0 '❯ fix findings 1 and 3')
  [ "$out" = pending ] || fail "under LC_ALL=C real text after a '❯' glyph must still read pending, got '$out'"
  # The dead-shell safety rule must not soften under the same locale either.
  out=$(classify_in_c_locale 0 '$')
  [ "$out" = unknown ] || fail "under LC_ALL=C a bare shell glyph must still read unknown, got '$out'"
  pass "fm_composer_classify_content: the leading-glyph strip is locale-invariant (LC_ALL=C)"
}

# The agent glyph set is a caller-supplied LITERAL set, so an adapter that
# recognizes a further harness's prompt glyph gets the same empty|pending verdict
# for it as for the built-in ❯ and ›. Without this threading, that harness's idle
# composer reads pending forever and away-mode defers every escalation behind
# input that was never there.
test_caller_supplied_glyph_set_is_honored() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 0 '»' '' sensitive '' '❯ › »')
  [ "$out" = empty ] || fail "a bare glyph from the caller's set must read empty, got '$out'"
  out=$(classify_in_c_locale 0 '» Type a message...' "$idle" sensitive '' '❯ › »')
  [ "$out" = empty ] || fail "under LC_ALL=C the idle placeholder after a caller-set glyph must read empty, got '$out'"
  out=$(classify 0 '» fix the login bug' "$idle" sensitive '' '❯ › »')
  [ "$out" = pending ] || fail "real text after a caller-set glyph must read pending, got '$out'"
  # A glyph outside the caller's set stays unrecognized, so the safety rule holds.
  out=$(classify 0 '»')
  [ "$out" = pending ] || fail "without the caller's set a '»' row is not a known agent glyph, got '$out'"
  pass "fm_composer_classify_content: a caller-supplied agent glyph set is honored for classification, not just detection"
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
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_glyph_strip_is_locale_invariant
test_caller_supplied_glyph_set_is_honored
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
