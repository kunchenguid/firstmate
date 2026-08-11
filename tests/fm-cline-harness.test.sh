#!/usr/bin/env bash
# Behavior tests for the verified Cline CLI crewmate adapter (cline 3.0.46).
#
# Every literal in this file is an EMPIRICAL capture from a live `cline -i --tui`
# pane driven through tmux (see docs/verification/cline-adapter.md):
#   - busy footer:      " ⠇ Thinking... (esc to cancel)"   (interrupt = esc)
#   - idle placeholders: "What can I do for you?" (first ready), "Ask anything..."
#   - agent glyph:      ❯ (U+276F, already a verified empty-composer glyph)
#   - launch:           cline -i --tui --auto-approve true [--model M] [--thinking E] "<brief>"
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"   # brings fm-composer-lib.sh + busy defaults/matcher

classify() { fm_composer_classify_content "$@"; }

# Verified idle placeholders as one anchored alternation (what the backend IDLE_RE
# must cover so an empty cline composer is not misread as pending).
CLINE_IDLE_RE='^(What can I do for you\?|Ask anything\.\.\.)$'

# --- launch template (mechanics half) ---------------------------------------

test_cline_launch_template_is_pinned() {
  local line="    cline) printf '%s' 'cline -i --tui --auto-approve true __MODELFLAG____EFFORTFLAG__\"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  grep -Fqx -- "$line" "$SPAWN" \
    || fail "fm-spawn: verified cline launch template missing/changed"
  pass "fm-spawn: cline launch template is the verified argv-seed line"
}

test_existing_launch_templates_untouched() {
  grep -Fq "claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "claude launch template changed"
  grep -Fq "grok --always-approve __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "grok launch template changed"
  pass "fm-spawn: pre-existing adapters' launch templates are untouched"
}

test_cline_is_a_known_bare_adapter_name() {
  # cline must be accepted as a bare adapter name, not routed to the raw-launch hatch.
  # (Robust to later adapters appended after cline, e.g. |cline|cursor-agent).)
  grep -Fq "|kimi|cline" "$SPAWN" \
    || fail "fm-spawn: cline not added to a known-harness allowlist"
  pass "fm-spawn: cline is recognized as a known bare adapter name"
}

test_cline_model_and_effort_flags() {
  # cline takes --model (long form of -m) and maps effort to --thinking (no max).
  # (Robust to later adapters appended after cline in the --model allowlist.)
  grep -Fq "|kimi|cline" "$SPAWN" \
    || fail "fm-spawn: cline not in the --model allowlist"
  grep -Fq "'--thinking %s '" "$SPAWN" \
    || fail "fm-spawn: cline effort->--thinking mapping missing"
  pass "fm-spawn: cline gets --model and effort->--thinking (low|medium|high|xhigh)"
}

# --- detection --------------------------------------------------------------

test_cline_detection_wired() {
  grep -Fq '*cline*) echo cline; return ;;' "$HARNESS" \
    || fail "fm-harness: cline ancestry case missing"
  pass "fm-harness: cline is detected by process ancestry"
}

# --- busy signature (knowledge half) ----------------------------------------

test_cline_busy_default_defined() {
  [ -n "${FM_TMUX_CLINE_BUSY_REGEX_DEFAULT:-}" ] \
    || fail "FM_TMUX_CLINE_BUSY_REGEX_DEFAULT is not defined"
  pass "fm-tmux-lib: FM_TMUX_CLINE_BUSY_REGEX_DEFAULT is defined"
}

test_cline_busy_line_matches() {
  printf '%s' ' ⠇ Thinking... (esc to cancel)' | fm_busy_lines_match cline \
    || fail "cline busy footer 'esc to cancel' did not classify busy"
  pass "fm_busy_lines_match: cline 'esc to cancel' footer reads busy"
}

test_cline_idle_line_not_busy() {
  if printf '%s' '❯ Ask anything...' | fm_busy_lines_match cline; then
    fail "cline idle composer must not read busy"
  fi
  pass "fm_busy_lines_match: cline idle composer does not read busy"
}

test_cline_does_not_borrow_signatures() {
  # A cline pane showing claude's 'esc to interrupt' must NOT be cline-busy:
  # cline's own footer is 'esc to cancel'. Guards against cross-harness borrow.
  if printf '%s' 'esc to interrupt' | fm_busy_lines_match cline; then
    fail "cline busy regex borrowed another harness's 'esc to interrupt'"
  fi
  pass "fm_busy_lines_match: cline uses only its own verified footer"
}

# --- composer idle classification -------------------------------------------

test_cline_idle_placeholders_read_empty() {
  local p out
  for p in 'What can I do for you?' 'Ask anything...'; do
    out=$(classify 1 "$p" "$CLINE_IDLE_RE" insensitive)
    [ "$out" = empty ] \
      || fail "cline idle placeholder '$p' must read empty (given idle-RE), got '$out'"
  done
  # After a leading agent glyph, still empty.
  out=$(classify 1 "❯ Ask anything..." "$CLINE_IDLE_RE" insensitive)
  [ "$out" = empty ] || fail "'❯ Ask anything...' must read empty, got '$out'"
  pass "fm_composer_classify_content: cline idle placeholders read empty"
}

test_cline_real_input_reads_pending() {
  local out
  out=$(classify 1 "Fix the null-pointer in the parser" "$CLINE_IDLE_RE" insensitive)
  [ "$out" = pending ] \
    || fail "real cline composer input must read pending, got '$out'"
  pass "fm_composer_classify_content: real cline input still reads pending"
}

# --- shared idle default covers cline (tmux + every backend) ----------------

test_shared_idle_default_covers_cline() {
  local p b bad=0 up
  for p in 'What can I do for you?' 'Ask anything...'; do
    printf '%s' "$p" | grep -qE "$FM_COMPOSER_IDLE_RE_DEFAULT" \
      || fail "shared FM_COMPOSER_IDLE_RE_DEFAULT does not match cline placeholder '$p'"
  done
  for b in herdr cmux orca; do
    up=$(printf '%s' "$b" | tr '[:lower:]' '[:upper:]')
    grep -Eq "FM_BACKEND_${up}_IDLE_RE=.*FM_COMPOSER_IDLE_RE_DEFAULT" \
      "$ROOT/bin/backends/$b.sh" || { echo "  backend $b IDLE_RE does not use the shared default"; bad=1; }
  done
  [ "$bad" -eq 0 ] || fail "one or more backend IDLE_RE defaults do not use the shared idle default"
  pass "shared idle default covers cline placeholders and backs herdr/cmux/orca"
}

# --- run --------------------------------------------------------------------
test_cline_launch_template_is_pinned
test_existing_launch_templates_untouched
test_cline_is_a_known_bare_adapter_name
test_cline_model_and_effort_flags
test_cline_detection_wired
test_cline_busy_default_defined
test_cline_busy_line_matches
test_cline_idle_line_not_busy
test_cline_does_not_borrow_signatures
test_cline_idle_placeholders_read_empty
test_cline_real_input_reads_pending
test_shared_idle_default_covers_cline
echo "ALL PASS: fm-cline-harness"
