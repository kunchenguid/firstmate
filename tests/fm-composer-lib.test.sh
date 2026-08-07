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
#   3. The AGENT prompt glyphs `❯` (claude), `›` (codex), and `⟩` (muse) are a
#      genuine empty agent composer either way, bordered or bare; Cursor's `→`
#      needs Cursor context unless it is structurally bordered.
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
  # Shell glyphs and unscoped Cursor arrow stay unknown without an idle match.
  for plain in '$' 'user@host $' '→'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must stay unknown without an idle match, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered shell/arrow content stays unknown without an idle match"
}

test_ghost_only_agent_glyphs_match_main_empty() {
  # Regression vs main: ghost-stripped bare established agent glyphs are empty
  # composers; Cursor's `→` stays unknown unscoped and empty with Cursor context.
  local out
  out=$(classify 0 '' '' sensitive '❯')
  [ "$out" = empty ] || fail "ghost-only '❯' must read empty, got '$out'"
  out=$(classify 0 '' '' sensitive '›')
  [ "$out" = empty ] || fail "ghost-only '›' must read empty, got '$out'"
  out=$(classify 0 '' '' sensitive '⟩')
  [ "$out" = empty ] || fail "ghost-only '⟩' must read empty, got '$out'"
  out=$(classify 0 '' '' sensitive '→')
  [ "$out" = unknown ] || fail "unscoped ghost-only '→' must read unknown, got '$out'"
  out=$(classify 0 '' '' sensitive '→' cursor)
  [ "$out" = empty ] || fail "Cursor ghost-only '→' must read empty, got '$out'"
  pass "fm_composer_classify_content: ghost-only ❯/›/⟩ empty; unscoped → unknown; Cursor → empty"
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
  # muse restores the interrupted prompt into its composer after Escape, as real
  # bright text. Reading that as pending is correct - it really is unsubmitted.
  out=$(classify 0 '⟩ second turn to interrupt'); [ "$out" = pending ] || fail "bare '⟩ <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# --- Cursor agent glyph (→) ---

test_cursor_agent_glyph_requires_cursor_context() {
  local out
  out=$(classify 0 '→'); [ "$out" = unknown ] || fail "bare unscoped '→' should read unknown, got '$out'"
  out=$(classify 0 '→' '' sensitive '' cursor)
  [ "$out" = empty ] || fail "bare Cursor '→' should read empty with Cursor context, got '$out'"
  out=$(classify 1 '→'); [ "$out" = empty ] || fail "bordered cursor '→' should read empty, got '$out'"
  pass "fm_composer_classify_content: bare cursor arrow needs Cursor context"
}

test_cursor_idle_placeholder_is_empty() {
  local idle='Add a follow-up' out
  out=$(classify 0 '→ Add a follow-up' "$idle")
  [ "$out" = unknown ] || fail "an unscoped arrow idle placeholder must stay unknown, got '$out'"
  out=$(classify 0 '→ Add a follow-up' "$idle" insensitive '' cursor)
  [ "$out" = empty ] || fail "a Cursor arrow idle placeholder should read empty, got '$out'"
  out=$(classify 0 '→ Add a follow-up')
  [ "$out" = pending ] || fail "cursor idle placeholder without idle regex should be pending, got '$out'"
  pass "fm_composer_classify_content: cursor idle placeholder 'Add a follow-up' reads empty"
}

test_cursor_real_text_is_pending() {
  local out
  out=$(classify 0 '→ Count slowly from 1 to 30')
  [ "$out" = pending ] || fail "cursor '→ <real text>' should be pending, got '$out'"
  pass "fm_composer_classify_content: cursor real text reads pending"
}

test_cursor_stripped_ghost_plain_is_empty() {
  local out
  # Real capture path: cursor-agent renders the `→` glyph dim (SGR 2) with the
  # idle placeholder, so ghost stripping empties the content and the verdict
  # rests on the plain-content fallback, which requires an idle-placeholder
  # match (anchored or not, glyph stripped before matching).
  out=$(classify 0 '' 'Add a follow-up' sensitive '→ Add a follow-up')
  [ "$out" = unknown ] || fail "unscoped stripped '→ Add a follow-up' must stay unknown, got '$out'"
  out=$(classify 0 '' 'Add a follow-up' sensitive '→ Add a follow-up' cursor)
  [ "$out" = empty ] || fail "stripped Cursor '→ Add a follow-up' with an idle match should read empty, got '$out'"
  out=$(classify 0 '' '^Add a follow-up$' sensitive '→ Add a follow-up' cursor)
  [ "$out" = empty ] || fail "stripped Cursor '→ Add a follow-up' with an anchored idle match should read empty, got '$out'"
  # Without an idle match, unscoped ghost-stripped Cursor arrow rows stay
  # unknown. Established agent glyphs (❯/›/⟩) are empty on glyph shape alone
  # (see test_ghost_only_agent_glyphs_match_main_empty); that safety rule does
  # not extend to Cursor's common bare `→` decoration.
  out=$(classify 0 '' '' sensitive '→ Add a follow-up')
  [ "$out" = unknown ] || fail "stripped '→ Add a follow-up' without an idle match must stay unknown, got '$out'"
  out=$(classify 0 '' '' sensitive '→')
  [ "$out" = unknown ] || fail "stripped bare '→' must stay unknown without an idle match, got '$out'"
  out=$(classify 0 '' '' sensitive '→' cursor)
  [ "$out" = empty ] || fail "stripped bare Cursor '→' must read empty with Cursor context, got '$out'"
  out=$(classify 0 '' '' sensitive '> ls')
  [ "$out" = unknown ] || fail "stripped shell-glyph row '> ls' must stay unknown, got '$out'"
  pass "fm_composer_classify_content: stripped Cursor ghost rows need idle match or Cursor bare arrow; shell stays unknown"
}

# --- Shared composer env contract (fm_composer_export_env) ------------------

# export_env_probe: run the exporter with the env contract scoped to this call,
# so one case's exported values cannot leak into the next.
export_env_probe() {  # <harness> [caller-supplied idle regex] -> "<harness>|<idle regex>"
  local FM_COMPOSER_HARNESS FM_COMPOSER_IDLE_RE
  [ -z "${2:-}" ] || FM_COMPOSER_IDLE_RE=$2
  fm_composer_export_env "$1"
  printf '%s|%s' "${FM_COMPOSER_HARNESS:-}" "${FM_COMPOSER_IDLE_RE:-}"
}

test_export_env_sets_cursor_idle_default() {
  local out
  out=$(export_env_probe cursor)
  [ "$out" = 'cursor|^Add a follow-up$' ] \
    || fail "cursor must default FM_COMPOSER_IDLE_RE to its idle placeholder, got '$out'"
  pass "fm_composer_export_env: cursor exports its verified idle-placeholder default"
}

test_export_env_keeps_explicit_idle_re_and_other_harnesses_unset() {
  local out
  out=$(export_env_probe cursor '^caller supplied$')
  [ "$out" = 'cursor|^caller supplied$' ] \
    || fail "an explicit idle regex must win over the cursor default, got '$out'"
  out=$(export_env_probe claude)
  [ "$out" = 'claude|' ] \
    || fail "a non-cursor harness must leave the idle override unset, got '$out'"
  pass "fm_composer_export_env: an explicit idle regex wins, and non-cursor harnesses stay unset"
}

# --- Shared exhausted-retry rule (fm_composer_queued_submit_verdict) --------

test_queued_submit_verdict_needs_queueing_harness_and_busy() {
  local h out
  # shellcheck disable=SC2329 # invoked indirectly through the verdict helper
  probe_busy() { return 0; }
  # shellcheck disable=SC2329 # invoked indirectly through the verdict helper
  probe_idle() { return 1; }
  for h in opencode cursor; do
    out=$(fm_composer_queued_submit_verdict "$h" probe_busy)
    [ "$out" = empty ] || fail "$h + busy must report empty (queued Enter), got '$out'"
    out=$(fm_composer_queued_submit_verdict "$h" probe_idle)
    [ "$out" = pending ] || fail "$h + idle must stay pending (genuine swallow), got '$out'"
  done
  pass "fm_composer_queued_submit_verdict: a verified queueing harness reports empty only when affirmatively busy"
}

test_queued_submit_verdict_never_widens_to_other_harnesses() {
  local h out
  # shellcheck disable=SC2329 # would be invoked indirectly if the rule widened
  probe_busy() { printf 'probed' >> "$PROBE_LOG"; return 0; }
  PROBE_LOG=$(mktemp)
  for h in claude codex pi grok kimi muse '' unknown-harness; do
    out=$(fm_composer_queued_submit_verdict "$h" probe_busy)
    [ "$out" = pending ] \
      || fail "harness '$h' has no verified Enter-while-busy queuing and must stay pending, got '$out'"
  done
  [ ! -s "$PROBE_LOG" ] \
    || fail "the busy probe must not run for a harness whose answer cannot change the verdict"
  rm -f "$PROBE_LOG"
  pass "fm_composer_queued_submit_verdict: the busy exception never widens past opencode/cursor, and skips their probe"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_ghost_only_agent_glyphs_match_main_empty
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_cursor_agent_glyph_requires_cursor_context
test_cursor_idle_placeholder_is_empty
test_cursor_real_text_is_pending
test_cursor_stripped_ghost_plain_is_empty
test_export_env_sets_cursor_idle_default
test_export_env_keeps_explicit_idle_re_and_other_harnesses_unset
test_queued_submit_verdict_needs_queueing_harness_and_busy
test_queued_submit_verdict_never_widens_to_other_harnesses
