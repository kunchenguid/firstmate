#!/usr/bin/env bash
# tests/fm-composer-nbsp.test.sh - regression guard for the overnight away-mode
# wedge of 2026-07-29/30 (task afk-wedge-noc).
#
# Reproduced live in an isolated herdr lab session against real claude 2.1.220:
# its composer is NOT a bordered box but a bare agent glyph between two solid
# rules, and the idle row's bytes are
#     e2 9d af c2 a0   =   "❯" + U+00A0 NO-BREAK SPACE
# U+00A0 is not in [[:space:]] in any locale, so the shared classifier's trims
# removed nothing, its exact-glyph case missed, and an IDLE composer read
# `pending` - the verdict that means "a human has typed something, do not type
# over it". The away-mode injector defers on anything but `empty`, so every
# escalation sat buffered for 6h14m against a pane that was ready the whole time.
#
# Two levels, because one alone would not have caught that night: the shared
# owner's verdict, and the same recorded screen replayed end to end through the
# real herdr adapter. Every existing composer fixture was hand-invented with a
# box border and ASCII spaces, which is why none of them saw this.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

NBSP=$'\302\240'
TMP_ROOT=$(fm_test_tmproot fm-composer-nbsp-tests)

# --- level 1: the shared owner of the verdict --------------------------------

test_glyph_plus_invisible_padding_is_empty() {
  local out
  out=$(fm_composer_classify_content 0 "❯${NBSP}")
  [ "$out" = empty ] \
    || fail "claude 2.1.220's idle bare composer '❯<U+00A0>' must read empty, got '$out'"
  out=$(fm_composer_classify_content 1 "❯${NBSP}")
  [ "$out" = empty ] || fail "the same row inside a bordered box must read empty, got '$out'"
  out=$(fm_composer_classify_content 0 "›${NBSP}")
  [ "$out" = empty ] || fail "the codex glyph with invisible padding must read empty, got '$out'"
  pass "fm_composer_classify_content: an agent glyph plus invisible padding reads empty (the 29/30-07 wedge)"
}

# The other invisible-padding characters a harness may use for the same job. A row
# holding nothing but these is empty by any reading a human could give it.
test_every_normalized_blank_reads_empty() {
  local blank out
  for blank in $'\302\240' $'\342\200\207' $'\342\200\257' $'\342\200\213' $'\342\201\240' $'\357\273\277'; do
    out=$(fm_composer_classify_content 0 "❯${blank}")
    [ "$out" = empty ] \
      || fail "an agent glyph padded with an invisible blank must read empty, got '$out'"
    out=$(fm_composer_classify_content 1 "${blank}")
    [ "$out" = empty ] \
      || fail "a composer holding only an invisible blank must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: every invisible-padding character normalizes to empty"
}

test_invisible_padding_never_swallows_typed_text() {
  local out
  out=$(fm_composer_classify_content 0 "❯${NBSP}fix findings 1 and 3")
  [ "$out" = pending ] || fail "real typed text after the NBSP separator must stay pending, got '$out'"
  out=$(fm_composer_classify_content 0 "❯${NBSP}/compact compaction instructions")
  [ "$out" = pending ] || fail "a popup argument-hint fill must stay pending, got '$out'"
  out=$(fm_composer_classify_content 1 "${NBSP}deploy staging now${NBSP}")
  [ "$out" = pending ] || fail "text wrapped in invisible padding must stay pending, got '$out'"
  pass "fm_composer_classify_content: invisible padding never swallows real typed content"
}

# The load-bearing safety rule of this owner (task fm-composer-shellglyph-safety):
# a bare shell prompt is a DEAD SHELL, never an injection target. Normalizing
# invisible padding must not turn one into an "empty composer".
test_dead_shell_refusal_survives_normalization() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(fm_composer_classify_content 0 "${g}${NBSP}")
    [ "$out" = unknown ] \
      || fail "a bare shell glyph '$g' with invisible padding must stay unknown, got '$out'"
    out=$(fm_composer_classify_content 0 '' '' sensitive "${g}${NBSP}")
    [ "$out" = unknown ] \
      || fail "a stripped bare shell glyph '$g' with invisible padding must stay unknown, got '$out'"
  done
  pass "fm_composer_classify_content: the dead-shell refusal survives invisible-padding normalization"
}

# The fleet runs LC_ALL=C in places, where a \u escape or a character-wise trim
# would mangle the multibyte glyph and the padding byte pair alike.
test_verdict_is_locale_independent() {
  local out
  out=$(LC_ALL=C bash -c '. "$0/bin/fm-composer-lib.sh"
    fm_composer_classify_content 0 "❯$(printf "\302\240")"' "$ROOT")
  [ "$out" = empty ] || fail "under LC_ALL=C the idle row must still read empty, got '$out'"
  out=$(LC_ALL=C bash -c '. "$0/bin/fm-composer-lib.sh"
    fm_composer_classify_content 0 "❯$(printf "\302\240")fix findings"' "$ROOT")
  [ "$out" = pending ] || fail "under LC_ALL=C typed text must still read pending, got '$out'"
  pass "fm_composer_classify_content: the verdict is identical under LC_ALL=C and a UTF-8 locale"
}

# --- level 2: the recorded screen, end to end through the herdr adapter ------

# The screen recorded in the lab that night: claude's rule / composer / rule
# triple, then the statusline and permission-mode footer that sit below the
# composer row and push it up out of the scan window. <extra-statusline-rows>
# grows that block to the height a wide window renders.
herdr_screen() {  # <composer-tail> [extra-statusline-rows]
  local tail=$1 extra=${2:-0} rule i=0
  rule=$(printf '─%.0s' $(seq 54))
  printf '%s\n' \
    "$rule" \
    "❯${NBSP}${tail}" \
    "$rule" \
    "  ⚠ Transcript saving is off - inherited CLAUDE_CODE_…" \
    "    BLAKE OS ◉2%"
  while [ "$i" -lt "$extra" ]; do
    i=$((i + 1))
    printf '  ◈ statusline row %s\n' "$i"
  done
  printf '%s\n' \
    "  ◈detached 12m │ ✿-→" \
    "  ◎ 📁0 ✦0 ⊕0" \
    "  ⏵⏵ bypass permissions on (shift+tab to cycle)"
}

herdr_verdict() {  # <case-name> <composer-tail> [extra-statusline-rows]
  local dir log resp fb
  dir="$TMP_ROOT/$1"; mkdir -p "$dir/responses"
  log="$dir/log"; resp="$dir/responses"; : > "$log"
  herdr_screen "$2" "${3:-0}" > "$resp/1.out"
  fb=$(make_herdr_fakebin "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state default:w1:p2' "$ROOT"
}

test_herdr_recorded_idle_screen_is_empty() {
  local out
  out=$(herdr_verdict idle-screen "")
  [ "$out" = empty ] || fail "the recorded idle claude 2.1.220 screen must read empty, got '$out'"
  pass "fm_backend_herdr_composer_state: the recorded 29/30-07 idle screen reads empty, not pending"
}

test_herdr_recorded_typed_screen_is_pending() {
  local out
  out=$(herdr_verdict typed-screen "fix findings 1 and 3")
  [ "$out" = pending ] || fail "the same screen with typed text must read pending, got '$out'"
  pass "fm_backend_herdr_composer_state: typed text on that same screen still reads pending"
}

# The second, independent half of the same wedge: a composer row pushed out of the
# scan window reads `unknown`, which defers injection exactly as a false `pending`
# does. The captain's pane was measured two rows from that cliff, so the default
# window must clear a statusline block of this height with the composer row still
# inside it - 21 rows below the composer, more than the old 20-row window held.
test_herdr_tall_statusline_keeps_the_composer_row_in_window() {
  local out
  out=$(herdr_verdict tall-statusline "" 18)
  [ "$out" = empty ] \
    || fail "a tall statusline must not push the composer row out of the scan window, got '$out'"
  pass "fm_backend_herdr_composer_state: a tall statusline leaves the composer row inside the default scan window"
}

test_glyph_plus_invisible_padding_is_empty
test_every_normalized_blank_reads_empty
test_invisible_padding_never_swallows_typed_text
test_dead_shell_refusal_survives_normalization
test_verdict_is_locale_independent

# Only level 2 needs jq: it drives the real herdr adapter, which parses the JSON
# capture. Level 1 above is pure shell and IS the regression guard for the
# 2026-07-29/30 wedge, so it must run on every host, jq or not - hence the gate
# sits here rather than at the top of the file (task afk-wedge-noc).
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter cases)"; exit 0; }

test_herdr_recorded_idle_screen_is_empty
test_herdr_recorded_typed_screen_is_pending
test_herdr_tall_statusline_keeps_the_composer_row_in_window
