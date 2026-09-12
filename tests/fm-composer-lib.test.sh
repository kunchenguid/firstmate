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

test_compare_normalizer_preserves_separators() {
  local out
  out=$(fm_composer_normalize_compare_text foobar)
  [ "$out" = foobar ] || fail "comparison normalization changed plain text: '$out'"
  out=$(fm_composer_normalize_compare_text 'foo bar')
  [ "$out" = 'foo bar' ] || fail "comparison normalization changed meaningful spaces: '$out'"
  out=$(fm_composer_normalize_compare_text $'foo\nbar')
  [ "$out" = 'foo bar' ] || fail "comparison normalization did not fold wrapping whitespace: '$out'"
  [ "$(fm_composer_normalize_compare_text 'foo  bar')" = 'foo  bar' ] \
    || fail "comparison normalization collapsed repeated spaces"
  [ "$(fm_composer_normalize_compare_text 'a  b')" != "$(fm_composer_normalize_compare_text $'a\nb')" ] \
    || fail "comparison normalization treated a wrapped line as an ordinary space"
  [ "$(fm_composer_normalize_compare_text $'a\nb')" = "$(fm_composer_normalize_compare_text $'a\nb')" ] \
    || fail "comparison normalization changed identical multiline text"
  [ "$(fm_composer_normalize_compare_text 'foobar')" != "$(fm_composer_normalize_compare_text 'foo bar')" ] \
    || fail "comparison normalization erased a meaningful separator"
  pass "fm_composer_normalize_compare_text: wrapping folds, meaningful separators survive"
}

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

test_agy_prompt_requires_footer_proof() {
  local caps=$'styled=0\ncursor=1' out
  out=$(fm_composer_classify_screen "$caps" $'────────────────\n>\n────────────────\n? for shortcuts' 1 '' agy)
  [ "$out" = empty ] || fail "an idle agy prompt with its footer must read empty, got '$out'"
  out=$(fm_composer_classify_screen "$caps" $'────────────────\n>\n────────────────\n? for shortcuts' 1)
  [ "$out" = unknown ] || fail "an AGY-shaped screen without harness proof must remain unknown, got '$out'"
  out=$(fm_composer_classify_screen "$caps" $'────────────────\n> draft\n────────────────\n? for shortcuts' 1 '' agy)
  [ "$out" = pending ] || fail "typed agy prompt text must read pending, got '$out'"
  out=$(fm_composer_classify_screen "$caps" $'> ' 0)
  [ "$out" = unknown ] || fail "a lone empty shell prompt must remain unknown, got '$out'"
  out=$(fm_composer_classify_screen "$caps" $'> $ ls' 0)
  [ "$out" = unknown ] || fail "a shell command prompt without a boundary must remain unknown, got '$out'"
  pass "fm_composer_classify_screen: agy uses positional boundary proof"
}

test_agy_prompt_requires_footer_proof_without_cursor() {
  local out
  out=$(fm_composer_classify_screen 'styled=0' $'────────────────\n>\n────────────────\n? for shortcuts' '' '' agy)
  [ "$out" = empty ] || fail "cursorless idle agy prompt must read empty, got '$out'"
  out=$(fm_composer_classify_screen 'styled=0' $'────────────────\n> draft\n────────────────\n? for shortcuts' '' '' agy)
  [ "$out" = pending ] || fail "cursorless typed agy prompt must read pending, got '$out'"
  out=$(fm_composer_classify_screen 'styled=0' $'> ')
  [ "$out" = unknown ] || fail "cursorless lone empty shell prompt must remain unknown, got '$out'"
  out=$(fm_composer_classify_screen 'styled=0' $'> $ ls')
  [ "$out" = unknown ] || fail "cursorless shell command prompt without a boundary must remain unknown, got '$out'"
  pass "fm_composer_classify_screen: cursorless agy uses positional boundary proof"
}

test_agy_rejects_generic_box_without_measured_pair() {
  local screen out baseline boundary box_boundary box_content
  screen=$'╭────────────────╮\n│ ❯              │\n╰────────────────╯'
  out=$(fm_composer_classify_screen 'styled=0' "$screen" '' '' agy)
  [ "$out" = unknown ] \
    || fail "AGY must reject a generic boxed composer without its measured pair, got '$out'"
  out=$(fm_composer_classify_screen 'styled=0' "$screen" '' '' codex)
  [ "$out" = empty ] \
    || fail "non-AGY boxed composer behavior changed, got '$out'"
  boundary=$(printf '─%.0s' {1..16})
  box_boundary=$(printf '─%.0s' {1..24})
  printf -v box_content '%-24s' hello
  screen="$boundary"$'\n>\n'"$boundary"$'\n╭'"$box_boundary"$'╮\n│ '"$box_content"$'│\n╰'"$box_boundary"$'╯'
  out=$(fm_composer_classify_screen 'styled=0' "$screen" '' '' agy)
  [ "$out" = empty ] \
    || fail "AGY must keep its measured pair ahead of a lower generic box, got '$out'"
  baseline=$(fm_composer_classify_screen 'styled=0' "$screen")
  out=$(fm_composer_classify_screen 'styled=0' "$screen" '' '' codex)
  [ "$out" = "$baseline" ] \
    || fail "non-AGY generic box behavior changed below an AGY-shaped pair: baseline '$baseline', got '$out'"
  pass "fm_composer_classify_screen: AGY requires its measured pair before generic candidates"
}

test_agy_prompt_uses_cursor_and_model_signals_for_multiline_drafts() {
  local cursor_caps=$'styled=1\ncursor=1' cursorless_caps='styled=0' out screen extract
  screen=$'────────────────\n> first line\n  second line\n────────────────\nGemini 3.8 Flash · low'
  out=$(fm_composer_classify_screen "$cursor_caps" "$screen" 2 '' agy)
  [ "$out" = pending ] || fail "a styled agy multiline draft under the cursor must read pending, got '$out'"
  out=$(fm_composer_classify_screen "$cursorless_caps" "$screen" '' '' agy)
  [ "$out" = pending ] || fail "a cursorless agy multiline draft must read pending, got '$out'"
  extract=$(fm_composer_extract_selected_content "$cursor_caps" "$screen" '' agy)
  [ "$extract" = 'first line second line' ] \
    || fail "styled agy extraction lost multiline draft content: '$extract'"
  extract=$(fm_composer_extract_selected_content "$cursorless_caps" "$screen" '' agy)
  [ "$extract" = 'first line second line' ] \
    || fail "cursorless agy extraction lost multiline draft content: '$extract'"
  screen=$'────────────────\n> first line\n? for shortcuts\n────────────────\nGemini 3.8 Flash · low'
  out=$(fm_composer_classify_screen "$cursor_caps" "$screen" 2 '' agy)
  [ "$out" = pending ] \
    || fail "a multiline agy draft containing furniture-looking rows must read pending, got '$out'"
  extract=$(fm_composer_extract_selected_content "$cursor_caps" "$screen" '' agy)
  [ "$extract" = 'first line ? for shortcuts' ] \
    || fail "agy extraction dropped furniture-looking multiline draft content: '$extract'"
  screen=$'output\n────────────────\n>\n────────────────\n? for shortcuts\n$ live shell'
  out=$(fm_composer_classify_screen "$cursor_caps" "$screen" 2 '' agy)
  [ "$out" = empty ] || fail "the cursor-anchored agy prompt must remain empty beside a lower shell, got '$out'"
  out=$(fm_composer_classify_screen "$cursorless_caps" "$screen" '' '' agy)
  [ "$out" = unknown ] || fail "cursorless agy selection must reject a lower shell, got '$out'"
  pass "fm_composer_classify_screen: agy uses cursor divergence and model-footer proof for multiline drafts"
}

test_agy_prompt_preserves_structural_draft_rows() {
  local screen out extract caps
  for caps in "$CAPS_TMUX" 'styled=0'; do
    screen=$'────────────────\n> first\n> second\n────────────────\nClaude Sonnet 4.6 · low'
    if [ "$caps" = "$CAPS_TMUX" ]; then
      out=$(fm_composer_classify_screen "$caps" "$screen" 1 '' agy)
    else
      out=$(fm_composer_classify_screen "$caps" "$screen" '' '' agy)
    fi
    [ "$out" = pending ] \
      || fail "agy draft rows beginning with > must classify pending, got '$out'"
    extract=$(fm_composer_extract_selected_content "$caps" "$screen" '' agy)
    [ "$extract" = 'first > second' ] \
      || fail "agy draft rows beginning with > were not preserved, got '$extract'"
    screen=$'────────────────\n> foo  bar\n────────────────\nClaude Sonnet 4.6 · low'
    extract=$(fm_composer_extract_selected_content "$caps" "$screen" '' agy)
    [ "$extract" = 'foo  bar' ] \
      || fail "agy extraction collapsed significant interior spaces, got '$extract'"
    screen=$'────────────────\n> run this:\n$ make test\n────────────────\nGPT-OSS 120B · medium'
    if [ "$caps" = "$CAPS_TMUX" ]; then
      out=$(fm_composer_classify_screen "$caps" "$screen" 1 '' agy)
    else
      out=$(fm_composer_classify_screen "$caps" "$screen" '' '' agy)
    fi
    [ "$out" = pending ] \
      || fail "agy shell-looking draft rows must classify pending, got '$out'"
    extract=$(fm_composer_extract_selected_content "$caps" "$screen" '' agy)
    [ "$extract" = 'run this: $ make test' ] \
      || fail "agy shell-looking draft rows were not preserved, got '$extract'"
    screen=$'────────────────\n> first \n second line\n────────────────'
    extract=$(fm_composer_extract_selected_content "$caps" "$screen" '' agy)
    [ "$extract" = 'first second line' ] \
      || fail "agy extraction must use the shared normalized row join, got '$extract'"
    screen=$'────────────────\n> first\n╭────────────────────────╮\n│ x                      │\n╰────────────────────────╯\n────────────────'
    if [ "$caps" = "$CAPS_TMUX" ]; then
      out=$(fm_composer_classify_screen "$caps" "$screen" 3 probe-absent agy)
    else
      out=$(fm_composer_classify_screen "$caps" "$screen" '' '' agy)
    fi
    [ "$out" = pending ] \
      || fail "a boxed AGY draft must classify pending, got '$out'"
    extract=$(fm_composer_extract_selected_content "$caps" "$screen" '' agy)
    [ "$extract" = 'first ╭────────────────────────╮ x ╰────────────────────────╯' ] \
      || fail "a boxed AGY draft lost rows during extraction, got '$extract'"
  done
  pass "fm_composer: agy preserves prompt and shell-looking multiline rows"
}

test_agy_ignores_incomplete_boxes_inside_pair() {
  local boundary screen out extract
  boundary=$(printf '─%.0s' {1..16})
  screen="$boundary"$'\n> draft\n╭────╮\n│ x\n'"$boundary"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 3 probe-absent agy)
  [ "$out" = pending ] \
    || fail "an incomplete box inside an AGY draft must stay pending, got '$out'"
  extract=$(fm_composer_extract_selected_content "$CAPS_TMUX" "$screen" '' agy)
  [ "$extract" = 'draft ╭────╮ │ x' ] \
    || fail "an incomplete box inside an AGY draft lost rows, got '$extract'"
  screen=$'╭────╮\n│ x\n'"$boundary"$'\n> draft\n'"$boundary"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 3 probe-absent agy)
  [ "$out" = unknown ] \
    || fail "an incomplete box outside an AGY pair must remain unknown, got '$out'"
  pass "fm_composer: AGY ignores incomplete boxes only inside its draft pair"
}

test_agy_prompt_uses_complete_positional_boundaries() {
  local caps boundary16 boundary72 boundary15 screen out extract
  boundary16=$(printf '─%.0s' {1..16})
  boundary72=$(printf '─%.0s' {1..72})
  boundary15=$(printf '─%.0s' {1..15})
  for caps in "$CAPS_TMUX" 'styled=0'; do
    for boundary in "$boundary16" "$boundary72"; do
      screen="$boundary"$'\n> draft\n'"$boundary"
      if [ "$caps" = "$CAPS_TMUX" ]; then
        out=$(fm_composer_classify_screen "$caps" "$screen" 1 probe-absent agy)
      else
        out=$(fm_composer_classify_screen "$caps" "$screen" '' '' agy)
      fi
      [ "$out" = pending ] \
        || fail "agy boundary '$boundary' must classify the draft pending, got '$out'"
    extract=$(fm_composer_extract_selected_content "$caps" "$screen" '' agy)
      [ "$extract" = draft ] \
        || fail "agy boundary '$boundary' must preserve the draft, got '$extract'"
    done
    for boundary in '━━━━' '═══' '----' '====' '____' '-' '─' "$boundary15"; do
      screen="$boundary"$'\n> draft\n'"$boundary"
      if [ "$caps" = "$CAPS_TMUX" ]; then
        out=$(fm_composer_classify_screen "$caps" "$screen" 1 probe-absent agy)
      else
        out=$(fm_composer_classify_screen "$caps" "$screen" '' '' agy)
      fi
      [ "$out" = unknown ] \
        || fail "unsupported AGY boundary '$boundary' must defer, got '$out'"
    done
    screen=$'────────────────\n> first\nsecond · low\n────────────────\nGemini 3.8 Flash · low'
    if [ "$caps" = "$CAPS_TMUX" ]; then
      out=$(fm_composer_classify_screen "$caps" "$screen" 1 '' agy)
    else
      out=$(fm_composer_classify_screen "$caps" "$screen" '' '' agy)
    fi
    [ "$out" = pending ] \
      || fail "a model-looking draft continuation must classify pending, got '$out'"
      extract=$(fm_composer_extract_selected_content "$caps" "$screen" '' agy)
    [ "$extract" = 'first second · low' ] \
      || fail "a model-looking draft continuation was dropped, got '$extract'"
  done
  for caps in "$CAPS_TMUX" 'styled=0'; do
    screen=$'> first\n-'
    if [ "$caps" = "$CAPS_TMUX" ]; then
      out=$(fm_composer_classify_screen "$caps" "$screen" 1 probe-absent agy)
    else
      out=$(fm_composer_classify_screen "$caps" "$screen" '' '' agy)
    fi
    [ "$out" = unknown ] \
      || fail "a draft dash without the native boundary must defer, got '$out'"
  done
  pass "fm_composer: agy uses the complete positional boundary contract"
}

test_agy_boundary_ambiguity_fails_closed() {
  local boundary screen out extract base_screen rules_screen base_out rules_out base_extract rules_extract
  boundary=$(printf '─%.0s' {1..16})
  screen="$boundary"$'\n> old\n'"$boundary"$'\n'"$boundary"$'\n> x\n'"$boundary"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 4 probe-absent agy)
  [ "$out" = unknown ] \
    || fail "an AGY capture with three boundaries must defer with a cursor, got '$out'"
  extract=$(fm_composer_extract_selected_content "$CAPS_TMUX" "$screen" 4 agy || true)
  [ -z "$extract" ] \
    || fail "an ambiguous AGY capture must extract nothing with a cursor, got '$extract'"
  out=$(fm_composer_classify_screen 'styled=0' "$screen" '' '' agy)
  [ "$out" = unknown ] \
    || fail "an AGY capture with three boundaries must defer cursorlessly, got '$out'"
  extract=$(fm_composer_extract_selected_content 'styled=0' "$screen" '' agy || true)
  [ -z "$extract" ] \
    || fail "an ambiguous AGY capture must extract nothing cursorlessly, got '$extract'"
  screen="$boundary"$'\n> x\n'"$boundary"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 1 probe-absent agy)
  [ "$out" = pending ] \
    || fail "an AGY capture with exactly two boundaries must remain pending, got '$out'"
  extract=$(fm_composer_extract_selected_content "$CAPS_TMUX" "$screen" 1 agy)
  [ "$extract" = x ] \
    || fail "an exact AGY pair must extract only current draft text, got '$extract'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 2 probe-absent agy)
  [ "$out" = unknown ] \
    || fail "a cursor outside the current AGY pair must defer, got '$out'"
  screen=$'scrollback\n────────────────\n> x\n────────────────'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 0 probe-absent agy)
  [ "$out" = unknown ] \
    || fail "a cursor above the AGY opening boundary must defer, got '$out'"
  local narrow boundary72 boundary80
  boundary72=$(printf '─%.0s' {1..72})
  narrow=$boundary72
  boundary80=$(printf '─%.0s' {1..80})
  screen="$boundary72"$'\nold transcript\n'"$boundary72"$'\n'"$boundary80"$'\n>\n'"$boundary80"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 4 probe-absent agy)
  [ "$out" = empty ] \
    || fail "a narrower full pair must not invalidate the wider AGY pair, got '$out'"
  screen="$narrow"$'\ntranscript divider\n'"$boundary80"$'\n>\n'"$boundary80"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 3 probe-absent agy)
  [ "$out" = empty ] \
    || fail "a narrower transcript divider above a full-width pair should remain empty, got '$out'"
  screen="$narrow"$'\ntranscript divider\n'"$boundary80"$'\n> x\n'"$boundary80"
  out=$(fm_composer_classify_screen 'styled=0' "$screen" '' '' agy)
  [ "$out" = pending ] \
    || fail "a draft below a narrower transcript divider should remain pending, got '$out'"
  base_screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯'
  rules_screen="$boundary"$'\nscrollback\n'"$boundary"$'\nmore output\n'"$boundary"$'\n'"$base_screen"
  base_out=$(fm_composer_classify_screen 'styled=1' "$base_screen")
  rules_out=$(fm_composer_classify_screen 'styled=1' "$rules_screen")
  [ "$rules_out" = "$base_out" ] \
    || fail "horizontal rules in non-AGY scrollback changed boxed classification from '$base_out' to '$rules_out'"
  base_extract=$(fm_composer_extract_selected_content 'styled=1' "$base_screen")
  rules_extract=$(fm_composer_extract_selected_content 'styled=1' "$rules_screen")
  [ "$rules_extract" = "$base_extract" ] \
    || fail "horizontal rules in non-AGY scrollback changed boxed extraction from '$base_extract' to '$rules_extract'"
  screen=$'> quoted\n────────────────\n╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯'
  out=$(fm_composer_classify_screen 'styled=1' "$screen")
  [ "$out" = empty ] \
    || fail "cursorless selection must keep the lower bordered composer, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 3)
  [ "$out" = empty ] \
    || fail "cursor selection must keep the lower bordered composer, got '$out'"
  screen="$boundary"$'\nscrollback\n'"$boundary"$'\nmore output\n'"$boundary"$'\n'"$base_screen"
  out=$(fm_composer_classify_screen 'styled=1' "$screen" '' '' agy)
  [ "$out" = unknown ] \
    || fail "an AGY capture with three boundaries and a lower box must defer cursorlessly, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 6 probe-absent agy)
  [ "$out" = unknown ] \
    || fail "an AGY capture with three boundaries and a lower box must defer with a cursor, got '$out'"
  extract=$(fm_composer_extract_selected_content 'styled=1' "$screen" '' agy || true)
  [ -z "$extract" ] \
    || fail "an ambiguous AGY capture must not extract a lower generic composer, got '$extract'"
  out=$(fm_composer_classify_screen 'styled=1' "$screen" '' '' codex)
  [ "$out" = empty ] \
    || fail "the same three-boundary capture must preserve the codex lower-box verdict, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 6 probe-absent codex)
  [ "$out" = empty ] \
    || fail "the same three-boundary capture must preserve the codex cursor verdict, got '$out'"
  pass "fm_composer: AGY rejects ambiguous boundary captures"
}

test_agy_boundary_is_locale_independent() {
  local utf8_locale locale boundary16 boundary72 boundary15 boundary
  utf8_locale=
  for candidate in C.UTF-8 en_US.UTF-8; do
    if LC_ALL="$candidate" locale charmap >/dev/null 2>&1; then
      utf8_locale=$candidate
      break
    fi
  done
  if [ -z "$utf8_locale" ]; then
    utf8_locale=$(LC_ALL=C locale -a | LC_ALL=C awk '/[Uu][Tt][Ff].*8/ { print; exit }')
  fi
  [ -n "$utf8_locale" ] || fail "no UTF-8 locale is available for AGY boundary coverage"
  boundary16=$(printf '─%.0s' {1..16})
  boundary72=$(printf '─%.0s' {1..72})
  boundary15=$(printf '─%.0s' {1..15})
  for boundary in "$boundary16" "$boundary72"; do
    for locale in C "$utf8_locale"; do
      LC_ALL="$locale" _fm_composer_agy_boundary_row "$boundary" \
        || fail "AGY boundary '$boundary' was rejected under $locale"
    done
  done
  for locale in C "$utf8_locale"; do
    for non_boundary in '━━━━' '═══' '----' '====' '____' '-' '─' "$boundary15" '│abc│' '- text -'; do
      if LC_ALL="$locale" _fm_composer_agy_boundary_row "$non_boundary"; then
        fail "unsupported AGY boundary was accepted under $locale: $non_boundary"
      fi
    done
  done
  pass "fm_composer: AGY boundaries are locale-independent"
}

test_generic_delivery_busy_union_includes_agy_cancel() {
  local active draft_screen cropped_screen long_active
  active=$'────────────────\n> \n────────────────\nesc to cancel                                                Gemini 3.8 Flash · medium'
  draft_screen=$'────────────────\n> first\nesc to cancel Gemini 3.8 Flash · medium\n────────────────\n? for shortcuts'
  cropped_screen=$'draft continuation 1\ndraft continuation 2\ndraft continuation 3\ndraft continuation 4\ndraft continuation 5\ndraft continuation 6\ndraft continuation 7\ndraft continuation 8\ndraft continuation 9\ndraft continuation 10\ndraft continuation 11\nesc to cancel Gemini 3.8 Flash · medium'
  long_active=$(printf '────────────────\n> row 1\nrow 2\nrow 3\nrow 4\nrow 5\nrow 6\nrow 7\nrow 8\nrow 9\nrow 10\nrow 11\nrow 12\nrow 13\nrow 14\n────────────────\nesc to cancel Gemini 3.8 Flash · medium')
  if printf '%s\n' 'esc to cancel' | fm_busy_lines_match; then
    fail "generic delivery busy matcher must not classify draft text as busy"
  fi
  if printf '%s\n' 'esc to cancel' | fm_busy_lines_match agy; then
    fail "agy busy matcher must not classify draft text as busy"
  fi
  if printf '%s\n' "$draft_screen" | fm_busy_lines_match; then
    fail "generic AGY busy matcher must exclude the draft region"
  fi
  if printf '%s\n' "$draft_screen" | fm_busy_lines_match agy; then
    fail "AGY busy matcher must exclude the draft region"
  fi
  if printf '%s\n' "$cropped_screen" | fm_busy_lines_match; then
    fail "generic AGY busy matcher must fail closed on cropped captures"
  fi
  if printf '%s\n' "$cropped_screen" | fm_busy_lines_match agy; then
    fail "AGY busy matcher must fail closed on cropped captures"
  fi
  if ! printf '%s\n' "$long_active" | fm_busy_lines_match agy; then
    fail "AGY busy matcher must scope the full capture before its tail limit"
  fi
  if ! FM_BUSY_REGEX=BUSYTOKEN fm_busy_lines_match agy <<< 'BUSYTOKEN'; then
    fail "an explicit busy-regex override must scan the full capture"
  fi
  if ! printf '%s\n' "$active" | fm_busy_lines_match; then
    fail "generic delivery busy matcher must recognize AGY's native active row"
  fi
  if ! printf '%s\n' "$active" | fm_busy_lines_match agy; then
    fail "agy busy matcher must recognize its native active row"
  fi
  if printf '%s\n' "$active" | fm_busy_lines_match unknown-harness; then
    fail "unknown harness must not borrow the generic delivery busy matcher"
  fi
  pass "fm_composer: AGY busy matching excludes draft text"
}

test_agy_prompt_preserves_furniture_looking_drafts() {
  local caps=$'styled=0\ncursor=1' out extract screen
  for draft in '? for shortcuts' '────────────────'; do
    screen=$'────────────────\n> '"$draft"$'\n────────────────\n? for shortcuts'
    out=$(fm_composer_classify_screen "$caps" "$screen" 1 '' agy)
    [ "$out" = pending ] \
      || fail "agy draft '$draft' must classify pending, got '$out'"
    extract=$(fm_composer_extract_selected_content "$caps" "$screen" '' agy)
    [ "$extract" = "$draft" ] \
      || fail "agy draft '$draft' must extract verbatim, got '$extract'"
  done
  pass "fm_composer: agy preserves prompt-row drafts that resemble furniture"
}

test_bare_shell_glyphs_are_unknown
test_compare_normalizer_preserves_separators
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
test_agy_prompt_requires_footer_proof
test_agy_prompt_requires_footer_proof_without_cursor
test_agy_rejects_generic_box_without_measured_pair
test_agy_prompt_uses_cursor_and_model_signals_for_multiline_drafts
test_agy_prompt_preserves_structural_draft_rows
test_agy_ignores_incomplete_boxes_inside_pair
test_agy_prompt_uses_complete_positional_boundaries
test_agy_boundary_ambiguity_fails_closed
test_agy_boundary_is_locale_independent
test_generic_delivery_busy_union_includes_agy_cancel
test_agy_prompt_preserves_furniture_looking_drafts

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
