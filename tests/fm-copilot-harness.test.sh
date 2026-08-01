#!/usr/bin/env bash
# Behavior tests for the verified GitHub Copilot CLI crewmate adapter (1.0.75).
#
# Every literal in this file is an EMPIRICAL capture from a live `copilot -i`
# pane driven through tmux (see docs/verification/copilot-adapter.md):
#   - busy footer:      " ◎ Working esc interrupt"  (optional " · <size>" infix;
#                        compound anchor 'Working.*esc interrupt' - bare
#                        "esc interrupt" collides with opencode's own anchor)
#   - idle composer:    bare "❯" glyph, NO placeholder text of any kind
#   - agent glyph:      ❯ (U+276F, already a verified empty-composer glyph)
#   - launch:           copilot --allow-all --no-ask-user [--model M]
#                        [--reasoning-effort E] -i "<brief>"
#   - interrupt:         single Ctrl-C mid-turn; exit: /exit (Esc is a no-op)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"   # brings fm-composer-lib.sh + busy defaults/matcher

classify() { fm_composer_classify_content "$@"; }

# --- launch template (mechanics half) ---------------------------------------

test_copilot_launch_template_is_pinned() {
  local line="    copilot) printf '%s' 'copilot --allow-all --no-ask-user __MODELFLAG____EFFORTFLAG__-i \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"' ;;"
  grep -Fqx -- "$line" "$SPAWN" \
    || fail "fm-spawn: verified copilot launch template missing/changed"
  pass "fm-spawn: copilot launch template is the verified argv-seed line"
}

test_existing_launch_templates_untouched() {
  grep -Fq "claude --dangerously-skip-permissions __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "claude launch template changed"
  grep -Fq "cline -i --tui --auto-approve true __MODELFLAG____EFFORTFLAG__" "$SPAWN" \
    || fail "cline launch template changed"
  grep -Fq 'cursor-agent --force __MODELFLAG__' "$SPAWN" \
    || fail "cursor-agent launch template changed"
  pass "fm-spawn: pre-existing adapters' launch templates are untouched"
}

test_copilot_is_a_known_bare_adapter_name() {
  # copilot must be accepted as a bare adapter name, not routed to the raw-launch hatch.
  # Match an executable case-pattern line, not the usage comment that spells the
  # same allowlist, and stay robust to later adapters appended after copilot
  # (e.g. |copilot|agy) - pinning the closing paren made this fence fail the
  # moment a new adapter joined the list, while copilot was still in it.
  grep -Eq "^[[:space:]]*[^#]*\|copilot[|)]" "$SPAWN" \
    || fail "fm-spawn: copilot not added to a known-harness allowlist"
  pass "fm-spawn: copilot is recognized as a known bare adapter name"
}

test_copilot_model_and_effort_flags() {
  # copilot takes --model and maps effort to --reasoning-effort, accepting the
  # full shared low|medium|high|xhigh|max vocabulary (no tier omitted, unlike
  # cline/codex/grok).
  # Scope the needle to the function that actually builds the flag, so deleting
  # copilot from model_flag_for_harness cannot stay green off some other line.
  local model_fn
  model_fn=$(sed -n '/^model_flag_for_harness()/,/^}/p' "$SPAWN")
  printf '%s\n' "$model_fn" | grep -Eq '^ *[^)]*\|copilot[|)]' \
    || fail "fm-spawn: copilot not in the --model allowlist"
  grep -Fq "low|medium|high|xhigh|max) printf -- '--reasoning-effort %s '" "$SPAWN" \
    || fail "fm-spawn: copilot effort->--reasoning-effort mapping missing"
  pass "fm-spawn: copilot gets --model and effort->--reasoning-effort (low|medium|high|xhigh|max)"
}

# --- detection --------------------------------------------------------------

test_copilot_detection_wired() {
  # copilot is a standalone compiled (Bun) binary whose /proc/<pid>/comm is
  # literally "MainThread" - never "copilot" or "node"/"python" - so detection
  # needs its own ancestry case (args-substring fallback) in addition to the
  # direct comm case and the verified COPILOT_CLI=1 env marker.
  grep -Fq '*copilot*) echo copilot; return ;;' "$HARNESS" \
    || fail "fm-harness: copilot direct ancestry case missing"
  grep -Fq 'MainThread)' "$HARNESS" \
    || fail "fm-harness: copilot MainThread ancestry fallback missing"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  grep -Fq '[ "${COPILOT_CLI:-}" = "1" ]' "$HARNESS" \
    || fail "fm-harness: copilot COPILOT_CLI=1 env marker missing"
  pass "fm-harness: copilot is detected by env marker and process ancestry (incl. MainThread fallback)"
}

# --- busy signature (knowledge half) ----------------------------------------

test_copilot_busy_default_defined() {
  [ -n "${FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT:-}" ] \
    || fail "FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT is not defined"
  pass "fm-tmux-lib: FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT is defined"
}

test_copilot_busy_line_matches() {
  # Real captured busy lines, with and without the tool-output-size infix.
  printf '%s' ' ◎ Working esc interrupt                                GPT-5.6 Terra' | fm_busy_lines_match copilot \
    || fail "copilot busy footer 'Working esc interrupt' did not classify busy"
  printf '%s' ' ◎ Working · 786 B esc interrupt                        GPT-5.6 Terra' | fm_busy_lines_match copilot \
    || fail "copilot busy footer with size infix did not classify busy"
  pass "fm_busy_lines_match: copilot 'Working.*esc interrupt' footer reads busy (with or without size infix)"
}

test_copilot_idle_line_not_busy() {
  if printf '%s' '❯' | fm_busy_lines_match copilot; then
    fail "copilot idle composer must not read busy"
  fi
  if printf '%s' ' / commands · ? help · tab next tab                    GPT-5.6 Terra' | fm_busy_lines_match copilot; then
    fail "copilot idle status bar must not read busy"
  fi
  pass "fm_busy_lines_match: copilot idle composer/status bar does not read busy"
}

test_copilot_does_not_borrow_signatures() {
  # G4: the copilot matcher must reject every foreign harness's literal token.
  # "esc interrupt" alone (no "Working") is opencode's own exact anchor - the
  # near-miss this compound regex exists to avoid.
  local foreign
  for foreign in 'esc to interrupt' 'esc interrupt' 'Working...' 'Ctrl+c:cancel' 'esc to cancel' 'ctrl+c to stop'; do
    if printf '%s' "$foreign" | fm_busy_lines_match copilot; then
      fail "copilot busy regex borrowed foreign token '$foreign'"
    fi
  done
  pass "fm_busy_lines_match: copilot uses only its own verified compound footer, no foreign borrow"
}

# --- composer idle classification -------------------------------------------

test_copilot_idle_placeholders_read_empty() {
  # copilot has NO idle placeholder text of any kind (verified: first-ready and
  # post-turn composer rows are byte-identical - just the bare ❯ glyph). Unlike
  # cline/cursor-agent there is no placeholder string to run through an idle-RE;
  # the bare agent glyph alone (already shared with claude) is what must read
  # empty, bordered or bare.
  local out
  out=$(classify 1 '❯')
  [ "$out" = empty ] || fail "bordered bare copilot composer glyph must read empty, got '$out'"
  out=$(classify 0 '❯')
  [ "$out" = empty ] || fail "unbordered bare copilot composer glyph must read empty, got '$out'"
  pass "fm_composer_classify_content: copilot's bare ❯ composer reads empty (no placeholder text exists)"
}

test_copilot_real_input_reads_pending() {
  local out
  out=$(classify 1 "fix the null-pointer in the parser")
  [ "$out" = pending ] \
    || fail "real copilot composer input must read pending, got '$out'"
  pass "fm_composer_classify_content: real copilot input still reads pending"
}

# --- shared fleet-wide defaults untouched (regression fence) ----------------

test_backend_idle_re_defaults_cover_copilot() {
  # copilot needed NO new placeholder in FM_COMPOSER_IDLE_RE_DEFAULT and NO
  # backend IDLE_RE override (verified; docs/verification/copilot-adapter.md
  # "Ready / idle composer" - there is no placeholder text to strip). This is
  # the PRD's coverage check adapted to that finding: prove the bare ❯ glyph
  # stays classified through the shared, untouched fleet-wide defaults rather
  # than needing a per-backend addition.
  printf '%s' '❯' | grep -qE "$FM_COMPOSER_BARE_PROMPT_RE_DEFAULT" \
    || fail "shared FM_COMPOSER_BARE_PROMPT_RE_DEFAULT does not match copilot's ❯ composer row"
  local b bad=0 up
  for b in herdr cmux orca; do
    up=$(printf '%s' "$b" | tr '[:lower:]' '[:upper:]')
    grep -Eq "FM_BACKEND_${up}_IDLE_RE=.*FM_COMPOSER_IDLE_RE_DEFAULT" \
      "$ROOT/bin/backends/$b.sh" || { echo "  backend $b IDLE_RE does not use the shared default"; bad=1; }
  done
  [ "$bad" -eq 0 ] || fail "one or more backend IDLE_RE defaults do not use the shared idle default"
  pass "copilot's bare-glyph composer is covered by the untouched shared fleet-wide defaults"
}

# --- trust gate (spawn-time readiness step, WI-4) ----------------------------
#
# The folder-trust dialog is real and blocking (docs/verification/
# copilot-adapter.md "Trust / permission gate"); a genuinely fresh worktree is
# never on copilot's persistent trust allow-list, so every case below forces
# an explicitly UNTRUSTED, non-$HOME path fixture (/opt/pool/crew/wt-0N) - a
# test that only ever exercises a $HOME path proves nothing (R4). The suite
# stays hermetic throughout: no live `copilot` process, no network, no read of
# the real ~/.copilot config.
#
# Behavior cases use the repo's function-extraction + eval idiom
# (tests/fm-backend-herdr.test.sh:1226): the gate helpers are sed-extracted
# from fm-spawn.sh and eval'd in a disposable `bash -c` subshell, with
# copilot_capture()/spawn_send_key() overridden by a scripted fixture. A
# fixture-local step counter MUST be file-backed, not a plain shell variable:
# $(copilot_capture) forks a subshell per call, so an in-process counter
# resets to its initial value on every invocation and never advances.
COPILOT_GATE_SOURCE=$(sed -n '/^copilot_capture()/,/^copilot_spawn_fail()/p' "$SPAWN" | sed '$d')

test_copilot_trust_gate_wired() {
  grep -Fq 'Confirm folder trust' "$SPAWN" \
    || fail "fm-spawn: copilot folder-trust dialog literal missing"
  grep -Fq 'copilot_wait_for_trust_clear' "$SPAWN" \
    || fail "fm-spawn: copilot trust readiness gate missing"
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  grep -Fq 'if [ "$HARNESS" = copilot ]; then' "$SPAWN" \
    || fail "fm-spawn: copilot trust gate call site not guarded by HARNESS = copilot"
  pass "fm-spawn: copilot folder-trust readiness gate is wired"
}

test_copilot_trust_gate_clears_untrusted_path() {
  local tmpd send_log seq_file out sends
  tmpd=$(fm_test_tmproot fm-copilot-trust-clear)
  # fm_test_tmproot's cleanup trap fires when the command-substitution
  # subshell that ran it exits, so $tmpd is already gone by the time this
  # line runs (the repo's established idiom - see e.g.
  # tests/fm-arm-pretool-check.test.sh - always mkdir -p a subpath
  # immediately after calling it to recreate the directory).
  mkdir -p "$tmpd"
  send_log="$tmpd/sends"; seq_file="$tmpd/seq"
  : > "$send_log"; echo 0 > "$seq_file"
  # Scripted pane sequence: dialog, dialog (Enter already sent, still
  # showing), busy-footer. The dialog names /opt/pool/crew/wt-01 -
  # explicitly untrusted, explicitly outside $HOME (R4).
  out=$(GATE_SOURCE="$COPILOT_GATE_SOURCE" SEND_LOG="$send_log" SEQ_FILE="$seq_file" bash -c '
    eval "$GATE_SOURCE"
    T=fake:0
    copilot_capture() {
      local n
      n=$(cat "$SEQ_FILE"); n=$((n + 1)); echo "$n" > "$SEQ_FILE"
      if [ "$n" -le 2 ]; then
        printf "%s\n" "Confirm folder trust" "/opt/pool/crew/wt-01" "❯ 1. Yes"
      else
        printf "%s\n" " ◎ Working esc interrupt                      GPT-5.6 Terra"
      fi
    }
    spawn_send_key() { printf "%s %s\n" "$1" "$2" >> "$SEND_LOG"; }
    FM_COPILOT_TRUST_POLLS=10
    FM_COPILOT_POLL_INTERVAL=0
    copilot_wait_for_trust_clear && printf cleared || printf timeout
  ')
  [ "$out" = cleared ] \
    || fail "copilot_wait_for_trust_clear must clear on an untrusted non-\$HOME path, got '$out'"
  sends=$(wc -l < "$send_log")
  [ "$sends" -eq 1 ] \
    || fail "Enter must be sent exactly once (S7), sent $sends time(s): $(cat "$send_log")"
  grep -Fq 'fake:0 Enter' "$send_log" \
    || fail "the one keystroke sent was not a named Enter key: $(cat "$send_log")"
  pass "copilot_wait_for_trust_clear: clears an untrusted /opt/pool/... path with exactly one Enter"
}

test_copilot_trust_gate_times_out_loudly() {
  # G2/S6, the load-bearing case: a fixture that returns the dialog forever.
  # FM_COPILOT_TRUST_POLLS=3 + FM_COPILOT_POLL_INTERVAL=0 must return
  # non-zero PROMPTLY - this proves "fails loud, never hangs", so it must not
  # be able to pass by hanging.
  local start end elapsed out
  start=$(date +%s%N)
  out=$(GATE_SOURCE="$COPILOT_GATE_SOURCE" bash -c '
    eval "$GATE_SOURCE"
    T=fake:0
    copilot_capture() {
      printf "%s\n" "Confirm folder trust" "/opt/pool/crew/wt-02" "❯ 1. Yes"
    }
    spawn_send_key() { :; }
    FM_COPILOT_TRUST_POLLS=3
    FM_COPILOT_POLL_INTERVAL=0
    copilot_wait_for_trust_clear && printf cleared || printf timeout
  ')
  end=$(date +%s%N)
  elapsed=$(( (end - start) / 1000000 ))
  [ "$out" = timeout ] \
    || fail "copilot_wait_for_trust_clear must fail (non-zero) when the dialog never clears, got '$out'"
  [ "$elapsed" -lt 1000 ] \
    || fail "trust-gate timeout must complete near-instantly with FM_COPILOT_POLL_INTERVAL=0, took ${elapsed}ms"
  pass "copilot_wait_for_trust_clear: exhausts FM_COPILOT_TRUST_POLLS=3 and fails loudly in ${elapsed}ms, never hangs (G2/S6)"
}

test_copilot_trust_anchor_matches_shared_busy_default() {
  # Drift fence (T1): the busy literal is necessarily duplicated between
  # fm-tmux-lib.sh's FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT and the gate helper
  # in fm-spawn.sh (fm-spawn.sh does not source fm-tmux-lib.sh). Pin the two
  # together so they cannot diverge silently across a copilot TUI update.
  # FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT is already in scope (this file sources
  # fm-tmux-lib.sh at the top).
  local extracted
  extracted=$(printf '%s' "$COPILOT_GATE_SOURCE" | grep -F "grep -Eq" \
    | sed -E "s/.*grep -Eq '([^|]*)\|.*/\1/")
  [ -n "$extracted" ] || fail "could not extract the duplicated busy literal from the gate source"
  [ "$extracted" = "$FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT" ] \
    || fail "duplicated busy literal in fm-spawn.sh ('$extracted') has drifted from FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT ('$FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT')"
  pass "copilot trust gate: duplicated busy literal in fm-spawn.sh matches FM_TMUX_COPILOT_BUSY_REGEX_DEFAULT (drift fence)"
}

test_copilot_past_trust_does_not_match_the_dialog() {
  # E9 regression fence - the single highest-value new test in this suite.
  # The trust dialog's own option cursor renders as the bare ❯ glyph
  # (byte-identical to copilot's idle composer glyph). Feed
  # copilot_pane_is_past_trust the VERBATIM captured trust dialog from
  # docs/verification/copilot-adapter.md and assert it does NOT read past
  # trust; then feed it the real busy footer and the real idle status bar
  # (also verbatim captures) and assert both DO read past trust.
  local dialog_capture busy_capture idle_capture out
  # shellcheck disable=SC2016  # single quotes are deliberate: the ``` fence is a literal needle, not an expansion
  dialog_capture=$(sed -n '/^## Trust \/ permission gate/,/^## Ready/p' \
      "$ROOT/docs/verification/copilot-adapter.md" \
    | sed -n '/^```$/,/^```$/p' | sed '1d;$d')
  printf '%s' "$dialog_capture" | grep -Fq 'Confirm folder trust' \
    || fail "test setup: extracted dialog capture is missing/wrong (doc structure changed?)"

  out=$(GATE_SOURCE="$COPILOT_GATE_SOURCE" DIALOG="$dialog_capture" bash -c '
    eval "$GATE_SOURCE"
    copilot_pane_is_past_trust "$DIALOG" && printf matched || printf clean
  ')
  [ "$out" = clean ] \
    || fail "E9 regression: copilot_pane_is_past_trust matched the verbatim trust dialog capture (bare-glyph collision)"

  busy_capture=' ◐ Working esc interrupt                                          GPT-5.6 Terra'
  out=$(GATE_SOURCE="$COPILOT_GATE_SOURCE" BUSY="$busy_capture" bash -c '
    eval "$GATE_SOURCE"
    copilot_pane_is_past_trust "$BUSY" && printf matched || printf clean
  ')
  [ "$out" = matched ] || fail "copilot_pane_is_past_trust must match the real busy footer"

  idle_capture=' / commands · ? help · tab next tab                              GPT-5.6 Terra'
  out=$(GATE_SOURCE="$COPILOT_GATE_SOURCE" IDLE="$idle_capture" bash -c '
    eval "$GATE_SOURCE"
    copilot_pane_is_past_trust "$IDLE" && printf matched || printf clean
  ')
  [ "$out" = matched ] || fail "copilot_pane_is_past_trust must match the real idle status bar"

  pass "copilot_pane_is_past_trust: rejects the E9 glyph-colliding trust dialog; matches busy footer + idle status bar"
}

test_copilot_trust_gate_has_no_home_shortcut() {
  # S8 / R4 fence: the gate must engage unconditionally for HARNESS=copilot,
  # never short-circuited for paths under $HOME (that would silently
  # re-create the local-invisibility trap the whole PRD exists to close).
  # Also S1: since Option B shipped (no pre-seed), fm-spawn.sh must contain
  # zero reference to copilot's trust config at all - no write, no read, not
  # even a diagnostic - proving R1 is eliminated structurally rather than
  # merely mitigated.
  # shellcheck disable=SC2016  # single quotes are deliberate: a literal needle string, not an expansion
  printf '%s' "$COPILOT_GATE_SOURCE" | grep -Fq '$HOME' \
    && fail "copilot trust gate helpers must not contain a \$HOME-prefix shortcut (S8)"
  grep -Fq 'trustedFolders' "$SPAWN" \
    && fail "fm-spawn.sh must not reference trustedFolders: Option B ships zero writes to copilot's config (S1)"
  grep -Fq 'copilotTokens' "$SPAWN" \
    && fail "fm-spawn.sh must not reference copilotTokens (S1)"
  grep -Fq '.copilot/config.json' "$SPAWN" \
    && fail "fm-spawn.sh must not reference ~/.copilot/config.json: Option B never opens it (S1)"
  pass "fm-spawn.sh: copilot trust gate has no \$HOME shortcut and never references copilot's credential-bearing config (S1/S8)"
}

# --- run --------------------------------------------------------------------
test_copilot_launch_template_is_pinned
test_existing_launch_templates_untouched
test_copilot_is_a_known_bare_adapter_name
test_copilot_model_and_effort_flags
test_copilot_detection_wired
test_copilot_busy_default_defined
test_copilot_busy_line_matches
test_copilot_idle_line_not_busy
test_copilot_does_not_borrow_signatures
test_copilot_idle_placeholders_read_empty
test_copilot_real_input_reads_pending
test_backend_idle_re_defaults_cover_copilot
test_copilot_trust_gate_wired
test_copilot_trust_gate_clears_untrusted_path
test_copilot_trust_gate_times_out_loudly
test_copilot_trust_anchor_matches_shared_busy_default
test_copilot_past_trust_does_not_match_the_dialog
test_copilot_trust_gate_has_no_home_shortcut
echo "ALL PASS: fm-copilot-harness"
