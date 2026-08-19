#!/usr/bin/env bash
# tests/fm-agy-ladder-enforcement.test.sh - the regression for the agy model
# ladder gate.
#
# The captain's ladder used to be prose only, so obeying it depended on an agent
# remembering it. This suite pins the tooling that now refuses instead. It
# drives the decision library directly for the rule matrix, and the real
# bin/fm-spawn.sh for the part that actually matters: that the gate sits on the
# ordinary dispatch path and fires there, not just in a library nobody calls.
#
# The load-bearing contracts:
#   1. Descending past a rung that still has headroom is refused, and the reason
#      names the rung and the percentage it acted on.
#   2. Descending with NO evidence about a rung above is refused too. Absence is
#      not permission; descending is the move the policy constrains.
#   3. Rung 1 is refused at or below its 25% floor - the captain's reserved
#      quarter - while rungs 2 and 3 exhaust to 0.
#   4. The honest paths still launch: rung 1 with healthy quota, rung 1 with no
#      evidence at all (a fresh home must not be wedged), and a lower rung once
#      every rung above is recorded exhausted.
#   5. The override launches a refused request and SAYS SO. A silent override
#      would be worse than no gate.
#   6. Both spellings agy accepts resolve to the same rung, and a model the
#      ladder does not rank is allowed but reported.
#   7. Headroom is reserved for launches already in flight, so a burst just
#      above the floor cannot all clear it on one pre-burst reading.
#   8. The intake poll serves BOTH decisions the gate makes. Stale evidence did
#      not only fail the floor open - it also blocked every descent, because a
#      descent needs the rungs above PROVEN spent. One fresh poll answers every
#      rung, which is what keeps the ladder usable instead of pushing dispatch
#      off it onto a costlier model.
#   9. When the poll cannot answer, the gate still decides and says which
#      fallback it took: rung 1 launches, a descent does not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-agy-ladder-lib.sh
. "$ROOT/bin/fm-agy-ladder-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-ladder)

# The rule-matrix cases below decide on readings this file writes by hand, so
# the live intake poll is off for them: a real poll would replace those readings
# with the host account's own and every expectation would turn on whatever agy
# says today. Every case that exercises the poll - including the bin/fm-spawn.sh
# ones - turns it back on explicitly, against a stub agy.
export FM_AGY_QUOTA_POLL=off
# Pinned rather than inherited so a host that tunes them cannot move a boundary
# this suite asserts against.
export FM_AGY_QUOTA_MAX_AGE=300
export FM_AGY_INFLIGHT_TTL=300
export FM_AGY_LADDER_INFLIGHT_MARGIN=1

RUNG1='Claude Opus 4.6 (Thinking)'
RUNG2='Gemini 3.1 Pro (High)'
RUNG3='Gemini 3.7 Flash (High)'

# Readings are written through the real observer, which stamps them with the
# wall clock, so this suite never encodes the on-disk format and takes its own
# offsets from the same clock.
NOW=$(date +%s)

# record <state-dir> <display-model> <percent> <reset-window>
# Writes one reading exactly as bin/fm-watch.sh would, by handing the real
# observer the pane footer agy draws.
record() {
  local state=$1 model=$2 percent=$3 window=$4
  mkdir -p "$state"
  fm_agy_quota_observe "$model | ctx: 3.0% | quota: $percent% ($window)" "$state"
}

# fresh_state: a state dir with no agy readings at all.
fresh_state() {
  local dir="$TMP_ROOT/state-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# gate_out <state-dir> <model>: run the gate, echo its output, return its code.
gate_out() {
  local state=$1 model=$2 out rc=0
  out=$(fm_agy_ladder_gate "$model" "$state") || rc=$?
  printf '%s' "$out"
  return "$rc"
}

# --- 1. Rung resolution ------------------------------------------------------

test_both_spellings_resolve_to_one_rung() {
  local rung
  rung=$(fm_agy_ladder_rung "$RUNG1") || fail "rung 1 display name must resolve"
  [ "$rung" = 1 ] || fail "expected rung 1 for '$RUNG1', got '$rung'"
  rung=$(fm_agy_ladder_rung claude-opus-4-6-thinking) || fail "rung 1 kebab id must resolve"
  [ "$rung" = 1 ] || fail "expected rung 1 for the kebab id, got '$rung'"

  rung=$(fm_agy_ladder_rung "$RUNG2") || fail "rung 2 display name must resolve"
  [ "$rung" = 2 ] || fail "expected rung 2 for '$RUNG2', got '$rung'"
  rung=$(fm_agy_ladder_rung gemini-3.1-pro-high) || fail "rung 2 kebab id must resolve"
  [ "$rung" = 2 ] || fail "expected rung 2 for the kebab id, got '$rung'"

  rung=$(fm_agy_ladder_rung "$RUNG3") || fail "rung 3 display name must resolve"
  [ "$rung" = 3 ] || fail "expected rung 3 for '$RUNG3', got '$rung'"
  rung=$(fm_agy_ladder_rung gemini-3.7-flash-high) || fail "rung 3 kebab id must resolve"
  [ "$rung" = 3 ] || fail "expected rung 3 for the kebab id, got '$rung'"

  ! fm_agy_ladder_rung 'Gemini 3.1 Pro (Low)' >/dev/null \
    || fail "a reasoning class the ladder does not rank must not resolve to a rung"
  ! fm_agy_ladder_rung 'Claude Sonnet 4.6 (Thinking)' >/dev/null \
    || fail "a model outside the ladder must not resolve to a rung"
  pass "fm_agy_ladder_rung: both spellings agy accepts map onto the ladder, and nothing else does"
}

test_floors_are_the_captains_floors() {
  [ "$(fm_agy_ladder_floor 1)" = 25 ] || fail "rung 1's floor is the captain's reserved 25%"
  [ "$(fm_agy_ladder_floor 2)" = 0 ] || fail "rung 2 exhausts to 0"
  [ "$(fm_agy_ladder_floor 3)" = 0 ] || fail "rung 3 exhausts to 0"
  pass "fm_agy_ladder_floor: rung 1 stops at 25%, the rest run to 0"
}

# --- 2. Refusals -------------------------------------------------------------

test_refuses_descending_past_an_available_rung() {
  local state out rc=0
  state=$(fresh_state descend-available)
  record "$state" "$RUNG1" 80.0 '4h 0m'

  out=$(gate_out "$state" "$RUNG2") || rc=$?
  [ "$rc" -eq 1 ] || fail "rung 2 must be refused while rung 1 still has headroom (rc=$rc)"
  assert_contains "$out" "error: agy ladder refuses" "the refusal must be an error line"
  assert_contains "$out" "rung 1 (Claude Opus 4.6 (Thinking))" "the reason must name the rung above"
  assert_contains "$out" "80.0%" "the reason must carry the evidence it acted on"
  assert_contains "$out" "25% floor" "the reason must name the floor it compared against"
  [ "$(printf '%s' "$out" | wc -l)" -eq 0 ] || fail "the refusal must be one line"

  # Rung 3 is refused for the same reason, from the topmost offending rung.
  rc=0
  out=$(gate_out "$state" "$RUNG3") || rc=$?
  [ "$rc" -eq 1 ] || fail "rung 3 must be refused while rung 1 still has headroom (rc=$rc)"
  assert_contains "$out" "rung 1 (Claude Opus 4.6 (Thinking))" "rung 3's refusal must name rung 1"
  pass "refuses a descent while a rung above still has headroom, naming the rung and the evidence"
}

test_refuses_descending_on_no_evidence() {
  local state out rc=0
  state=$(fresh_state descend-unknown)

  out=$(gate_out "$state" "$RUNG2") || rc=$?
  [ "$rc" -eq 1 ] || fail "rung 2 must be refused when nothing is known about rung 1 (rc=$rc)"
  assert_contains "$out" "rung 1 (Claude Opus 4.6 (Thinking)) has no current quota reading" \
    "the reason must say the rung above is unproven"

  # A reading that has outlived its own reset window is not evidence either:
  # the window it described has rolled over, so rung 1 may be full again.
  record "$state" "$RUNG1" 4.0 '1h 0m'
  rc=0
  out=$(fm_agy_ladder_check "$RUNG2" "$state" "$((NOW + 7200))") || rc=$?
  [ "$rc" -eq 1 ] || fail "an expired rung-1 reading must not authorize a descent (rc=$rc)"
  assert_contains "$out" "has no current quota reading" \
    "an expired reading must read as unknown, not as exhausted"
  pass "refuses a descent on absent or expired evidence about the rung above"
}

test_refuses_rung_one_at_the_captains_floor() {
  local state out rc=0
  state=$(fresh_state floor)
  record "$state" "$RUNG1" 24.9 '4h 0m'

  out=$(gate_out "$state" "$RUNG1") || rc=$?
  [ "$rc" -eq 1 ] || fail "rung 1 must be refused below its 25% floor (rc=$rc)"
  assert_contains "$out" "rung 1 (Claude Opus 4.6 (Thinking)) is at 24.9%" \
    "the reason must name rung 1 and the reading"
  assert_contains "$out" "reserved for the captain" "the reason must say whose quarter it is"

  # The floor is inclusive: exactly 25% is already spent, as far as automatic
  # dispatch is concerned.
  record "$state" "$RUNG1" 25.0 '4h 0m'
  rc=0
  gate_out "$state" "$RUNG1" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "rung 1 at exactly 25% must be refused; the floor is inclusive"

  # And just above it, rung 1 runs.
  record "$state" "$RUNG1" 25.1 '4h 0m'
  rc=0
  gate_out "$state" "$RUNG1" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "rung 1 at 25.1% is above the floor and must launch (rc=$rc)"
  pass "refuses rung 1 at or below the captain's reserved 25%, and runs it just above"
}

test_refuses_an_exhausted_lower_rung() {
  local state out rc=0
  state=$(fresh_state lower-spent)
  record "$state" "$RUNG1" 10.0 '4h 0m'
  record "$state" "$RUNG2" 0.0 '4h 0m'

  out=$(gate_out "$state" "$RUNG2") || rc=$?
  [ "$rc" -eq 1 ] || fail "a rung at 0% must be refused even with every rung above it spent (rc=$rc)"
  assert_contains "$out" "rung 2 (Gemini 3.1 Pro (High)) is exhausted at 0.0%" \
    "the reason must name the spent rung and its reading"
  pass "refuses a rung that is itself exhausted, on its own 0% floor"
}

# --- 3. The honest paths still launch ---------------------------------------

test_rung_one_launches_with_healthy_quota() {
  local state rc=0 out
  state=$(fresh_state healthy)
  record "$state" "$RUNG1" 94.7 '4h 24m'

  out=$(gate_out "$state" "$RUNG1") || rc=$?
  [ "$rc" -eq 0 ] || fail "rung 1 with 94.7% remaining must launch (rc=$rc)"
  [ -z "$out" ] || fail "an ordinary clean allow must stay quiet, got '$out'"
  pass "rung 1 with healthy quota launches, and says nothing"
}

test_rung_one_launches_on_a_fresh_home() {
  local state rc=0 out
  state=$(fresh_state fresh-home)

  out=$(gate_out "$state" "$RUNG1") || rc=$?
  [ "$rc" -eq 0 ] || fail "rung 1 must launch on a home that has never drawn an agy pane (rc=$rc)"
  [ -z "$out" ] || fail "a fresh-home allow must stay quiet, got '$out'"

  # The same absence that permits rung 1 still blocks rung 2. That asymmetry is
  # the design, so assert the two verdicts diverge on identical evidence.
  rc=0
  gate_out "$state" "$RUNG2" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "the same empty evidence must refuse rung 2 while permitting rung 1"
  pass "no evidence never wedges rung 1, and still blocks a descent from it"
}

test_lower_rung_launches_once_every_rung_above_is_spent() {
  local state rc=0 out
  state=$(fresh_state descend-ok)
  record "$state" "$RUNG1" 12.0 '4h 0m'

  out=$(gate_out "$state" "$RUNG2") || rc=$?
  [ "$rc" -eq 0 ] || fail "rung 2 must launch once rung 1 is below its floor (rc=$rc)"
  [ -z "$out" ] || fail "an authorized descent must stay quiet, got '$out'"

  # Rung 3 needs BOTH rungs above spent, not just the top one.
  rc=0
  out=$(gate_out "$state" "$RUNG3") || rc=$?
  [ "$rc" -eq 1 ] || fail "rung 3 must still be refused while rung 2 is unproven (rc=$rc)"
  assert_contains "$out" "rung 2 (Gemini 3.1 Pro (High))" "rung 3's refusal must name rung 2"

  record "$state" "$RUNG2" 0.0 '4h 0m'
  rc=0
  out=$(gate_out "$state" "$RUNG3") || rc=$?
  [ "$rc" -eq 0 ] || fail "rung 3 must launch once rungs 1 and 2 are both spent (rc=$rc)"
  [ -z "$out" ] || fail "an authorized two-rung descent must stay quiet, got '$out'"
  pass "a lower rung launches only once every rung above it is recorded exhausted"
}

test_off_ladder_models_are_allowed_but_reported() {
  local state rc=0 out
  state=$(fresh_state off-ladder)
  record "$state" "$RUNG1" 99.0 '4h 0m'

  out=$(gate_out "$state" 'Claude Sonnet 4.6 (Thinking)') || rc=$?
  [ "$rc" -eq 0 ] || fail "a model the ladder does not rank must not be refused by it (rc=$rc)"
  assert_contains "$out" "notice: agy ladder not applied" \
    "an off-ladder launch must be reported, not silent"
  assert_contains "$out" "is not on the ladder" "the notice must say why the ladder did not apply"

  # No model at all: agy picks its own, so there is nothing to enforce - and
  # that is exactly the case worth saying out loud.
  rc=0
  out=$(gate_out "$state" '') || rc=$?
  [ "$rc" -eq 0 ] || fail "a launch with no model must not be refused by the ladder (rc=$rc)"
  assert_contains "$out" "no model was requested" "an unmodelled launch must be reported"
  pass "an off-ladder or unmodelled launch is allowed and reported, never silently ungoverned"
}

# --- 4. The override ---------------------------------------------------------

test_override_launches_and_is_visible() {
  local state rc=0 out
  state=$(fresh_state override)
  record "$state" "$RUNG1" 8.0 '4h 0m'

  # Without it, the captain's reserved quarter is unreachable.
  out=$(gate_out "$state" "$RUNG1") || rc=$?
  [ "$rc" -eq 1 ] || fail "rung 1 below its floor must be refused without the override"
  assert_contains "$out" "FM_AGY_LADDER_OVERRIDE" "the refusal must name the way past it"

  # Set inside the command substitution's own subshell so the override cannot
  # leak into any later case and quietly pass a test that should refuse.
  rc=0
  out=$(FM_AGY_LADDER_OVERRIDE='captain asked for the reserve'; export FM_AGY_LADDER_OVERRIDE; fm_agy_ladder_gate "$RUNG1" "$state") || rc=$?
  [ "$rc" -eq 0 ] || fail "the override must let the refused launch through (rc=$rc)"
  assert_contains "$out" "OVERRIDDEN" "the override must announce itself"
  assert_contains "$out" "captain asked for the reserve" "the override's stated reason must be printed"
  assert_contains "$out" "is at 8.0%" "the override must still print what it overrode"

  # It reaches every refusal, not only the floor.
  local empty
  empty=$(fresh_state override-descend)
  rc=0
  out=$(FM_AGY_LADDER_OVERRIDE=1; export FM_AGY_LADDER_OVERRIDE; fm_agy_ladder_gate "$RUNG3" "$empty") || rc=$?
  [ "$rc" -eq 0 ] || fail "the override must also cover an unproven descent (rc=$rc)"
  assert_contains "$out" "OVERRIDDEN" "the override must announce itself on a descent too"
  pass "the override reaches the captain's reserve and every other refusal, and never silently"
}

test_override_must_be_deliberate() {
  local state rc=0
  state=$(fresh_state override-empty)
  record "$state" "$RUNG1" 8.0 '4h 0m'

  # An exported-but-empty variable is not an override. Reaching the reserved
  # quarter has to be an act, not a leftover in the environment.
  rc=0
  ( FM_AGY_LADDER_OVERRIDE=; export FM_AGY_LADDER_OVERRIDE; fm_agy_ladder_gate "$RUNG1" "$state" >/dev/null ) || rc=$?
  [ "$rc" -eq 1 ] || fail "an empty FM_AGY_LADDER_OVERRIDE must not override anything"
  pass "an empty override variable is not an override"
}

# --- 5. Headroom for launches already in flight ------------------------------
#
# A reading describes the account at the moment it was taken. Concurrent
# launches are invisible to it, so at 26% an unbounded burst could all clear the
# 25% floor on the same pre-burst number and land the account well under the
# captain's reserve before anything was re-read.

test_a_burst_just_above_the_floor_is_refused() {
  local state rc=0 out
  state=$(fresh_state burst)
  record "$state" "$RUNG1" 26.0 '4h 0m'

  # The first launch fits: 26% really is above 25%.
  out=$(gate_out "$state" "$RUNG1") || rc=$?
  [ "$rc" -eq 0 ] || fail "the first launch at 26% must be allowed (rc=$rc)"

  # Each authorized launch reserves its margin. bin/fm-spawn.sh records this the
  # moment the gate allows; here the same ledger is driven directly.
  for _ in 1 2; do
    fm_agy_inflight_record 1 "$state"
    rc=0
    out=$(gate_out "$state" "$RUNG1") || rc=$?
  done

  [ "$rc" -eq 1 ] || fail "a burst at 26% must be refused before it crosses the floor (rc=$rc)"
  assert_contains "$out" "is at 26.0%" "the refusal must still report the evidence it read"
  assert_contains "$out" "in flight" "the refusal must say headroom was reserved for launches in flight"
  assert_contains "$out" "leaving 24.0%" "the refusal must show the figure it actually compared"
  assert_contains "$out" "reserved for the captain" "the refusal is still the captain's floor"

  # The reading itself never moved, so this is the reservation refusing and not
  # some other change of evidence.
  case "$(fm_agy_quota_read "$RUNG1" "$state")" in
    '26.0 '*) ;;
    *) fail "the burst must be refused on the SAME reading that allowed the first launch" ;;
  esac
  pass "a burst of launches just above the floor is refused before it crosses the captain's reserve"
}

test_in_flight_reservations_expire() {
  local state rc=0 now
  state=$(fresh_state inflight-expire)
  record "$state" "$RUNG1" 26.0 '4h 0m'
  now=$(date +%s)

  fm_agy_inflight_record 1 "$state" "$now"
  fm_agy_inflight_record 1 "$state" "$now"
  rc=0
  fm_agy_ladder_check "$RUNG1" "$state" "$now" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "two launches in flight at 26% must be refused (rc=$rc)"

  # Once a reading could have seen them, they stop being reserved - otherwise
  # every past launch would permanently shrink the rung. The reading is re-taken
  # at the same moment so this turns on expiry alone.
  record "$state" "$RUNG1" 26.0 '4h 0m'
  rc=0
  fm_agy_ladder_check "$RUNG1" "$state" "$((now + 301))" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || fail "expired reservations must stop reserving headroom (rc=$rc)"
  pass "headroom is reserved only for launches a current reading cannot have seen"
}

# --- 6. The intake poll serves the floor AND the descent ---------------------
#
# This is the half the original diagnosis understated. Absent evidence does not
# only fail rung 1's floor open; it also refuses every descent, because a
# descent must PROVE the rungs above are spent. Both halves are fixed by the
# same fresh reading, and one poll answers every rung at once.

# stub_agy_quota <dir> <rung1-fraction> <rung2-fraction>: an `agy` on PATH that
# answers /quota with the real command's JSON shape and runs no turn.
stub_agy_quota() {
  local dir=$1 f1=$2 f2=$3 fakebin
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/agy" <<SH
#!/usr/bin/env bash
case "\$*" in
  *models*)
    printf 'claude-opus-4-6-thinking\tClaude Opus 4.6 (Thinking)\n'
    printf 'gemini-3.1-pro-high\tGemini 3.1 Pro (High)\n'
    printf 'gemini-3.7-flash-high\tGemini 3.7 Flash (High)\n'
    ;;
  */quota*)
    cat <<'JSON'
{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"All Models","buckets":[
{"id":"claude-opus-4-6-thinking","name":"Claude Opus 4.6 (Thinking)","remaining_fraction":$f1,"reset_time":""},
{"id":"gemini-3.1-pro-high","name":"Gemini 3.1 Pro (High)","remaining_fraction":$f2,"reset_time":""}
]}]}}}
JSON
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/agy"
  printf '%s\n' "$fakebin"
}

test_the_poll_unblocks_a_descent_stale_evidence_refused() {
  local state fakebin rc=0 out
  command -v jq >/dev/null 2>&1 || { echo "skip - the intake poll needs jq, which is absent"; return 0; }

  state=$(fresh_state poll-descent)

  # Rung 1 was observed spent, but long enough ago that the reading is no longer
  # evidence. This is the state a home sits in whenever no agy pane is running.
  record "$state" "$RUNG1" 4.0 '5h 0m'
  rc=0
  out=$(fm_agy_ladder_check "$RUNG2" "$state" "$(( $(date +%s) + 400 ))") || rc=$?
  [ "$rc" -eq 1 ] || fail "a descent on a reading past the ceiling must be refused (rc=$rc)"
  assert_contains "$out" "has no current quota reading" \
    "stale evidence must read as unproven, which is what blocks the descent"

  # The same request, with the poll allowed to answer: rung 1 really is spent,
  # so the descent is now PROVEN rather than merely likely, and it proceeds.
  fakebin=$(stub_agy_quota "$TMP_ROOT/poll-descent-bin" 0.04 0.91)
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_AGY_QUOTA_POLL=on fm_agy_ladder_gate "$RUNG2" "$state") || rc=$?
  [ "$rc" -eq 0 ] || fail "a live poll proving rung 1 spent must permit the descent (rc=$rc)"
  [ -z "$out" ] || fail "an authorized descent must stay quiet, got '$out'"
  pass "a live poll turns an unprovable descent into an authorized one, instead of stranding the ladder"
}

test_the_poll_holds_the_floor_a_stale_reading_would_have_missed() {
  local state fakebin rc=0 out
  command -v jq >/dev/null 2>&1 || { echo "skip - the intake poll needs jq, which is absent"; return 0; }

  state=$(fresh_state poll-floor)
  # An hours-old reading says rung 1 is healthy. Under the window-only rule this
  # authorised every launch for the rest of its window; the account has since
  # fallen below the captain's reserve.
  record "$state" "$RUNG1" 95.0 '5h 0m'
  fakebin=$(stub_agy_quota "$TMP_ROOT/poll-floor-bin" 0.203 0.91)

  rc=0
  out=$(PATH="$fakebin:$PATH" FM_AGY_QUOTA_POLL=on fm_agy_ladder_gate "$RUNG1" "$state") || rc=$?
  [ "$rc" -eq 1 ] || fail "the poll's current reading must hold the floor the stale one missed (rc=$rc)"
  assert_contains "$out" "is at 20.3%" "the refusal must act on the polled figure, not the stale one"
  assert_not_contains "$out" "95.0" "the stale reading must not survive the poll"

  # And the descent it implies is now available, which is the whole point of
  # polling every rung at once rather than only the requested one.
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_AGY_QUOTA_POLL=on fm_agy_ladder_gate "$RUNG2" "$state") || rc=$?
  [ "$rc" -eq 0 ] || fail "the same poll must authorize the descent it just justified (rc=$rc)"
  pass "one poll both holds rung 1's floor and authorizes the descent that follows from it"
}

# --- 7. When the poll itself cannot answer ----------------------------------
#
# The captain ruled the fleet must not stall, so an unreachable quota service
# never refuses a launch at the top of the ladder. It must still refuse a
# descent, and it must SAY which of the two it did, so the reader reaches for
# the override rather than abandoning the ladder for a model outside it.

stub_agy_silent() {  # <dir>: an agy that answers nothing at all
  local dir=$1 fakebin
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/agy"
  chmod +x "$fakebin/agy"
  printf '%s\n' "$fakebin"
}

test_an_unavailable_poll_never_stalls_rung_one_but_still_blocks_a_descent() {
  local state fakebin rc=0 out
  state=$(fresh_state poll-unavailable)
  fakebin=$(stub_agy_silent "$TMP_ROOT/poll-unavailable-bin")

  # Rung 1 launches. This is the no-stall ruling: no evidence is not a reason to
  # stop agy work at the top of the ladder.
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_AGY_QUOTA_POLL=on fm_agy_ladder_gate "$RUNG1" "$state") || rc=$?
  [ "$rc" -eq 0 ] || fail "an unreachable quota read must not stall rung 1 (rc=$rc)"
  assert_contains "$out" "unchecked against the floor" \
    "an allow the floor could not check must say so rather than passing silently"

  # The descent is still refused, and the reason distinguishes "could not reach
  # agy just now" from "never observed" so the next step is obvious.
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_AGY_QUOTA_POLL=on fm_agy_ladder_gate "$RUNG2" "$state") || rc=$?
  [ "$rc" -eq 1 ] || fail "an unreachable quota read must not authorize a descent (rc=$rc)"
  assert_contains "$out" "a live quota read was attempted just now and did not answer" \
    "the refusal must name the failed live read, not report a bare absence"
  assert_contains "$out" "FM_AGY_LADDER_OVERRIDE" \
    "the refusal must name the way through, so the ladder is not abandoned for a costlier model"

  # The two verdicts diverge on identical evidence, which is the asymmetry
  # itself; assert the divergence so neither half can go quietly vacuous.
  pass "an unreachable quota read launches rung 1, refuses a descent, and names which it did"
}

# --- 8. The gate is on the real dispatch path -------------------------------
#
# Everything above proves the decision. This proves it is WIRED: bin/fm-spawn.sh
# is the one path every agy crewmate and scout launch takes, so the gate has to
# fire there. The refusal lands before the brief, the worktree, or any backend
# endpoint exists, which is why these cases need none of them.

spawn_agy() {  # <state-dir> <model> [<env-assignment>...]
  local state=$1 model=$2
  shift 2
  local dir="$TMP_ROOT/spawn" fakebin
  mkdir -p "$dir/data" "$dir/config" "$dir/projects" "$state"
  fakebin=$(fm_fakebin "$dir")
  # agy resolves from PATH before the gate runs, and the catalogue probe after
  # it does. A stub covers both so the case turns on the ladder alone and never
  # makes a network call.
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
  # The poll is left ON for these cases, against that same stub, which answers
  # nothing for /quota. That is deliberate: it proves the live read sits on the
  # real dispatch path and that failing to answer degrades to the recorded
  # reading instead of stopping the spawn.
  env "$@" PATH="$fakebin:$PATH" FM_AGY_QUOTA_POLL=on \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_PROJECTS_OVERRIDE="$dir/projects" \
    "$ROOT/bin/fm-spawn.sh" agy-ladder-probe "$dir/projects" --scout \
    --harness agy --model "$model" 2>&1
}

test_spawn_refuses_a_ladder_violation() {
  local state out rc=0
  state=$(fresh_state spawn-refuse)
  record "$state" "$RUNG1" 91.0 '4h 0m'

  out=$(spawn_agy "$state" "$RUNG3") || rc=$?
  [ "$rc" -ne 0 ] || fail "fm-spawn.sh must refuse an agy launch that violates the ladder"
  assert_contains "$out" "error: agy ladder refuses this launch" \
    "fm-spawn.sh did not report the ladder refusal"
  assert_contains "$out" "rung 1 (Claude Opus 4.6 (Thinking))" \
    "the spawn refusal must name the rung and the evidence"
  pass "fm-spawn.sh: refuses an agy launch that violates the ladder, on the ordinary dispatch path"
}

test_spawn_passes_an_honest_launch_through() {
  local state out rc=0
  state=$(fresh_state spawn-allow)
  record "$state" "$RUNG1" 91.0 '4h 0m'

  out=$(spawn_agy "$state" "$RUNG1") || rc=$?
  assert_not_contains "$out" "agy ladder" "an honest rung-1 launch must not be gated"
  # The spawn still stops - there is no brief for this probe id - but it stops
  # PAST the gate, which is what proves the gate let it through.
  assert_contains "$out" "no brief at" \
    "the honest launch must reach the brief check, i.e. past the ladder gate"
  [ "$rc" -ne 0 ] || fail "this probe spawn cannot succeed; it has no brief"
  pass "fm-spawn.sh: an honest rung-1 launch passes the gate and proceeds"
}

test_spawn_reserves_headroom_for_the_launch_it_authorized() {
  local state out rc=0
  state=$(fresh_state spawn-inflight)
  record "$state" "$RUNG1" 91.0 '4h 0m'

  [ "$(fm_agy_inflight_count 1 "$state")" = 0 ] \
    || fail "a fresh state must owe no headroom"

  out=$(spawn_agy "$state" "$RUNG1") || rc=$?
  assert_contains "$out" "no brief at" "the launch must have been authorized"
  [ "$(fm_agy_inflight_count 1 "$state")" = 1 ] \
    || fail "an authorized rung-1 launch must reserve headroom against the NEXT launch"

  # A refused launch spends nothing, so it must reserve nothing either.
  rc=0
  spawn_agy "$state" "$RUNG3" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the rung-3 probe must be refused while rung 1 is healthy"
  [ "$(fm_agy_inflight_count 3 "$state")" = 0 ] \
    || fail "a refused launch must not reserve headroom"
  pass "fm-spawn.sh: an authorized launch reserves its headroom and a refused one does not"
}

test_spawn_records_the_override() {
  local state out rc=0
  state=$(fresh_state spawn-override)
  record "$state" "$RUNG1" 91.0 '4h 0m'

  out=$(spawn_agy "$state" "$RUNG3" FM_AGY_LADDER_OVERRIDE='captain: drain flash tonight') || rc=$?
  assert_contains "$out" "OVERRIDDEN by FM_AGY_LADDER_OVERRIDE=captain: drain flash tonight" \
    "fm-spawn.sh must print the override and its stated reason"
  assert_contains "$out" "no brief at" \
    "the overridden launch must proceed past the gate"
  [ "$rc" -ne 0 ] || fail "this probe spawn cannot succeed; it has no brief"
  pass "fm-spawn.sh: the override launches a refused request and prints that it did"
}

test_both_spellings_resolve_to_one_rung
test_floors_are_the_captains_floors
test_refuses_descending_past_an_available_rung
test_refuses_descending_on_no_evidence
test_refuses_rung_one_at_the_captains_floor
test_refuses_an_exhausted_lower_rung
test_rung_one_launches_with_healthy_quota
test_rung_one_launches_on_a_fresh_home
test_lower_rung_launches_once_every_rung_above_is_spent
test_off_ladder_models_are_allowed_but_reported
test_override_launches_and_is_visible
test_override_must_be_deliberate
test_a_burst_just_above_the_floor_is_refused
test_in_flight_reservations_expire
test_the_poll_unblocks_a_descent_stale_evidence_refused
test_the_poll_holds_the_floor_a_stale_reading_would_have_missed
test_an_unavailable_poll_never_stalls_rung_one_but_still_blocks_a_descent
test_spawn_refuses_a_ladder_violation
test_spawn_passes_an_honest_launch_through
test_spawn_records_the_override
test_spawn_reserves_headroom_for_the_launch_it_authorized
