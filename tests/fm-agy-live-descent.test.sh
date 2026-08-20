#!/usr/bin/env bash
# tests/fm-agy-live-descent.test.sh - the regression for moving an ALREADY
# RUNNING agy worker down the ladder when its rung crosses its floor.
#
# The launch gate (tests/fm-agy-ladder-enforcement.test.sh) covers a worker
# being STARTED. It cannot cover the failure this suite exists for: on
# 2026-08-20 a crewmate launched on rung 1 above the floor and then consumed
# Claude Opus 4.6 (Thinking) to zero during its run, which spent the captain's
# reserved quarter and left the worker stalled on an exhausted model. Nothing
# watched a run in progress.
#
# The load-bearing contracts:
#   1. A rung crossing its floor is detected from the SAME evidence and the SAME
#      policy the launch gate uses, never from a second copy of the rules.
#   2. The descent target is whatever bin/fm-agy-ladder-lib.sh authorizes, so
#      strict exhaustion still governs; a rung the gate refuses is never taken.
#   3. The rendered model picker is positively identified before a single
#      navigation key is sent, and every way of failing that identification
#      refuses.
#   4. The number of moves is parsed from the rendered list, never assumed, and
#      an ambiguous or absent target refuses instead of guessing.
#   5. A completed switch is believed only from BOTH independent signals agy
#      leaves behind. Losing either one must refuse - that is asserted by
#      driving the two apart deliberately.
#   6. The per-poll evaluation is silent and free for a healthy fleet, escalates
#      once rather than every minute, and refuses instead of acting whenever the
#      durable record and the running worker disagree.
#
# WHAT THIS SUITE DOES NOT PROVE. The picker's shape is a VENDOR fact, and the
# fixtures below are real agy 1.1.16 output captured in an isolated lab
# (docs/verification/agy-model-switch.md). This suite pins the classifier and
# the walk arithmetic against that output with no harness present, so CI
# enforces them everywhere. It cannot prove agy still draws that picker. That is
# what the opt-in live guard tests/fm-agy-model-switch-live-e2e.test.sh is for;
# run it after every agy upgrade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The backend read is the one thing a portable run cannot have: it needs a real
# pane with a real agy in it. Defining these two BEFORE the library is sourced
# uses the same "already defined wins" composition the libraries use on each
# other, so the tick below runs its real decision logic, against real files,
# with only the pane read and the turn-state read supplied by this file.
FAKE_PANE=
FAKE_BUSY='idle agy-hook'

# FAKE_MODE=static returns FAKE_PANE unchanged, which is all the cases that
# never reach a switch need. FAKE_MODE=picker is a small simulator of the vendor
# TUI itself: it holds a selection, moves it on the arrow keys, and settles on
# Enter, so the walk arithmetic is driven end to end against something that
# behaves like the picker rather than against a fixed screenshot.
#
# Its selection lives in FILES, not variables. The evaluation under test is
# invoked through command substitution and drives the switch through another,
# so every mutation a variable-backed simulator made would be discarded with the
# subshell that made it - and the assertions afterwards would be reading the
# starting state while believing they were reading the result.
FAKE_MODE=static
FAKE_STICKY=0
FAKE_DIR=
FAKE_ROWS=(
  'Gemini 3.7 Flash'
  'Gemini 3.6 Flash'
  'Gemini 3.5 Flash'
  'Gemini 3.1 Pro'
  'Claude Sonnet 4.6 (Thinking)'
  'Claude Opus 4.6 (Thinking)'
  'GPT-OSS 120B (Medium)'
)

fake_selection() { cat "$FAKE_DIR/selection" 2>/dev/null || true; }
fake_settled() { cat "$FAKE_DIR/settled" 2>/dev/null || true; }
fake_phase() { cat "$FAKE_DIR/phase" 2>/dev/null || true; }

# fake_worker_start <state-dir> <model-row-the-worker-is-running>
# The worker begins at its composer, exactly as a live one does; the picker only
# exists once something opens it.
fake_worker_start() {
  FAKE_DIR="$1/.fake-picker"
  mkdir -p "$FAKE_DIR"
  printf '%s' "$2" > "$FAKE_DIR/selection"
  : > "$FAKE_DIR/settled"
  printf 'composer' > "$FAKE_DIR/phase"
  FAKE_MODE=picker
}

# fake_enter: the modal transition that made this worth simulating. An Enter at
# the composer OPENS the picker; an Enter once it is open COMMITS the
# highlighted row. That is why the submitted `/model` must carry exactly one
# Enter: a second one selects a model nobody chose.
fake_enter() {
  if [ "$(fake_phase)" = composer ]; then
    printf 'picker' > "$FAKE_DIR/phase"
  else
    fake_display "$(fake_selection)" > "$FAKE_DIR/settled"
  fi
}

# fake_display: what a row is called once selected. A Gemini family row takes
# its effort from the slider, which this walk always saturates to High; every
# other row already carries its qualifier.
fake_display() {
  case "$1" in
    Gemini*) printf '%s (High)' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

fake_render_picker() {
  local row selected
  selected=$(fake_selection)
  printf 'Switch Model\n\n'
  for row in "${FAKE_ROWS[@]}"; do
    if [ "$row" = "$selected" ]; then
      printf '> %s               (current)\n' "$row"
    else
      printf '  %s\n' "$row"
    fi
  done
  printf '\n  Effort  x\n\nKeyboard: up/down Navigate  left/right Effort  enter Select  esc Go Back\n\n'
  printf '%s | ctx: 2.1%% | quota: 50%% (3h 0m)\n' "$(fake_display "$selected")"
}

fake_render_settled() {
  local settled
  settled=$(fake_settled)
  printf '> do the thing\n\n  working on it\n\n> /model\n  Model set to %s\n\n>\n%s | ctx: 2.1%% | quota: 100%% (4h 0m)\n' \
    "$settled" "$settled"
}

fake_move() {  # <direction>
  local i target selected
  [ "$FAKE_STICKY" = 0 ] || return 0
  selected=$(fake_selection)
  for i in "${!FAKE_ROWS[@]}"; do
    [ "${FAKE_ROWS[$i]}" = "$selected" ] || continue
    if [ "$1" = Up ]; then target=$((i - 1)); else target=$((i + 1)); fi
    [ "$target" -ge 0 ] && [ "$target" -lt "${#FAKE_ROWS[@]}" ] || return 0
    printf '%s' "${FAKE_ROWS[$target]}" > "$FAKE_DIR/selection"
    return 0
  done
}

fake_render_composer() {
  printf '> do the thing\n\n  working on it\n\n>\n%s | ctx: 2.1%% | quota: 50%% (3h 0m)\n' \
    "$(fake_display "$(fake_selection)")"
}

fm_backend_capture() {
  case "$FAKE_MODE" in
    picker)
      if [ -n "$(fake_settled)" ]; then
        fake_render_settled
      elif [ "$(fake_phase)" = picker ]; then
        fake_render_picker
      else
        fake_render_composer
      fi
      ;;
    *) printf '%s' "$FAKE_PANE" ;;
  esac
}

fm_backend_send_key() {
  [ "$FAKE_MODE" = picker ] || return 0
  case "$3" in
    Up|Down) fake_move "$3" ;;
    Enter) fake_enter ;;
    Escape) printf 'composer' > "$FAKE_DIR/phase" ;;
  esac
  return 0
}

# The shared submit helper types once and then presses Enter up to <retries>
# times, so the retry count is not a tuning knob here - it is how many Enters
# reach the worker. Modelling that faithfully is what makes the one-Enter rule
# testable at all.
fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> ...
  local i=0
  [ "$FAKE_MODE" = picker ] || return 0
  while [ "$i" -lt "$4" ]; do
    fake_enter
    i=$((i + 1))
  done
  printf 'pending'
  return 0
}
fm_busy_classify_meta() { printf '%s' "$FAKE_BUSY"; }
fm_meta_get() {
  [ -f "$1" ] || return 0
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
fm_backend_of_meta() {
  local v
  v=$(fm_meta_get "$1" backend)
  printf '%s' "${v:-tmux}"
}
fm_backend_target_of_meta() { fm_meta_get "$1" window; }

# shellcheck source=bin/fm-agy-descent-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-agy-descent-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-descent)

# Readings are written by hand here, so the live intake poll must stay off: a
# real poll would replace them with the host account's own and every
# expectation would turn on whatever agy says today.
export FM_AGY_QUOTA_POLL=off
export FM_AGY_QUOTA_MAX_AGE=300
export FM_AGY_INFLIGHT_TTL=300
export FM_AGY_LADDER_INFLIGHT_MARGIN=1
export FM_AGY_DESCENT_INTERVAL=60
export FM_AGY_DESCENT_GRACE=900

RUNG1='Claude Opus 4.6 (Thinking)'
RUNG2='Gemini 3.1 Pro (High)'
RUNG3='Gemini 3.7 Flash (High)'

NOW=$(date +%s)

record() {  # <state-dir> <display-model> <percent> <reset-window>
  mkdir -p "$1"
  fm_agy_quota_observe "$2 | ctx: 3.0% | quota: $3% ($4)" "$1"
}

fresh_state() {
  local dir="$TMP_ROOT/state-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# meta <state-dir> <id> <model>: the durable record of a live agy worker.
meta() {
  {
    printf 'harness=agy\n'
    printf 'backend=tmux\n'
    printf 'window=fmlab:%s\n' "$2"
    printf 'kind=ship\n'
    printf 'model=%s\n' "$3"
  } > "$1/$2.meta"
}

# --- vendor fixtures --------------------------------------------------------
#
# Captured from a real agy 1.1.16 pane in an isolated lab. Reproduced verbatim
# (including the box-drawing and slider glyphs) because the classifier's whole
# job is to recognise THIS, and a tidied-up paraphrase would prove nothing.

picker_on_rung2() {
  cat <<'EOF'
  ACK

─────────────────────────────────────────────
>
─────────────────────────────────────────────
Switch Model

  Gemini 3.7 Flash
  Gemini 3.6 Flash
  Gemini 3.5 Flash
> Gemini 3.1 Pro               (current)
  Claude Sonnet 4.6 (Thinking)
  Claude Opus 4.6 (Thinking)
  GPT-OSS 120B (Medium)

  Effort  ◂            ●━━━━━━━━━━━━━━━━━━━━━━◉            ▸
                      low                   high
            Deepest reasoning for complex problems — slower but strongest

Keyboard: ↑/↓ Navigate  ←/→ Effort  enter Select  esc Go Back

Gemini 3.1 Pro (High) | ctx: 2.1% | quota: 87% (3h 35m)
EOF
}

picker_on_rung1() {
  picker_on_rung2 | sed \
    -e 's/^> Gemini 3.1 Pro               (current)$/  Gemini 3.1 Pro/' \
    -e 's/^  Claude Opus 4.6 (Thinking)$/> Claude Opus 4.6 (Thinking)               (current)/' \
    -e 's/^Gemini 3.1 Pro (High) | ctx/Claude Opus 4.6 (Thinking) | ctx/'
}

# The pane after a confirmed switch onto rung 3: agy's own acknowledgement plus
# the footer, which are the two independent signals the confirmation demands.
settled_on_rung3() {
  cat <<'EOF'
> Remember this codeword: BANANA-SEVEN. Reply with only the word ACK.

  ACK

> /model
  ⎿  Model set to Gemini 3.7 Flash (High)

─────────────────────────────────────────────
>
─────────────────────────────────────────────
Gemini 3.7 Flash (High) | ctx: 2.1% | quota: 100% (4h 59m)
EOF
}

ordinary_pane() {
  cat <<'EOF'
> do the thing

  working on it

─────────────────────────────────────────────
>
─────────────────────────────────────────────
Claude Opus 4.6 (Thinking) | ctx: 12.0% | quota: 8.0% (3h 41m)
EOF
}

# --- 1. Recognising the picker ----------------------------------------------

test_recognises_the_real_picker() {
  fm_agy_descent_is_picker "$(picker_on_rung2)" \
    || fail "the real agy model picker must be recognised"
  ! fm_agy_descent_is_picker "$(ordinary_pane)" \
    || fail "an ordinary working pane must never be mistaken for the picker"
  ! fm_agy_descent_is_picker "$(settled_on_rung3)" \
    || fail "a pane that has already closed the picker must not read as open"
  ! fm_agy_descent_is_picker "" \
    || fail "an empty capture must not read as the picker"
  pass "fm_agy_descent_is_picker: the real picker is recognised and nothing else is"
}

test_every_missing_marker_refuses_the_picker() {
  local base each
  base=$(picker_on_rung2)

  # Each marker is dropped on its own, so no single one is doing all the work
  # and none of them can go quietly vacuous.
  for each in 'Switch Model' 'enter Select' 'esc Go Back' '(current)'; do
    ! fm_agy_descent_is_picker "$(printf '%s\n' "$base" | grep -vF "$each")" \
      || fail "dropping '$each' must stop the picker being identified"
  done

  # Two selection markers is an unreadable list, not a pickable one.
  ! fm_agy_descent_is_picker \
    "$(printf '%s\n' "$base" | sed 's/^  Gemini 3.6 Flash$/> Gemini 3.6 Flash/')" \
    || fail "two selection markers must refuse rather than pick one"

  # ...and the base itself still passes, so the assertions above are about the
  # dropped marker and not about a fixture that never matched.
  fm_agy_descent_is_picker "$base" \
    || fail "the unmodified fixture must still be identified"
  pass "fm_agy_descent_is_picker: each marker is load-bearing on its own"
}

# --- 2. Parsing the walk ----------------------------------------------------

test_parses_the_rows_agy_actually_draws() {
  local rows
  rows=$(fm_agy_descent_picker_rows "$(picker_on_rung2)")
  [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = 7 ] \
    || fail "the picker's seven model rows must be parsed, got: $rows"
  [ "$(fm_agy_descent_selected_row "$rows")" = 'Gemini 3.1 Pro' ] \
    || fail "the selected row must be read from the marker, not guessed"
  [ "$(fm_agy_descent_row_index "$rows" 'Gemini 3.7 Flash')" = 0 ] \
    || fail "the first row must index 0"
  [ "$(fm_agy_descent_row_index "$rows" 'GPT-OSS 120B (Medium)')" = 6 ] \
    || fail "the last row must index 6"
  ! fm_agy_descent_row_index "$rows" 'Gemini 9 Ultra' >/dev/null \
    || fail "a row the picker does not offer must not resolve to an index"
  pass "fm_agy_descent_picker_rows: the rendered list is parsed, marker included"
}

test_a_ladder_name_resolves_against_the_pickers_own_rows() {
  local rows resolved
  rows=$(fm_agy_descent_picker_rows "$(picker_on_rung2)")

  # A Gemini rung names a family plus an effort the slider owns...
  resolved=$(fm_agy_descent_row_for "$rows" "$RUNG3") \
    || fail "rung 3 must resolve against the picker"
  [ "$resolved" = "$(printf 'Gemini 3.7 Flash\thigh')" ] \
    || fail "rung 3 must resolve to its family row plus a high effort, got '$resolved'"

  # ...while a Claude rung carries its qualifier inline and needs no slider.
  resolved=$(fm_agy_descent_row_for "$rows" "$RUNG1") \
    || fail "rung 1 must resolve against the picker"
  [ "$resolved" = "$(printf 'Claude Opus 4.6 (Thinking)\t')" ] \
    || fail "rung 1 must resolve to an exact row with no effort to set, got '$resolved'"

  # An effort this walk saturates rather than counts must be refused outright.
  ! fm_agy_descent_row_for "$rows" 'Gemini 3.1 Pro (Low)' >/dev/null \
    || fail "an effort below the top of the range must refuse, not be saturated to High"
  ! fm_agy_descent_row_for "$rows" 'Gemini 9 Ultra (High)' >/dev/null \
    || fail "a model the picker does not offer must refuse"
  pass "fm_agy_descent_row_for: the family/effort split is read from the picker, and anything else refuses"
}

test_the_walk_is_counted_from_the_rendered_list() {
  local plan
  plan=$(fm_agy_descent_plan "$(picker_on_rung2)" "$RUNG3") \
    || fail "a descent from rung 2 to rung 3 must produce a plan"
  [ "$plan" = 'Up 3 high' ] \
    || fail "rung 2 sits three rows below rung 3 on this picker; got '$plan'"

  # The same target from a different starting selection must produce a
  # different count. A hard-coded walk would return the same answer here.
  plan=$(fm_agy_descent_plan "$(picker_on_rung1)" "$RUNG3") \
    || fail "a descent from rung 1 must produce a plan"
  [ "$plan" = 'Up 5 high' ] \
    || fail "rung 1 sits five rows below rung 3 on this picker; got '$plan'"

  ! fm_agy_descent_plan "$(picker_on_rung2)" 'Gemini 9 Ultra (High)' >/dev/null \
    || fail "a target the picker does not offer must produce no plan"
  ! fm_agy_descent_plan "$(ordinary_pane)" "$RUNG3" >/dev/null \
    || fail "a pane with no picker in it must produce no plan"
  pass "fm_agy_descent_plan: the move count comes from the rendered list, not from an assumption"
}

# --- 3. Believing the result ------------------------------------------------

test_confirmation_needs_both_signals() {
  local both ack_only footer_only
  both=$(settled_on_rung3)
  fm_agy_descent_confirms "$both" "$RUNG3" \
    || fail "a real settled pane must confirm the switch"

  # Drive the two signals apart. Each one alone must NOT confirm, so neither is
  # carrying the verdict by itself.
  ack_only=$(printf '%s\n' "$both" | sed 's/^Gemini 3.7 Flash (High) | ctx/Gemini 3.1 Pro (High) | ctx/')
  ! fm_agy_descent_confirms "$ack_only" "$RUNG3" \
    || fail "agy's acknowledgement alone must not confirm while the footer disagrees"

  footer_only=$(printf '%s\n' "$both" | grep -vF 'Model set to')
  ! fm_agy_descent_confirms "$footer_only" "$RUNG3" \
    || fail "the footer alone must not confirm without agy's own acknowledgement"

  # And the divergence itself is real: the two doctored panes differ from the
  # original and from each other, so neither assertion above is vacuous.
  [ "$ack_only" != "$both" ] || fail "the footer-doctored fixture must actually differ"
  [ "$footer_only" != "$both" ] || fail "the acknowledgement-stripped fixture must actually differ"
  [ "$ack_only" != "$footer_only" ] || fail "the two doctored fixtures must differ from each other"

  ! fm_agy_descent_confirms "$both" "$RUNG2" \
    || fail "a pane settled on rung 3 must not confirm a switch to rung 2"
  pass "fm_agy_descent_confirms: both signals are required and each is checked independently"
}

# --- 4. The target is the ladder's answer, not a rung number ----------------

test_the_target_is_whatever_the_ladder_authorizes() {
  local state target
  state=$(fresh_state target-one-step)
  record "$state" "$RUNG1" 4.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  record "$state" "$RUNG3" 100.0 '4h 59m'
  target=$(fm_agy_descent_target 1 "$state" "$NOW") \
    || fail "a spent rung 1 with a healthy rung 2 must have a target"
  [ "$target" = 2 ] || fail "the descent must be one rung, to rung 2; got '$target'"

  # Rung 2 spent as well: the gate proves rungs 1 AND 2 exhausted before rung 3
  # is authorized, so stepping down again is the policy's own answer rather than
  # a jump past a rung.
  state=$(fresh_state target-two-spent)
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 0.0 '3h 37m'
  record "$state" "$RUNG3" 100.0 '4h 59m'
  target=$(fm_agy_descent_target 1 "$state" "$NOW") \
    || fail "a spent rung 1 and rung 2 must still reach rung 3"
  [ "$target" = 3 ] || fail "the target must be rung 3; got '$target'"

  # Nothing below is available: refuse, never invent a model off the ladder.
  state=$(fresh_state target-spent)
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 0.0 '3h 37m'
  record "$state" "$RUNG3" 0.0 '4h 59m'
  ! fm_agy_descent_target 1 "$state" "$NOW" >/dev/null \
    || fail "a fully spent ladder must have no target at all"

  # The ladder's asymmetry is inherited whole, in both directions. An unread
  # rung BELOW is still takeable - nothing shows it spent, and refusing here
  # would stall the fleet at exactly the moment it needs to move...
  state=$(fresh_state target-unread-below)
  record "$state" "$RUNG1" 0.0 '3h 41m'
  target=$(fm_agy_descent_target 1 "$state" "$NOW") \
    || fail "an unread rung below must still be reachable; refusing would stall the fleet"
  [ "$target" = 2 ] || fail "the target must be rung 2; got '$target'"

  # ...while an unproven rung ABOVE the candidate blocks it, because descending
  # is the move the policy constrains and absence is not proof of exhaustion.
  state=$(fresh_state target-unproven-above)
  record "$state" "$RUNG2" 0.0 '3h 37m'
  record "$state" "$RUNG3" 100.0 '4h 59m'
  ! fm_agy_descent_target 2 "$state" "$NOW" >/dev/null \
    || fail "rung 3 must not be taken while rung 1 is unproven"
  pass "fm_agy_descent_target: the descent target is the ladder gate's answer, including its refusals"
}

test_crossing_the_floor_uses_the_ladders_own_reading() {
  local state
  state=$(fresh_state needed)
  record "$state" "$RUNG1" 25.0 '3h 41m'
  fm_agy_descent_needed 1 "$state" "$NOW" \
    || fail "rung 1 AT the captain's 25% floor must count as crossed"

  record "$state" "$RUNG1" 25.1 '3h 41m'
  ! fm_agy_descent_needed 1 "$state" "$NOW" \
    || fail "rung 1 above its floor must not be moved"

  # Absence of evidence is not a crossing. Acting on an unknown reading would
  # move live workers for no reason, and the ladder's own asymmetry says only
  # positive evidence refuses a rung's own floor.
  state=$(fresh_state needed-unknown)
  ! fm_agy_descent_needed 1 "$state" "$NOW" \
    || fail "no reading at all must never be treated as a crossing"
  pass "fm_agy_descent_needed: the crossing is the ladder's verdict on the ladder's evidence"
}

# --- 5. The per-poll evaluation ---------------------------------------------

test_a_healthy_fleet_is_silent_and_starts_no_clock() {
  local state out
  state=$(fresh_state tick-healthy)
  meta "$state" healthy "$RUNG1"
  record "$state" "$RUNG1" 80.0 '3h 41m'
  FAKE_PANE=$(ordinary_pane)
  out=$(fm_agy_descent_tick "$state" "$NOW")
  [ -z "$out" ] || fail "a worker on a healthy rung must produce no output, got: $out"

  # A home with no agy worker on a rung pays nothing and starts no clock, so it
  # can never be the reason a later evaluation is skipped.
  state=$(fresh_state tick-no-agy)
  {
    printf 'harness=claude\nbackend=tmux\nwindow=fmlab:c\nkind=ship\nmodel=claude-opus-5\n'
  } > "$state/other.meta"
  out=$(fm_agy_descent_tick "$state" "$NOW")
  [ -z "$out" ] || fail "a home with no agy worker must produce no output, got: $out"
  [ ! -f "$state/.agy-descent-last" ] \
    || fail "a home with no agy worker must not start the evaluation clock"
  pass "fm_agy_descent_tick: a healthy fleet costs nothing and says nothing"
}

test_a_spent_ladder_escalates_exactly_once() {
  local state out
  state=$(fresh_state tick-spent)
  meta "$state" wedged "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 0.0 '3h 37m'
  record "$state" "$RUNG3" 0.0 '4h 59m'
  FAKE_PANE=$(ordinary_pane)

  out=$(fm_agy_descent_tick "$state" "$NOW")
  assert_contains "$out" "refused wedged" "a spent ladder must be refused and reported"
  assert_contains "$out" "no lower model on the ladder can be shown to be available" \
    "the refusal must say what it could not prove"

  # The condition persists, so a second evaluation must NOT wake anyone again.
  rm -f "$state/.agy-descent-last"
  out=$(fm_agy_descent_tick "$state" "$((NOW + 120))")
  [ -z "$out" ] || fail "the same unchanged refusal must not be reported twice, got: $out"

  # Once the rung recovers the episode is over, so a LATER crossing can escalate
  # again rather than being suppressed forever. Every step stays inside
  # FM_AGY_QUOTA_MAX_AGE of the readings above, so what is being asserted is the
  # episode bookkeeping and never a reading quietly ageing out underneath it.
  record "$state" "$RUNG1" 80.0 '3h 41m'
  rm -f "$state/.agy-descent-last"
  out=$(fm_agy_descent_tick "$state" "$((NOW + 180))")
  [ -z "$out" ] || fail "a recovered rung must be silent, got: $out"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  rm -f "$state/.agy-descent-last"
  out=$(fm_agy_descent_tick "$state" "$((NOW + 240))")
  assert_contains "$out" "refused wedged" "a fresh crossing must be able to escalate again"
  pass "fm_agy_descent_tick: a refusal escalates once per episode, not once per poll"
}

test_a_disagreeing_record_refuses_rather_than_guessing() {
  local state out
  state=$(fresh_state tick-disagree)
  meta "$state" drifted "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  # The worker is actually running rung 2 while the durable record still says
  # rung 1. Every move count below is derived from that record, so acting on it
  # would be moving a worker on a description that does not fit it.
  FAKE_PANE=$(settled_on_rung3 | sed 's/^Gemini 3.7 Flash (High) | ctx/Gemini 3.1 Pro (High) | ctx/')

  out=$(fm_agy_descent_tick "$state" "$NOW")
  assert_contains "$out" "refused drifted" "a record that disagrees with the worker must refuse"
  assert_contains "$out" "Gemini 3.1 Pro (High)" "the refusal must name what the worker reports"
  assert_not_contains "$out" "descended" "nothing may be moved while the two disagree"
  pass "fm_agy_descent_tick: a durable record that does not describe the worker refuses"
}

test_a_worker_that_never_settles_is_escalated_after_the_grace() {
  # A short grace, so every evaluation below still sits inside
  # FM_AGY_QUOTA_MAX_AGE of the readings it decides on. Waiting out the real
  # 900s grace against a 300s reading ceiling would age the evidence out and the
  # suite would pass on the wrong reason.
  local state out
  local FM_AGY_DESCENT_GRACE=120
  state=$(fresh_state tick-busy)
  meta "$state" grinding "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  FAKE_PANE=$(ordinary_pane)
  FAKE_BUSY='busy agy-hook'

  # Inside the grace, a busy worker is simply left alone and retried later: a
  # modal picker driven into a pane mid-turn is exactly where this is unsafe.
  out=$(fm_agy_descent_tick "$state" "$NOW")
  [ -z "$out" ] || fail "a busy worker inside the grace must be retried quietly, got: $out"

  # Past it, silence would reproduce the original failure with extra steps.
  rm -f "$state/.agy-descent-last"
  out=$(fm_agy_descent_tick "$state" "$((NOW + FM_AGY_DESCENT_GRACE + 60))")
  assert_contains "$out" "refused grinding" "a worker that never settles must be escalated eventually"
  assert_contains "$out" "without ever being safely interruptible" "the refusal must say why it could not act"

  # An unreadable turn state is not permission either, at any age.
  FAKE_BUSY='unknown source-mismatch'
  state=$(fresh_state tick-unknown-busy)
  meta "$state" opaque "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  out=$(fm_agy_descent_tick "$state" "$NOW")
  [ -z "$out" ] || fail "an unreadable turn state must not be acted on, got: $out"
  rm -f "$state/.agy-descent-last"
  out=$(fm_agy_descent_tick "$state" "$((NOW + FM_AGY_DESCENT_GRACE + 60))")
  assert_not_contains "$out" "descended" "an unreadable turn state must never produce a switch"
  assert_contains "$out" "refused opaque" "an unreadable turn state must still be escalated, not dropped"
  FAKE_BUSY='idle agy-hook'
  pass "fm_agy_descent_tick: only a provably settled worker is touched, and never settling is escalated"
}

test_the_captains_override_holds_a_worker_and_says_so() {
  local state out
  state=$(fresh_state tick-override)
  meta "$state" pinned "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  FAKE_PANE=$(ordinary_pane)

  out=$(FM_AGY_LADDER_OVERRIDE='captain: finish this run on opus' \
    fm_agy_descent_tick "$state" "$NOW")
  assert_contains "$out" "override pinned" "an overridden worker must be reported, not moved"
  assert_contains "$out" "captain: finish this run on opus" \
    "the override's stated reason must be printed, exactly as the launch gate prints it"
  assert_not_contains "$out" "descended" "an overridden worker must not be moved"
  pass "fm_agy_descent_tick: the captain's override holds a worker in place and is never silent"
}

test_the_evaluation_is_rate_limited() {
  local state out
  state=$(fresh_state tick-cadence)
  meta "$state" spent "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 0.0 '3h 37m'
  record "$state" "$RUNG3" 0.0 '4h 59m'
  FAKE_PANE=$(ordinary_pane)

  out=$(fm_agy_descent_tick "$state" "$NOW")
  assert_contains "$out" "refused spent" "the first evaluation must run"
  [ -f "$state/.agy-descent-last" ] || fail "a completed evaluation must stamp its clock"

  # A second call one second later must not re-run the bounded quota read.
  rm -f "$state/.agy-descent-escalated-spent"
  out=$(fm_agy_descent_tick "$state" "$((NOW + 1))")
  [ -z "$out" ] || fail "an evaluation inside the interval must not run again, got: $out"

  out=$(fm_agy_descent_tick "$state" "$((NOW + FM_AGY_DESCENT_INTERVAL))")
  assert_contains "$out" "refused spent" "the interval elapsing must let the evaluation run again"
  pass "fm_agy_descent_tick: the bounded quota read is rate-limited, not paid every poll"
}

test_the_evaluation_can_be_turned_off() {
  local state out
  state=$(fresh_state tick-off)
  meta "$state" spent "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  FAKE_PANE=$(ordinary_pane)
  out=$(FM_AGY_DESCENT=off fm_agy_descent_tick "$state" "$NOW")
  [ -z "$out" ] || fail "the disabled evaluation must do nothing at all, got: $out"
  [ ! -f "$state/.agy-descent-last" ] || fail "the disabled evaluation must not stamp its clock"
  pass "fm_agy_descent_tick: FM_AGY_DESCENT=off leaves the launch gate as the only enforcement"
}

# --- 6. The whole descent, end to end ---------------------------------------

test_a_crossed_floor_moves_the_worker_and_records_it() {
  local state out
  state=$(fresh_state tick-descend)
  meta "$state" runner "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  record "$state" "$RUNG3" 100.0 '4h 59m'
  FAKE_STICKY=0
  fake_worker_start "$state" 'Claude Opus 4.6 (Thinking)'

  out=$(fm_agy_descent_tick "$state" "$NOW")
  assert_contains "$out" "descended runner" "a worker below its floor must be moved"
  assert_contains "$out" "$RUNG1 -> $RUNG2" "the move must be one rung, and must name both ends"

  # The picker really was walked to the target rather than the target being
  # asserted from the plan alone.
  [ "$(fake_selection)" = 'Gemini 3.1 Pro' ] \
    || fail "the walk must have left the picker on rung 2's row; got '$(fake_selection)'"
  [ "$(fake_settled)" = "$RUNG2" ] \
    || fail "the selection must have been committed to rung 2; got '$(fake_settled)'"

  # The durable record has to follow the worker, or the next evaluation would
  # decide about a model this worker is no longer running.
  [ "$(fm_meta_get "$state/runner.meta" model)" = "$RUNG2" ] \
    || fail "the task's durable record must now name rung 2"

  # ...and the episode is over, so nothing repeats on the next evaluation.
  [ ! -f "$state/.agy-descent-below-runner" ] \
    || fail "a completed descent must close the below-the-floor episode"
  rm -f "$state/.agy-descent-last"
  out=$(fm_agy_descent_tick "$state" "$((NOW + 120))")
  [ -z "$out" ] || fail "a worker already moved to a healthy rung must be silent, got: $out"
  FAKE_MODE=static
  pass "fm_agy_descent_tick: a crossed floor moves the worker one rung and records it"
}

test_a_walk_that_does_not_land_on_the_target_commits_nothing() {
  local state out
  state=$(fresh_state tick-mismatch)
  meta "$state" adrift "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  # The navigation keys do nothing, which is exactly how a picker whose list no
  # longer matches the parsed walk behaves. The counted moves are sent and the
  # selection stays put.
  FAKE_STICKY=1
  fake_worker_start "$state" 'Claude Opus 4.6 (Thinking)' 

  out=$(fm_agy_descent_tick "$state" "$NOW")
  assert_contains "$out" "refused adrift" "a walk that missed its target must refuse"
  assert_contains "$out" "settled on Claude Opus 4.6 (Thinking) instead of $RUNG2" \
    "the refusal must name what it found and what it wanted"
  assert_not_contains "$out" "descended" "nothing may be committed after a missed walk"

  # The critical property: nothing was ever committed, and the worker is back at
  # its composer rather than parked in a modal nobody will close.
  [ -z "$(fake_settled)" ] \
    || fail "a missed walk must commit nothing; it selected '$(fake_settled)'"
  [ "$(fake_phase)" = composer ] \
    || fail "a missed walk must leave the worker out of the picker; phase is '$(fake_phase)'"

  # And the durable record is untouched, so the worker is still described by it.
  [ "$(fm_meta_get "$state/adrift.meta" model)" = "$RUNG1" ] \
    || fail "a refused descent must leave the durable record exactly as it was"
  FAKE_MODE=static
  FAKE_STICKY=0
  pass "fm_agy_descent_tick: a walk that does not land on the target selects nothing and escalates"
}

test_the_model_command_carries_exactly_one_enter() {
  local state out
  state=$(fresh_state tick-one-enter)
  meta "$state" single "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  FAKE_STICKY=0
  fake_worker_start "$state" 'Claude Opus 4.6 (Thinking)'

  # The simulated worker opens its picker on the first Enter and COMMITS on the
  # second, which is what a live agy does. If the model command were submitted
  # with a retry, that retry would land inside the picker and select the row the
  # worker is already on - the exact rung the descent exists to leave. Observed
  # against agy 1.1.16 before the retry count was pinned to one.
  out=$(fm_agy_descent_tick "$state" "$NOW")
  assert_contains "$out" "descended single" "the descent must still complete"
  [ "$(fake_settled)" = "$RUNG2" ] \
    || fail "an extra Enter committed the wrong model: settled on '$(fake_settled)', not $RUNG2"
  [ "$(fm_meta_get "$state/single.meta" model)" = "$RUNG2" ] \
    || fail "the durable record must name the model that was actually selected"
  FAKE_MODE=static
  pass "fm_agy_descent_switch: the model command carries exactly one Enter, so no retry commits a selection"
}

# --- 7. The watcher actually calls it ---------------------------------------

test_the_watcher_runs_the_evaluation() {
  # The library is worthless if nothing invokes it, and a suite that only drives
  # the library directly cannot tell the difference. This asserts through the
  # watcher's own executable behaviour: bash's syntax-and-source check loads
  # every sourced library, so a watcher that no longer pulls this one in loses
  # the function.
  local probe
  probe=$(bash -c '
    set -u
    STATE=$1
    SCRIPT_DIR=$2
    . "$SCRIPT_DIR/fm-agy-descent-lib.sh"
    declare -f fm_agy_descent_tick >/dev/null && echo present
  ' _ "$TMP_ROOT" "$(dirname "${BASH_SOURCE[0]}")/../bin")
  [ "$probe" = present ] || fail "the descent library must define its evaluation"

  grep -q 'fm_agy_descent_tick' "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-watch.sh" \
    || fail "bin/fm-watch.sh must run the descent evaluation on its poll cadence"
  pass "bin/fm-watch.sh: the descent evaluation is on the watcher's poll cadence"
}

test_recognises_the_real_picker
test_every_missing_marker_refuses_the_picker
test_parses_the_rows_agy_actually_draws
test_a_ladder_name_resolves_against_the_pickers_own_rows
test_the_walk_is_counted_from_the_rendered_list
test_confirmation_needs_both_signals
test_the_target_is_whatever_the_ladder_authorizes
test_crossing_the_floor_uses_the_ladders_own_reading
test_a_healthy_fleet_is_silent_and_starts_no_clock
test_a_spent_ladder_escalates_exactly_once
test_a_disagreeing_record_refuses_rather_than_guessing
test_a_worker_that_never_settles_is_escalated_after_the_grace
test_the_captains_override_holds_a_worker_and_says_so
test_the_evaluation_is_rate_limited
test_the_evaluation_can_be_turned_off
test_a_crossed_floor_moves_the_worker_and_records_it
test_a_walk_that_does_not_land_on_the_target_commits_nothing
test_the_model_command_carries_exactly_one_enter
test_the_watcher_runs_the_evaluation
