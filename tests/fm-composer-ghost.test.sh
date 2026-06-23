#!/usr/bin/env bash
# Ghost-text robustness (incident composer-robust).
#
# claude renders a predicted-next-prompt "suggestion" as DIM/FAINT (ANSI SGR 2)
# text inside an otherwise-empty composer. A plain pane capture cannot tell that
# ghost text apart from text a human typed, which made the composer reader see an
# idle pane as holding pending input. These tests pin two guarantees:
#   1. fm_tmux_strip_ghost drops dim/faint runs and keeps normal-intensity text.
#   2. fm_pane_input_pending reads a dim-ghost-only composer as NOT pending, while
#      still treating real (normal-intensity) text as pending.
#   3. The human/LLM-facing capture path (fm-peek.sh) stays PLAIN - no escape codes
#      ever reach firstmate's context.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/bin/fm-tmux-lib.sh"
PEEK="$ROOT/bin/fm-peek.sh"

# shellcheck source=bin/fm-tmux-lib.sh
. "$LIB"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-ghost-tests.XXXXXX")
cleanup() { [ -n "${TMP_ROOT:-}" ] && rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

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
  out=$(printf '\033[38;5;2mgreen typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "green typed" ] || fail "8-bit color payload 2 was treated as dim: '$out'"
  out=$(printf '\033[38;2;1;2;3mtruecolor typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "truecolor typed" ] || fail "truecolor payload 2 was treated as dim: '$out'"
  out=$(printf '\033[48;2;4;5;6mbackground typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "background typed" ] || fail "background truecolor payload was treated as dim: '$out'"
  out=$(printf '\033[58;5;2munderline-color typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "underline-color typed" ] || fail "underline color payload 2 was treated as dim: '$out'"
  out=$(printf '\033[38:2::1:2:3mcolon truecolor typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "colon truecolor typed" ] || fail "colon truecolor payload 2 was treated as dim: '$out'"
  out=$(printf '\033[58::5::2mcolon underline typed\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "colon underline typed" ] || fail "colon underline SGR leaked or dimmed text: '$out'"
  out=$(printf '\033[4:2mnot dim underline\033[0m\n' | fm_tmux_strip_ghost)
  [ "$out" = "not dim underline" ] || fail "colon subparameter 2 was treated as dim: '$out'"
  pass "fm_tmux_strip_ghost keeps colored text with 2 payloads"
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
  printf '\xe2\x9d\xaf \033[38;2;1;2;3mtruecolor typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "truecolor typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[58;5;2munderline-color typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "underline-colored typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[58::5::2mcolon underline typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fm_pane_input_pending "fakepane" \
    || fail "colon underline typed text was not detected as pending"
  pass "fm_pane_input_pending: colored text with 2 payloads is still pending"
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
test_dim_ghost_only_composer_is_not_pending
test_dim_ghost_inside_bordered_composer_is_not_pending
test_normal_text_still_pending
test_colored_text_with_2_payload_still_pending
test_real_text_with_trailing_ghost_is_pending
test_peek_output_is_escape_free
