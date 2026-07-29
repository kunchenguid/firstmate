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
#
# The blank-normalisation contract, task fm-afk-wedge-bgjob-pane:
#   5. Claude's current CLI draws its idle composer as an UNBORDERED `❯`
#      followed by U+00A0 (no-break space). A row carrying only a known agent
#      prompt glyph plus any combination of Unicode blanks is an EMPTY composer,
#      so the owner trims Unicode blanks as well as ASCII whitespace. Without
#      that, the residual U+00A0 read as typed text and away mode deferred every
#      escalation forever. The safety direction is unchanged: a Unicode blank
#      next to REAL text still reads `pending`, and a bare shell glyph padded
#      with Unicode blanks still reads `unknown`.
#   6. The trim widens no other verdict. A row an ASCII trim already emptied
#      keeps its pre-existing `empty` reading, bordered or not, which is what
#      keeps a container-less composer such as Pi deliverable on the tmux path.
#      Only the row the trim itself would newly permit - an UNBORDERED row of
#      nothing but Unicode blanks - defers as `unknown`.
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

test_empty_content_reads_empty() {
  local out
  # A genuinely empty row keeps its long-standing empty reading, bordered or not.
  # That is what keeps a container-less composer deliverable on the tmux path,
  # and what makes a cleared composer a positive submit acknowledgement; the
  # blank trim deliberately does not narrow it. Every adapter ASCII-trims its
  # candidate row before calling this owner, so this is the shape they pass.
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  # Passing an UNTRIMMED all-ASCII-blank row defers instead, because the raw row
  # reaches the ghost-only branch as non-empty. No adapter produces this shape;
  # it is pinned so the deferral is a recorded choice, not an accident.
  out=$(classify 0 '   '); [ "$out" = unknown ] || fail "an untrimmed ASCII-blank bare row should defer, got '$out'"
  pass "fm_composer_classify_content: a genuinely blank row reads empty; an untrimmed ASCII-blank row defers"
}

test_container_less_blank_composer_row_is_empty() {
  local out
  # Pi draws its composer as a region between two separator rules, with no side
  # border and no prompt glyph, so on the tmux path an idle Pi composer arrives
  # here as an unbordered row with empty content. It must read empty or away-mode
  # delivery to a Pi primary in a tmux pane is lost.
  # This pins the classifier's answer only; the Pi shape itself is driven end to
  # end through the real tmux reader in tests/fm-composer-ghost.test.sh.
  out=$(classify 0 '' '' insensitive '')
  [ "$out" = empty ] \
    || fail "a container-less blank composer row must read empty (Pi on tmux), got '$out'"
  pass "fm_composer_classify_content: a container-less blank composer row stays empty"
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

# --- Unicode blanks are blanks, not typed text ------------------------------
#
# NBSP is the shape claude's current CLI actually renders (`❯` U+276F + U+00A0);
# the rest are the other Unicode space separators plus the two zero-width
# characters a harness could pad an empty composer with.
NBSP=$(printf '\xc2\xa0')            # U+00A0 no-break space
NNBSP=$(printf '\xe2\x80\xaf')       # U+202F narrow no-break space
EMSP=$(printf '\xe2\x80\x83')        # U+2003 em space
IDSP=$(printf '\xe3\x80\x80')        # U+3000 ideographic space
ZWSP=$(printf '\xe2\x80\x8b')        # U+200B zero-width space

test_agent_glyph_with_unicode_blanks_is_empty() {
  local out blank
  # The live claude shape: an unbordered `❯` + U+00A0 and nothing else.
  out=$(classify 0 "❯$NBSP")
  [ "$out" = empty ] \
    || fail "an idle claude composer (bare '❯'+U+00A0) must read empty, got '$out'"
  out=$(classify 1 "❯$NBSP")
  [ "$out" = empty ] \
    || fail "an idle claude composer (bordered '❯'+U+00A0) must read empty, got '$out'"
  # Every other Unicode blank, leading and trailing, and in combination.
  for blank in "$NBSP" "$NNBSP" "$EMSP" "$IDSP" "$ZWSP"; do
    out=$(classify 0 "$blank❯$blank$blank")
    [ "$out" = empty ] \
      || fail "'❯' padded with a Unicode blank must read empty, got '$out'"
    out=$(classify 0 "› $blank")
    [ "$out" = empty ] \
      || fail "codex '›' padded with a Unicode blank must read empty, got '$out'"
  done
  # A composer holding nothing but Unicode blanks is empty, like an ASCII-blank one.
  out=$(classify 1 "$NBSP$ZWSP")
  [ "$out" = empty ] || fail "a blanks-only bordered composer must read empty, got '$out'"
  pass "fm_composer_classify_content: an agent glyph plus Unicode blanks reads empty (claude's ❯+U+00A0 idle composer)"
}

test_unbordered_blanks_only_row_is_unknown() {
  local out blank
  # An unbordered row holding nothing but UNICODE blanks - no prompt glyph, no
  # text - is the one row this branch would newly permit: before the blank trim
  # existed it read pending, and the trim alone would flip it to empty. That is a
  # new injection permission on a row carrying no composer evidence, so it is
  # declined as unknown. A row an ASCII trim already emptied is a different case
  # and keeps its pre-existing empty verdict (see the empty-content tests above).
  for blank in "$NBSP" "$NNBSP" "$EMSP" "$IDSP" "$ZWSP"; do
    out=$(classify 0 "$blank")
    [ "$out" = unknown ] \
      || fail "an unbordered blanks-only row must read unknown (dead pane), got '$out'"
  done
  out=$(classify 0 "$NBSP$ZWSP  ")
  [ "$out" = unknown ] \
    || fail "an unbordered row of mixed ASCII and Unicode blanks must read unknown, got '$out'"
  pass "fm_composer_classify_content: an unbordered blanks-only row reads unknown, never empty"
}

test_plain_content_path_is_not_blank_trimmed() {
  local out
  # `[plain_content]` is the RAW row, and the ghost-only branch that consumes it
  # asks whether that row carried anything AT ALL. Blank-trimming it was tried
  # and reverted: it let a blanks-only plain row skip that branch and reach the
  # empty-row decision as `empty`, an injection-permitting flip. These verdicts
  # are therefore identical to pre-branch behaviour, measured against fork/main.
  out=$(classify 0 '' '' sensitive "❯$NBSP")
  [ "$out" = unknown ] \
    || fail "an untrimmed plain row of '❯'+U+00A0 must keep its pre-branch unknown, got '$out'"
  out=$(classify 0 '' '' sensitive "\$$NBSP")
  [ "$out" = unknown ] \
    || fail "an untrimmed plain row of a shell prompt + U+00A0 must stay unknown, got '$out'"
  out=$(classify 0 '' '' sensitive '   ')
  [ "$out" = unknown ] \
    || fail "an ASCII-blank plain row must keep its pre-branch unknown (not injectable), got '$out'"
  out=$(classify 0 '' '' sensitive '❯')
  [ "$out" = empty ] \
    || fail "a plain row of exactly the agent glyph must still read empty, got '$out'"
  pass "fm_composer_classify_content: the plain-content path is deliberately not blank-trimmed"
}

test_plain_content_blanks_only_row_is_unknown() {
  local out blank
  # The same declined permission, reached through the PLAIN row instead of the
  # content row: tmux passes the ANSI-stripped plain line as the 5th argument, so
  # a de-emphasised no-break space ghost-strips to nothing while the plain row
  # still holds the blank. Trimming it would empty both rows and let the row read
  # empty, which is the injection-permitting flip this branch declines - it read
  # unknown before the trim existed and must still read unknown.
  for blank in "$NBSP" "$NNBSP" "$EMSP" "$IDSP" "$ZWSP"; do
    out=$(classify 0 '' '' sensitive "$blank")
    [ "$out" = unknown ] \
      || fail "a plain row holding only a Unicode blank must read unknown, got '$out'"
  done
  out=$(classify 0 '' '' sensitive "$NBSP$ZWSP  ")
  [ "$out" = unknown ] \
    || fail "a plain row of mixed ASCII and Unicode blanks must read unknown, got '$out'"
  # An ASCII-blank plain row also reads unknown, measured identical to fork/main:
  # `[plain_content]` is not blank-trimmed, so the ghost-only branch still sees a
  # non-empty raw row. Container-less delivery (Pi on tmux) does NOT depend on
  # this path - it comes from an empty <content> with an empty plain row, pinned
  # by test_container_less_blank_composer_row_is_empty.
  out=$(classify 0 '' '' sensitive '   ')
  [ "$out" = unknown ] \
    || fail "an ASCII-blank plain row must read unknown, matching fork/main, got '$out'"
  pass "fm_composer_classify_content: a blanks-only plain row reads unknown, never empty"
}

test_unicode_blanks_around_real_text_stay_pending() {
  local out
  out=$(classify 0 "❯${NBSP}fix findings 1 and 3")
  [ "$out" = pending ] \
    || fail "real text after '❯'+U+00A0 must stay pending, got '$out'"
  out=$(classify 1 "${NBSP}deploy staging now$NBSP")
  [ "$out" = pending ] \
    || fail "real text padded with U+00A0 must stay pending, got '$out'"
  out=$(classify 0 "❯ a${NBSP}b")
  [ "$out" = pending ] \
    || fail "real text containing an interior U+00A0 must stay pending, got '$out'"
  pass "fm_composer_classify_content: Unicode blanks around or inside real text still read pending"
}

test_shell_glyph_with_unicode_blanks_keeps_its_verdict() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g$NBSP")
    [ "$out" = unknown ] \
      || fail "a bare shell glyph '$g' padded with U+00A0 must stay unknown (dead shell), got '$out'"
    out=$(classify 0 "$g$NBSP ls -la")
    [ "$out" != empty ] \
      || fail "a bare shell prompt with a command must never read empty, got '$out'"
    out=$(classify 1 "$g$NBSP")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' + U+00A0 inside a composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: Unicode blanks do not weaken the bare-shell-prompt safety verdict"
}

test_blank_trim_is_locale_independent_and_errexit_safe() {
  local loc out
  # The blank set is matched as literal UTF-8 byte strings, never as a byte
  # class: U+202F (E2 80 AF) shares its lead byte with '❯' (U+276F, E2 9D AF),
  # so a byte class would eat the glyph under LC_ALL=C. Callers also run the
  # classifier under `set -euo pipefail`, which the trim loop must survive.
  # Scope: this pins the blank SET only. The trim's ASCII step still uses
  # [[:space:]], which glibc widens in a UTF-8 locale to U+2028/U+2029, a
  # pre-existing divergence recorded in docs/herdr-backend.md.
  for loc in C C.UTF-8; do
    out=$(LC_ALL=$loc bash -euo pipefail -c \
      '. "$1/bin/fm-composer-lib.sh"
       fm_composer_classify_content 0 "❯$2"; printf ";"
       fm_composer_classify_content 0 "❯${2}typed"' _ "$ROOT" "$NBSP") \
      || fail "the classifier failed under LC_ALL=$loc with set -euo pipefail"
    [ "$out" = 'empty;pending' ] \
      || fail "LC_ALL=$loc must give 'empty;pending' for the idle and typed rows, got '$out'"
  done
  pass "fm_composer_trim: the blank set trims the same in either locale and is set -euo pipefail safe"
}

test_leading_glyph_strip_is_locale_independent() {
  local loc out
  # A glyph-prefixed idle placeholder is the row that actually REACHES the
  # leading-glyph strip: it is non-empty, is not a bare glyph, and does not match
  # the idle regex until the glyph is gone. The multibyte glyphs must be removed
  # whole, so a `?` byte match under LC_ALL=C cannot leave an invalid UTF-8 tail
  # that defeats the post-strip idle match and misreads an idle pane as pending.
  for loc in C C.UTF-8; do
    out=$(LC_ALL=$loc bash -euo pipefail -c \
      '. "$1/bin/fm-composer-lib.sh"
       idle="^Type a message\.\.\.$"
       fm_composer_classify_content 0 "❯$2Type a message..." "$idle"; printf ";"
       fm_composer_classify_content 0 "›$2Type a message..." "$idle"; printf ";"
       fm_composer_classify_content 0 "❯$2deploy staging now" "$idle"' \
      _ "$ROOT" "$NBSP") \
      || fail "the classifier failed under LC_ALL=$loc with set -euo pipefail"
    [ "$out" = 'empty;empty;pending' ] \
      || fail "LC_ALL=$loc must strip a whole agent glyph ('empty;empty;pending'), got '$out'"
  done
  pass "fm_composer_classify_content: a leading multibyte agent glyph is stripped whole in any locale"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_blank_trim_is_locale_independent_and_errexit_safe
test_leading_glyph_strip_is_locale_independent
test_agent_glyph_with_unicode_blanks_is_empty
test_unbordered_blanks_only_row_is_unknown
test_plain_content_path_is_not_blank_trimmed
test_plain_content_blanks_only_row_is_unknown
test_unicode_blanks_around_real_text_stay_pending
test_shell_glyph_with_unicode_blanks_keeps_its_verdict
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_reads_empty
test_container_less_blank_composer_row_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
