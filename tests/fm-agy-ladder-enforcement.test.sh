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
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-agy-ladder-lib.sh
. "$ROOT/bin/fm-agy-ladder-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-agy-ladder)

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

# --- 5. The gate is on the real dispatch path -------------------------------
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
  env "$@" PATH="$fakebin:$PATH" \
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
test_spawn_refuses_a_ladder_violation
test_spawn_passes_an_honest_launch_through
test_spawn_records_the_override
