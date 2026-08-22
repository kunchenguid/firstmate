#!/usr/bin/env bash
# tests/fm-agy-live-descent.test.sh - the regression for moving an ALREADY
# RUNNING agy worker along the ladder: down when its rung crosses its floor, and
# back up when a rung above it has reset clear of that floor.
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
#   7. Climbing back up obeys the SAME floor: a running worker returns into the
#      free three quarters of rung 1 and never into the captain's reserved
#      quarter, and unlike a launch it needs positive evidence to move at all.
#   8. The climb's hysteresis holds. A rung oscillating across its boundary must
#      move the worker nowhere, which is the failure that kept this half out of
#      the descent's own change; both the dead band and the dwell are asserted
#      by driving a reading across the line and back repeatedly.
#   9. A confirmed move is written to the durable record before it is reported,
#      it REPLACES the model the record named rather than adding a second one,
#      and a move that cannot be recorded is escalated instead of announced as a
#      success - because recovery reads that record, so one still naming the
#      reserved rung would put the worker straight back onto it.
#  10. The reserve is enforced on the schedule of the worker SPENDING it, not on
#      firstmate's turn boundaries. A reading above the floor, a long gap with no
#      evaluation at all, then a reading below it must still move the worker, and
#      an agy worker's own turn end must be a driver that reaches the durable
#      queue with no watcher running.
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

TMP_ROOT=$(fm_test_tmproot fm-agy-descent)

# The library under test takes the shared per-task record lock and a
# single-flight lock of its own, and loads the lock owner itself when a caller
# has not. That owner materializes whatever state directory it resolves, and its
# default is this repo's own, so point it at a scratch home before it loads. The
# per-case queue assertions below address their own state directory explicitly.
# It is unset again immediately: the cases that run a real executable name the
# home they mean, and an exported override would follow them there.
FM_STATE_OVERRIDE="$TMP_ROOT/lockhome-state"
export FM_STATE_OVERRIDE

# shellcheck source=bin/fm-agy-descent-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-agy-descent-lib.sh"
unset FM_STATE_OVERRIDE

# Readings are written by hand here, so the live intake poll must stay off: a
# real poll would replace them with the host account's own and every
# expectation would turn on whatever agy says today.
export FM_AGY_QUOTA_POLL=off
export FM_AGY_QUOTA_MAX_AGE=300
export FM_AGY_INFLIGHT_TTL=300
export FM_AGY_LADDER_INFLIGHT_MARGIN=1
export FM_AGY_DESCENT_INTERVAL=60
export FM_AGY_DESCENT_GRACE=900
export FM_AGY_CLIMB=on
export FM_AGY_CLIMB_MARGIN=10
export FM_AGY_CLIMB_DWELL=300

RUNG1='Claude Opus 4.6 (Thinking)'
RUNG2='Gemini 3.1 Pro (High)'
RUNG3='Gemini 3.7 Flash (High)'

NOW=$(date +%s)

record() {  # <state-dir> <display-model> <percent> <reset-window>
  mkdir -p "$1"
  fm_agy_quota_observe "$2 | ctx: 3.0% | quota: $3% ($4)" "$1"
}

# record_at: the same reading, stamped at an explicit instant. The climb's dwell
# is measured in multiples of the reading ceiling, so every evaluation that
# waits one out has to carry its evidence forward with it; a wall-clock reading
# would age out underneath the test and it would pass for the wrong reason.
record_at() {  # <state-dir> <display-model> <percent> <reset-window> <now>
  mkdir -p "$1"
  fm_agy_quota_observe "$2 | ctx: 3.0% | quota: $3% ($4)" "$1" "$5"
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

# wait_for_queue <queue-file> <pattern>: the durable queue is written by a
# DETACHED evaluation, so the cases that drive one wait for the record instead
# of assuming it has landed. Bounded, and it never reports success on a timeout.
wait_for_queue() {  # <queue-file> <pattern>
  local file=$1 pattern=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# agy_fakebin <dir>: the two commands a real agy spawn shells out to, and
# nothing else. `agy models` answers the catalogue the launch validates against;
# `agy /quota` answers nothing, which the cases below rely on because they write
# their own readings.
agy_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
  printf 'claude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)\n'
  printf 'gemini-3.1-pro-high\tGemini 3.1 Pro (High)\n'
  printf 'gemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
fi
exit 0
SH
  chmod +x "$fakebin/agy"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# spawn_agy_worker <dir> <id>: a REAL bin/fm-spawn.sh launch of an agy ship task
# on rung 1, into a scratch agy customization root. This exists so the hook the
# spawn actually writes can be driven, rather than a copy of it written here.
spawn_agy_worker() {  # <dir> <id>
  local dir=$1 id=$2 home proj wt fakebin
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" "$dir/agy-config"
  fakebin=$(agy_fakebin "$dir/fake")
  fm_git_worktree "$proj" "$wt" "wt-$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  # A healthy reading so the LAUNCH gate lets rung 1 through; the cases replace
  # it afterwards with the reading the running worker is to be judged on.
  fm_agy_quota_observe "$RUNG1 | ctx: 3.0% | quota: 88.0% (4h 0m)" "$home/state"
  env PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_AGY_CONFIG_HOME="$dir/agy-config" FM_AGY_SETTINGS="$dir/agy-settings.json" \
    FM_AGY_QUOTA_POLL=off FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-spawn.sh" "$id" "$proj" \
    --harness agy --model "$RUNG1" --mode no-mistakes --yolo off 2>&1
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
  assert_contains "$out" "no lower rung can be shown to be available" \
    "the refusal must say what it could not prove downwards"
  assert_contains "$out" "no rung above it has reset clear of its own floor" \
    "the refusal must say it looked upwards too, so a spent ladder is not confused with an unclimbed one"

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

# --- 7. Climbing back up ----------------------------------------------------
#
# The other half of the captain's rule, and the half that needed hysteresis. A
# bare "rung 1 is above its floor" trigger would hand a worker back and forth
# between models every time a hovering rung crossed the line, so the contracts
# here are the dead band, the dwell, and the fact that neither of them is a
# second floor: the reserved quarter is refused by exactly the gate that refuses
# a launch into it.

# climb_tick: one evaluation at <now>, with the readings this test wants carried
# forward to that instant and the rate limiter cleared so the evaluation is not
# skipped for the interval rather than for the reason under test.
climb_tick() {  # <state-dir> <now> [<rung1-percent>] [<rung2-percent>] [<rung3-percent>]
  local state=$1 at=$2
  [ -z "${3:-}" ] || record_at "$state" "$RUNG1" "$3" '3h 41m' "$at"
  [ -z "${4:-}" ] || record_at "$state" "$RUNG2" "$4" '3h 37m' "$at"
  [ -z "${5:-}" ] || record_at "$state" "$RUNG3" "$5" '4h 59m' "$at"
  rm -f "$state/.agy-descent-last"
  fm_agy_descent_tick "$state" "$at"
}

# climb_worker: a live agy worker recorded on, and rendered on, <row>.
climb_worker() {  # <state-dir> <id> <ladder-display> <picker-row>
  meta "$1" "$2" "$3"
  FAKE_STICKY=0
  fake_worker_start "$1" "$4"
}

test_a_reset_rung_climbs_the_worker_back_and_records_it() {
  local state out t
  state=$(fresh_state climb-back)
  climb_worker "$state" returner "$RUNG2" 'Gemini 3.1 Pro'

  # Rung 1 has reset well clear of the captain's quarter. One reading is not
  # enough on its own - that is the dwell - so the first evaluation is silent.
  t=$NOW
  out=$(climb_tick "$state" "$t" 100.0 94.6)
  [ -z "$out" ] || fail "a single reading must never authorize a climb, got: $out"
  [ "$(fm_meta_get "$state/returner.meta" model)" = "$RUNG2" ] \
    || fail "nothing may move inside the dwell"

  t=$((t + FM_AGY_CLIMB_DWELL))
  out=$(climb_tick "$state" "$t" 100.0 94.6)
  assert_contains "$out" "climbed returner" "a rung held clear for the dwell must climb the worker back"
  assert_contains "$out" "$RUNG2 -> $RUNG1" "the climb must name both ends"

  # The picker really was walked upwards to rung 1's own row, rather than the
  # outcome being asserted from the plan alone.
  [ "$(fake_selection)" = 'Claude Opus 4.6 (Thinking)' ] \
    || fail "the walk must have left the picker on rung 1's row; got '$(fake_selection)'"
  [ "$(fake_settled)" = "$RUNG1" ] \
    || fail "the selection must have been committed to rung 1; got '$(fake_settled)'"
  [ "$(fm_meta_get "$state/returner.meta" model)" = "$RUNG1" ] \
    || fail "the task's durable record must now name rung 1"

  # And the worker is where it belongs, so the next evaluation says nothing.
  out=$(climb_tick "$state" "$((t + 120))" 100.0 94.6)
  [ -z "$out" ] || fail "a worker already back on rung 1 must be silent, got: $out"
  FAKE_MODE=static
  pass "fm_agy_descent_tick: a rung that has reset clear of its floor climbs the worker back and records it"
}

test_the_climb_never_reaches_into_the_captains_reserve() {
  local state out t pct

  # The floor exactly, just under it, and two figures above it but still inside
  # the dead band. Each is held far longer than the dwell, so what refuses is
  # the policy and never a wait that had not finished.
  for pct in 25.0 24.9 30.0 34.9; do
    state=$(fresh_state "climb-reserve-$pct")
    climb_worker "$state" reserved "$RUNG2" 'Gemini 3.1 Pro'
    t=$NOW
    for _ in 1 2 3 4; do
      out=$(climb_tick "$state" "$t" "$pct" 94.6)
      [ -z "$out" ] || fail "rung 1 at $pct% must never climb a running worker, got: $out"
      t=$((t + FM_AGY_CLIMB_DWELL))
    done
    [ "$(fm_meta_get "$state/reserved.meta" model)" = "$RUNG2" ] \
      || fail "the worker must still be recorded on rung 2 with rung 1 at $pct%"
    [ -z "$(fake_settled)" ] \
      || fail "nothing may be selected with rung 1 at $pct%; it settled on '$(fake_settled)'"
  done

  # The contrast, so the refusals above are about the reserve and not about a
  # climb that never fires: the same worker, one notch higher, does climb.
  state=$(fresh_state climb-reserve-clear)
  climb_worker "$state" cleared "$RUNG2" 'Gemini 3.1 Pro'
  t=$NOW
  out=$(climb_tick "$state" "$t" 35.0 94.6)
  [ -z "$out" ] || fail "the dwell must still apply at the edge of the band, got: $out"
  out=$(climb_tick "$state" "$((t + FM_AGY_CLIMB_DWELL))" 35.0 94.6)
  assert_contains "$out" "climbed cleared" \
    "the first figure clear of the floor by the whole margin must climb"
  FAKE_MODE=static
  pass "fm_agy_climb: the captain's reserved quarter is refused to a running worker by the same floor that refuses a launch"
}

test_an_unread_rung_above_is_never_climbed_into() {
  local state out t
  state=$(fresh_state climb-unread)
  climb_worker "$state" blind "$RUNG2" 'Gemini 3.1 Pro'

  t=$NOW
  for _ in 1 2 3 4; do
    out=$(climb_tick "$state" "$t" '' 94.6)
    [ -z "$out" ] || fail "a rung with no reading at all must never climb a worker, got: $out"
    t=$((t + FM_AGY_CLIMB_DWELL))
  done
  [ "$(fm_meta_get "$state/blind.meta" model)" = "$RUNG2" ] \
    || fail "an unread rung 1 must leave the durable record alone"

  # ...and that same absence really does authorize a LAUNCH at the top of the
  # ladder. Without this the assertions above could be passing because absence
  # refuses everything, rather than because a climb demands positive evidence.
  fm_agy_ladder_check "$RUNG1" "$state" "$t" >/dev/null \
    || fail "the launch gate must still allow rung 1 with no reading, or this test proves nothing"
  FAKE_MODE=static
  pass "fm_agy_climb: climbing needs positive evidence even where launching does not"
}

test_a_rung_hovering_at_its_boundary_never_flaps_the_worker() {
  local state out t i pct
  state=$(fresh_state climb-hover)
  climb_worker "$state" steady "$RUNG2" 'Gemini 3.1 Pro'

  # Rung 1 crosses the climb line and falls back under it, over and over, for
  # six times the dwell. Under a bare threshold every one of those crossings is
  # a model switch on a live worker mid-task. Under the dead band plus the
  # dwell it must be none of them, because the timer is destroyed each time the
  # condition lapses and so never reaches the dwell at all.
  t=$NOW
  i=0
  while [ "$i" -lt 12 ]; do
    if [ $((i % 2)) -eq 0 ]; then pct=40.0; else pct=30.0; fi
    out=$(climb_tick "$state" "$t" "$pct" 94.6)
    [ -z "$out" ] || fail "a rung hovering at the boundary must move nothing (step $i, rung 1 at $pct%), got: $out"
    t=$((t + FM_AGY_CLIMB_DWELL))
    i=$((i + 1))
  done

  [ "$(fm_meta_get "$state/steady.meta" model)" = "$RUNG2" ] \
    || fail "the hovering rung must have left the durable record on rung 2"
  [ -z "$(fake_settled)" ] \
    || fail "the hovering rung must have committed nothing; it settled on '$(fake_settled)'"
  [ "$(fake_phase)" = composer ] \
    || fail "the worker must never have been taken into the picker at all; phase is '$(fake_phase)'"

  # And the hold is the hysteresis doing its job rather than a climb that never
  # works: the SAME rung, at the SAME percentage it kept crossing to, moves the
  # worker as soon as it stops falling back.
  out=$(climb_tick "$state" "$t" 40.0 94.6)
  [ -z "$out" ] || fail "the first steady evaluation is still inside the dwell, got: $out"
  t=$((t + FM_AGY_CLIMB_DWELL))
  out=$(climb_tick "$state" "$t" 40.0 94.6)
  assert_contains "$out" "climbed steady" \
    "a rung that stops hovering and holds for the dwell must climb the worker back"
  FAKE_MODE=static
  pass "fm_agy_climb: a rung oscillating across its boundary holds the worker, and holding it steady moves it"
}

test_a_worker_on_a_spent_rung_climbs_instead_of_being_reported_stuck() {
  local state out t
  state=$(fresh_state climb-from-spent)
  climb_worker "$state" stranded "$RUNG2" 'Gemini 3.1 Pro'

  # Rung 2 is dead and rung 1 has reset. Descending to rung 3 is correctly
  # refused - rung 1 is not exhausted, so rung 3 is not the highest available
  # rung - and before the climb existed this worker was reported stuck on a
  # spent ladder while the top of that ladder sat free.
  t=$NOW
  out=$(climb_tick "$state" "$t" 100.0 0.0 100.0)
  [ -z "$out" ] || fail "a climb merely waiting out its dwell is a bounded wait, not a refusal to report, got: $out"

  t=$((t + FM_AGY_CLIMB_DWELL))
  out=$(climb_tick "$state" "$t" 100.0 0.0 100.0)
  assert_contains "$out" "climbed stranded" "a worker on a spent rung must be climbed to the rung that reset"
  assert_contains "$out" "$RUNG2 -> $RUNG1" "the move must be to rung 1, not down to rung 3"
  assert_not_contains "$out" "descended" "nothing may descend while a rung above is available"
  [ "$(fm_meta_get "$state/stranded.meta" model)" = "$RUNG1" ] \
    || fail "the durable record must follow the worker up"
  FAKE_MODE=static
  pass "fm_agy_descent_tick: a spent rung with a reset rung above it climbs rather than escalating as a spent ladder"
}

test_a_spent_ladder_is_still_reported_when_nothing_above_has_reset() {
  # The counterpart to the test above: the bounded-wait suppression must not
  # have made a genuinely spent ladder silent.
  local state out
  state=$(fresh_state climb-still-spent)
  climb_worker "$state" wedged "$RUNG2" 'Gemini 3.1 Pro'
  out=$(climb_tick "$state" "$NOW" 0.0 0.0 0.0)
  assert_contains "$out" "refused wedged" "a ladder with nothing left anywhere must still be reported"
  assert_not_contains "$out" "climbed" "nothing may climb into a spent rung"
  FAKE_MODE=static
  pass "fm_agy_descent_tick: suppressing a pending climb did not silence a genuinely spent ladder"
}

test_a_failed_climb_is_reported_once_and_not_retried_every_minute() {
  local state out t
  state=$(fresh_state climb-failed)
  climb_worker "$state" balky "$RUNG2" 'Gemini 3.1 Pro'
  # The navigation keys do nothing, so the walk cannot land on rung 1's row.
  FAKE_STICKY=1

  t=$((NOW + FM_AGY_CLIMB_DWELL))
  out=$(climb_tick "$state" "$NOW" 100.0 94.6)
  [ -z "$out" ] || fail "the dwell must not be skipped, got: $out"
  out=$(climb_tick "$state" "$t" 100.0 94.6)
  assert_contains "$out" "refused balky" "a climb that missed its target must be reported"
  assert_not_contains "$out" "climbed" "nothing may be committed after a missed walk"
  [ -z "$(fake_settled)" ] || fail "a missed climb must commit nothing; it selected '$(fake_settled)'"
  [ "$(fake_phase)" = composer ] \
    || fail "a missed climb must leave the worker out of the picker; phase is '$(fake_phase)'"

  # The rung is still climbable, so a retry loop here would drive the modal
  # picker into a live pane once a minute for an optimisation. It must not.
  printf 'composer' > "$FAKE_DIR/phase"
  out=$(climb_tick "$state" "$((t + FM_AGY_CLIMB_DWELL))" 100.0 94.6)
  [ -z "$out" ] || fail "a failed climb must not be retried while the rung stays climbable, got: $out"
  [ "$(fake_phase)" = composer ] \
    || fail "a failed climb must not reopen the picker; phase is '$(fake_phase)'"

  # Once the rung stops being climbable the episode is over, so a later reset
  # is attempted again rather than suppressed forever.
  t=$((t + 2 * FM_AGY_CLIMB_DWELL))
  out=$(climb_tick "$state" "$t" 20.0 94.6)
  [ -z "$out" ] || fail "a lapsed rung must be silent, got: $out"
  FAKE_STICKY=0
  out=$(climb_tick "$state" "$((t + FM_AGY_CLIMB_DWELL))" 100.0 94.6)
  [ -z "$out" ] || fail "the dwell restarts with the rung, got: $out"
  out=$(climb_tick "$state" "$((t + 2 * FM_AGY_CLIMB_DWELL))" 100.0 94.6)
  assert_contains "$out" "climbed balky" "a fresh episode must be attempted again"
  FAKE_MODE=static
  pass "fm_agy_descent_tick: a failed climb is reported once and left alone until the rung lapses and returns"
}

test_the_captains_override_holds_a_worker_down_and_says_nothing() {
  local state out
  state=$(fresh_state climb-override)
  climb_worker "$state" pinned "$RUNG2" 'Gemini 3.1 Pro'

  out=$(FM_AGY_LADDER_OVERRIDE='captain: keep this one on gemini' \
    climb_tick "$state" "$NOW" 100.0 94.6)
  [ -z "$out" ] || fail "an override inside the dwell must be silent, got: $out"
  out=$(FM_AGY_LADDER_OVERRIDE='captain: keep this one on gemini' \
    climb_tick "$state" "$((NOW + FM_AGY_CLIMB_DWELL))" 100.0 94.6)
  [ -z "$out" ] || fail "a pinned worker on a slower rung is what the captain asked for, so it must not wake them, got: $out"
  [ "$(fm_meta_get "$state/pinned.meta" model)" = "$RUNG2" ] \
    || fail "an overridden worker must not be climbed"

  # The downward side of the same override still speaks, so silence here is a
  # deliberate asymmetry and not the override having stopped being honoured.
  state=$(fresh_state climb-override-down)
  climb_worker "$state" pinned "$RUNG1" 'Claude Opus 4.6 (Thinking)'
  out=$(FM_AGY_LADDER_OVERRIDE='captain: finish this run on opus' \
    climb_tick "$state" "$NOW" 0.0 94.6)
  assert_contains "$out" "override pinned" "a pinned worker below its floor must still be reported"
  FAKE_MODE=static
  pass "fm_agy_descent_tick: the override holds a worker down silently and still speaks when it holds one below its floor"
}

test_the_climb_can_be_turned_off_on_its_own() {
  local state out
  state=$(fresh_state climb-off)
  climb_worker "$state" grounded "$RUNG2" 'Gemini 3.1 Pro'

  out=$(FM_AGY_CLIMB=off climb_tick "$state" "$NOW" 100.0 94.6)
  [ -z "$out" ] || fail "the disabled climb must do nothing, got: $out"
  out=$(FM_AGY_CLIMB=off climb_tick "$state" "$((NOW + FM_AGY_CLIMB_DWELL))" 100.0 94.6)
  [ -z "$out" ] || fail "the disabled climb must still do nothing after the dwell, got: $out"
  [ "$(fm_meta_get "$state/grounded.meta" model)" = "$RUNG2" ] \
    || fail "FM_AGY_CLIMB=off must leave the worker where it is"

  # ...while the descent it shares a tick with is untouched, so the two halves
  # really are separately controllable.
  state=$(fresh_state climb-off-descent)
  climb_worker "$state" sinking "$RUNG1" 'Claude Opus 4.6 (Thinking)'
  out=$(FM_AGY_CLIMB=off climb_tick "$state" "$NOW" 0.0 94.6)
  assert_contains "$out" "descended sinking" "FM_AGY_CLIMB=off must not disable the descent"
  FAKE_MODE=static
  pass "fm_agy_descent_tick: FM_AGY_CLIMB=off disables the climb alone"
}

test_the_dwell_timer_belongs_to_the_rung_not_to_a_worker() {
  # The condition is a property of the RUNG, so a worker that arrives on rung 2
  # after the timer started must inherit it rather than begin a clock of its own
  # - otherwise a long-lived worker and a fresh one on the same rung would climb
  # at different moments on the same evidence.
  #
  # Asserted through the decision, not through the tick: the picker simulator
  # renders one pane for the whole home, so two simulated workers cannot be
  # switched independently and a two-worker tick would be testing the fixture.
  local state
  state=$(fresh_state climb-shared)

  record_at "$state" "$RUNG1" 100.0 '3h 41m' "$NOW"
  fm_agy_climb_dwell_tick "$state" "$NOW"
  [ -f "$state/.agy-climb-since-1" ] \
    || fail "a rung clear of its margin must start one timer for the rung"
  [ "$(cat "$state/.agy-climb-since-1")" = "$NOW" ] \
    || fail "the timer must be stamped when the condition began"

  # A later evaluation must not restart it, which is what makes the wait a real
  # dwell rather than something that resets under whoever asks.
  record_at "$state" "$RUNG1" 100.0 '3h 41m' "$((NOW + 60))"
  fm_agy_climb_dwell_tick "$state" "$((NOW + 60))"
  [ "$(cat "$state/.agy-climb-since-1")" = "$NOW" ] \
    || fail "an already-running timer must not be restarted by a later evaluation"
  ! fm_agy_climb_target 2 "$state" "$((NOW + 60))" >/dev/null \
    || fail "the dwell must not be satisfied 60s in"

  # The timer is keyed by rung alone, so any worker asking at the same instant
  # gets the same answer whenever it arrived.
  [ "$(fm_agy_climb_target 2 "$state" "$((NOW + FM_AGY_CLIMB_DWELL))")" = 1 ] \
    || fail "a worker on rung 2 must be told to climb once the rung's own timer has run"
  [ "$(fm_agy_climb_target 3 "$state" "$((NOW + FM_AGY_CLIMB_DWELL))")" = 1 ] \
    || fail "a worker on rung 3 must be told the same, from the same timer"

  # And the timer is destroyed the moment the condition lapses, so the next
  # crossing starts from zero instead of resuming a part-served wait.
  record_at "$state" "$RUNG1" 20.0 '3h 41m' "$((NOW + FM_AGY_CLIMB_DWELL))"
  fm_agy_climb_dwell_tick "$state" "$((NOW + FM_AGY_CLIMB_DWELL))"
  [ ! -f "$state/.agy-climb-since-1" ] \
    || fail "a lapsed condition must destroy the timer, not pause it"
  pass "fm_agy_climb_dwell_tick: the dwell timer belongs to the rung, is never restarted early, and is destroyed when the condition lapses"
}

# --- 8. The durable record follows the worker -------------------------------
#
# A ladder move changes which model a RUNNING worker is on, and recovery reads
# that from state/<id>.meta. Everything below is about the record, not the walk:
# a record that still names the rung the worker was moved OFF sends it back onto
# the captain's reserved quarter after the next crash, stall, or relaunch, and
# does it silently. Observed on 2026-08-21, when two workers reported "Model set
# to Gemini 3.1 Pro (High)" and both records still said Claude Opus 4.6
# (Thinking).

test_a_move_leaves_a_record_naming_only_the_model_the_worker_is_on() {
  local state out
  state=$(fresh_state record-replaces)
  meta "$state" scribe "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  record "$state" "$RUNG3" 100.0 '4h 59m'
  FAKE_STICKY=0
  fake_worker_start "$state" 'Claude Opus 4.6 (Thinking)'

  out=$(fm_agy_descent_tick "$state" "$NOW")
  assert_contains "$out" "descended scribe" "the worker must have been moved"

  # The record must not name the reserved rung ANYWHERE afterwards. Reading the
  # last matching line happens to give the right answer even when an older one
  # survives above it, so a record that still carries the reserved model is one
  # careless reader away from the failure this exists to stop.
  ! grep -q "^model=$RUNG1\$" "$state/scribe.meta" \
    || fail "the durable record must no longer name the reserved rung anywhere:
$(cat "$state/scribe.meta")"
  [ "$(fm_meta_get "$state/scribe.meta" model)" = "$RUNG2" ] \
    || fail "the durable record must name the model the worker is actually on"

  # Everything else the record carried is still there: this replaces one field,
  # it does not rewrite the task.
  [ "$(fm_meta_get "$state/scribe.meta" harness)" = agy ] \
    || fail "the rest of the record must survive the update"
  [ "$(fm_meta_get "$state/scribe.meta" window)" = "fmlab:scribe" ] \
    || fail "the endpoint the record names must survive the update"
  FAKE_MODE=static
  pass "fm_agy_descent_tick: a move replaces the model the record names, leaving no trace of the rung it left"
}

test_a_move_that_cannot_be_recorded_is_never_reported_as_a_success() {
  local state out
  state=$(fresh_state record-fails)
  meta "$state" mute "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  record "$state" "$RUNG3" 100.0 '4h 59m'
  FAKE_STICKY=0
  fake_worker_start "$state" 'Claude Opus 4.6 (Thinking)'

  # A record that cannot be rewritten in place. Everything up to the write is
  # unaffected - the model is still read from it, the worker is still moved - so
  # this isolates the one thing that can still be lost after a confirmed switch.
  mv "$state/mute.meta" "$state/mute.meta.real"
  ln -s "$state/mute.meta.real" "$state/mute.meta"

  out=$(fm_agy_descent_tick "$state" "$NOW")

  [ "$(fake_settled)" = "$RUNG2" ] \
    || fail "this case is only meaningful if the worker really was moved first"
  assert_not_contains "$out" "descended mute" \
    "a move whose record was lost must not be reported as a completed descent"
  assert_contains "$out" "unrecorded mute" \
    "an unrecorded move must be escalated in its own right"
  assert_contains "$out" "$RUNG2" "the escalation must name the model the worker is now on"
  assert_contains "$out" "relaunch would bring it back onto $RUNG1" \
    "the escalation must name the consequence: recovery onto the reserved rung"
  FAKE_MODE=static
  pass "fm_agy_descent_tick: a move that could not be written down is escalated, not announced as done"
}

# --- 9. The reserve does not wait for firstmate ------------------------------
#
# The evaluation was driven from bin/fm-watch.sh alone, and the watcher runs
# between firstmate's turns rather than during them. That made the captain's
# reserved quarter conditional on how long a turn happens to last. Observed on
# 2026-08-21: an evaluation at 18:48 read 28.7%, correctly above the floor and
# correctly moving nobody; firstmate then spent about ten minutes inside one
# turn; the rung was at 19.6% with workers still spending it before anything
# looked again. The interval was never the problem - a driver that is not
# running cannot run more often - so these cases drive the gap itself.

test_the_reserve_is_enforced_across_a_gap_with_no_evaluation() {
  local state out later
  state=$(fresh_state unwatched-gap)
  meta "$state" holdout "$RUNG1"
  record_at "$state" "$RUNG1" 28.7 '3h 41m' "$NOW"
  record_at "$state" "$RUNG2" 94.6 '3h 37m' "$NOW"
  record_at "$state" "$RUNG3" 100.0 '4h 59m' "$NOW"
  FAKE_STICKY=0
  fake_worker_start "$state" 'Claude Opus 4.6 (Thinking)'

  # 18:48. Above the floor, so the right answer is to do nothing.
  out=$(fm_agy_descent_tick "$state" "$NOW")
  [ -z "$out" ] || fail "a rung above its floor must move nobody, got: $out"
  [ "$(fm_meta_get "$state/holdout.meta" model)" = "$RUNG1" ] \
    || fail "nothing should have moved while the rung was above its floor"

  # Ten minutes inside a single firstmate turn. NOTHING evaluates in this gap -
  # not once, for ten times the evaluation interval - and the rung falls well
  # inside the captain's reserve while the worker keeps spending it.
  later=$((NOW + 600))
  record_at "$state" "$RUNG1" 19.6 '3h 31m' "$later"
  record_at "$state" "$RUNG2" 94.6 '3h 27m' "$later"
  record_at "$state" "$RUNG3" 100.0 '4h 49m' "$later"
  [ "$(cat "$state/.agy-descent-last")" = "$NOW" ] \
    || fail "this case is only meaningful if nothing re-evaluated during the gap"

  # The worker ends a turn. That is the one thing guaranteed to happen while
  # firstmate is mid-turn, because it is the worker spending the quota.
  fm_agy_descent_turn_end "$state" "$later" \
    || fail "the turn-end driver must publish its outcome"

  [ "$(fm_meta_get "$state/holdout.meta" model)" = "$RUNG2" ] \
    || fail "the worker must be off the reserved rung, not still spending it"
  [ "$(fake_settled)" = "$RUNG2" ] \
    || fail "the move must have been committed in the worker's own session"
  assert_grep "descended holdout" "$state/.wake-queue" \
    "the move must be queued where firstmate finds it, with no watcher running"
  FAKE_MODE=static
  pass "the reserved quarter is enforced across a gap in which nothing evaluated at all"
}

test_a_turn_end_that_finds_nothing_to_do_stays_silent() {
  local state
  state=$(fresh_state turn-end-quiet)
  meta "$state" easy "$RUNG1"
  record "$state" "$RUNG1" 88.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'

  fm_agy_descent_turn_end "$state" "$NOW" || fail "a quiet evaluation must still succeed"
  [ ! -s "$state/.wake-queue" ] \
    || fail "a healthy fleet must not wake anyone on every turn end: $(cat "$state/.wake-queue")"
  pass "the turn-end driver is silent for a fleet that is where it should be"
}

test_two_drivers_never_evaluate_at_once() {
  local state held
  state=$(fresh_state single-flight)
  meta "$state" shared "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'

  # A live holder of the evaluation lock, standing in for the other driver:
  # the watcher polling while a worker's turn end fires, or two workers ending
  # turns together. A second evaluation must not start, because it would pay for
  # a second quota read and could drive a second picker walk into the same pane.
  held=$(mktemp -d "$TMP_ROOT/holder.XXXXXX")
  fm_lock_try_acquire "$state/.agy-descent.lock" \
    || fail "the evaluation lock should have been free"

  [ -z "$(fm_agy_descent_tick "$state" "$NOW")" ] \
    || fail "a second evaluation must not run while one holds the lock"
  [ "$(fm_meta_get "$state/shared.meta" model)" = "$RUNG1" ] \
    || fail "the blocked evaluation must not have touched the worker"
  [ ! -f "$state/.agy-descent-last" ] \
    || fail "a blocked evaluation must not consume the evaluation clock either"

  fm_lock_release "$state/.agy-descent.lock"
  rmdir "$held" 2>/dev/null || true
  pass "fm_agy_descent_tick: the drivers share one evaluation instead of racing each other"
}

# --- 10. The drivers are really wired ---------------------------------------

test_the_turn_end_entry_point_publishes_into_the_durable_queue() {
  local state out
  state=$(fresh_state entry-point)
  meta "$state" stranded "$RUNG1"
  # Every rung spent: the ladder has somewhere to complain but nowhere to move
  # the worker, which is the one outcome that needs no pane at all, so this case
  # exercises the real executable end to end with no harness present.
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 0.0 '3h 37m'
  record "$state" "$RUNG3" 0.0 '4h 59m'

  out=$(FM_STATE_OVERRIDE="$state" FM_AGY_QUOTA_POLL=off FM_AGY_DESCENT_INTERVAL=60 \
    "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-agy-ladder-tick.sh" 2>&1) \
    || fail "the turn-end entry point failed: $out"
  [ -z "$out" ] || fail "the entry point must speak only through the queue, got: $out"
  assert_grep "agy ladder refused stranded" "$state/.wake-queue" \
    "the entry point must queue the ladder's verdict for firstmate"
  pass "bin/fm-agy-ladder-tick.sh: one evaluation, published where firstmate will read it"
}

test_the_watcher_still_runs_the_evaluation() {
  local dir state fakebin out pid rc=0
  dir="$TMP_ROOT/watcher-driver"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/tmux"
  meta "$state" polled "$RUNG1"
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 0.0 '3h 37m'
  record "$state" "$RUNG3" 0.0 '4h 59m'

  # The turn-end driver is an ADDITION, not a replacement: firstmate is still
  # between turns most of the time, and the watcher is what covers that. Drive
  # the real one and require the same verdict out of it.
  out="$dir/watch.out"
  env PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_AGY_QUOTA_POLL=off \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-watch.sh" > "$out" 2>/dev/null &
  pid=$!
  local i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || rc=$?
  assert_grep "agy ladder refused polled" "$out" \
    "the watcher must still reach the ladder's verdict on its own poll cadence"
  assert_grep "agy ladder refused polled" "$state/.wake-queue" \
    "the watcher must queue that verdict durably as well as reporting it live"
  pass "bin/fm-watch.sh: the evaluation is still on the watcher's poll cadence too"
}

test_an_agy_workers_turn_end_drives_the_evaluation() {
  local dir home state out hook payload
  dir="$TMP_ROOT/hook-wiring"
  home="$dir/home"
  state="$home/state"
  out=$(spawn_agy_worker "$dir" hooked) \
    || fail "the agy spawn under test failed: $out"
  hook="$dir/agy-config/plugins/fm-turn-end/fm-turn-end.sh"
  assert_present "$hook" "the agy spawn must install its turn-end hook"

  # The worker is on the reserved rung and every rung is spent, so the ladder has
  # a verdict to reach and needs no pane to reach it.
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 0.0 '3h 37m'
  record "$state" "$RUNG3" 0.0 '4h 59m'
  rm -f "$state/.agy-descent-last"

  # agy's real Stop payload shape, naming the worktree this task was registered
  # for. Nothing else here is firstmate's to fake: the hook is the file the
  # spawn actually wrote.
  payload=$(printf '{"conversationId":"c1","workspacePaths":["%s"],"modelName":"%s"}' \
    "$dir/wt" "$RUNG1")
  out=$(printf '%s' "$payload" | bash "$hook" Stop 2>&1) \
    || fail "the Stop hook must succeed: $out"
  [ "$out" = '{}' ] || fail "the Stop hook must still answer agy with {}, got: $out"

  # The evaluation is detached, so give it a bounded moment to land.
  wait_for_queue "$state/.wake-queue" "agy ladder refused hooked" \
    || fail "an agy worker's turn end must drive the ladder evaluation; queue was:
$(cat "$state/.wake-queue" 2>/dev/null)"
  pass "an agy worker's own turn end drives the reserve check, with no watcher and no firstmate turn"
}

test_the_evaluation_outlives_the_hook_that_started_it() {
  local dir home state out hook payload pgid
  dir="$TMP_ROOT/hook-detach"
  home="$dir/home"
  state="$home/state"
  out=$(spawn_agy_worker "$dir" outlives) \
    || fail "the agy spawn under test failed: $out"
  hook="$dir/agy-config/plugins/fm-turn-end/fm-turn-end.sh"

  # A worker that must be MOVED, so the evaluation is still working when the
  # hook that started it is torn down: it has a pane to read and a picker to
  # wait for, and the bounded waits below are shortened so the case costs
  # seconds rather than the production ceiling.
  record "$state" "$RUNG1" 0.0 '3h 41m'
  record "$state" "$RUNG2" 94.6 '3h 37m'
  record "$state" "$RUNG3" 100.0 '4h 59m'
  rm -f "$state/.agy-descent-last"
  payload=$(printf '{"conversationId":"c2","workspacePaths":["%s"],"modelName":"%s"}' \
    "$dir/wt" "$RUNG1")

  # Run the hook in a process group of its own and then destroy that group, which
  # is what a harness bounding its hook at a timeout does. The evaluation must
  # not go with it - a reaped fire-and-forget child would leave the reserve
  # unenforced with nothing to show for it.
  set -m
  ( export PATH="$dir/fake/fakebin:$PATH" FM_AGY_QUOTA_POLL=off \
      FM_AGY_DESCENT_PICKER_WAIT=4 FM_AGY_DESCENT_CONFIRM_WAIT=4
    printf '%s' "$payload" | bash "$hook" Stop >/dev/null 2>&1 ) &
  pgid=$!
  wait "$pgid" 2>/dev/null || true
  kill -- -"$pgid" 2>/dev/null || true
  set +m

  wait_for_queue "$state/.wake-queue" "agy ladder .* outlives" \
    || fail "the evaluation must outlive the hook process group that started it; queue was:
$(cat "$state/.wake-queue" 2>/dev/null)"
  pass "the turn-end evaluation runs in its own process group, so reaping the hook does not reap the reserve check"
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
test_a_reset_rung_climbs_the_worker_back_and_records_it
test_the_climb_never_reaches_into_the_captains_reserve
test_an_unread_rung_above_is_never_climbed_into
test_a_rung_hovering_at_its_boundary_never_flaps_the_worker
test_a_worker_on_a_spent_rung_climbs_instead_of_being_reported_stuck
test_a_spent_ladder_is_still_reported_when_nothing_above_has_reset
test_a_failed_climb_is_reported_once_and_not_retried_every_minute
test_the_captains_override_holds_a_worker_down_and_says_nothing
test_the_climb_can_be_turned_off_on_its_own
test_the_dwell_timer_belongs_to_the_rung_not_to_a_worker
test_a_move_leaves_a_record_naming_only_the_model_the_worker_is_on
test_a_move_that_cannot_be_recorded_is_never_reported_as_a_success
test_the_reserve_is_enforced_across_a_gap_with_no_evaluation
test_a_turn_end_that_finds_nothing_to_do_stays_silent
test_two_drivers_never_evaluate_at_once
test_the_turn_end_entry_point_publishes_into_the_durable_queue
test_the_watcher_still_runs_the_evaluation
test_an_agy_workers_turn_end_drives_the_evaluation
test_the_evaluation_outlives_the_hook_that_started_it
