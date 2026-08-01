#!/usr/bin/env bash
# Behavior tests for the verified Antigravity CLI crewmate adapter (agy 1.1.9).
#
# Every literal in this file is an EMPIRICAL capture from a live `agy -i` pane
# driven through tmux (see docs/verification/agy-adapter.md):
#   - busy footer:      "esc to cancel" (braille + Generating.../Running... body)
#   - idle footer:      "? for shortcuts"
#   - idle composer:    bare bordered ">", NO placeholder text
#   - launch:           agy --dangerously-skip-permissions [--model M] [--effort E]
#                        -i "<brief>"
#   - interrupt:        single Esc mid-turn; exit: /exit
#   - trust dialog:     "Do you trust the contents of this project?"
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"   # brings fm-composer-lib.sh + busy defaults/matcher

classify() { fm_composer_classify_content "$@"; }

# --- launch template (mechanics half) ---------------------------------------

test_agy_launch_template_is_pinned() {
  local line="    agy) printf '%s' 'agy --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__-i \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  grep -Fqx -- "$line" "$SPAWN" \
    || fail "fm-spawn: verified agy launch template missing/changed"
  pass "fm-spawn: agy launch template is the verified argv-seed line"
}

test_existing_launch_templates_untouched() {
  grep -Fq "claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "claude launch template changed"
  grep -Fq "copilot --allow-all --no-ask-user __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "copilot launch template changed"
  grep -Fq 'cursor-agent --force __MODELFLAG__' "$SPAWN" \
    || fail "cursor-agent launch template changed"
  pass "fm-spawn: pre-existing adapters' launch templates are untouched"
}

test_agy_is_a_known_bare_adapter_name() {
  grep -Fq "|copilot|agy)" "$SPAWN" \
    || fail "fm-spawn: agy not added to a known-harness allowlist"
  pass "fm-spawn: agy is recognized as a known bare adapter name"
}

test_agy_model_and_effort_flags() {
  grep -Fq "|copilot|agy)" "$SPAWN" \
    || fail "fm-spawn: agy not in the --model allowlist"
  grep -Fq "low|medium|high) printf -- '--effort %s '" "$SPAWN" \
    || fail "fm-spawn: agy effort->--effort mapping missing"
  pass "fm-spawn: agy gets --model and effort->--effort (low|medium|high)"
}

# --- detection --------------------------------------------------------------

test_agy_detection_wired() {
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  grep -Fq '[ "${ANTIGRAVITY_AGENT:-}" = "1" ]' "$HARNESS" \
    || fail "fm-harness: agy ANTIGRAVITY_AGENT=1 env marker missing"
  # ANTIGRAVITY_AGENT must be checked before CLAUDECODE so an agy worker is
  # never misidentified as claude when both markers are present in the tree.
  # Match the actual assignment checks, not comments that mention either name.
  local antigravity_line claude_line
  # shellcheck disable=SC2016  # single quotes are deliberate: literal needles, not expansions
  antigravity_line=$(grep -n '\[ "${ANTIGRAVITY_AGENT:-}" = "1" \]' "$HARNESS" | head -1 | cut -d: -f1)
  # shellcheck disable=SC2016  # single quotes are deliberate: literal needles, not expansions
  claude_line=$(grep -n '\[ "${CLAUDECODE:-}" = "1" \]' "$HARNESS" | head -1 | cut -d: -f1)
  [ -n "$antigravity_line" ] && [ -n "$claude_line" ] \
    || fail "fm-harness: could not locate ANTIGRAVITY_AGENT / CLAUDECODE check lines"
  [ "$antigravity_line" -lt "$claude_line" ] \
    || fail "fm-harness: ANTIGRAVITY_AGENT must be checked before CLAUDECODE (got lines $antigravity_line vs $claude_line)"
  grep -Fq 'agy) echo agy; return ;;' "$HARNESS" \
    || fail "fm-harness: agy direct ancestry case missing"
  pass "fm-harness: agy is detected by env marker (before CLAUDECODE) and process ancestry"
}

test_agy_env_marker_takes_precedence() {
  local out
  out=$(ANTIGRAVITY_AGENT=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = agy ] || fail "expected harness=agy when both markers set, got '$out'"
  out=$(CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "expected harness=claude when only CLAUDECODE set, got '$out'"
  pass "fm-harness: ANTIGRAVITY_AGENT beats CLAUDECODE; CLAUDECODE alone still means claude"
}

# --- busy signature (knowledge half) ----------------------------------------

test_agy_busy_default_defined() {
  [ -n "${FM_TMUX_AGY_BUSY_REGEX_DEFAULT:-}" ] \
    || fail "FM_TMUX_AGY_BUSY_REGEX_DEFAULT is not defined"
  pass "fm-tmux-lib: FM_TMUX_AGY_BUSY_REGEX_DEFAULT is defined"
}

test_agy_busy_line_matches() {
  printf '%s' 'esc to cancel                                                                                                         Gemini 3.6 Flash · low' | fm_busy_lines_match agy \
    || fail "agy busy footer 'esc to cancel' did not classify busy"
  pass "fm_busy_lines_match: agy 'esc to cancel' footer reads busy"
}

test_agy_idle_line_not_busy() {
  if printf '%s' '? for shortcuts                                                                                                       Gemini 3.6 Flash · low' | fm_busy_lines_match agy; then
    fail "agy idle shortcuts bar must not read busy"
  fi
  if printf '%s' '>' | fm_busy_lines_match agy; then
    fail "agy idle composer must not read busy"
  fi
  pass "fm_busy_lines_match: agy idle composer/status bar does not read busy"
}

test_agy_does_not_borrow_foreign_signatures() {
  # Same posture as other adapters: reject foreign harness tokens that are not
  # agy's own. Note: 'esc to cancel' is also cline's token; that is agy's own
  # verified signature too (docs/verification/agy-adapter.md), so it is not a
  # foreign borrow when harness=agy.
  local foreign
  for foreign in 'esc to interrupt' 'esc interrupt' 'Working...' 'Ctrl+c:cancel' 'ctrl+c to stop' 'Working.*esc interrupt'; do
    if printf '%s' "$foreign" | fm_busy_lines_match agy; then
      fail "agy busy regex borrowed foreign token '$foreign'"
    fi
  done
  pass "fm_busy_lines_match: agy rejects foreign busy tokens"
}

# --- composer idle classification -------------------------------------------

test_agy_idle_composer_reads_empty() {
  # agy has NO idle placeholder text. Bordered bare ">" is the idle composer
  # (already a shell glyph that reads empty when bordered in the shared
  # classifier). Bare unbordered ">" remains dead-shell (unknown), not empty.
  local out
  out=$(classify 1 '>')
  [ "$out" = empty ] || fail "bordered bare agy composer glyph must read empty, got '$out'"
  out=$(classify 0 '>')
  [ "$out" = unknown ] || fail "unbordered bare '>' must stay dead-shell unknown, got '$out'"
  pass "fm_composer_classify_content: agy bordered '>' reads empty; bare stays unknown"
}

test_agy_real_input_reads_pending() {
  local out
  out=$(classify 1 "Fix the null-pointer in the parser")
  [ "$out" = pending ] \
    || fail "real agy composer input must read pending, got '$out'"
  pass "fm_composer_classify_content: real agy input still reads pending"
}

# --- trust gate (spawn-time readiness step) ---------------------------------

AGY_GATE_SOURCE=$(sed -n '/^agy_capture()/,/^agy_spawn_fail()/p' "$SPAWN" | sed '$d')

test_agy_trust_gate_wired() {
  grep -Fq 'Do you trust the contents of this project?' "$SPAWN" \
    || fail "fm-spawn: agy project-trust dialog literal missing"
  grep -Fq 'agy_wait_for_trust_clear' "$SPAWN" \
    || fail "fm-spawn: agy trust readiness gate missing"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  grep -Fq 'if [ "$HARNESS" = agy ]; then' "$SPAWN" \
    || fail "fm-spawn: agy trust gate call site not guarded by HARNESS = agy"
  pass "fm-spawn: agy project-trust readiness gate is wired"
}

test_agy_past_trust_does_not_match_the_dialog() {
  # The dialog body contains "Antigravity CLI requires permission..." - past
  # trust must not treat that as success. Only esc-to-cancel / ? for shortcuts.
  local dialog
  dialog='Accessing workspace:

/tmp/fm-agy-fresh.TO2lcN

Do you trust the contents of this project?

Antigravity CLI requires permission to read, edit, and execute files here.

> Yes, I trust this folder
  No, exit

  ↑/↓ Navigate · enter Confirm
                                                                                                 Gemini 3.6 Flash · low · AI: Out of credits'
  if printf '%s\n' "$dialog" | grep -Eq 'esc to cancel|\? for shortcuts'; then
    fail "dialog fixture unexpectedly matched past-trust regex"
  fi
  # Extracted predicate must reject the dialog.
  local out
  out=$(bash -c "
$AGY_GATE_SOURCE
agy_pane_is_past_trust \"\$1\" && echo past || echo blocked
" bash "$dialog")
  [ "$out" = blocked ] || fail "agy_pane_is_past_trust matched the trust dialog itself"
  pass "agy past-trust predicate does not match the trust dialog body"
}

test_agy_trust_gate_clears_untrusted_path() {
  local tmpd send_log seq_file out sends
  tmpd=$(fm_test_tmproot fm-agy-trust-clear)
  send_log=$tmpd/sends
  seq_file=$tmpd/seq
  printf '0\n' > "$seq_file"
  : > "$send_log"
  out=$(bash -c '
set -u
'"$AGY_GATE_SOURCE"'
T=fake:0
W=
BACKEND=tmux
FM_AGY_TRUST_POLLS=8
FM_AGY_POLL_INTERVAL=0
spawn_send_key() { printf "KEY:%s\n" "$2" >> "'"$send_log"'"; }
agy_capture() {
  local n
  n=$(cat "'"$seq_file"'")
  n=$((n + 1))
  printf "%s\n" "$n" > "'"$seq_file"'"
  if [ "$n" -le 2 ]; then
    cat <<EOF
Do you trust the contents of this project?
Antigravity CLI requires permission to read, edit, and execute files here.
> Yes, I trust this folder
  No, exit
EOF
  else
    cat <<EOF
? for shortcuts                                                                                                       Gemini 3.6 Flash · low
>
EOF
  fi
}
if agy_wait_for_trust_clear; then echo OK; else echo FAIL; fi
')
  [ "$out" = OK ] || fail "agy trust gate did not clear untrusted fixture, got '$out'"
  sends=$(wc -l < "$send_log" | tr -d ' ')
  [ "$sends" = 1 ] || fail "expected exactly one Enter keystroke, got $sends"
  grep -Fq 'KEY:Enter' "$send_log" || fail "expected Enter keystroke log"
  pass "agy trust gate clears untrusted path with one Enter then past-trust idle"
}

test_agy_trust_gate_fails_loudly_on_budget() {
  local out
  out=$(bash -c '
set -u
'"$AGY_GATE_SOURCE"'
T=fake:0
W=
BACKEND=tmux
FM_AGY_TRUST_POLLS=3
FM_AGY_POLL_INTERVAL=0
spawn_send_key() { :; }
agy_capture() {
  cat <<EOF
Do you trust the contents of this project?
> Yes, I trust this folder
EOF
}
if agy_wait_for_trust_clear; then echo OK; else echo FAIL; fi
')
  [ "$out" = FAIL ] || fail "expected trust gate budget exhaustion, got '$out'"
  pass "agy trust gate fails loudly when dialog never clears"
}

# --- run --------------------------------------------------------------------
test_agy_launch_template_is_pinned
test_existing_launch_templates_untouched
test_agy_is_a_known_bare_adapter_name
test_agy_model_and_effort_flags
test_agy_detection_wired
test_agy_env_marker_takes_precedence
test_agy_busy_default_defined
test_agy_busy_line_matches
test_agy_idle_line_not_busy
test_agy_does_not_borrow_foreign_signatures
test_agy_idle_composer_reads_empty
test_agy_real_input_reads_pending
test_agy_trust_gate_wired
test_agy_past_trust_does_not_match_the_dialog
test_agy_trust_gate_clears_untrusted_path
test_agy_trust_gate_fails_loudly_on_budget
