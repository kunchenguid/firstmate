#!/usr/bin/env bash
# Ghost-text robustness (incident composer-robust; task afk-herdr-false-pending).
#
# A harness fills an otherwise-empty composer with de-emphasised ghost text that a
# plain pane capture cannot tell apart from human input, so the composer reader
# saw an idle pane as holding pending input. Two rendering styles are covered by
# the one shared ANSI-aware owner (fm_composer_strip_ghost, bin/fm-composer-lib.sh,
# reached here through the fm_tmux_strip_ghost thin adapter):
#   - DIM/FAINT (SGR 2): claude's rotating prompt suggestion, codex's idle tip.
#   - a dark/muted TRUECOLOR foreground: grok's placeholder/hint text.
# These tests pin:
#   1. fm_tmux_strip_ghost drops dim/faint AND dark-truecolor runs, keeping
#      normal-intensity, brightly-coloured text.
#   2. fm_pane_input_pending reads a ghost-only composer (either style) as NOT
#      pending, while still treating real (normal/bright) text as pending.
#   3. The human/LLM-facing capture path (fm-peek.sh) stays PLAIN - no escape codes
#      ever reach firstmate's context.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-tmux-lib.sh"
PEEK="$ROOT/bin/fm-peek.sh"

# shellcheck source=/dev/null
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-ghost-tests)

# ESC byte for building styled fixtures and asserting escape-free output.
ESC=$(printf '\033')

# A fake tmux that serves a styled composer line for the dim-aware reader and an
# escape-free line for the plain (peek) path. capture-pane returns the styled
# fixture verbatim WITH -e (mirrors `tmux capture-pane -e`), and the same content
# with SGR sequences stripped WITHOUT -e (mirrors a plain capture). cursor_y comes
# from FM_FAKE_CY.
make_fake_tmux() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    has_e=0
    for a in "$@"; do [ "$a" = "-e" ] && has_e=1; done
    f="${FM_FAKE_STYLED:-/dev/null}"
    if [ "$has_e" = 1 ]; then
      cat "$f" 2>/dev/null
    else
      # Plain capture: drop SGR sequences, as real `tmux capture-pane -p` does.
      LC_ALL=C awk '{gsub(/\033\[[0-9;]*m/, ""); print}' "$f" 2>/dev/null
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# A fake tmux that serves a MULTI-ROW composer box, addressable by row, so the
# cursor_y row-window re-anchor (incident afk-daemon-composer-wedge-fix) can be
# exercised. Rows are 1-indexed from a FM_FAKE_ROWS file (one styled row per
# line); cursor_y comes from FM_FAKE_CY. capture-pane honours -S/-E as absolute
# row bounds (mirroring how fm_tmux_composer_state addresses rows by cursor_y),
# returns the styled rows verbatim WITH -e, and SGR-stripped WITHOUT -e. A row
# index outside the file yields a blank line, as a real pane's empty rows do.
make_fake_tmux_box() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
rows_file="${FM_FAKE_ROWS:-/dev/null}"
row_at() {  # <1-indexed row> -> that row's styled bytes, or blank
  local want=$1 n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    if [ "$n" = "$want" ]; then printf '%s\n' "$line"; return 0; fi
  done < "$rows_file"
  printf '\n'
}
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    has_e=0; S=""; E=""; prev=""
    for a in "$@"; do
      [ "$a" = "-e" ] && has_e=1
      case "$prev" in -S) S=$a ;; -E) E=$a ;; esac
      prev=$a
    done
    [ -n "$S" ] || S="${FM_FAKE_CY:-0}"; [ -n "$E" ] || E=$S
    r=$S
    while [ "$r" -le "$E" ]; do
      if [ "$r" -ge 1 ]; then styled=$(row_at "$r"); else styled=""; fi
      if [ "$has_e" = 1 ]; then
        printf '%s\n' "$styled"
      else
        printf '%s\n' "$styled" | LC_ALL=C awk '{gsub(/\033\[[0-9;]*m/, ""); print}'
      fi
      r=$((r + 1))
    done
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# A pristine, rule-bordered agent composer box: a top rule, the bare prompt-glyph
# input row, and a bottom rule. <glyph> is the agent prompt glyph bytes (❯ or ›);
# [input_tail] optional real typed text after the glyph. tmux's cursor_y lands on
# the BOTTOM rule (row 3), one below the input row (row 2) - the off-by-one this
# fixture exists to exercise.
write_composer_box() {  # <file> <glyph-bytes> [input_tail]
  local file=$1 glyph=$2 tail=${3:-}
  {
    printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n'
    printf '%s %s\n' "$glyph" "$tail"
    printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n'
  } > "$file"
}

# --- fm_tmux_strip_ghost (pure) ---------------------------------------------

test_strip_ghost_drops_dim_keeps_normal() {
  local out
  # Dim run between ESC[2m and ESC[0m is dropped; the prompt glyph survives.
  out=$(printf '\xe2\x9d\xaf \033[2mWhat is the largest country by area?\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "dim run not dropped: '$out'"
  # Normal-intensity text is kept verbatim (no styling at all).
  out=$(printf '\xe2\x9d\xaf real human text\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf real human text')" ] || fail "normal text changed: '$out'"
  # Bold (SGR 1) is normal-intensity, NOT dim - must be kept.
  out=$(printf '\033[1mbold typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "bold typed" ] || fail "bold text wrongly dropped: '$out'"
  pass "fm_tmux_strip_ghost drops dim/faint runs, keeps normal and bold text"
}

test_strip_ghost_handles_combined_and_boundary_codes() {
  local out
  # Dim combined with a color in one sequence (ESC[2;37m) is still a dim run.
  out=$(printf '\xe2\x9d\xaf \033[2;37mpredicted\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "combined dim+color not dropped: '$out'"
  # ESC[22m (normal intensity) ends a dim run mid-line; the tail is kept.
  out=$(printf '\033[2mghost\033[22mREALTAIL\n' | fm_tmux_strip_ghost)
  [ "$out" = "REALTAIL" ] || fail "ESC[22m did not end the dim run: '$out'"
  # ESC[0;2m (reset then dim) reads as dim (left-to-right within the sequence).
  out=$(printf 'keep\033[0;2mdrop\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "keep" ] || fail "reset-then-dim not treated as dim: '$out'"
  pass "fm_tmux_strip_ghost handles combined SGR, ESC[22m, and reset-then-dim"
}

test_strip_ghost_keeps_colored_text_with_2_payloads() {
  local out
  # These pin that the awk's truecolor/256-color `2` payload SELECTOR is not
  # mistaken for the SGR-2 dim attribute. The truecolor foregrounds use a BRIGHT
  # colour (grok's real-input RGB 224,222,244, luminance ~225), because a DARK
  # truecolor foreground is now itself a ghost signal (grok's placeholder) and is
  # covered by test_strip_ghost_drops_dark_truecolor_ghost below.
  out=$(printf '\033[38;5;2mgreen typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "green typed" ] || fail "8-bit color payload 2 was treated as dim: '$out'"
  out=$(printf '\033[38;2;224;222;244mtruecolor typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "truecolor typed" ] || fail "bright truecolor payload 2 was treated as dim/ghost: '$out'"
  out=$(printf '\033[48;2;4;5;6mbackground typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "background typed" ] || fail "background truecolor payload was treated as dim: '$out'"
  out=$(printf '\033[58;5;2munderline-color typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "underline-color typed" ] || fail "underline color payload 2 was treated as dim: '$out'"
  out=$(printf '\033[38:2::224:222:244mcolon truecolor typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "colon truecolor typed" ] || fail "bright colon truecolor payload 2 was treated as dim/ghost: '$out'"
  out=$(printf '\033[58::5::2mcolon underline typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "colon underline typed" ] || fail "colon underline SGR leaked or dimmed text: '$out'"
  out=$(printf '\033[4:2mnot dim underline\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "not dim underline" ] || fail "colon subparameter 2 was treated as dim: '$out'"
  pass "fm_tmux_strip_ghost keeps bright colored text with 2 payloads"
}

# --- Dark truecolor foreground is ghost (grok placeholder), dropped ----------

test_strip_ghost_drops_dark_truecolor_ghost() {
  local out
  # grok renders its placeholder/hint text with a dark, muted truecolor
  # foreground (empirically 38;2;50;47;70 .. 38;2;110;106;134, luminance ~51..110,
  # verified live against grok 0.2.93; the pristine "Type a message..." placeholder
  # was this shape in grok 0.2.82). The shared owner drops it while keeping the
  # bright prompt glyph, so an idle grok composer never reads as pending.
  out=$(printf '\xe2\x9d\xaf \033[38;2;50;47;70mType a message...\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "dark truecolor ghost not dropped: '$out'"
  out=$(printf '\033[38;2;110;106;134mplaceholder hint text\033[39m\n' | fm_tmux_strip_ghost)
  [ -z "$out" ] || fail "dark truecolor hint not dropped: '$out'"
  # The colon form drops too.
  out=$(printf '\xe2\x9d\xaf \033[38:2::86:82:110mmuted\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "dark colon-truecolor ghost not dropped: '$out'"
  pass "fm_tmux_strip_ghost drops a dark/muted truecolor foreground (grok placeholder)"
}

# --- fm_pane_input_pending: dim ghost is not pending ------------------------

test_dim_ghost_only_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/ghost-only"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # The exact rendering claude emits: a normal prompt glyph + a DIM predicted prompt.
  printf '\xe2\x9d\xaf \033[2mWhat is the largest country by area?\033[0m\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
     fm_pane_input_pending "fakepane"; then
    fail "dim ghost-only composer falsely read as pending"
  fi
  pass "fm_pane_input_pending: a dim ghost-only composer is NOT pending"
}

test_dim_ghost_inside_bordered_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/ghost-bordered"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # Bordered composer (claude box) holding only dim ghost text.
  printf '\xe2\x94\x82 \033[2mtry the other approach instead\033[0m \xe2\x94\x82\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
     fm_pane_input_pending "fakepane"; then
    fail "dim ghost in a bordered composer falsely read as pending"
  fi
  pass "fm_pane_input_pending: dim ghost inside a bordered composer is NOT pending"
}

test_normal_text_still_pending() {
  local dir fb capture
  dir="$TMP_ROOT/real-text"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # Real human text, normal intensity - must still read as pending.
  printf '\xe2\x9d\xaf fix findings 1 and 3, skip 2\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "real typed text was not detected as pending"
  pass "fm_pane_input_pending: normal-intensity typed text is still pending"
}

test_colored_text_with_2_payload_still_pending() {
  local dir fb capture
  dir="$TMP_ROOT/colored-text"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '\xe2\x9d\xaf \033[38;5;2mgreen typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "8-bit colored typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[38;2;224;222;244mtruecolor typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "bright truecolor typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[58;5;2munderline-color typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "underline-colored typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[58::5::2mcolon underline typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "colon underline typed text was not detected as pending"
  pass "fm_pane_input_pending: bright colored text with 2 payloads is still pending"
}

test_dark_truecolor_ghost_only_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/grok-ghost"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # A grok-style pristine composer: bright prompt glyph + a dark/muted truecolor
  # placeholder. It must read NOT pending (the grok TRUECOLOR gap, now covered by
  # the same ANSI-aware owner as claude's dim ghost).
  printf '\xe2\x9d\xaf \033[38;2;50;47;70mType a message...\033[0m\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
     fm_pane_input_pending "fakepane"; then
    fail "dark truecolor ghost-only composer falsely read as pending"
  fi
  pass "fm_pane_input_pending: a dark truecolor ghost-only composer (grok placeholder) is NOT pending"
}

test_dark_truecolor_bare_shell_prompt_is_unknown() {
  local dir fb capture out prompt
  dir="$TMP_ROOT/dark-shell-prompt"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for prompt in '$' 'user@host $'; do
    printf '\033[38;2;50;47;70m%s\033[0m\n' "$prompt" > "$capture"
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = unknown ] \
      || fail "dark truecolor bare shell prompt '$prompt' must read unknown, got '$out'"
  done
  pass "fm_tmux_composer_state: dark truecolor shell prompts read unknown"
}

test_real_text_with_trailing_ghost_is_pending() {
  local dir fb capture
  dir="$TMP_ROOT/mixed"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # A human typed "deploy" and claude appended a dim ghost completion. The real
  # text must win - the composer is pending.
  printf '\xe2\x9d\xaf deploy\033[2m the staging environment now\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "real text with a trailing ghost completion was not detected as pending"
  pass "fm_pane_input_pending: real text plus a trailing ghost run is still pending"
}

# --- cursor_y row-window re-anchor (incident afk-daemon-composer-wedge-fix) --
#
# A pristine, never-typed-into claude/codex composer renders its input row inside
# a rule-bordered box (─────/❯/─────), and tmux's #{cursor_y} points one row BELOW
# the ❯ input row, at the box's bottom rule. Reading only that single cursor row,
# the rule glyphs classify as pending, so the away-mode injector read firstmate's
# OWN idle composer as pending input and deferred 100% of escalations for ~15h.
# fm_tmux_composer_state now re-anchors from a pure rule row onto the neighbouring
# ❯/› input row. These pin the fix AND its safety envelope: it only ever turns a
# rule-masked empty composer back into empty, never forces a busy/half-typed pane.

test_row_is_rule_recognizes_only_pure_rule_rows() {
  # Pure light and heavy rules (any length >=1) are rules; anything with other
  # glyphs, or a blank row, is not.
  fm_tmux_row_is_rule "$(printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80')" \
    || fail "light rule ───  not recognized"
  fm_tmux_row_is_rule "$(printf '\xe2\x94\x81\xe2\x94\x81')" \
    || fail "heavy rule ━━ not recognized"
  if fm_tmux_row_is_rule "$(printf '\xe2\x9d\xaf ')"; then fail "❯ prompt row misread as a rule"; fi
  if fm_tmux_row_is_rule ""; then fail "blank row misread as a rule"; fi
  if fm_tmux_row_is_rule "$(printf '\xe2\x94\x80\xe2\x94\x80 typed')"; then
    fail "rule with trailing text misread as a pure rule"
  fi
  pass "fm_tmux_row_is_rule: only pure ─/━ rows are rules"
}

test_pristine_composer_box_cursor_on_bottom_rule_is_empty() {
  local dir fb rows glyph out
  dir="$TMP_ROOT/box-wedge"; mkdir -p "$dir"
  fb=$(make_fake_tmux_box "$dir")
  rows="$dir/rows.txt"
  # The exact overnight-wedge shape: pristine claude composer box, cursor_y on
  # the bottom rule (row 3), input row (row 2) is a bare ❯. This is the case that
  # returned `pending` before the fix; it must now read `empty`.
  for glyph in '\xe2\x9d\xaf' '\xe2\x80\xba'; do  # ❯ (claude), › (codex)
    write_composer_box "$rows" "$(printf '%b' "$glyph")"
    out=$(PATH="$fb:$PATH" FM_FAKE_ROWS="$rows" FM_FAKE_CY=3 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = empty ] \
      || fail "pristine composer box (glyph '$glyph') with cursor_y on the bottom rule must read empty, got '$out'"
  done
  pass "fm_tmux_composer_state: pristine composer box, cursor_y on the bottom rule, reads empty (wedge fix)"
}

test_pristine_composer_box_cursor_on_input_row_is_empty() {
  local dir fb rows out
  dir="$TMP_ROOT/box-aligned"; mkdir -p "$dir"
  fb=$(make_fake_tmux_box "$dir")
  rows="$dir/rows.txt"
  # Same box, but cursor_y correctly on the ❯ input row (row 2): unchanged, empty.
  write_composer_box "$rows" "$(printf '\xe2\x9d\xaf')"
  out=$(PATH="$fb:$PATH" FM_FAKE_ROWS="$rows" FM_FAKE_CY=2 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "composer box with cursor_y on the ❯ input row must read empty, got '$out'"
  pass "fm_tmux_composer_state: composer box, cursor_y on the ❯ input row, reads empty (no regression)"
}

test_composer_box_with_real_text_stays_pending() {
  local dir fb rows out cy
  dir="$TMP_ROOT/box-real"; mkdir -p "$dir"
  fb=$(make_fake_tmux_box "$dir")
  rows="$dir/rows.txt"
  # Real unsubmitted text inside the box. Whether cursor_y sits on the bottom
  # rule (re-anchor path) or on the input row, the safety guard must hold: real
  # text reads pending, never forced empty.
  write_composer_box "$rows" "$(printf '\xe2\x9d\xaf')" 'fix findings 1 and 3, skip 2'
  for cy in 3 2; do
    out=$(PATH="$fb:$PATH" FM_FAKE_ROWS="$rows" FM_FAKE_CY=$cy \
      fm_tmux_composer_state "fakepane")
    [ "$out" = pending ] \
      || fail "real text in composer box (cursor_y=$cy) must read pending, got '$out'"
  done
  pass "fm_tmux_composer_state: real text in a composer box stays pending (cursor on rule OR input row)"
}

test_pristine_composer_box_dim_glyph_reanchors_empty() {
  local dir fb rows out styled
  dir="$TMP_ROOT/box-dimglyph"; mkdir -p "$dir"
  fb=$(make_fake_tmux_box "$dir")
  rows="$dir/rows.txt"
  # A pristine composer box whose ❯/› input row glyph is de-emphasised - dim/faint
  # (claude) OR a dark/muted truecolor (grok's placeholder shape), with cursor_y on
  # the bottom rule. The re-anchor must detect the glyph off the ANSI-stripped
  # (ghost-KEPT) row: ghost-stripping the anchor row would drop the de-emphasised
  # glyph and miss the input row, keeping the rule verdict (pending) - the latent
  # gap this pins. It must read empty.
  for styled in '\033[2m\xe2\x9d\xaf\033[0m' '\033[38;2;50;47;70m\xe2\x80\xba\033[0m'; do
    {
      printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n'
      printf '%b \n' "$styled"
      printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n'
    } > "$rows"
    out=$(PATH="$fb:$PATH" FM_FAKE_ROWS="$rows" FM_FAKE_CY=3 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = empty ] \
      || fail "composer box with a de-emphasised input glyph ('$styled') must re-anchor and read empty, got '$out'"
  done
  pass "fm_tmux_composer_state: pristine composer box, de-emphasised input glyph, re-anchors empty"
}

test_rule_cursor_never_reanchors_onto_a_shell_prompt() {
  local dir fb rows out
  dir="$TMP_ROOT/box-shellnear"; mkdir -p "$dir"
  fb=$(make_fake_tmux_box "$dir")
  rows="$dir/rows.txt"
  # A pure rule on the cursor row (row 2) with a BARE shell prompt one row above
  # (row 1) and nothing agent-composer-shaped. Re-anchor is ❯/›-ONLY, so it must
  # NOT latch a shell prompt and force empty: the injector must never type into a
  # dead shell. The rule row itself carries no agent glyph, so the verdict stays
  # non-empty (the rule text reads pending) - a safe defer, not a forced inject.
  {
    printf '$ \n'
    printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n'
  } > "$rows"
  out=$(PATH="$fb:$PATH" FM_FAKE_ROWS="$rows" FM_FAKE_CY=2 \
    fm_tmux_composer_state "fakepane")
  [ "$out" != empty ] \
    || fail "rule cursor row near a bare shell prompt must NOT be forced empty, got '$out'"
  pass "fm_tmux_composer_state: a rule cursor row never re-anchors onto a bare shell prompt"
}

# --- fm-peek.sh stays escape-free (LLM-facing path) -------------------------

test_peek_output_is_escape_free() {
  local dir fb capture home out
  dir="$TMP_ROOT/peek"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # A pane full of styling, including dim ghost text. The plain peek path must
  # surface NONE of these escape codes into firstmate's context.
  printf 'normal output line\n\xe2\x9d\xaf \033[2mpredicted next prompt\033[0m\n' > "$capture"
  # Empty FM_HOME so fm-guard.sh finds no in-flight task and stays silent.
  home="$dir/home"; mkdir -p "$home/state"
  # Pass an explicit session:window so resolution needs no metadata.
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_FAKE_STYLED="$capture" \
        "$PEEK" "sess:win" 2>/dev/null)
  case "$out" in
    *"$ESC"*) fail "fm-peek surfaced ANSI escape codes into LLM-facing output" ;;
  esac
  # And it should still carry the real content.
  case "$out" in
    *"predicted next prompt"*) : ;;
    *) fail "fm-peek dropped pane content (expected the ghost text body as plain text)" ;;
  esac
  pass "fm-peek output is escape-free (no raw -e bytes reach firstmate context)"
}

test_strip_ghost_drops_dim_keeps_normal
test_strip_ghost_handles_combined_and_boundary_codes
test_strip_ghost_keeps_colored_text_with_2_payloads
test_strip_ghost_drops_dark_truecolor_ghost
test_dim_ghost_only_composer_is_not_pending
test_dim_ghost_inside_bordered_composer_is_not_pending
test_normal_text_still_pending
test_colored_text_with_2_payload_still_pending
test_dark_truecolor_ghost_only_composer_is_not_pending
test_dark_truecolor_bare_shell_prompt_is_unknown
test_real_text_with_trailing_ghost_is_pending
test_row_is_rule_recognizes_only_pure_rule_rows
test_pristine_composer_box_cursor_on_bottom_rule_is_empty
test_pristine_composer_box_cursor_on_input_row_is_empty
test_composer_box_with_real_text_stays_pending
test_pristine_composer_box_dim_glyph_reanchors_empty
test_rule_cursor_never_reanchors_onto_a_shell_prompt
test_peek_output_is_escape_free
