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
#   3. The AGENT prompt glyphs `❯` (claude), `›` (codex), `⟩` (muse), and `→`
#      (cursor) are a genuine empty agent composer either way, bordered or bare.
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
  # muse draws `⟩` at luminance ~150, the tightest margin over the 128 ghost
  # threshold in the fleet, so a raised threshold really can strip it to empty
  # and leave only the plain row. This branch is what keeps that pane readable.
  for plain in '❯' '›' '⟩'; do
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
  out=$(classify 0 '⟩'); [ "$out" = empty ] || fail "bare muse '⟩' should read empty, got '$out'"
  out=$(classify 1 '⟩'); [ "$out" = empty ] || fail "bordered muse '⟩' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex, ⟩ muse) read empty bordered or bare"
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
  out=$(classify 1 'Type a message...' "$idle" sensitive 'Type a message...' 1 1)
  [ "$out" = pending ] || fail "placeholder-like text surviving a styled box capture should read pending, got '$out'"
  out=$(classify 1 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 1 0)
  [ "$out" = empty ] || fail "a glyph-bearing plain box placeholder should read empty, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 1)
  [ "$out" = pending ] || fail "placeholder text on a styled bare input row must be pending, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 0)
  [ "$out" = unknown ] || fail "placeholder text on a plain bare input row must be unknown, got '$out'"
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: idle matching is limited to proven placeholder positions"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle" sensitive 'type a message...' 1 0)
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive 'type a message...' 1 0)
  [ "$out" = empty ] || fail "an explicitly insensitive plain placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # muse restores the interrupted prompt into its composer after Escape, as real
  # bright text. Reading that as pending is correct - it really is unsubmitted.
  out=$(classify 0 '⟩ second turn to interrupt'); [ "$out" = pending ] || fail "bare '⟩ <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# =============================================================================
# fm_composer_classify_screen: the adapter-facing screen classifier and the
# correctness matrix (audit data/fm-composer-consolidation-audit-s1, task
# fm-composer-thin-adapter-refactor-r1).
#
# Fixtures are the audit's byte-level captures of six REAL idle harnesses:
# claude 2.1.226 (bare `❯` + U+00A0 NO-BREAK SPACE), codex 0.146.0 (bold `›`
# + SGR-2 dim hint), codex 0.154.0 (the same `›` amid a braille starfield over
# a status footer, captured through Herdr on 2026-09-15), muse (truecolor `⟩`, 38;2;90;160;255), pi (blank row
# between solid `─` rules), opencode 1.14.46 (left-bar `┃` rows), and grok
# 1.0.0 (bordered box with a TITLED bottom border), plus claude captured
# inside zellij through `dump-screen --ansi` (`ESC[m` `❯` U+00A0).
#
# Capability profiles mirror the real adapters' descriptors: tmux
# (styled+cursor+identity), herdr/zellij (styled), cmux/orca (plain). Every
# emptiness verdict is asserted under the ambient UTF-8 locale AND LC_ALL=C,
# pinning the locale-safe Unicode-space normalization (issue #1988).
# =============================================================================

ESC=$(printf '\033')
NBSP=$(printf '\302\240')
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'      # herdr
CAPS_STYLED_NOID=$'styled=1\ncursor=0\nidentity=0\nrows=20' # zellij
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'       # cmux, orca

# assert_screen <label> <want> <caps> <screen> [cursor] [identity]: one
# verdict, asserted under the ambient locale AND LC_ALL=C.
assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

test_matrix_claude_bare_nbsp_row() {
  # Real idle claude: `❯` + U+00A0, borderless, between horizontal rules.
  # The audit's headline defect: this row read `pending` under LC_ALL=C
  # (issue #1988), deferring every away-mode escalation in daemon contexts.
  local screen typed
  screen=$'transcript line\n────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n  bypass permissions'
  assert_screen "claude idle on tmux" empty "$CAPS_TMUX" "$screen" 2 probe-absent
  assert_screen "claude idle on herdr" empty "$CAPS_STYLED" "$screen" '' probe-absent
  assert_screen "claude idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  typed=$'────────────────────────\n❯ fix the login bug\n────────────────────────'
  assert_screen "claude typed on tmux" pending "$CAPS_TMUX" "$typed" 1 probe-absent
  # Plain capture cannot tell typed text from claude's rotating suggestion:
  # the styled=0 degradation defers instead of fabricating pending.
  assert_screen "claude typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  pass "matrix: claude's ❯+NBSP row reads empty on every profile in both locales (#1988)"
}

test_matrix_codex_dim_hint_row() {
  # Real idle codex: bold `›`, reset, then an SGR-2 dim hint. Styled captures
  # strip the ghost and prove empty; plain captures must defer as unknown -
  # NEVER the old false `pending` that read the hint as unsent text.
  local styled plain
  styled=$'banner\n'"${ESC}[1m›${ESC}[0m ${ESC}[2mUse /skills to list available skills${ESC}[0m"
  plain=$'banner\n› Use /skills to list available skills'
  assert_screen "codex idle on tmux" empty "$CAPS_TMUX" "$styled" 1
  assert_screen "codex idle on herdr" empty "$CAPS_STYLED" "$styled"
  assert_screen "codex idle on zellij" empty "$CAPS_STYLED_NOID" "$styled"
  assert_screen "codex idle on plain backends" unknown "$CAPS_PLAIN" "$plain"
  pass "matrix: codex's dim hint is empty when styling proves it, unknown (never pending) when it cannot"
}

test_matrix_muse_truecolor_glyph_survives_signal_loss() {
  # Real idle muse: truecolor `⟩` (38;2;90;160;255, luminance ~149.9) under a
  # TITLED rule. Two independent signals prove emptiness: the glyph surviving
  # the ghost strip, and the UNSTRIPPED plain row carrying an agent glyph.
  # Drive them apart: with the luma threshold raised past the glyph's
  # luminance, the ghost strip erases it, and the verdict must survive on the
  # plain-row signal alone.
  local screen plain out
  screen=$'── Voice input (⌥ + v to start) ─────\n'"${ESC}[0m${ESC}[38;2;90;160;255m⟩${ESC}[0m"
  plain=$'── Voice input (⌥ + v to start) ─────\n⟩'
  assert_screen "muse idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "muse idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "muse idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "muse idle on cmux/orca" empty "$CAPS_PLAIN" "$plain"
  out=$(FM_COMPOSER_GHOST_LUMA_MAX=200 fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] || fail "muse must stay empty when the ghost strip eats its glyph (plain-row signal), got '$out'"
  pass "matrix: muse's ⟩ reads empty everywhere and survives losing the styled-glyph signal"
}

test_matrix_cursor_reverse_video_placeholder_remnant() {
  # Real idle cursor-agent (2026.08.11-e8db854), captured byte-for-byte from a
  # live pane: the `→ ` glyph and the placeholder tail are dim (SGR 2), but the
  # cell under the terminal cursor is REVERSE VIDEO (SGR 0;7). Reverse video is
  # neither dim nor a dark foreground, so the ghost stripper keeps that one
  # character and an idle composer reduces to a lone `P`.
  local row screen plain out stripped
  row="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0;7m${ESC}[48;2;21;21;21mP"
  row="${row}${ESC}[0;2m${ESC}[48;2;21;21;21mlan, search, build anything${ESC}[0m"
  screen=$'transcript\n\n'"$row"
  plain=$'transcript\n\n  → Plan, search, build anything'

  # NON-VACUOUSNESS: prove the remnant really survives stripping. If the ghost
  # stripper ever learned SGR 7, `stripped` would be empty and the verdict below
  # would come from the empty-content path instead, silently retiring the
  # plain-row branch this case exists to cover.
  stripped=$(printf '%s' "$row" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = P ] \
    || fail "cursor's reverse-video remnant must survive ghost stripping as 'P', got '$stripped'"

  assert_screen "cursor idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "cursor idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  # An UNSTYLED capture carries no ghost-strip proof, so a bare row matching a
  # placeholder is indistinguishable from typed text and must stay unknown -
  # the same degradation every other bare-row placeholder already takes.
  assert_screen "cursor idle on cmux/orca" unknown "$CAPS_PLAIN" "$plain"

  # The dangerous direction: text a user actually TYPED is uniformly bright, so
  # stripping leaves it EQUAL to the plain row. Even when that text is exactly
  # the placeholder, it must stay pending - never a false empty.
  local typed typed_plain
  typed="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0m${ESC}[38;2;224;222;244mAdd a follow-up${ESC}[0m"
  typed_plain=$'transcript\n\n  → Add a follow-up'
  assert_screen "cursor typed placeholder text stays pending" pending \
    "$CAPS_STYLED" $'transcript\n\n'"$typed"
  # Without styling there is no proof either way, so it must not read empty.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$typed_plain")
  [ "$out" != empty ] \
    || fail "an unstyled cursor row matching the placeholder must not read empty, got '$out'"
  pass "matrix: cursor's reverse-video placeholder remnant reads empty; real typed text stays pending"
}

test_matrix_herdr_halfblock_rule_bounds_bare_wrap() {
  # Herdr draws a composer's rules with half-block glyphs (▄ above, ▀ below)
  # rather than the box-drawing family. Without treating those as edges, a bare
  # composer's WRAP region walks through its own closing rule and swallows the
  # footer, whose real content turns an idle pane into a false `pending`.
  # Captured live from a herdr cursor pane.
  local screen plain out
  plain=$'transcript\n ▄▄▄▄▄▄▄▄\n  → Add a follow-up\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  # The closing rule must bound the region, so the footer below is not input.
  fm_composer_row_has_edge ' ▀▀▀' \
    || fail "a half-block rule row must count as a structural edge"
  fm_composer_row_has_edge ' ▄▄▄' \
    || fail "the upper half-block rule must count as a structural edge"
  # Non-vacuousness: the footer rows really are non-blank content that would be
  # swallowed if the rule did not bound the region.
  case "$plain" in *"Run Everything"*) : ;; *) fail "fixture lost its footer content" ;; esac
  ESC_LOCAL=$(printf '\033')
  screen=$'transcript\n ▄▄▄▄▄▄▄▄\n'"  ${ESC_LOCAL}[2m→ ${ESC_LOCAL}[0;7mA${ESC_LOCAL}[0;2mdd a follow-up${ESC_LOCAL}[0m"$'\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] \
    || fail "an idle cursor composer inside herdr half-block rules must read empty, got '$out'"
  pass "matrix: herdr half-block rules bound a bare composer's wrap region"
}

test_matrix_omp_status_row_bounds_bare_composer() {
  # omp (Oh My Pi) draws its status line directly BELOW the borderless `❯`
  # composer. Captured live through Herdr on omp 18.1.11 under the captain's
  # unicode preset (idle), plus the nerd-preset idle row and the busy spinner
  # row from the 18.1.2 investigation. Without the status-row rule the bare
  # wrap region swallows that row and an idle omp pane reads `pending`, which
  # skipped the doorbell on the first live omp worker.
  local idle_unicode idle_nerd busy typed wrapped
  idle_unicode=$'transcript line

❯
 π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  idle_nerd=$'transcript line

❯
 󰵗  ·  qwen3:8b ·  kun-agent-workspace/… ·  detached ?1 ·  36.7%/41K'
  busy=$'transcript line

  ⎋ Working…

❯
 ⠧ 11s  · ◔ GPT-6-Astra · ◫ 15.4%/272K'
  typed=$'transcript line

❯ fix the flaky test
 π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  # Non-vacuousness: each status row is real non-blank content that the wrap
  # region would otherwise take as typed input.
  _fm_composer_row_is_omp_status ' π  · ◔ GPT-6-Astra · 🌳 …-workspace' \
    || fail "the unicode-preset omp status row must be recognized as furniture"
  _fm_composer_row_is_omp_status ' 󰵗  ·  qwen3:8b ·  kun-agent-workspace/… ·  detached ?1 ·  36.7%/41K' \
    || fail "the nerd-preset omp status row must be recognized as furniture"
  _fm_composer_row_is_omp_status ' ⠧ 11s  · ◔ GPT-6-Astra' \
    || fail "the busy omp spinner row must be recognized as furniture"
  _fm_composer_row_is_omp_status 'fix the flaky test' \
    && fail "ordinary typed text must not be mistaken for omp status furniture"
  _fm_composer_row_is_omp_status 'please rerun the suite and report' \
    && fail "ordinary prose must not be mistaken for omp status furniture"
  # Only omp's identity cell opens the row: a wrapped typed row that happens
  # to begin with a short word and a spaced middle dot is composer input.
  _fm_composer_row_is_omp_status 'fix · tests before pushing' \
    && fail "wrapped typed text with a middle dot must not be mistaken for omp status furniture"
  # The ascii preset's identity cell is `pi`, but that preset separates its
  # cells with ` - `, so a row opening `pi ·` is never omp furniture.
  _fm_composer_row_is_omp_status 'pi · e · phi as the three constants' \
    && fail "typed text opening 'pi ·' must not be mistaken for omp status furniture"
  _fm_composer_row_is_omp_status ' ⣾ 3s  · ◔ GPT-6-Astra' \
    || fail "the status-set omp spinner row must be recognized as furniture"
  assert_screen "idle omp (unicode preset)" empty "$CAPS_STYLED" "$idle_unicode"
  assert_screen "idle omp (nerd preset)" empty "$CAPS_STYLED" "$idle_nerd"
  assert_screen "busy omp keeps an empty composer" empty "$CAPS_STYLED" "$busy"
  assert_screen "typed omp text is pending" pending "$CAPS_STYLED" "$typed"
  assert_screen "idle omp on a plain capture" empty "$CAPS_PLAIN" "$idle_unicode"
  # The boundary must not cut a bare composer's own wrapped input: with the
  # cursor on a continuation row that opens `fix · tests`, the composer is a
  # proven wrap region and reads pending, exactly as it did before the rule.
  wrapped=$'transcript line\n\n❯ please run the suite and then\nfix · tests before pushing'
  assert_screen "wrapped typed text with a middle dot stays pending" pending "$CAPS_TMUX" "$wrapped" 3
  wrapped=$'transcript line\n\n❯ document the constants in the order\npi · e · phi with one example each'
  assert_screen "wrapped typed text opening 'pi ·' stays pending" pending "$CAPS_TMUX" "$wrapped" 3
  pass "matrix: omp's status row bounds the bare composer's wrap region"
}

# codex_cell <grey> <glyph>: one codex 0.154 starfield cell exactly as the
# harness draws it - a truecolor grey foreground, the composer's grey
# background, the braille glyph, then a reset.
codex_cell() {
  printf '%s[38;2;%s;%s;%sm%s[48;2;57;57;57m%s%s[0m' "$ESC" "$1" "$1" "$1" "$ESC" "$2" "$ESC"
}

test_matrix_codex_idle_starfield_furniture() {
  # Real idle codex-cli 0.154.0 (gpt-6-astra, fast mode) captured byte-for-byte
  # through Herdr (`pane read --format ansi`) from the first codex second mate:
  # an animated braille "starfield" on the row above the bold `›`, on the `›`
  # row behind the SGR-2 dim `Ask Codex to do anything` placeholder, and on
  # the row below, then a bright model/path/title status footer. The cells are
  # truecolor greys on BOTH sides of the 128 ghost-luma ceiling, so the
  # brighter ones survive the ghost strip, and the rows below the glyph carry
  # no structural edge. The bare shape therefore extended its wrap region over
  # the two rows beneath the glyph and read the survivors as wrapped typed
  # input: `pending`, which deferred every steering doorbell for that pane.
  local bg="${ESC}[48;2;57;57;57m" above glyph glyph2 below footer
  local screen screen2 plain plain2 ascii_screen stripped out
  above="${ESC}[0m${bg}                         ${ESC}[0m$(codex_cell 82 ⢀)${bg}      ${ESC}[0m$(codex_cell 136 ⠂)${bg} ${ESC}[0m$(codex_cell 163 ⠄)${bg}     ${ESC}[0m$(codex_cell 118 ⠈)"
  glyph="${ESC}[0m${ESC}[1m${bg}›${ESC}[0m${bg} ${ESC}[0m${ESC}[2m${bg}Ask Codex to do anything${ESC}[0m$(codex_cell 117 ⡀)${bg}  ${ESC}[0m$(codex_cell 88 ⠈)${bg}       ${ESC}[0m$(codex_cell 156 ⠂)${bg}        ${ESC}[0m$(codex_cell 71 ⠁)$(codex_cell 161 ⠐)${bg} ${ESC}[0m$(codex_cell 165 ⠁)"
  # A second live sample of the same pane, minutes later: the animation had
  # placed a bright cell BETWEEN the glyph and the placeholder.
  glyph2="${ESC}[0m${ESC}[1m${bg}›${ESC}[0m$(codex_cell 138 ⠁)${ESC}[2m${bg}Ask Codex to do anything${ESC}[0m$(codex_cell 163 ⡀)${bg}  ${ESC}[0m$(codex_cell 132 ⠈)"
  below="${ESC}[0m${bg}        ${ESC}[0m$(codex_cell 101 ⠐)${bg}    ${ESC}[0m$(codex_cell 111 ⠄)${bg}   ${ESC}[0m$(codex_cell 165 ⠠)${bg}  ${ESC}[0m$(codex_cell 121 ⢀)$(codex_cell 122 ⠠)$(codex_cell 81 ⡀)$(codex_cell 150 ⠄⠂)"
  footer="  ${ESC}[0m${ESC}[38;2;246;226;183mgpt-6-astra high fast${ESC}[0m${ESC}[2m · ${ESC}[0m${ESC}[38;2;171;223;167m~/Projects/purser${ESC}[0m${ESC}[2m · ${ESC}[0m${ESC}[38;2;156;222;211mLaunch Purser desk brief${ESC}[0m"
  screen=$'transcript line\n\n'"$above"$'\n'"$glyph"$'\n'"$below"$'\n'"$footer"
  screen2=$'transcript line\n\n'"$above"$'\n'"$glyph2"$'\n'"$below"$'\n'"$footer"
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  plain2=$(printf '%s\n' "$screen2" | fm_composer_strip_ansi)

  # NON-VACUOUSNESS: the ghost strip really leaves braille survivors behind the
  # placeholder and on the row below (cells above the luma ceiling), and the
  # footer really is non-blank, edge-free content the wrap region would take.
  stripped=$(printf '%s\n' "$glyph" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" != '›' ] \
    || fail "the glyph row's starfield cells must survive ghost stripping, or the furniture case is vacuous"
  stripped=$(printf '%s\n' "$stripped" | fm_composer_strip_braille)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = '›' ] \
    || fail "everything surviving ghost stripping behind the glyph must be braille, got '$stripped'"
  stripped=$(printf '%s\n' "$below" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ -n "$stripped" ] \
    || fail "the row below the glyph must keep starfield cells after ghost stripping"
  _fm_composer_row_is_braille_furniture "$stripped" \
    || fail "the row below the glyph must be recognized as braille furniture"
  fm_composer_row_has_edge '  gpt-6-astra high fast · ~/Projects/purser · Launch Purser desk brief' \
    && fail "fixture drift: the footer must carry no structural edge, or the boundary rule is untested"

  # The verdicts: empty wherever styling can prove the placeholder ghost, on
  # both live samples, in both locales; unknown (never pending) on a plain
  # capture, exactly as the codex dim-hint row above.
  assert_screen "codex 0.154 idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "codex 0.154 idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "codex 0.154 idle on tmux (cursor on the glyph row)" empty "$CAPS_TMUX" "$screen" 3
  assert_screen "codex 0.154 idle on cmux/orca" unknown "$CAPS_PLAIN" "$plain"
  assert_screen "codex 0.154 idle (second sample) on herdr" empty "$CAPS_STYLED" "$screen2"
  assert_screen "codex 0.154 idle (second sample) on tmux" empty "$CAPS_TMUX" "$screen2" 3
  assert_screen "codex 0.154 idle (second sample) on cmux/orca" unknown "$CAPS_PLAIN" "$plain2"
  # A cursor parked on the starfield row below the glyph is not inside a wrap
  # region, so the strict blank-row posture keeps it unknown.
  assert_screen "codex 0.154 cursor on the starfield row" unknown "$CAPS_TMUX" "$screen" 4

  # DIVERGENCE: the same screen with every starfield cell replaced by a letter
  # is wrapped typed input and must stay pending, so the furniture verdict
  # above cannot come from anything but the braille rule.
  ascii_screen=$(printf '%s\n' "$screen" | LC_ALL=C sed 's/⢀/x/g; s/⠂/x/g; s/⠄/x/g; s/⠈/x/g; s/⡀/x/g; s/⠁/x/g; s/⠐/x/g; s/⠠/x/g')
  case "$ascii_screen" in *'⠂'*|*'⠁'*) fail "fixture drift: the divergence screen still carries braille" ;; esac
  assert_screen "starfield replaced by letters on herdr" pending "$CAPS_STYLED" "$ascii_screen"
  assert_screen "starfield replaced by letters on tmux" pending "$CAPS_TMUX" "$ascii_screen" 3

  # NEGATIVES that keep the rule from over-stripping:
  # (i) a real message wrapped below the `›` row, footer beneath, stays pending.
  out=$'transcript line\n\n› please run the suite and then\ncontinue with the docs\n'"$footer"
  assert_screen "wrapped typed input above the codex footer on herdr" pending "$CAPS_STYLED" "$out"
  assert_screen "wrapped typed input above the codex footer on tmux" pending "$CAPS_TMUX" "$out" 3
  # (ii) braille mixed with typed text is typed text, on the glyph row and on
  # a wrapped row alike.
  assert_screen "braille mixed into the glyph row" pending "$CAPS_STYLED" $'transcript line\n\n› fix ⠂ the tests'
  assert_screen "braille mixed into a wrapped row" pending "$CAPS_STYLED" $'transcript line\n\n› please\nfix ⠂ the tests'
  # (iii) a typed row carrying a spaced middle dot is composer input.
  assert_screen "wrapped typed row with a middle dot on herdr" pending "$CAPS_STYLED" $'transcript line\n\n› deploy\nfix · tests before pushing'
  assert_screen "wrapped typed row with a middle dot on tmux" pending "$CAPS_TMUX" $'transcript line\n\n› deploy\nfix · tests before pushing' 3
  # (iv) the footer or a starfield row alone, with no bare glyph above, gains
  # no new verdict: still no container proof.
  assert_screen "codex footer alone on herdr" unknown "$CAPS_STYLED" $'transcript line\n\n'"$footer"
  assert_screen "codex footer alone on tmux" unknown "$CAPS_TMUX" $'transcript line\n\n'"$footer" 2
  assert_screen "starfield row alone on herdr" unknown "$CAPS_STYLED" $'transcript line\n\n'"$below"
  pass "matrix: codex 0.154's starfield rows are furniture; typed, mixed, and unanchored rows keep their verdicts"
}

test_matrix_pi_separated_needs_identity() {
  # Real idle pi: a blank row between two solid rules. The blank row alone is
  # exactly what the strict rule refuses; only structure PLUS a live
  # idle/done pi identity proves the composer (herdr's rule, now
  # fleet-wide; tmux supplies identity from its foreground-process probe).
  local screen typed pi_idle pi_working pi_blocked none
  screen=$'transcript\n────────────────────────\n\n────────────────────────\n footer'
  pi_idle=$(printf 'pi\tidle'); pi_working=$(printf 'pi\tworking'); none=$(printf 'zsh\t')
  pi_blocked=$(printf 'pi\tblocked')
  assert_screen "pi idle with identity" empty "$CAPS_STYLED" "$screen" '' "$pi_idle"
  assert_screen "pi idle on tmux with identity" empty "$CAPS_TMUX" "$screen" 2 "$pi_idle"
  assert_screen "pi idle on zellij" unknown "$CAPS_STYLED_NOID" "$screen"
  # Identity-capable but unfetched: the adapter is asked to probe lazily.
  [ "$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")" = need-identity ] \
    || fail "an identity-capable profile should request the lazy identity probe"
  # No identity capability (cmux/orca/zellij): the shape is unprovable.
  assert_screen "pi pair without identity capability" unknown "$CAPS_PLAIN" "$screen"
  # A working pi cannot authorize injection into the blank region.
  assert_screen "working pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_working"
  # A pi parked on an interactive prompt reports `blocked`: it is waiting on a
  # human keystroke, so the blank region is a menu's, not a free composer's.
  # Typing there answers the prompt and the text is discarded (issue #2797).
  assert_screen "blocked pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_blocked"
  # The audit's live counterexample: a plain shell running sleep, cursor
  # parked on a blank line between two rules, NO pi process. The permissive
  # rule read this `empty`; identity+structure refuses it.
  assert_screen "sleep-pane counterexample" unknown "$CAPS_TMUX" "$screen" 2 "$none"
  assert_screen "absent identity cannot prove blank pi pair" unknown "$CAPS_TMUX" "$screen" 2 probe-absent
  typed=$'────────────────────────\nfix the flaky test\n────────────────────────'
  assert_screen "pi typed" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  typed=$'────────────────────────\n❯\n────────────────────────'
  assert_screen "pi lone-glyph draft with identity" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  assert_screen "pi lone-glyph draft on tmux" pending "$CAPS_TMUX" "$typed" 1 "$pi_idle"
  assert_screen "lone glyph without identity capability" empty "$CAPS_STYLED_NOID" "$typed"
  assert_screen "lone glyph on plain backend" empty "$CAPS_PLAIN" "$typed"
  assert_screen "lone glyph with non-pi identity" empty "$CAPS_STYLED" "$typed" '' "$none"
  pass "matrix: pi's separated composer needs identity + structure; the blank row alone never proves it"
}

test_matrix_opencode_leftbar_signals() {
  # Real idle opencode: `┃`-prefixed rows holding an "Ask anything" hint,
  # blanks, and a Build-mode footer. Two independent idle signals: the shared
  # idle-placeholder pattern (works on plain captures) and the ghost strip
  # (works on styled captures even if the pattern is overridden away).
  local screen typed dim_screen captured_idle captured_pending out
  screen=$'  ┃\n  ┃  Ask anything... "What is the tech stack?"\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
  dim_screen=$'  ┃\n  ┃  '"${ESC}[2mAsk anything...${ESC}[0m"$'\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀'
  assert_screen "opencode idle on tmux (cursor on hint)" empty "$CAPS_TMUX" "$dim_screen" 1
  assert_screen "opencode idle on herdr" empty "$CAPS_STYLED" "$dim_screen"
  assert_screen "opencode idle on zellij" empty "$CAPS_STYLED_NOID" "$dim_screen"
  assert_screen "opencode idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  # This sanitized live OpenCode 1.18.30 capture preserves its U+2026 hint and
  # RGB 128 styling. RGB 128 is deliberately outside the ghost threshold, so
  # the placeholder spelling is the independent empty signal. The completed-
  # turn row above the active composer also pins the incident's idle layout.
  captured_idle=$'  ▣ Build · Big Pickle · 3.4s\n\n  ┃\n  ┃  '"${ESC}[38;2;128;128;128mAsk anything… \"Fix a TODO in the codebase\"${ESC}[38;2;255;255;255m"$'\n  ┃\n  ┃  Build · Big Pickle OpenCode Zen\n  ╹▀▀▀▀▀▀▀▀'
  assert_screen "opencode 1.18.30 completed-turn idle hint on tmux" empty "$CAPS_TMUX" "$captured_idle" 3
  captured_pending=$'  ▣ Build · Big Pickle · 3.4s\n\n  ┃\n  ┃  '"${ESC}[38;2;255;255;255mReply with OK.${ESC}[38;2;255;255;255m"$'\n  ┃\n  ┃  Build · Big Pickle OpenCode Zen\n  ╹▀▀▀▀▀▀▀▀'
  assert_screen "opencode 1.18.30 completed-turn typed composer on tmux" pending "$CAPS_TMUX" "$captured_pending" 3
  # Signal separation: with the idle pattern overridden to something that
  # cannot match, a DIM-styled hint still proves empty through the ghost strip.
  out=$(FM_COMPOSER_IDLE_RE='^NEVER-MATCHES$' fm_composer_classify_screen "$CAPS_TMUX" "$dim_screen" 1)
  [ "$out" = empty ] || fail "a dim opencode hint must stay empty via the ghost strip alone, got '$out'"
  typed=$'┃\n┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "opencode typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  Ask anything... please investigate\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode placeholder-like input on tmux" pending "$CAPS_TMUX" "$typed" 0
  assert_screen "opencode placeholder-like input on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high'
  assert_screen "opencode multiline draft above blank cursor row" pending "$CAPS_TMUX" "$typed" 1
  pass "matrix: opencode's left-bar composer reads empty everywhere and scans the full active run"
}

test_matrix_grok_titled_bottom_border() {
  # Grok 1.0.5 widened its titled BOTTOM border three columns past the top and
  # content rows. This is the idle capture from issue #3436; Herdr has no
  # cursor anchor, so the geometry mismatch used to make the proven box
  # ambiguous and the verdict unknown, stranding away-mode injection.
  local titled plain_border typed malformed placeholder_draft
  titled=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯                                                                        │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯\n\n  Shift+Tab:mode  │  Ctrl+x:shortcuts'
  plain_border=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────────────────────────╯'
  assert_screen "grok titled on tmux" empty "$CAPS_TMUX" "$titled" 1
  assert_screen "grok titled on tmux bottom-border cursor" empty "$CAPS_TMUX" "$titled" 2
  assert_screen "issue #3436 idle grok 1.0.5 on herdr" empty "$CAPS_STYLED" "$titled"
  placeholder_draft=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯ Type a message...                                                      │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯'
  assert_screen "grok bright placeholder-like draft on tmux" pending "$CAPS_TMUX" "$placeholder_draft" 1
  assert_screen "grok placeholder on plain backends" empty "$CAPS_PLAIN" "$placeholder_draft"
  assert_screen "grok titled on cmux/orca" empty "$CAPS_PLAIN" "$titled"
  assert_screen "grok titled on zellij" empty "$CAPS_STYLED_NOID" "$titled"
  # The tolerance is additive: an untitled border still proves the same box.
  assert_screen "grok untitled border" empty "$CAPS_TMUX" "$plain_border" 1
  typed=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯ deploy the fix                                                         │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯'
  assert_screen "grok typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "grok typed on herdr" pending "$CAPS_STYLED" "$typed"
  malformed=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯                                                                        │\n  ╰────────────────────────────────────────────────────────── unknown surface ─╯'
  assert_screen "oversized unknown title on herdr" unknown "$CAPS_STYLED" "$malformed"
  pass "matrix: grok's real oversized titled bottom is empty while typed and unproved panes stay safe"
}

test_matrix_kimi_bordered_shell_glyph_box() {
  # Kimi's bordered `│ > │` composer - the shape fm-spawn.sh's retired
  # spawn-local regex used to own. Now the shared owner proves it everywhere,
  # which is what kimi launch-readiness and delivery route through.
  local screen
  screen=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯'
  assert_screen "kimi idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "kimi idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  assert_screen "kimi idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "kimi idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  pass "matrix: kimi's bordered shell-glyph box reads empty through the shared owner (spawn's fourth copy retired)"
}

test_matrix_claude_inside_zellij_ansi_dump() {
  # Real claude captured through `zellij action dump-screen --ansi`
  # (capability established by the audit): `ESC[m` `❯` U+00A0.
  local screen plain
  screen=$'zellij pane transcript\n'"${ESC}[m❯${NBSP}"
  plain=$'zellij pane transcript\n❯'"$NBSP"
  assert_screen "claude-in-zellij on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "claude-in-zellij on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "claude-in-zellij on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude-in-zellij on plain backends" empty "$CAPS_PLAIN" "$plain"
  pass "matrix: the real claude-in-zellij --ansi dump reads empty in both locales"
}

test_strict_blank_row_divergence() {
  # THE STRICT POSTURE PIN (captain decision blank-row-injection-posture,
  # 2026-08-09): a blank or otherwise unidentified input row with no positive
  # container proof is `unknown`. Each case below read `empty` (or `pending`)
  # under the replaced permissive rule; if any of them drifts back, the
  # permissive posture has silently returned and away-mode injection would
  # again type escalations into unproven panes.
  local out
  # Permissive read this blank cursor row as empty = safe to inject.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'some output\nmore output\n' 2)
  [ "$out" = unknown ] || fail "a blank unidentified cursor row must be unknown (was permissive empty), got '$out'"
  # A dead shell's prompt row.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\n$ ' 1)
  [ "$out" = unknown ] || fail "a dead-shell prompt row must be unknown, got '$out'"
  # A bare busy-footer row is not a composer container.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'Working...' 0)
  [ "$out" = unknown ] || fail "a bare busy-footer row must be unknown (was permissive empty), got '$out'"
  # An unidentified free-text cursor row carries no container proof either.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\nhuman draft text' 1)
  [ "$out" = unknown ] || fail "an unidentified text row must be unknown under strict, got '$out'"
  # A blank screen with no cursor capability.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'\n\n')
  [ "$out" = unknown ] || fail "a blank screen must be unknown, got '$out'"
  pass "strict posture: blank and unidentified rows are unknown, never injectable empty"
}

test_bare_wrap_region_classifies() {
  # Long typed input wraps below the glyph row; the cursor rides the wrapped
  # continuation. The region is IDENTIFIED (glyph row + contiguous non-blank,
  # non-structural rows), so a swallowed Enter still reads pending and earns
  # its retry; a wrapped GHOST suggestion still proves empty.
  local wrapped ghost_wrapped out
  wrapped=$'❯ a very long steer message that\nwraps onto the following line'
  assert_screen "wrapped typed input" pending "$CAPS_TMUX" "$wrapped" 1
  wrapped=$'❯ wrapped typed input\ncontinues without a terminal-inserted glyph'
  assert_screen "ordinary wrapped input" pending "$CAPS_TMUX" "$wrapped" 1
  ghost_wrapped=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$ghost_wrapped" 1)
  [ "$out" = empty ] || fail "a wrapped ghost suggestion should still prove empty, got '$out'"
  # A structural row between the glyph and the cursor breaks the wrap claim.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n────────────────\nbelow the rule' 2)
  [ "$out" = unknown ] || fail "a rule between glyph and cursor must break the wrap region, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n$ live shell' 1)
  [ "$out" = unknown ] || fail "a shell prompt below a glyph row must not become wrapped input, got '$out'"
  pass "fm_composer_classify_screen: the bare composer's wrap region stays identified; structure breaks it"
}

test_contiguous_transcript_reanchors_on_live_prompt() {
  local screen
  screen=$'❯ hi\nHello!\n❯'
  assert_screen "contiguous transcript live prompt on cursorless styled backend" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "contiguous transcript live prompt on cursorless plain backend" empty "$CAPS_PLAIN" "$screen"
  assert_screen "contiguous transcript live prompt with cursor" empty "$CAPS_TMUX" "$screen" 2
  pass "fm_composer_classify_screen: a row-leading agent glyph reanchors the live composer"
}

test_lower_dead_shell_invalidates_cursorless_candidate() {
  local stale live out
  stale=$'old transcript\n❯\nprocess exited\n$'
  assert_screen "stale composer above dead shell on herdr" unknown "$CAPS_STYLED" "$stale"
  assert_screen "stale composer above dead shell on zellij" unknown "$CAPS_STYLED_NOID" "$stale"
  assert_screen "stale composer above dead shell on cmux/orca" unknown "$CAPS_PLAIN" "$stale"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$stale" 1)
  [ "$out" = empty ] \
    || fail "cursor mode must keep the cursor-anchored composer verdict, got '$out'"

  live=$'transcript shell snippet\n$ echo old output\nmore transcript\n❯'
  assert_screen "shell transcript above live composer on herdr" empty "$CAPS_STYLED" "$live"
  assert_screen "shell transcript above live composer on zellij" empty "$CAPS_STYLED_NOID" "$live"
  assert_screen "shell transcript above live composer on cmux/orca" empty "$CAPS_PLAIN" "$live"
  pass "fm_composer_classify_screen: a lower dead shell invalidates only cursorless stale composers"
}

test_cursorless_bare_wrap_region_classifies() {
  local activity status bounded ghost out
  activity=$'❯\nWorking on request...'
  assert_screen "cursorless activity below bare row on herdr" pending "$CAPS_STYLED" "$activity"
  assert_screen "cursorless activity below bare row on zellij" pending "$CAPS_STYLED_NOID" "$activity"
  assert_screen "cursorless activity below bare row on cmux/orca" unknown "$CAPS_PLAIN" "$activity"

  status=$'›\n\ncodex status line'
  assert_screen "blank-separated codex status on herdr" empty "$CAPS_STYLED" "$status"
  assert_screen "blank-separated codex status on zellij" empty "$CAPS_STYLED_NOID" "$status"
  assert_screen "blank-separated codex status on cmux/orca" empty "$CAPS_PLAIN" "$status"

  bounded=$'────────────────────────\n❯\n────────────────────────\nClaude 4.1'
  assert_screen "rule-bounded claude footer on herdr" empty "$CAPS_STYLED" "$bounded" '' probe-absent
  assert_screen "rule-bounded claude footer on zellij" empty "$CAPS_STYLED_NOID" "$bounded"
  assert_screen "rule-bounded claude footer on cmux/orca" empty "$CAPS_PLAIN" "$bounded"

  ghost=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on herdr should be empty, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_STYLED_NOID" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on zellij should be empty, got '$out'"
  pass "fm_composer_classify_screen: cursorless bare wrap regions participate in verdicts"
}

test_cursorless_container_rejects_contiguous_lower_activity() {
  local box leftbar grok kimi opencode
  box=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nWorking on request...'
  assert_screen "stale box above activity on herdr" unknown "$CAPS_STYLED" "$box"
  assert_screen "stale box above activity on zellij" unknown "$CAPS_STYLED_NOID" "$box"
  assert_screen "stale box above activity on cmux/orca" unknown "$CAPS_PLAIN" "$box"

  leftbar=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\nWorking on request...'
  assert_screen "stale left-bar above activity on herdr" unknown "$CAPS_STYLED" "$leftbar"
  assert_screen "stale left-bar above activity on zellij" unknown "$CAPS_STYLED_NOID" "$leftbar"
  assert_screen "stale left-bar above activity on cmux/orca" unknown "$CAPS_PLAIN" "$leftbar"

  grok=$'╭────────────────────────╮\n│ ❯                      │\n╰──────── Grok 4.5 ──────╯\n\nGrok status'
  kimi=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯\n\nKimi status'
  opencode=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\n\nOpenCode status'
  assert_screen "blank-separated grok footer" empty "$CAPS_STYLED_NOID" "$grok"
  assert_screen "blank-separated kimi footer" empty "$CAPS_PLAIN" "$kimi"
  assert_screen "left-bar floor and blank-separated footer" empty "$CAPS_STYLED_NOID" "$opencode"
  pass "fm_composer_classify_screen: cursorless containers reject only contiguous unclaimed activity"
}

test_bottom_most_candidate_wins() {
  # The one ranking rule: the live composer is bottom-anchored, so a stale
  # decorative box (codex's startup banner) can never outrank the real row
  # below it - the confidently-wrong orca case from the audit.
  local screen out
  screen=$'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n❯'"$NBSP"
  assert_screen "banner above live claude row" empty "$CAPS_PLAIN" "$screen"
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n› Use /skills to list available skills')
  [ "$out" != pending ] || fail "a stale banner must never classify as pending composer text"
  screen=$'❯ old draft\n\n❯'
  assert_screen "blank-separated newer bare composer" empty "$CAPS_STYLED_NOID" "$screen"
  pass "fm_composer_classify_screen: the bottom-most candidate wins; stale banners cannot"
}

test_incomplete_lower_box_invalidates_stale_candidate() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nstartup complete\n╭────────────────────────╮\n│ ❯ clipped live draft  '
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$screen")
  [ "$out" = unknown ] \
    || fail "an incomplete lower box must invalidate an earlier empty box, got '$out'"
  pass "fm_composer_classify_screen: incomplete lower structure invalidates stale boxes"
}

test_titled_bottom_requires_matching_width() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰─ Grok ─╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 1)
  [ "$out" = unknown ] \
    || fail "a short titled bottom must not prove an empty box, got '$out'"
  pass "fm_composer_classify_screen: titled bottoms retain full box geometry"
}

test_cursor_on_proven_box_bottom_classifies_content() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 2)
  [ "$out" = empty ] \
    || fail "a cursor on a proven box bottom must classify its content, got '$out'"
  pass "fm_composer_classify_screen: a proven box tolerates a bottom-border cursor"
}

test_selected_content_is_composer_scoped_and_wrap_normalized() {
  local screen out
  screen=$'hello captain in transcript\n╭────────────────────╮\n│ unrelated          │\n│ draft               │\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'unrelated draft' ] \
    || fail "box extraction should contain only normalized selected composer rows, got '$out'"
  screen=$'hello captain in transcript\n┃ hello\n┃ captain\n┃ Build · GPT-5.5 Fast OpenAI · high'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'hello captain' ] \
    || fail "left-bar extraction should join user rows without footer furniture, got '$out'"
  screen=$'╭────────────────────╮\n│ ❯ '"${ESC}[2mType a message...${ESC}[0m"$'│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] \
    || fail "ghost agent-prompt placeholders should be excluded from extracted user content, got '$out'"
  screen=$'╭────────────────────╮\n│ > '"${ESC}[2mType a message...${ESC}[0m"$'│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] \
    || fail "ghost shell-prompt placeholders should be excluded from boxed user content, got '$out'"
  screen=$'╭────────────────────╮\n│ ❯ Type a message...│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'Type a message...' ] \
    || fail "surviving placeholder-like input should remain extracted user content, got '$out'"
  screen=$'❯ a legitimately long steer that\nwraps across the next bare row\n\ntranscript below the break'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'a legitimately long steer that wraps across the next bare row' ] \
    || fail "bare extraction should include only its contiguous wrap region, got '$out'"
  screen=$'❯ wrapped user content\ncontinuation preserves a mid-row ❯ glyph'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'wrapped user content continuation preserves a mid-row ❯ glyph' ] \
    || fail "bare extraction should preserve mid-row agent glyph bytes, got '$out'"
  screen=$'❯ stale composer\n$ live shell'
  if out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen"); then
    fail "a lower live shell must invalidate composer extraction, got '$out'"
  fi
  screen=$'╭──────────────────────────────╮\n│ > wrapped user content       │\n│ ❯ preserves its leading glyph│\n╰──────────────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'wrapped user content ❯ preserves its leading glyph' ] \
    || fail "box extraction should strip only its actual prompt-row glyph, got '$out'"
  pass "fm_composer_extract_selected_content: scopes user content and excludes furniture"
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
test_matrix_claude_bare_nbsp_row
test_matrix_codex_dim_hint_row
test_matrix_muse_truecolor_glyph_survives_signal_loss
test_matrix_cursor_reverse_video_placeholder_remnant
test_matrix_herdr_halfblock_rule_bounds_bare_wrap
test_matrix_omp_status_row_bounds_bare_composer
test_matrix_codex_idle_starfield_furniture
test_matrix_pi_separated_needs_identity
test_matrix_opencode_leftbar_signals
test_matrix_grok_titled_bottom_border
test_matrix_kimi_bordered_shell_glyph_box
test_matrix_claude_inside_zellij_ansi_dump
test_strict_blank_row_divergence
test_bare_wrap_region_classifies
test_contiguous_transcript_reanchors_on_live_prompt
test_lower_dead_shell_invalidates_cursorless_candidate
test_cursorless_bare_wrap_region_classifies
test_cursorless_container_rejects_contiguous_lower_activity
test_bottom_most_candidate_wins
test_incomplete_lower_box_invalidates_stale_candidate
test_titled_bottom_requires_matching_width
test_cursor_on_proven_box_bottom_classifies_content
test_selected_content_is_composer_scoped_and_wrap_normalized

test_queued_enter_verdict_busy_pending_is_empty() {
  local out
  out=$(fm_composer_queued_enter_verdict pending busy)
  [ "$out" = empty ] || fail "busy + proven pending must be queued delivery (empty), got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + busy returns empty (queued Enter)"
}

test_queued_enter_verdict_idle_pending_stays_pending() {
  local out
  out=$(fm_composer_queued_enter_verdict pending idle)
  [ "$out" = pending ] || fail "idle + proven pending must stay a genuine swallow, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending unknown)
  [ "$out" = pending ] || fail "unknown busy is not proof of a queue, got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + idle/unknown stays pending"
}

test_queued_enter_verdict_does_not_convert_other_states() {
  local state out
  for state in empty pending-unproven unknown send-failed future-state; do
    out=$(fm_composer_queued_enter_verdict "$state" busy)
    [ "$out" = "$state" ] || fail "busy must not convert '$state', got '$out'"
    out=$(fm_composer_queued_enter_verdict "$state" idle)
    [ "$out" = "$state" ] || fail "idle must not convert '$state', got '$out'"
  done
  pass "fm_composer_queued_enter_verdict: only proven pending is converted"
}

test_queued_enter_verdict_busy_pending_is_empty
test_queued_enter_verdict_idle_pending_stays_pending
test_queued_enter_verdict_does_not_convert_other_states

# --- opencode 1.18.31: furniture below the floor, sidebar beside it ----------
# Captured live on 2026-09-20 against real opencode 1.18.31 (see
# docs/verification/runtime-backends.md). opencode draws a status/hint bar
# BELOW its composer's `╹▀…` floor, and once a session has history at a wide
# pane it draws a context sidebar on the composer's OWN rows. Each defeated the
# cursorless read on its own: the bar discarded the whole left-bar selection
# (`unknown`), and the sidebar read as typed text (`pending`). Together they
# meant no opencode worker on a cursorless backend - herdr, zellij, cmux, orca -
# could be stopped through bin/fm-control.sh at all, idle or wedged.

test_count_and_clip_columns_are_locale_independent() {
  local out
  out=$(printf '%s\n' '  ┃  Build · x' | fm_composer_count_columns)
  [ "$out" = 14 ] || fail "count_columns must count characters, not bytes, got '$out'"
  out=$(printf '%s\n' '  ┃  Build · x' | LC_ALL=C fm_composer_count_columns)
  [ "$out" = 14 ] || fail "count_columns under LC_ALL=C must agree, got '$out'"
  out=$(printf '%s\n' "${ESC}[38;2;1;2;3mab${ESC}[0m" | fm_composer_count_columns)
  [ "$out" = 2 ] || fail "ANSI sequences occupy no columns, got '$out'"
  # A clip that lands in whitespace separates a panel...
  out=$(printf '%s\n' 'abc     xyz' | fm_composer_clip_columns 5)
  [ "$out" = 'abc  ' ] || fail "a clip landing in whitespace must cut, got '$out'"
  # ...but a clip that would SPLIT a run returns the row whole, because deleting
  # part of what the composer holds is the one error that can manufacture a
  # false `empty` and let a caller type onto existing text.
  out=$(printf '%s\n' 'abcdefgh' | fm_composer_clip_columns 5)
  [ "$out" = 'abcdefgh' ] || fail "a clip splitting text must return the row whole, got '$out'"
  out=$(printf '%s\n' '  ┃  Build · x' | fm_composer_clip_columns 7)
  [ "$out" = '  ┃  Build · x' ] || fail "clip must not split a word, got '$out'"
  # A bound landing ON a multibyte glyph is a split too, counted in characters.
  out=$(printf '%s\n' '  ┃  Build · x' | fm_composer_clip_columns 2)
  [ "$out" = '  ┃  Build · x' ] || fail "clip must not split at a multibyte glyph, got '$out'"
  # ...and a bound landing in whitespace passes earlier multibyte glyphs intact.
  out=$(printf '%s\n' '  ┃  Build · x' | fm_composer_clip_columns 4)
  [ "$out" = '  ┃ ' ] || fail "clip must keep multibyte glyphs intact, got '$out'"
  pass "fm_composer_count_columns/clip_columns: character-exact, ANSI-transparent, never split a run"
}

test_matrix_opencode_below_floor_and_sidebar() {
  local bar floor idle wedged typed narrow mismatched blanking hidden past beside pad extracted typed_beside
  # Geometry, in columns, mirroring the live capture: the floor is the
  # composer's own width (63), composer text sits well inside it, and the
  # sidebar starts at column 70 - beyond the floor's right edge, across a gap.
  oc_row() {  # <left-bar content> [sidebar]
    local content=$1 side=${2:-} cols
    cols=$(printf '%s\n' "$content" | fm_composer_count_columns)
    while [ "$cols" -lt 69 ]; do content="$content "; cols=$((cols + 1)); done
    [ -n "$side" ] || { printf '%s' "$1"; return 0; }
    printf '%s%s' "$content" "$side"
  }
  pad='                                                            ' # 60
  floor="  ╹${pad// /▀}"
  bar='             tab agents  ctrl+p commands'

  # 1. The reported failure, idle: every row empty, a hint bar below the floor.
  idle=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    '  ┃' \
    "$(oc_row '  ┃  Ask anything… "Fix a TODO in the codebase"' '/home/u/app:main')" \
    '  ┃' \
    "$(oc_row '  ┃  Build · Big Pickle OpenCode Zen' '0 tokens')" \
    "$floor" "$bar")
  assert_screen "opencode idle below-floor bar on herdr"     empty "$CAPS_STYLED"      "$idle"
  assert_screen "opencode idle below-floor bar on zellij"    empty "$CAPS_STYLED_NOID" "$idle"
  assert_screen "opencode idle below-floor bar on cmux/orca" empty "$CAPS_PLAIN"       "$idle"

  # 2. The wedged worker the incident was reported for: a spinner/status line
  # below the floor while the composer itself holds nothing.
  wedged=$(printf '%s\n%s\n%s\n%s\n%s' \
    '  ┃' '  ┃' \
    "$(oc_row '  ┃  Build · Big Pickle OpenCode Zen' '/home/u/app:main')" \
    "$floor" \
    '   ⬝⬝⬝⬝ Cannot connect to API… [retrying in 16s attempt #4]        esc interrupt    • OpenCode 1.18.31')
  assert_screen "opencode wedged below-floor status on herdr"     empty "$CAPS_STYLED"      "$wedged"
  assert_screen "opencode wedged below-floor status on cmux/orca" empty "$CAPS_PLAIN"       "$wedged"

  # 3. THE GUARD. Real typed text still refuses, with the same furniture and
  # sidebar present. This is what must fail if the fix is ever loosened into
  # "probably empty": typing onto existing text is the concatenation hazard the
  # refusal exists to prevent.
  typed=$(printf '%s\n%s\n%s\n%s\n%s' \
    '  ┃' \
    "$(oc_row '  ┃  refactor the parser please' '/home/u/app:main')" \
    "$(oc_row '  ┃  Build · Big Pickle OpenCode Zen' '0 tokens')" \
    "$floor" "$bar")
  assert_screen "opencode typed text still refuses on herdr"  pending "$CAPS_STYLED" "$typed"
  assert_screen "opencode typed text still refuses on zellij" pending "$CAPS_STYLED_NOID" "$typed"
  # Without styling a left-bar row carrying text degrades to unknown, never empty.
  assert_screen "opencode typed text on cmux/orca stays unproven" unknown "$CAPS_PLAIN" "$typed"

  # 4. THE OTHER GUARD. A floor too narrow to be this composer's border is a
  # mismatched or stale shape, so contiguous activity below it still discards
  # the selection. Without this the below-floor allowance would swallow the
  # cursorless staleness rule whole.
  narrow=$(printf '%s\n%s\n%s\n%s' \
    '  ┃' '  ┃  Build · Big Pickle OpenCode Zen' '  ╹▀▀▀' 'Working on request...')
  assert_screen "opencode narrow floor above activity stays unknown" unknown "$CAPS_STYLED" "$narrow"

  # 5. THE CLIP'S OWN GUARD, on the CURSOR-ANCHORED path. The clip is where
  # bytes are deleted, and the cursor path reaches the left-bar classifier
  # without passing through the cursorless selector, so the floor's credibility
  # has to be established at the clip itself. Here the floor is drawn narrower
  # than the composer it closes: the footer row's text runs straight across the
  # bound (so the floor cannot be this composer's border), while the draft row
  # happens to have a space at that column and would be cut away to nothing.
  # Trusting that floor would report a composer visibly holding a draft as
  # `empty`, and do_exit would then type the exit command onto it.
  mismatched=$(printf '%s\n%s\n%s\n%s' \
    '  ┃' '  ┃   the draft' '  ┃  Build · Big Pickle OpenCode Zen' '  ╹▀▀')
  assert_screen "opencode mismatched floor keeps the draft on tmux" pending "$CAPS_TMUX" "$mismatched" 1
  assert_screen "opencode mismatched floor keeps the draft cursorless" pending "$CAPS_STYLED" "$mismatched"
  # 6. THE CLIP MUST NOT BLANK A ROW THAT HOLDS TEXT. A bound whose span covers
  # only the left bar and the gap after it cuts cleanly - no run is split, so
  # the fit test alone is satisfied - and deletes the draft that starts past
  # that gap. A floor whose span blanks every row it covers is not describing
  # this composer, so the bound is refused and the rows are read whole.
  blanking=$(printf '%s\n%s\n%s' \
    ' ┃' ' ┃   hidden draft' ' ╹▀▀')
  assert_screen "opencode floor that blanks its own rows keeps the draft cursorless" \
    pending "$CAPS_STYLED" "$blanking"
  assert_screen "opencode floor that blanks its own rows keeps the draft on tmux" \
    pending "$CAPS_TMUX" "$blanking" 1

  # 7. A ROW BLANKED WHILE ANOTHER ROW SUPPLIES THE IN-BOUND PROOF. The bound
  # clears the footer, so the composer-wide "something is inside the bound"
  # test is satisfied by that row alone, and it still cuts cleanly in the gap
  # before the draft and deletes it. Nothing on this screen shows the
  # composer's own text and a panel side by side, so nothing explains the
  # deleted run as anything but the composer's own input.
  hidden=$(printf '%s\n%s\n%s\n%s' \
    '  ┃' "  ┃$(printf '%*s' 14 '')draft text here" '  ┃  Build · x' \
    '     ╹▀▀▀▀▀▀▀▀▀▀')
  assert_screen "opencode bound that deletes a row keeps the draft" \
    pending "$CAPS_STYLED" "$hidden"
  assert_screen "opencode bound that deletes a row keeps the draft on tmux" \
    pending "$CAPS_TMUX" "$hidden" 1

  # 8. THE SAME SHAPE AT THE COMPOSER'S OWN INDENT, which is the reviewer's
  # reproduction: the footer sits inside the bound and supplies the in-bound
  # proof, while the draft row's entire content lies past it and clips away.
  past=$(printf '%s\n%s\n%s' \
    " ┃$(printf '%*s' 15 '')the draft" ' ┃ Build · x' ' ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀')
  assert_screen "opencode draft entirely past the bound is never empty" \
    pending "$CAPS_STYLED" "$past"
  assert_screen "opencode draft entirely past the bound is never empty on tmux" \
    pending "$CAPS_TMUX" "$past" 0

  # 9. AND THE CASE THAT MUST NOT REGRESS WITH IT. A real sidebar runs beside
  # the composer's BLANK rows too, so those rows carry panel text and nothing
  # else, and clipping them to blank is correct. What licenses it is the rows
  # that show the composer's own text and the panel side by side: refusing
  # every bound that empties a row would read this idle pane as `unknown` and
  # leave opencode-on-herdr exactly as unstoppable as before.
  beside=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    "$(oc_row '  ┃' 'session: fix the parser')" \
    "$(oc_row '  ┃  Ask anything… "Fix a TODO in the codebase"' '/home/u/app:main')" \
    "$(oc_row '  ┃' '1.2k tokens')" \
    "$(oc_row '  ┃  Build · Big Pickle OpenCode Zen' '0 tokens')" \
    "$floor" "$bar")
  assert_screen "opencode idle with the sidebar beside its blank rows" \
    empty "$CAPS_STYLED" "$beside"
  assert_screen "opencode idle with the sidebar beside its blank rows on cmux/orca" \
    empty "$CAPS_PLAIN" "$beside"

  # 10. ONE SELECTION, ONE SET OF BYTES. The classifier and the extractor read
  # the same selected rows, so a bound proven for one must bound the other -
  # otherwise this pane classifies `empty` while extraction hands its caller the
  # sidebar text. zellij's delivery check compares `before` + the typed text
  # against what it reads afterwards, so a `before` carrying panel text can
  # never match, and the steer is typed and then reported failed: an unsent
  # draft left in the composer, which is what makes `exit`, `relaunch` and
  # `stop` all refuse afterwards.
  extracted=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$beside") \
    || fail "extraction must succeed on an idle composer beside a sidebar"
  [ -z "$extracted" ] \
    || fail "extraction must not hand back the sidebar the bound excludes, got '$extracted'"
  typed_beside=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
    "$(oc_row '  ┃' 'session: fix the parser')" \
    "$(oc_row '  ┃  please rerun the gate' '/home/u/app:main')" \
    "$(oc_row '  ┃' '1.2k tokens')" \
    "$(oc_row '  ┃  Build · Big Pickle OpenCode Zen' '0 tokens')" \
    "$floor" "$bar")
  extracted=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$typed_beside") \
    || fail "extraction must succeed on a typed composer beside a sidebar"
  [ "$extracted" = 'please rerun the gate' ] \
    || fail "extraction must return exactly what was typed, got '$extracted'"
  unset -f oc_row
  pass "matrix: opencode's below-floor furniture and side panel are bounded, and typed text still refuses"
}

test_count_and_clip_columns_are_locale_independent
test_matrix_opencode_below_floor_and_sidebar

# --- the stop gate's own question: was anything OBSERVED? --------------------
# fm_composer_no_content_observed is the only thing standing between
# bin/fm-control.sh `stop` and a SIGTERM, so it answers about OBSERVATION, not
# about the verdict. These cases pin both directions of that.
test_no_content_observed_requires_a_readable_capture() {
  local blank
  # A pane whose composer is scrolled out of the captured window still carries
  # transcript rows: nothing composer-shaped was observed, so the gate opens.
  fm_composer_no_content_observed unknown \
    "$(printf 'building index\nwrote 12 files\n')" \
    || fail "a readable capture with no composer shape must read as no content observed"
  # A capture that came back with nothing readable did not fail, but it is an
  # unreadable pane - not a pane proven to hold nothing - and must refuse.
  for blank in '' '   ' "$(printf '\n\n\n')" "$(printf '  \n\t\n')" "$NBSP"; do
    ! fm_composer_no_content_observed unknown "$blank" \
      || fail "an unreadable (blank) capture must not read as no content observed"
    ! fm_composer_no_content_observed empty "$blank" \
      || fail "an unreadable (blank) capture must refuse even when the verdict says empty"
  done
  # A composer that was read and proven to hold nothing is the other yes.
  fm_composer_no_content_observed empty "$(printf 'transcript\n❯\n')" \
    || fail "a composer proven empty must read as no content observed"
  # A composer shape that was SEEN but not proven empty must refuse, whatever
  # the verdict degraded to.
  ! fm_composer_no_content_observed unknown "$(printf '  ┃\n  ┃  a draft\n  ╹▀▀▀\n')" \
    || fail "an observed left-bar composer must refuse regardless of the verdict"
  pass "fm_composer_no_content_observed: only a readable capture with no shape, or a proven-empty composer, opens the gate"
}

test_no_content_observed_requires_a_readable_capture
