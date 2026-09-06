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
# + SGR-2 dim hint), muse (truecolor `⟩`, 38;2;90;160;255), pi (blank row
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
  # Real idle opencode: `┃`-prefixed rows holding the "Ask anything..." hint,
  # blanks, and a Build-mode footer. Two independent idle signals: the shared
  # idle-placeholder pattern (works on plain captures) and the ghost strip
  # (works on styled captures even if the pattern is overridden away).
  local screen typed dim_screen out
  screen=$'  ┃\n  ┃  Ask anything... "What is the tech stack?"\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
  dim_screen=$'  ┃\n  ┃  '"${ESC}[2mAsk anything...${ESC}[0m"$'\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀'
  assert_screen "opencode idle on tmux (cursor on hint)" empty "$CAPS_TMUX" "$dim_screen" 1
  assert_screen "opencode idle on herdr" empty "$CAPS_STYLED" "$dim_screen"
  assert_screen "opencode idle on zellij" empty "$CAPS_STYLED_NOID" "$dim_screen"
  assert_screen "opencode idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
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
  # Real idle grok: a bordered box whose BOTTOM border carries the model name.
  # The audit showed the title alone flipped tmux's geometry check to
  # ambiguous and the verdict to unknown, stranding every grok steer.
  local titled plain_border typed placeholder_draft
  titled=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────── Grok 4.5 (high) ─╯'
  plain_border=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────────────────────────╯'
  assert_screen "grok titled on tmux" empty "$CAPS_TMUX" "$titled" 1
  assert_screen "grok titled on tmux bottom-border cursor" empty "$CAPS_TMUX" "$titled" 2
  assert_screen "grok titled on herdr" empty "$CAPS_STYLED" "$titled"
  placeholder_draft=$'  ╭──────────────────────────────────────╮\n  │ ❯ Type a message...                  │\n  ╰──────────────────── Grok 4.5 (high) ─╯'
  assert_screen "grok bright placeholder-like draft on tmux" pending "$CAPS_TMUX" "$placeholder_draft" 1
  assert_screen "grok placeholder on plain backends" empty "$CAPS_PLAIN" "$placeholder_draft"
  assert_screen "grok titled on cmux/orca" empty "$CAPS_PLAIN" "$titled"
  assert_screen "grok titled on zellij" empty "$CAPS_STYLED_NOID" "$titled"
  # The tolerance is additive: an untitled border still proves the same box.
  assert_screen "grok untitled border" empty "$CAPS_TMUX" "$plain_border" 1
  typed=$'  ╭──────────────────────────────────────╮\n  │ ❯ deploy the fix                     │\n  ╰──────────────────── Grok 4.5 (high) ─╯'
  assert_screen "grok typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  pass "matrix: grok's titled bottom border is tolerated as a title, not read as ambiguity"
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

test_matrix_kimi_status_footer_below_box() {
  # Real kimi 0.40.1 (captured live 2026.09.03 over backend=herdr): the status
  # footer renders as free-text DIRECTLY BELOW the composer box - one row
  # ("K2.7 Coding thinking <cwd> <hint>") at narrow widths, with a right-aligned
  # "context: N% (used/total)" meter row beneath it at wider widths. The
  # below-box staleness walk must step over these furniture rows exactly as it
  # steps over blanks, or the visibly-empty composer reads unknown and the
  # spawn delivery gate false-fails. The FM_COMPOSER_KIMI_FOOTER=1 prefix on
  # every read mirrors bin/fm-spawn.sh's kimi gate, the production caller that
  # positively identified the pane as kimi; an unidentified read refuses these
  # same screens (pinned in
  # test_matrix_kimi_footer_requires_positive_kimi_identification below). The
  # divergence pins prove any OTHER free-text row below the box still
  # invalidates it, with and without the override knob.
  local box typed hint meter wide transcript meter_prose out
  box=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯'
  typed=$'╭────────────────────────╮\n│ > deploy the fix       │\n╰────────────────────────╯'
  hint=$'K2.7 Coding thinking  /repo    shift-tab to Plan mode to review the approach'
  meter=$'                                                                            context: 0% (0/256k)'
  wide=$'K2.7 Coding thinking  /repo'
  transcript=$'the user asked about the parser yesterday'
  meter_prose=$'the meter says context: 50% (128/256k) now'
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi idle, hint footer below the box" empty "$CAPS_STYLED" "$box"$'\n'"$hint"
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi idle, hint footer, plain capture" empty "$CAPS_PLAIN" "$box"$'\n'"$hint"
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi idle, two-row footer with context meter" empty "$CAPS_STYLED" "$box"$'\n'"$wide"$'\n'"$meter"
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi typed, hint footer below the box" pending "$CAPS_STYLED" "$typed"$'\n'"$hint"
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi typed, two-row footer" pending "$CAPS_STYLED" "$typed"$'\n'"$wide"$'\n'"$meter"
  # Divergence: an ordinary transcript row directly below the box is NOT
  # furniture; the candidate must still be refused as stale.
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi box above transcript text stays stale" unknown "$CAPS_STYLED" "$box"$'\n'"$transcript"
  # Divergence: a transcript row merely EMBEDDING meter-shaped prose mid-row
  # is not the right-aligned furniture row either; it must still refuse.
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi box above mid-row meter prose stays stale" unknown "$CAPS_STYLED" "$box"$'\n'"$meter_prose"
  # Divergence: with the footer pattern overridden away, the real footer no
  # longer qualifies either - the pass above came from the furniture match,
  # not from a weakened staleness check.
  out=$(FM_COMPOSER_KIMI_FOOTER=1 FM_COMPOSER_KIMI_FOOTER_RE='^NEVER-MATCHES$' fm_composer_classify_screen "$CAPS_STYLED" "$box"$'\n'"$hint")
  [ "$out" = unknown ] \
    || fail "kimi footer override must restore refusal, got '$out'"
  pass "matrix: kimi's below-box status footer is stepped over as furniture and nothing else is"
}

test_matrix_kimi_permission_badged_footer() {
  # Real kimi 0.40.1 --auto (captured live 2026.09.03 on a fleet-spawned pane):
  # the footer row renders the permission mode as a LEFT BADGE ahead of the
  # model token - "Never Ask  K2.7 Coding thinking  <cwd>  <hint>". The badge
  # vocabulary (from the kimi binary's own strings): "Never Ask" (--auto),
  # "Ask When Needed" (--yolo), "Always Ask" (manual). Without the badge in
  # the furniture pattern, every --auto spawn's visibly-empty composer reads
  # unknown and both the readiness and the delivery gate false-fail. As in
  # the test above, FM_COMPOSER_KIMI_FOOTER=1 mirrors the production
  # kimi-identified caller. The divergence pins below prove badge-like prose
  # without the model token is still ordinary transcript and refuses the box.
  local box typed never_ask ask_needed always_ask prose out
  box=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯'
  typed=$'╭────────────────────────╮\n│ > deploy the fix       │\n╰────────────────────────╯'
  never_ask=$'Never Ask  K2.7 Coding thinking  /repo    shift-tab to Plan mode'
  ask_needed=$'Ask When Needed  K2.7 Coding thinking  /repo'
  always_ask=$'Always Ask  K2.7 Coding thinking  /repo'
  prose=$'Never Ask me about the parser again'
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi --auto badged footer below the box" empty "$CAPS_STYLED" "$box"$'\n'"$never_ask"
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi --yolo badged footer below the box" empty "$CAPS_STYLED" "$box"$'\n'"$ask_needed"
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi manual badged footer below the box" empty "$CAPS_STYLED" "$box"$'\n'"$always_ask"
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi typed, badged footer below the box" pending "$CAPS_STYLED" "$typed"$'\n'"$never_ask"
  # Divergence: badge-shaped prose without the "<model> Coding" furniture
  # token is transcript and still invalidates the box above it.
  FM_COMPOSER_KIMI_FOOTER=1 assert_screen "kimi badge-shaped prose below box stays stale" unknown "$CAPS_STYLED" "$box"$'\n'"$prose"
  # Divergence: with the footer pattern overridden away, the badged footer no
  # longer qualifies either.
  out=$(FM_COMPOSER_KIMI_FOOTER=1 FM_COMPOSER_KIMI_FOOTER_RE='^NEVER-MATCHES$' fm_composer_classify_screen "$CAPS_STYLED" "$box"$'\n'"$never_ask")
  [ "$out" = unknown ] \
    || fail "kimi badged footer override must restore refusal, got '$out'"
  pass "matrix: kimi's permission-badged footer is stepped over as furniture and badge-shaped prose is not"
}

test_matrix_kimi_footer_requires_positive_kimi_identification() {
  # STRICT DEFAULT PIN (review fix on PR 3716): the kimi footer furniture
  # tolerance is identification-scoped. Without a caller's positive kimi
  # identification (FM_COMPOSER_KIMI_FOOTER unset - the default every foreign
  # harness, steer guard, and injection guard reads under), the exact footer
  # rows a kimi-identified pane steps over MUST refuse the box above them: a
  # matching below-box row on an unidentified or foreign pane is ordinary
  # transcript and the candidate stays stale. This is what keeps one vendor's
  # rendered footer from binding fleet-wide delivery truth (VISION.md:
  # contracts bind to semantics a vendor exposes, never to the pixels of
  # today's UI) - and when a future kimi footer out-drifts the pattern, the
  # unidentified default fails LOUD here instead of quietly confirming.
  local box hint meter never_ask claude_box out
  box=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯'
  hint=$'K2.7 Coding thinking  /repo    shift-tab to Plan mode to review the approach'
  meter=$'                                                                            context: 0% (0/256k)'
  never_ask=$'Never Ask  K2.7 Coding thinking  /repo'
  claude_box=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯'
  unset FM_COMPOSER_KIMI_FOOTER
  assert_screen "unidentified pane: hint footer below box stays stale" unknown "$CAPS_STYLED" "$box"$'\n'"$hint"
  assert_screen "unidentified pane: badged footer below box stays stale" unknown "$CAPS_STYLED" "$box"$'\n'"$never_ask"
  assert_screen "unidentified pane: two-row footer below box stays stale" unknown "$CAPS_STYLED" "$box"$'\n'"$hint"$'\n'"$meter"
  # The foreign-harness case the scoping exists for: another boxed harness
  # whose transcript happens to emit a kimi-footer-shaped row directly below
  # a (stale) box. Unidentified, it must still refuse - never discard the
  # row as furniture.
  assert_screen "unidentified pane: footer-shaped row below a foreign box stays stale" unknown "$CAPS_STYLED" "$claude_box"$'\n'"$never_ask"
  # Sanity: the same read under positive identification flips to empty,
  # proving the strict verdicts above came from the absent identification
  # and not from any change to the pattern or the walk.
  out=$(FM_COMPOSER_KIMI_FOOTER=1 fm_composer_classify_screen "$CAPS_STYLED" "$box"$'\n'"$never_ask")
  [ "$out" = empty ] \
    || fail "the same badged footer read under positive kimi identification must be empty, got '$out'"
  pass "matrix: the kimi footer tolerance applies only to a positively identified kimi pane"
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
test_matrix_pi_separated_needs_identity
test_matrix_opencode_leftbar_signals
test_matrix_grok_titled_bottom_border
test_matrix_kimi_bordered_shell_glyph_box
test_matrix_kimi_status_footer_below_box
test_matrix_kimi_permission_badged_footer
test_matrix_kimi_footer_requires_positive_kimi_identification
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
