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
#   3. The tmux reader structurally scans every row of a multi-row composer.
#   4. The human/LLM-facing capture path (fm-peek.sh) stays PLAIN - no escape codes
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
# from FM_FAKE_CY. The fake deliberately returns the complete fixture for every
# capture, which exercises the structural scan while preserving the historical
# single-row fallback fixtures.
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
    start= end= prev=
    for a in "$@"; do
      [ "$a" = "-e" ] && has_e=1
      case "$prev" in
        -S) start=$a ;;
        -E) end=$a ;;
      esac
      prev=$a
    done
    f="${FM_FAKE_STYLED:-/dev/null}"
    if [ -n "${FM_FAKE_ROW:-}" ] \
       && [ "$start" = "${FM_FAKE_CY:-0}" ] \
       && [ "$end" = "${FM_FAKE_CY:-0}" ]; then
      f=$FM_FAKE_ROW
    fi
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

# --- muse's composer sits closest to the ghost threshold ---------------------

# These are muse 0.1.0-R708.1's real captured composer rows. Its prompt glyph
# `⟩` is truecolor 38;2;90;160;255 (luminance ~149.9) and its typed text is
# 38;2;204;211;219 (~209.8), so the glyph clears the 128 default by the
# narrowest margin in the fleet - roughly a fifth of grok's real-input margin.
# Both must survive stripping: dropping the glyph would empty an idle composer's
# plain row, and dropping the typed text would read a pending pane as empty and
# make it an injection target.
test_strip_ghost_keeps_muse_composer_colors() {
  local out glyph
  glyph=$(printf '\xe2\x9f\xa9')
  out=$(printf '\033[0m\033[38;2;90;160;255m\xe2\x9f\xa9 \033[39m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '%s ' "$glyph")" ] \
    || fail "muse's idle composer glyph was stripped as ghost text: '$out'"
  # The submitted-prompt row carries a background colour too; an SGR 48 payload
  # must not be luminance-tested as if it were the foreground.
  out=$(printf '\033[38;2;90;160;255m\033[48;2;38;56;84m\xe2\x9f\xa9 \033[38;2;204;211;219mhello from firstmate\033[39m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '%s hello from firstmate' "$glyph")" ] \
    || fail "muse's typed text or background-coloured glyph row was stripped: '$out'"
  # The restored prompt muse puts back into the composer after an Escape
  # interrupt is real bright text and must stay visible as pending input.
  out=$(printf '\033[0m\033[38;2;90;160;255m\xe2\x9f\xa9 \033[38;2;204;211;219msecond turn to interrupt\033[39m\n' | fm_tmux_strip_ghost)
  [ "$out" = "$(printf '%s second turn to interrupt' "$glyph")" ] \
    || fail "muse's restored post-interrupt prompt was stripped as ghost text: '$out'"
  pass "fm_tmux_strip_ghost keeps muse's near-threshold glyph and its typed text"
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
  printf '╭─────────────────────────────────────╮\n│ \033[2mtry the other approach instead\033[0m      │\n╰─────────────────────────────────────╯\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
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

# --- fm_tmux_composer_state: structural multi-row box scan ------------------

test_two_row_composer_reads_text_above_empty_cursor_row() {
  local dir fb capture out
  dir="$TMP_ROOT/two-row"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  cat > "$capture" <<'EOF'
╭────────────────────────────────────────────────────╮
│ > Read the brief at /tmp/brief.md and follow it.   │
│                                                    │
╰────────────────────────────────────────────────────╯
EOF
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=2 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] \
    || fail "two-row composer text above the empty cursor row should be pending, got '$out'"
  pass "fm_tmux_composer_state: text above an empty cursor row is pending"
}

test_wrapped_composer_reads_all_content_rows() {
  local dir fb capture out
  dir="$TMP_ROOT/wrapped"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  cat > "$capture" <<'EOF'
╭────────────────────────────────────────────╮
│ > This deliberately long instruction wraps │
│ across a second composer content row and   │
│ across a third composer content row too.   │
│                                            │
╰────────────────────────────────────────────╯
EOF
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=4 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] \
    || fail "a three-row wrapped composer should be pending, got '$out'"
  pass "fm_tmux_composer_state: a message wrapped across three rows is pending"
}

test_proven_box_bottom_border_cursor_classifies_content() {
  local dir fb capture out
  dir="$TMP_ROOT/bottom-border-ghost"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '╭────────────────────────╮\n│ ❯ \033[38;2;50;47;70mType a message...\033[0m    │\n╰──────── Grok 4.5 ──────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=2 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] \
    || fail "a cursor on a proven titled box bottom must classify its content, got '$out'"
  pass "fm_tmux_composer_state: a proven titled box tolerates a bottom-border cursor"
}

test_copilot_half_box_requires_complete_rules() {
  local dir fb capture out
  dir="$TMP_ROOT/copilot-half-box"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"

  printf '╻▄▄▄▄▄▄▄▄▄▄▄▄\n┃\n╹▀▀▀▀▀▀▀▀▀▀▀▀\n' > "$capture"
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1' "$(cat "$capture")" 1 $'copilot\tpresent')
  [ "$out" = empty ] || fail "a complete identified Copilot half-box should be empty, got '$out'"

  printf '╻▄▄▄▄▄▄▄▄▄▄▄▄\n┃ fix login\n╹▀▀▀▀▀▀▀▀▀▀▀▀\n' > "$capture"
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1' "$(cat "$capture")" 1 $'copilot\tpresent')
  [ "$out" = pending ] || fail "Copilot half-box text should be pending, got '$out'"

  printf '╻▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄\n┃ Plan · release checklist\n╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\n' > "$capture"
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1' "$(cat "$capture")" 1 $'copilot\tpresent')
  [ "$out" = pending ] || fail "Copilot half-box content beginning with Plan must stay pending, got '$out'"

  printf '╻▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄\n┃ Build · release checklist\n╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀\n' > "$capture"
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1' "$(cat "$capture")" 1 $'copilot\tpresent')
  [ "$out" = pending ] || fail "Copilot half-box content beginning with Build must stay pending, got '$out'"

  printf '╻▄▄▄▄▄▄▄▄▄▄▄▄\n┃\n╹▀▀▀▀▀▀▀▀▀▀▀▀\n' > "$capture"
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1' "$(cat "$capture")" 1 probe-absent)
  [ "$out" = unknown ] || fail "an unidentified Copilot half-box must stay unknown, got '$out'"

  printf '┃\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] || fail "a lone blank left bar must stay unknown, got '$out'"

  printf '╻▄▄▄▄▄▄▄▄▄▄▄▄\n┃\n╹▀▀▀▀▀▀▀\n' > "$capture"
  out=$(fm_composer_classify_screen $'styled=1\ncursor=1\nidentity=1' "$(cat "$capture")" 1 $'copilot\tpresent')
  [ "$out" = unknown ] || fail "a width-mismatched Copilot half-box must stay unknown, got '$out'"
  pass "fm_tmux_composer_state: Copilot half-box emptiness requires complete width-matched rules"
}

test_copilot_cursorless_fallback_requires_identity() (
  local dir fb capture out
  dir="$TMP_ROOT/copilot-cursorless"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf 'menu row\n╻▄▄▄▄▄▄▄▄▄▄▄▄\n┃\n╹▀▀▀▀▀▀▀▀▀▀▀▀\nfooter row\n' > "$capture"

  # shellcheck disable=SC2329 # Mocks invoked indirectly by fm_tmux_composer_state.
  fm_tmux_pane_is_cursor() { return 1; }
  # shellcheck disable=SC2329 # Mock invoked indirectly by fm_tmux_composer_state.
  fm_tmux_pane_is_copilot() { return 0; }
  # shellcheck disable=SC2329 # Mock invoked indirectly by fm_tmux_composer_state.
  fm_tmux_composer_identity() { printf 'copilot\tpresent'; }
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] || fail "identified Copilot with an external cursor should read empty, got '$out'"

  # shellcheck disable=SC2329 # Replacement mock invoked indirectly.
  fm_tmux_composer_identity() { return 1; }
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] || fail "Copilot cursorless fallback without live identity should stay unknown, got '$out'"
  pass "fm_tmux_composer_state: Copilot cursorless fallback is gated on live identity"
)

test_pi_identity_requires_readable_busy_state() (
  local out
  # Keep the mocks in this subshell so they cannot affect later tests. Defining
  # functions directly inside a command substitution does not parse in Bash 3.2.
  # shellcheck disable=SC2329 # Mock invoked indirectly by the sourced adapter.
  tmux() {
    local arg
    for arg in "$@"; do
      case "$arg" in
        *pane_tty*) printf '\n'; return 0 ;;
        *pane_current_command*) printf 'pi\n'; return 0 ;;
      esac
    done
    return 1
  }
  # shellcheck disable=SC2329 # Mock invoked indirectly by the sourced adapter.
  fm_pane_busy_state() { printf 'unknown'; }
  if out=$(fm_tmux_composer_identity fakepane); then
    fail "a live Pi process with unreadable busy state must not produce identity, got '$out'"
  fi
  pass "fm_tmux_composer_identity: unknown busy state cannot become idle identity"
)

test_bordered_busy_signatures_are_pending() {
  local dir fb capture out signature
  dir="$TMP_ROOT/bordered-busy-signatures"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for signature in 'Working...' 'Ctrl+c:cancel'; do
    printf '╭────────────────────╮\n│ %-18s │\n╰────────────────────╯\n' "$signature" > "$capture"
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = pending ] \
      || fail "typed bordered busy signature '$signature' should be pending, got '$out'"
  done
  pass "fm_tmux_composer_state: typed Pi and Grok busy signatures inside a box are pending"
}

test_non_bordered_busy_footer_is_unknown_strict() {
  # STRICT divergence (captain decision blank-row-injection-posture): a bare
  # busy-footer row under the cursor is not a composer container, so it no
  # longer reads `empty` the way the old allow-busy compatibility fallback
  # did. Its one load-bearing consumer - submit confirmation on a harness
  # whose mid-turn screen hides the composer (pi) - moved to the submit
  # core's baseline-idle turn-started conversion (fm_tmux_submit_core), which
  # requires an idle-to-busy transition across our own Enter instead of
  # trusting any busy-looking row.
  local dir fb capture out
  dir="$TMP_ROOT/non-bordered-busy"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf 'Working...\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "a non-bordered busy footer must read unknown under the strict rule, got '$out'"
  pass "fm_tmux_composer_state: a bare busy-footer row reads unknown (strict container-proof rule)"
}

test_clipped_bordered_box_is_unknown() {
  local dir fb capture out
  dir="$TMP_ROOT/clipped-box"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '╭────────────────────╮\n│ >                  │\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "a bordered box with no readable bottom border should be unknown, got '$out'"
  pass "fm_tmux_composer_state: an unbounded bordered box fails closed as unknown"
}

test_asymmetric_composer_edges_are_unknown() {
  local dir fb capture out row
  dir="$TMP_ROOT/asymmetric-box"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for row in '│ > text' 'text │' '│ > text ┃' '──────' '+----' 'text +'; do
    printf '%s\n' "$row" > "$capture"
    out=$(PATH="$fb:$PATH" LC_ALL=C FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = unknown ] \
      || fail "unbounded composer-edge row '$row' should be unknown, got '$out'"
  done
  pass "fm_tmux_composer_state: clipped and asymmetric composer edges fail closed"
}

test_mismatched_box_families_are_unknown() {
  local dir fb capture out
  dir="$TMP_ROOT/mismatched-box"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '╭────────╮\n┃ >      ┃\n╰────────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "a box with mismatched border families should be unknown, got '$out'"
  pass "fm_tmux_composer_state: inconsistent box geometry fails closed"
}

test_misaligned_box_is_unknown() {
  local dir fb capture out fixture
  dir="$TMP_ROOT/misaligned-box"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for fixture in offset width; do
    case "$fixture" in
      offset) printf ' ╭────╮\n │    │\n╰────╯\n' > "$capture" ;;
      width) printf '╭────╮\n│     │\n╰────╯\n' > "$capture" ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = unknown ] \
      || fail "a box with inconsistent $fixture geometry should be unknown, got '$out'"
  done
  pass "fm_tmux_composer_state: misaligned box bounds fail closed"
}

test_unproved_empty_geometry_fails_closed() {
  local dir fb capture out fixture expected
  dir="$TMP_ROOT/unproved-empty-geometry"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for fixture in ghost idle malformed-top; do
    case "$fixture" in
      ghost)
        expected=unknown
        printf '╭────────────╮\n│ \033[2mghost\033[0m │\n╰────────────╯\n' > "$capture"
        out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
          fm_tmux_composer_state "fakepane")
        ;;
      idle)
        expected=pending-unproven
        printf '╭────────────╮\n│ idle hint │\n╰────────────╯\n' > "$capture"
        out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
          FM_COMPOSER_IDLE_RE='^idle hint$' fm_tmux_composer_state "fakepane")
        ;;
      malformed-top)
        expected=unknown
        printf '╭────x───────╮\n│            │\n╰────────────╯\n' > "$capture"
        out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
          fm_tmux_composer_state "fakepane")
        ;;
    esac
    [ "$out" = "$expected" ] \
      || fail "unproved geometry '$fixture' should be $expected, got '$out'"
  done
  pass "fm_tmux_composer_state: unproved ghost and malformed geometry stay unknown while styled placeholder-like text stays pending-unproven"
}

test_differing_widths_use_asymmetric_verdicts() {
  local dir fb capture out
  dir="$TMP_ROOT/differing-widths"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '╭──────────╮\n│ > text │\n╰──────────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending-unproven ] \
    || fail "text in a differing-width box should be pending-unproven, got '$out'"
  printf '╭──────────╮\n│        │\n╰──────────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = unknown ] \
    || fail "an empty differing-width box should be unknown, never empty, got '$out'"
  pass "fm_tmux_composer_state: differing widths prefer pending or unknown, never empty"
}

test_wide_composer_text_is_pending() {
  local dir fb capture out text
  dir="$TMP_ROOT/wide-text"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for text in '修复登录问题' 'fix the bug 🔧'; do
    printf '╭────────────────────╮\n│ > %s │\n╰────────────────────╯\n' "$text" > "$capture"
    out=$(PATH="$fb:$PATH" LC_ALL=C FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = pending-unproven ] \
      || fail "wide composer text '$text' should be pending-unproven, got '$out'"
  done
  pass "fm_tmux_composer_state: emoji and CJK text remain pending under the C locale"
}

test_all_tmux_harness_composers_share_classification() {
  local dir fb capture out harness
  dir="$TMP_ROOT/all-harness-composers"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for harness in claude codex opencode pi pi-signed grok; do
    case "$harness" in
      claude) printf '╭────────────╮\n│ ❯ \033[2mtry\033[0m      │\n╰────────────╯\n' > "$capture" ;;
      codex) printf '╭────────────╮\n│ › \033[2mtip\033[0m      │\n╰────────────╯\n' > "$capture" ;;
      opencode) printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$capture" ;;
      pi|pi-signed) printf '╭────────────╮\n│            │\n╰────────────╯\n' > "$capture" ;;
      grok) printf '╭────────────╮\n│ ❯ \033[38;2;50;47;70mType\033[0m     │\n╰────────────╯\n' > "$capture" ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = empty ] \
      || fail "$harness aligned idle composer should be empty, got '$out'"
    case "$harness" in
      claude|grok) printf '╭────────────╮\n│ ❯ fix      │\n╰────────────╯\n' > "$capture" ;;
      codex) printf '╭────────────╮\n│ › fix      │\n╰────────────╯\n' > "$capture" ;;
      opencode|pi|pi-signed) printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$capture" ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = pending ] \
      || fail "$harness composer with text should be pending, got '$out'"
  done
  pass "fm_tmux_composer_state: all tmux harnesses share empty and pending classification"
}

test_unrecognized_state_defers_input_guard() {
  (
    # shellcheck disable=SC2329
    fm_tmux_composer_state() { printf 'future-state'; }
    fm_pane_input_pending "fakepane"
  ) || fail "an unrecognized composer state should defer the input guard"
  pass "fm_pane_input_pending: unrecognized states defer by default"
}

test_single_capture_leaves_no_fallback_race() {
  # The old reader captured twice (a full-pane scan, then a separate
  # cursor-row band capture), so a pane redraw between the two could hand the
  # verdict a row the scan never saw. The consolidated reader classifies ONE
  # capture (bin/fm-composer-lib.sh, fm_composer_classify_screen), so the
  # race is structurally gone: a divergent band-capture row (served via
  # FM_FAKE_ROW, which only a band capture would read) must have no effect on
  # the verdict.
  local dir fb capture row_capture out
  dir="$TMP_ROOT/fallback-race"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  row_capture="$dir/row.txt"
  printf '› deploy staging\n' > "$capture"
  printf '│ > │\n' > "$row_capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_ROW="$row_capture" FM_FAKE_CY=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] \
    || fail "the verdict must come from the one full capture (agent glyph + typed text = pending), got '$out'"
  pass "fm_tmux_composer_state: one capture feeds the classifier; no band-capture race remains"
}

test_absent_tmux_identity_keeps_enclosed_bare_verdict() {
  local dir fb capture out nbsp
  dir="$TMP_ROOT/absent-identity"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  nbsp=$(printf '\302\240')
  printf '────────────────────────\n❯%s\n────────────────────────\n' "$nbsp" > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = empty ] \
    || fail "an enclosed Claude glyph must keep its bare empty verdict when the Pi-only probe is absent, got '$out'"
  pass "fm_tmux_composer_state: absent Pi identity preserves Claude's enclosed bare verdict"
}

test_legitimate_empty_routes_remain_empty() {
  local dir fb capture out fixture cursor
  dir="$TMP_ROOT/legitimate-empty"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  # A blank pane is deliberately absent here: under the strict container-proof
  # rule (captain decision blank-row-injection-posture) a blank cursor row is
  # unknown, pinned by tests/fm-daemon.test.sh and tests/fm-composer-lib.test.sh.
  for fixture in bordered double-bordered agent-prompt; do
    case "$fixture" in
      bordered) printf '╭────╮\n│    │\n╰────╯\n' > "$capture"; cursor=1 ;;
      double-bordered) printf '╔════╗\n║    ║\n╚════╝\n' > "$capture"; cursor=1 ;;
      agent-prompt) printf '›\n' > "$capture"; cursor=0 ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY="$cursor" \
      fm_tmux_composer_state "fakepane")
    [ "$out" = empty ] \
      || fail "legitimate empty route '$fixture' should remain empty, got '$out'"
  done
  pass "fm_tmux_composer_state: only proven structural and non-bordered empty routes stay empty"
}

test_non_bordered_composer_uses_compatibility_fallback() {
  local dir fb capture out
  dir="$TMP_ROOT/non-bordered-fallback"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  printf '› deploy staging\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_tmux_composer_state "fakepane")
  [ "$out" = pending ] \
    || fail "a non-bordered composer should retain cursor-row classification, got '$out'"
  pass "fm_tmux_composer_state: panes without bordered structure retain compatibility fallback"
}

test_non_bordered_interior_edges_are_pending() {
  local dir fb capture out row
  dir="$TMP_ROOT/non-bordered-interior-edges"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  capture="$dir/styled.txt"
  for row in '› cat file | grep x' '› explain │ this glyph'; do
    printf '%s\n' "$row" > "$capture"
    out=$(PATH="$fb:$PATH" LC_ALL=C FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
      fm_tmux_composer_state "fakepane")
    [ "$out" = pending ] \
      || fail "non-bordered interior edge row '$row' should be pending, got '$out'"
  done
  pass "fm_tmux_composer_state: interior edge glyphs retain non-bordered fallback"
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
test_strip_ghost_keeps_muse_composer_colors
test_dim_ghost_only_composer_is_not_pending
test_dim_ghost_inside_bordered_composer_is_not_pending
test_normal_text_still_pending
test_colored_text_with_2_payload_still_pending
test_dark_truecolor_ghost_only_composer_is_not_pending
test_dark_truecolor_bare_shell_prompt_is_unknown
test_real_text_with_trailing_ghost_is_pending
test_two_row_composer_reads_text_above_empty_cursor_row
test_wrapped_composer_reads_all_content_rows
test_proven_box_bottom_border_cursor_classifies_content
test_copilot_half_box_requires_complete_rules
test_copilot_cursorless_fallback_requires_identity
test_pi_identity_requires_readable_busy_state
test_bordered_busy_signatures_are_pending
test_non_bordered_busy_footer_is_unknown_strict
test_clipped_bordered_box_is_unknown
test_asymmetric_composer_edges_are_unknown
test_mismatched_box_families_are_unknown
test_misaligned_box_is_unknown
test_unproved_empty_geometry_fails_closed
test_differing_widths_use_asymmetric_verdicts
test_wide_composer_text_is_pending
test_all_tmux_harness_composers_share_classification
test_unrecognized_state_defers_input_guard
test_single_capture_leaves_no_fallback_race
test_absent_tmux_identity_keeps_enclosed_bare_verdict
test_legitimate_empty_routes_remain_empty
test_non_bordered_composer_uses_compatibility_fallback
test_non_bordered_interior_edges_are_pending
test_peek_output_is_escape_free
