#!/usr/bin/env bash
# Behavior tests for the verified Cursor CLI (`cursor-agent`) crewmate adapter.
#
# Fixtures reproduce the rendering observed live on cursor-agent
# 2026.07.23-e383d2b under tmux 3.7b. Two of cursor's properties are unlike every
# previously verified adapter and are what these tests exist to pin:
#
#   1. Its composer is BARE (no box) and it draws its OWN block cursor, leaving
#      the terminal cursor parked on a blank row well below the composer. A
#      cursor-anchored read therefore inspects a blank row and reports "empty"
#      while real text sits unsubmitted - the false-empty that lets the away-mode
#      injector type over live input and lets the submit core report a swallowed
#      Enter as delivered.
#   2. Its whole EMPTY composer is de-emphasised - agent glyph and placeholder
#      alike - with the self-drawn block cursor rendering one placeholder
#      character at normal intensity in reverse video. Ghost stripping correctly
#      removes everything else, so that single leftover character would read as
#      real typed input on every idle pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-tmux-lib.sh"
TMUX_BACKEND="$ROOT/bin/backends/tmux.sh"
HARNESS="$ROOT/bin/fm-harness.sh"

# shellcheck source=/dev/null
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-cursor-harness)

ARROW=$(printf '\xe2\x86\x92')   # U+2192, cursor-agent's composer glyph

# The live idle composer row: a background band, a DIM glyph, one reverse-video
# block-cursor character at normal intensity, then the DIM remainder of the
# placeholder.
idle_composer_row() {  # <placeholder-first-char> <placeholder-rest>
  printf '\033[48;2;21;21;21m \033[2m%s \033[0;7m\033[48;2;21;21;21m%s\033[0;2m\033[48;2;21;21;21m%s\033[0m\033[49m' \
    "$ARROW" "$1" "$2"
}

# A full visible pane whose composer sits well above the parked terminal cursor.
make_pane_file() {  # <file> <composer-row-styled> [extra-trailing-blank-rows]
  local file=$1 composer=$2 blanks=${3:-6} i
  {
    printf '  Cursor Agent\n'
    printf '  v2026.07.23-e383d2b\n'
    printf '\n'
    printf '  1. One is where everything starts.\n'
    printf '\n'
    printf '%s\n' "$composer"
    printf '\n'
    printf '  Opus 5 300K Low                     Run Everything\n'
    printf '  /tmp/repo %s main\n' '·'
    i=0
    while [ "$i" -lt "$blanks" ]; do printf '\n'; i=$((i + 1)); done
  } > "$file"
}

# A fake tmux serving one styled pane file, with the terminal cursor parked on a
# blank row (FM_FAKE_CY), exactly as cursor-agent leaves it.
make_fake_tmux() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '%s\n' "${FM_FAKE_CY:-0}"; exit 0 ;;
        *pane_current_command*) printf '%s\n' "${FM_FAKE_COMM:-node}"; exit 0 ;;
      esac
    done
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
    if [ -n "$start" ] && [ "$start" = "$end" ]; then
      # Single-row read at the parked cursor row.
      LC_ALL=C sed -n "$((start + 1))p" "$f" 2>/dev/null
      exit 0
    fi
    if [ "$has_e" = 1 ]; then
      cat "$f" 2>/dev/null
    else
      LC_ALL=C awk '{gsub(/\033\[[0-9;:]*m/, ""); print}' "$f" 2>/dev/null
    fi
    exit 0 ;;
  list-windows) printf '%s\n' "${FM_FAKE_WINDOWS:-fakepane}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fb/tmux"
  printf '%s\n' "$fb"
}

# --- busy signature ---------------------------------------------------------

test_busy_signature_matches_only_the_composer_anchored_hint() {
  local busy_row idle_row devserver
  busy_row="  $ARROW Add a follow-up                            ctrl+c to stop"
  idle_row="  $ARROW Add a follow-up"
  # A dev server's own hint: the same words, NOT in cursor's composer row.
  devserver="  Press Ctrl+C to stop"

  printf '%s\n' "$busy_row" | fm_busy_lines_match cursor \
    || fail "cursor busy composer row was not recognised as busy"
  printf '%s\n' "$idle_row" | fm_busy_lines_match cursor \
    && fail "cursor idle composer row was wrongly recognised as busy"
  printf '%s\n' "$devserver" | fm_busy_lines_match cursor \
    && fail "a dev server's 'Press Ctrl+C to stop' must not read as a busy cursor turn"
  pass "cursor busy signature matches its composer-anchored hint, not the bare phrase"
}

test_busy_signature_is_not_shared_across_harnesses() {
  local busy_row
  busy_row="  $ARROW Add a follow-up                            ctrl+c to stop"
  # Like claude's and kimi's, cursor's signature stays out of the shared default,
  # so an unrecorded harness never borrows it.
  printf '%s\n' "$busy_row" | fm_busy_lines_match '' \
    && fail "cursor's signature must not be in the shared unrecorded-harness default"
  printf '%s\n' "$busy_row" | fm_busy_lines_match grok \
    && fail "grok must not borrow cursor's busy signature"
  # And cursor must not borrow anyone else's.
  printf '%s\n' '  esc to interrupt' | fm_busy_lines_match cursor \
    && fail "cursor must not borrow claude/codex's busy signature"
  pass "cursor's busy signature is neither borrowed nor lent"
}

test_busy_signature_survives_tool_execution_rendering() {
  local busy_row
  # During a shell tool the spinner WORD changes (Working -> Running) while the
  # composer hint is unchanged, which is why the word is never the signature.
  busy_row="  $ARROW Add a follow-up                            ctrl+c to stop"
  printf ' %s Running  114 tokens\n%s\n' "$(printf '\xe2\xa0\xa0\xe2\xa0\x9b')" "$busy_row" \
    | fm_busy_lines_match cursor \
    || fail "cursor busy signature lost during tool execution"
  printf ' %s Running  114 tokens\n' "$(printf '\xe2\xa0\xa0\xe2\xa0\x9b')" \
    | fm_busy_lines_match cursor \
    && fail "the rotating spinner word must not be treated as the signature"
  pass "cursor busy signature holds across tool execution and ignores the spinner word"
}

# --- composer classification ------------------------------------------------

test_parked_cursor_idle_composer_reads_empty() {
  local dir fb pane state
  dir="$TMP_ROOT/idle"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  pane="$dir/pane.txt"
  make_pane_file "$pane" "$(idle_composer_row A 'dd a follow-up')"
  # Row 5 is the composer; the terminal cursor is parked on blank row 10.
  state=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$pane" FM_FAKE_CY=10 \
    fm_tmux_composer_state "fakepane")
  [ "$state" = empty ] || fail "idle cursor composer read '$state', expected empty"
  pass "an idle cursor composer reads empty despite its self-drawn block cursor"
}

test_parked_cursor_fresh_launch_placeholder_reads_empty() {
  local dir fb pane state
  dir="$TMP_ROOT/idle-fresh"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  pane="$dir/pane.txt"
  # The other placeholder cursor-agent shows, on a never-used session.
  make_pane_file "$pane" "$(idle_composer_row P 'lan, search, build anything')"
  state=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$pane" FM_FAKE_CY=10 \
    fm_tmux_composer_state "fakepane")
  [ "$state" = empty ] || fail "fresh-launch cursor composer read '$state', expected empty"
  pass "a fresh-launch cursor composer placeholder reads empty"
}

test_parked_cursor_pending_text_is_not_missed() {
  local dir fb pane state
  dir="$TMP_ROOT/pending"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  pane="$dir/pane.txt"
  # Real typed text: cursor-agent renders the glyph and the text at NORMAL
  # intensity, and the placeholder is gone.
  make_pane_file "$pane" "  $ARROW unsubmitted instruction"
  state=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$pane" FM_FAKE_CY=10 \
    fm_tmux_composer_state "fakepane")
  [ "$state" = pending ] || fail "unsubmitted cursor text read '$state', expected pending"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$pane" FM_FAKE_CY=10 \
    fm_pane_input_pending "fakepane" \
    || fail "unsubmitted cursor text was not treated as pending input"
  pass "unsubmitted text in a parked-cursor composer is never read as empty"
}

test_busy_cursor_composer_still_reads_empty() {
  local dir fb pane state
  dir="$TMP_ROOT/busy-composer"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  pane="$dir/pane.txt"
  # Mid-turn the placeholder row gains a right-aligned stop hint; it is still an
  # empty composer, so a queued steer must not be deferred forever.
  make_pane_file "$pane" \
    "$(idle_composer_row A 'dd a follow-up')                    ctrl+c to stop"
  state=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$pane" FM_FAKE_CY=10 \
    fm_tmux_composer_state "fakepane")
  [ "$state" = empty ] || fail "busy cursor composer read '$state', expected empty"
  pass "a busy cursor composer row still reads empty"
}

test_blank_cursor_row_without_a_cursor_composer_is_unchanged() {
  local dir fb pane state
  dir="$TMP_ROOT/no-composer"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")
  pane="$dir/pane.txt"
  # No cursor-agent composer anywhere: the bare-row fallback must behave exactly
  # as it did before, so no already-verified adapter changes behaviour.
  make_pane_file "$pane" "  ordinary agent output line"
  state=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$pane" FM_FAKE_CY=10 \
    fm_tmux_composer_state "fakepane")
  [ "$state" = empty ] || fail "blank cursor row without a cursor composer read '$state'"
  pass "a blank cursor row with no cursor composer keeps the pre-existing verdict"
}

test_bare_arrow_glyph_is_an_agent_composer_not_a_dead_shell() {
  local state
  # Bare `→` is cursor's own prompt glyph, so it is a genuine empty agent
  # composer - unlike the shell glyphs, which stay `unknown` on a bare row.
  state=$(fm_composer_classify_content 0 "$ARROW")
  [ "$state" = empty ] || fail "bare cursor glyph read '$state', expected empty"
  state=$(fm_composer_classify_content 0 '$')
  [ "$state" = unknown ] || fail "dead-shell rule regressed: bare '\$' read '$state'"
  state=$(fm_composer_classify_content 0 '>')
  [ "$state" = unknown ] || fail "dead-shell rule regressed: bare '>' read '$state'"
  pass "the bare cursor glyph is an agent composer while shell glyphs stay unknown"
}

test_placeholder_rule_does_not_swallow_real_text() {
  local state
  # The placeholder rule is anchored to the glyph and the exact placeholder, so
  # text that merely mentions it is still pending.
  state=$(fm_composer_classify_content 0 "$ARROW please add a follow-up test")
  [ "$state" = pending ] || fail "real text mentioning the placeholder read '$state'"
  pass "the cursor placeholder rule does not swallow real typed text"
}

# --- harness detection ------------------------------------------------------

test_env_marker_detects_cursor() {
  local out
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT CURSOR_AGENT=1 "$HARNESS")
  [ "$out" = cursor ] || fail "CURSOR_AGENT=1 detected as '$out', expected cursor"
  pass "fm-harness detects cursor from its CURSOR_AGENT marker"
}

test_cursor_is_an_accepted_configured_crew_harness() {
  local dir out
  dir="$TMP_ROOT/crew-config"; mkdir -p "$dir/config"
  printf 'cursor\n' > "$dir/config/crew-harness"
  out=$(FM_CONFIG_OVERRIDE="$dir/config" "$HARNESS" crew)
  [ "$out" = cursor ] || fail "configured crew harness resolved to '$out', expected cursor"
  out=$(FM_CONFIG_OVERRIDE="$dir/config" "$HARNESS" secondmate)
  [ "$out" = cursor ] || fail "secondmate fallback resolved to '$out', expected cursor"
  pass "cursor resolves as a configured crewmate and secondmate harness"
}

# --- tmux agent liveness ----------------------------------------------------

test_agent_liveness_states() {
  local dir fb state
  dir="$TMP_ROOT/liveness"; mkdir -p "$dir"
  fb=$(make_fake_tmux "$dir")

  agent_state() {  # <fake-pane-current-command>
    PATH="$fb:$PATH" FM_BACKEND_LIB_DIR="$ROOT/bin" FM_FAKE_WINDOWS=win FM_FAKE_COMM="$1" \
      bash -c '. "$0"; fm_backend_tmux_agent_state "sess:win"' "$TMUX_BACKEND"
  }

  state=$(agent_state 'cursor-agent')
  [ "$state" = alive ] || fail "a reported cursor-agent command read '$state', expected alive"

  # The verified local reality: tmux resolves the pane to the bundled `node`, so
  # a live cursor pane is `ambiguous` - preserved, never relaunched.
  state=$(agent_state 'node')
  [ "$state" = ambiguous ] || fail "a live cursor pane reporting node read '$state', expected ambiguous"

  # Death detection is unaffected: an exited cursor pane falls back to the shell.
  state=$(agent_state 'zsh')
  [ "$state" = dead ] || fail "an exited cursor pane read '$state', expected dead"
  pass "cursor pane liveness: alive when named, ambiguous as node, dead on the shell"
}

test_busy_signature_matches_only_the_composer_anchored_hint
test_busy_signature_is_not_shared_across_harnesses
test_busy_signature_survives_tool_execution_rendering
test_parked_cursor_idle_composer_reads_empty
test_parked_cursor_fresh_launch_placeholder_reads_empty
test_parked_cursor_pending_text_is_not_missed
test_busy_cursor_composer_still_reads_empty
test_blank_cursor_row_without_a_cursor_composer_is_unchanged
test_bare_arrow_glyph_is_an_agent_composer_not_a_dead_shell
test_placeholder_rule_does_not_swallow_real_text
test_env_marker_detects_cursor
test_cursor_is_an_accepted_configured_crew_harness
test_agent_liveness_states

echo "# all fm-cursor-harness tests passed"
