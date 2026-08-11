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
  grep -Fq "grok --always-approve __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "grok launch template changed"
  grep -Fq '__KIMIBIN__ __MODELFLAG__--auto' "$SPAWN" \
    || fail "kimi launch template changed"
  pass "fm-spawn: pre-existing adapters' launch templates are untouched"
}

test_agy_is_a_known_bare_adapter_name() {
  # Assert an executable case-pattern line, not the usage comment that spells
  # the same allowlist - a comment-only match would keep this fence green after
  # agy was dropped from the real arg-parsing arm.
  grep -Eq "^[[:space:]]*[^#]*\|agy\)" "$SPAWN" \
    || fail "fm-spawn: agy not added to a known-harness allowlist case arm"
  pass "fm-spawn: agy is recognized as a known bare adapter name"
}

test_agy_model_and_effort_flags() {
  # Scope both needles to the function bodies that actually build the flags.
  # A bare file-wide grep for "|kimi|agy)" also matches a usage comment and
  # the secondmate bare-name case, so deleting agy from model_flag_for_harness
  # alone would leave this fence green while agy silently loses --model.
  local model_fn effort_agy_arm
  model_fn=$(sed -n '/^model_flag_for_harness()/,/^}/p' "$SPAWN")
  printf '%s\n' "$model_fn" | grep -Eq '^ *[^)]*\|agy\)' \
    || fail "fm-spawn: agy not in model_flag_for_harness's --model allowlist"
  printf '%s\n' "$model_fn" | grep -Fq "printf -- '--model %s '" \
    || fail "fm-spawn: model_flag_for_harness no longer emits --model"
  # The agy arm runs from its `agy)` case label to that arm's `;;` terminator.
  effort_agy_arm=$(sed -n '/^effort_flag_for_harness()/,/^}/p' "$SPAWN" \
    | sed -n '/^ *agy)/,/^ *;;/p')
  [ -n "$effort_agy_arm" ] \
    || fail "fm-spawn: effort_flag_for_harness has no agy case arm"
  printf '%s\n' "$effort_agy_arm" | grep -Fq "low|medium|high) printf -- '--effort %s '" \
    || fail "fm-spawn: agy effort->--effort (low|medium|high) mapping missing"
  # agy REJECTS the literal values xhigh/max, so they must never be emitted.
  if printf '%s\n' "$effort_agy_arm" | grep -Eq -- "--effort (xhigh|max)"; then
    fail "fm-spawn: agy effort arm must never emit --effort xhigh/max"
  fi
  pass "fm-spawn: agy gets --model and effort->--effort (low|medium|high)"
}

# Run the REAL effort_flag_for_harness against agy's verified probe matrix
# instead of grepping for one shape of it - the emitted argv is the contract,
# and every rewrite of the arm has to keep satisfying agy, not a literal.
AGY_EFFORT_SOURCE=$(
  sed -n '/^effort_flag_for_harness()/,/^}/p' "$SPAWN"
  sed -n '/^shell_quote()/,/^}/p' "$SPAWN"
)

agy_effort_flag() {  # <effort> <model>
  bash -c "
set -u
$AGY_EFFORT_SOURCE
effort_flag_for_harness agy \"\$1\" \"\$2\"
" bash "$1" "$2"
}

test_agy_effort_never_emits_a_combination_agy_rejects() {
  # Probe matrix from docs/verification/agy-adapter.md:
  #   P3  base id + no --effort            -> Error "requires --effort"
  #   P6  base id + in-range --effort      -> Success
  #   P1  baked id + no --effort           -> Success
  #   P5  baked id + MATCHING --effort     -> Success
  #   P4/P7 baked id + CONFLICTING --effort -> Error "conflicts with --effort"
  # So an out-of-range shared tier (xhigh/max) may only cap to `high` when the
  # id carries no baked suffix; against a baked id the cap WOULD conflict, and
  # withholding the flag is the launchable answer.
  local out
  [ -n "$AGY_EFFORT_SOURCE" ] || fail "could not extract effort_flag_for_harness from fm-spawn"

  out=$(agy_effort_flag low gemini-3.6-flash)
  [ "$out" = "--effort 'low' " ] || fail "base id + low must pass through, got '$out'"
  out=$(agy_effort_flag high gemini-3.6-flash)
  [ "$out" = "--effort 'high' " ] || fail "base id + high must pass through, got '$out'"

  # Base id: the cap is mandatory - dropping it makes agy exit "requires --effort".
  out=$(agy_effort_flag xhigh gemini-3.6-flash)
  [ "$out" = "--effort high " ] || fail "base id + xhigh must clamp to --effort high, got '$out'"
  out=$(agy_effort_flag max gemini-3.6-flash)
  [ "$out" = "--effort high " ] || fail "base id + max must clamp to --effort high, got '$out'"
  # No model id at all: nothing can conflict, and the flag is still safe.
  out=$(agy_effort_flag xhigh '')
  [ "$out" = "--effort high " ] || fail "no model + xhigh must still clamp to --effort high, got '$out'"

  # Baked id: capping to `high` is exactly probe P4's error. Withhold instead.
  local baked
  for baked in gemini-3.6-flash-low gemini-3.6-flash-medium gemini-3.6-flash-high; do
    out=$(agy_effort_flag xhigh "$baked")
    [ -z "$out" ] || fail "baked id '$baked' + xhigh must emit no effort flag, got '$out'"
    out=$(agy_effort_flag max "$baked")
    [ -z "$out" ] || fail "baked id '$baked' + max must emit no effort flag, got '$out'"
  done

  # In-range efforts still pass through verbatim against a baked id: a matching
  # pair is P5 (Success) and a conflicting pair is the captain's own explicit
  # request, which agy refuses loudly rather than firstmate silently rewriting.
  out=$(agy_effort_flag low gemini-3.6-flash-low)
  [ "$out" = "--effort 'low' " ] || fail "baked id + matching low must pass through, got '$out'"

  # Nothing in the matrix may ever emit a value agy's --effort does not accept.
  local e m
  for e in low medium high xhigh max; do
    for m in '' gemini-3.6-flash gemini-3.6-flash-low gemini-3.6-flash-medium gemini-3.6-flash-high; do
      out=$(agy_effort_flag "$e" "$m")
      case "$out" in
        *xhigh*|*max*) fail "effort='$e' model='$m' emitted an unsupported effort: '$out'" ;;
      esac
    done
  done
  pass "fm-spawn: agy effort resolution never emits a model/effort pair agy rejects"
}

# --- crewmate-only posture --------------------------------------------------

test_agy_is_refused_as_a_secondmate_harness() {
  # agy has no primary supervision protocol. Every non-raw path that can resolve
  # HARNESS=agy for a secondmate must refuse before endpoint creation.
  grep -Fq 'secondmate_harness_unsupported' "$SPAWN" \
    || fail "fm-spawn: no secondmate crewmate-only refusal helper"
  # shellcheck disable=SC2016 # The grep pattern intentionally matches literal source text.
  grep -Fq 'muse|cline|cursor-agent|copilot|agy) secondmate_harness_unsupported "$HARNESS"' "$SPAWN" \
    || fail "fm-spawn: post-resolution crewmate-only secondmate guard missing"
  # The bare-name parse arm must not silently accept agy either.
  local sm_case
  # shellcheck disable=SC2016  # single quotes are deliberate: $KIND is literal awk pattern text
  sm_case=$(awk '/^elif \[ "\$KIND" = secondmate \]; then/ { capture=1 } capture { print; if ($0 == "fi") exit }' "$SPAWN" | head -20)
  # Assert the INTENT - agy is absent from the arm - rather than pinning the
  # arm's exact membership. The exact-list form was written before muse, cline,
  # cursor-agent and copilot joined it, and upstream's own main would fail it:
  # every one of those is crewmate-only and refused by its post-resolution
  # guard, exactly as agy is. Pinning the list made this fence fail whenever a
  # legitimate crewmate-only adapter was added, which is not what it is for.
  printf '%s\n' "$sm_case" | grep -Eq "^ *''\|claude\|codex\|" \
    || fail "fm-spawn: secondmate bare-adapter parse arm is missing or reshaped"
  printf '%s\n' "$sm_case" | grep -Eq "^ *''\|[^)]*\bagy\b" \
    && fail "fm-spawn: secondmate bare-adapter allowlist still carries agy"
  printf '%s\n' "$sm_case" | grep -Fq 'muse|cline|cursor-agent|copilot|agy)' \
    || fail "fm-spawn: bare 'agy' secondmate name is not explicitly refused"
  pass "fm-spawn: agy is refused as a secondmate harness on every non-raw path"
}

test_agy_not_recovery_graded_in_secondmate_sweep() {
  local sweep allowed rejected
  sweep=$(sed -n '/^secondmate_liveness_one()/,/^}/p' "$ROOT/bin/fm-bootstrap.sh")
  [ -n "$sweep" ] || fail "fm-bootstrap: secondmate_liveness_one not found"
  # shellcheck disable=SC2016 # Literal source pattern under test.
  printf '%s\n' "$sweep" | grep -Fq 'fm_control_harness_state_recovery_grade "$harness"' \
    || fail "fm-bootstrap: secondmate sweep no longer delegates recovery-grade truth to fm-control-lib"
  # shellcheck source=bin/fm-control-lib.sh
  . "$ROOT/bin/fm-control-lib.sh"
  if fm_control_harness_state_recovery_grade agy; then rejected=0; else rejected=1; fi
  if fm_control_harness_state_recovery_grade claude; then allowed=1; else allowed=0; fi
  [ "$allowed" = 1 ] || fail "fm-control-lib: known recovery-grade harness claude is not accepted"
  [ "$rejected" = 1 ] || fail "fm-control-lib: agy must not be recovery-grade for secondmate recovery"
  pass "fm-bootstrap: agy dead/missing readings are not trusted as secondmate recovery-grade"
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

test_agy_argv_match_is_anchored() {
  # A bare *agy* pattern in the node/python argv fallback also matches the
  # ordinary word "legacy" (`node /repo/packages/legacy-cli/index.js`), which
  # would resolve detect_own to agy and dispatch crewmates onto the wrong
  # adapter. Only a whole argv token or a trailing path segment may match,
  # the same anchoring the pi arm already uses.
  local argv_arm
  argv_arm=$(sed -n '/node\*|python\*)/,/esac ;;/p' "$HARNESS")
  [ -n "$argv_arm" ] || fail "fm-harness: node/python argv fallback arm not found"
  if printf '%s\n' "$argv_arm" | grep -Eq '^ *\*agy\*\)'; then
    fail "fm-harness: agy argv match must be anchored, not a bare *agy* substring"
  fi
  printf '%s\n' "$argv_arm" | grep -Fq '*" agy "*' \
    || fail "fm-harness: anchored agy argv token match missing"
  pass "fm-harness: agy argv fallback is anchored so 'legacy' cannot false-positive"
}

test_agy_env_marker_takes_precedence() {
  local out
  out=$(ANTIGRAVITY_AGENT=1 CLAUDECODE=1 "$HARNESS")
  [ "$out" = agy ] || fail "expected harness=agy when both markers set, got '$out'"
  out=$(ANTIGRAVITY_AGENT='' CLAUDECODE=1 "$HARNESS")
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
  # agy's own. Note: 'esc to cancel' is not exclusive to agy, but it is agy's
  # own verified signature too (docs/verification/agy-adapter.md), so it is not
  # a foreign borrow when harness=agy.
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
  # Use plain mktemp: fm_test_tmproot via command-substitution installs its
  # EXIT cleanup on the subshell and deletes the dir before the parent can use it.
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-trust-clear.XXXXXX")
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
  [ "$out" = OK ] || { rm -rf "$tmpd"; fail "agy trust gate did not clear untrusted fixture, got '$out'"; }
  sends=$(wc -l < "$send_log" | tr -d ' ')
  [ "$sends" = 1 ] || { rm -rf "$tmpd"; fail "expected exactly one Enter keystroke, got $sends"; }
  grep -Fq 'KEY:Enter' "$send_log" || { rm -rf "$tmpd"; fail "expected Enter keystroke log"; }
  rm -rf "$tmpd"
  pass "agy trust gate clears untrusted path with one Enter then past-trust idle"
}

test_agy_trust_gate_clears_when_dialog_stays_in_scrollback() {
  # An Ink TUI need not scrub the accepted trust frame from the scrollback,
  # which keeps the dialog literal inside every capture forever. The gate must
  # still succeed the moment a past-trust anchor appears below it, or it burns
  # the whole poll budget and reports a false spawn failure while a trusted,
  # working agent runs unsupervised.
  local tmpd send_log out sends
  tmpd=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-trust-scrollback.XXXXXX")
  send_log=$tmpd/sends
  : > "$send_log"
  out=$(bash -c '
set -u
'"$AGY_GATE_SOURCE"'
T=fake:0
W=
BACKEND=tmux
FM_AGY_TRUST_POLLS=4
FM_AGY_POLL_INTERVAL=0
spawn_send_key() { printf "KEY:%s\n" "$2" >> "'"$send_log"'"; }
agy_capture() {
  cat <<EOF
Do you trust the contents of this project?
Antigravity CLI requires permission to read, edit, and execute files here.
> Yes, I trust this folder
  No, exit
esc to cancel                                                          Gemini 3.6 Flash · low
EOF
}
if agy_wait_for_trust_clear; then echo OK; else echo FAIL; fi
')
  [ "$out" = OK ] \
    || { rm -rf "$tmpd"; fail "agy trust gate must clear when the dialog literal persists in scrollback below a past-trust anchor, got '$out'"; }
  sends=$(wc -l < "$send_log" | tr -d ' ')
  [ "$sends" = 0 ] \
    || { rm -rf "$tmpd"; fail "expected no keystroke once the pane is already past trust, got $sends"; }
  rm -rf "$tmpd"
  pass "agy trust gate succeeds when the accepted dialog stays in scrollback"
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
test_agy_effort_never_emits_a_combination_agy_rejects
test_agy_is_refused_as_a_secondmate_harness
test_agy_not_recovery_graded_in_secondmate_sweep
test_agy_detection_wired
test_agy_argv_match_is_anchored
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
test_agy_trust_gate_clears_when_dialog_stays_in_scrollback
test_agy_trust_gate_fails_loudly_on_budget
