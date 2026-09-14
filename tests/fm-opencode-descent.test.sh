#!/usr/bin/env bash
# Behavior tests for bin/fm-opencode-descent-lib.sh - the running-worker half
# of the opencode free-then-Go ladder.
#
# The dispatch gate (bin/fm-opencode-ladder-lib.sh) routes the NEXT spawn; it
# never looks at a lane again. A lane that starts on free and hits the cap
# mid-run sits in a vendor retry backoff for hours doing nothing, which the
# supervisor reads as working. This evaluation re-checks RUNNING lanes against
# the same cap evidence the dispatch gate uses and moves the honest ones.
#
# The load-bearing contracts:
#   1. A healthy lane, a transient retry, and an expired cap stay silent: the
#      descent never touches a worker that is making progress or may resume.
#   2. A quota-scale cap is proven through the REAL record helper
#      (bin/fm-opencode-retry.sh) fed the recorded vendor refusal below
#      ("Free usage exceeded, subscribe to Go [retrying in 21h 54m]", 78840s),
#      so the state machine is exercised against the refusal without spending
#      paid quota - plus the REAL busy writer (bin/fm-busy-event.sh) latching
#      session-retry, so a stale sidecar beside a resumed turn never moves a
#      worker.
#   3. A proven free cap relaunches the lane on Go through the control plane
#      (overridable for tests), verifies the durable record followed, clears
#      the dead session's sidecar, and says `relaunched`.
#   4. A Go-recorded cap, a secondmate, and a failed relaunch surface as
#      `refused`, exactly once per episode - the ladder has no third rung, a
#      persistent supervision agent is never auto-touched, and a broken move
#      is never retried blindly.
#   5. FM_OPENCODE_LADDER_OVERRIDE holds a capped worker where the captain put
#      it and says `override`, once per episode.
#   6. A move the record did not follow is reported as `unrecorded`, never as
#      a success.
#   7. An unbound cap on a free-recorded lane still relaunches, with the
#      ambiguity owned in the handoff note - the launch gate's own bias.
#   8. Off-ladder models are never governed, and the evaluation itself is
#      rate-limited off the watcher's poll.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-opencode-descent-lib.sh
. "$ROOT/bin/fm-opencode-descent-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-opencode-descent)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'rm -rf "$TMP_ROOT"' EXIT

RETRY="$ROOT/bin/fm-opencode-retry.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"

FREE='opencode/muse-spark-1.3-contributor-free'
GO='opencode-go/muse-spark-1.3-contributor'

now_s() { date +%s; }
ms_from_now() {  # <offset-secs> -> epoch ms
  echo $(( ($(now_s) + $1) * 1000 ))
}

fresh_state() {  # <name> -> empty state dir
  local dir="$TMP_ROOT/state-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s\n' "$dir"
}

# write_meta <state-dir> <id> <harness> <model> <kind>: the durable record the
# way a spawn leaves it - the routed tier, not the requested one - with an
# endpoint the capture stub below can serve.
write_meta() {  # <state-dir> <id> <harness> <model> <kind>
  printf 'harness=%s\nmodel=%s\nkind=%s\nbackend=tmux\nwindow=pane-%s\n' \
    "$3" "$4" "$5" "$2" > "$1/$2.meta"
}

# --- pane-capture stub -------------------------------------------------------
# fm_opencode_descent_cap captures the pane tail for the idle shape; the stub
# serves per-target fixture text so that shape is exercised without a real
# pane. A target with no fixture is uncapturable (unknown, never a move).
FM_PANE_FIXTURES="$TMP_ROOT/panes"
mkdir -p "$FM_PANE_FIXTURES"
fm_backend_capture() {  # <backend> <target> <lines> [label]
  local fixture="$FM_PANE_FIXTURES/${2:-}.txt"
  [ -f "$fixture" ] || return 1
  cat "$fixture"
}

# arm_busy <state-dir> <id> <event>: the REAL busy writer the way the
# spawn-installed plugin drives it - busy on the latched worker session.
arm_busy() {  # <state-dir> <id> <event>
  "$BUSY" arm "$1" "$2" >/dev/null || return 1
  "$BUSY" apply "$1" "$2" busy --current-gen \
    --source opencode-plugin --event "$3" >/dev/null || return 1
}

# arm_idle <state-dir> <id> <event>: the plugin's own turn-end write - state
# idle on session-idle / session-status-idle, which also clears the retry
# sidecar. This is the record an idle-after-cap lane carries.
arm_idle() {  # <state-dir> <id> <event>
  "$BUSY" arm "$1" "$2" >/dev/null || return 1
  "$BUSY" apply "$1" "$2" idle --current-gen \
    --source opencode-plugin --event "$3" >/dev/null || return 1
}

# record_cap <state-dir> <id> <offset-secs> [model]: one retry observation
# through the REAL record helper the plugin names - the recorded vendor
# refusal converted to the structural `next` timestamp the detector owns.
record_cap() {  # <state-dir> <id> <offset-secs> [model]
  local state=$1 id=$2 offset=$3 model=${4:-}
  if [ -n "$model" ]; then
    "$RETRY" record "$state" "$id" 3 "$(ms_from_now "$offset")" "$model" "ses_$id"
  else
    "$RETRY" record "$state" "$id" 3 "$(ms_from_now "$offset")"
  fi
}

# --- the control-plane stub --------------------------------------------------
# The tick moves a worker through bin/fm-control.sh relaunch. Tests override
# that binary so no real agent is ever stopped: the stub records its argv,
# fails on demand, and publishes the Go record the way a real relaunch would.
STUB="$TMP_ROOT/control-stub.sh"
STUB_LOG="$TMP_ROOT/control-argv.log"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_STUB_LOG"
[ "${FM_STUB_EXIT:-0}" != 0 ] && exit 1
if [ "${FM_STUB_PUBLISH_GO:-0}" = 1 ]; then
  id=$1
  meta="$FM_STUB_STATE/$id.meta"
  sed 's|^model=.*|model=opencode-go/muse-spark-1.3-contributor|' "$meta" > "$meta.new" \
    && mv "$meta.new" "$meta"
fi
exit 0
SH
chmod +x "$STUB"

stub_env() {  # <state-dir> <exit> <publish>: reset stub behavior for one case
  FM_STUB_STATE=$1 FM_STUB_EXIT=$2 FM_STUB_PUBLISH_GO=$3
  export FM_STUB_STATE FM_STUB_EXIT FM_STUB_PUBLISH_GO
  export FM_STUB_LOG="$STUB_LOG"
  : > "$STUB_LOG"
  export FM_OPENCODE_DESCENT_CONTROL_BIN="$STUB"
}

stub_calls() { cat "$STUB_LOG" 2>/dev/null; }
stub_called() { [ -s "$STUB_LOG" ]; }

# run_tick <state-dir>: one evaluation, outcome lines on stdout.
run_tick() {  # <state-dir>
  FM_OPENCODE_DESCENT_INTERVAL=0 fm_opencode_descent_tick "$1" 2>/dev/null
}

# --- 1. healthy, transient, and expired lanes stay silent ---------------------

test_healthy_lane_is_silent() {
  local state out
  state=$(fresh_state healthy)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-busy || fail "busy writer refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail a healthy lane"
  [ -z "$out" ] || fail "a healthy lane must stay silent, said: $out"
  stub_called && fail "a healthy lane must never reach the control plane"
  pass "a healthy lane stays silent"
}

test_transient_retry_stays() {
  local state out
  state=$(fresh_state transient)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 8 "$FREE" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "a seconds-long backoff must stay silent, said: $out"
  stub_called && fail "a transient retry must never reach the control plane"
  pass "a transient retry backoff stays put"
}

test_expired_cap_stays() {
  local state out
  state=$(fresh_state expired)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 -82800 "$FREE" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "an expired cap must stay silent, said: $out"
  stub_called && fail "an expired cap must never reach the control plane"
  pass "an expired cap is left alone"
}

# --- 2. the latch: a stale sidecar beside a resumed turn never moves ---------

test_stale_sidecar_needs_latch() {
  local state out
  state=$(fresh_state latch)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  # Quota-scale sidecar, but the busy record says the turn resumed: the
  # sidecar belongs to a retired observation, not to this worker now.
  arm_busy "$state" lane1 session-busy || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "a stale sidecar must stay silent, said: $out"
  stub_called && fail "a stale sidecar must never reach the control plane"
  pass "a stale sidecar beside a resumed turn never moves a worker"
}

# --- 3. the recorded refusal relaunches onto Go -------------------------------

test_recorded_refusal_relaunches_to_go() {
  local state out
  state=$(fresh_state refusal)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  # Recorded vendor refusal, verbatim from the 2026-09-07 twelve-wide stall:
  #   Free usage exceeded, subscribe to Go [retrying in 21h 54m]
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail past the cap"
  case "$out" in
    relaunched' '*) : ;;
    *) fail "a proven free cap must relaunch, said: ${out:-<silent>}" ;;
  esac
  stub_called || fail "a proven free cap must reach the control plane"
  case "$(stub_calls)" in
    *'relaunch'*"$GO"*) : ;;
    *) fail "the move must be a relaunch onto the Go tier, called: $(stub_calls)" ;;
  esac
  case "$(stub_calls)" in
    *'--note'*) : ;;
    *) fail "the replacement must inherit a handoff note, called: $(stub_calls)" ;;
  esac
  [ "$(fm_meta_model "$state" lane1)" = "$GO" ] \
    || fail "the durable record must name Go after the move"
  [ ! -f "$state/lane1.opencode-retry" ] \
    || fail "the dead session's sidecar must be cleared after the move"
  pass "the recorded free refusal relaunches the lane onto Go"
}

fm_meta_model() {  # <state-dir> <id> -> recorded model (test reader only)
  sed -n 's/^model=//p' "$1/$2.meta"
}

# --- 4. nowhere to move, and nobody to move -----------------------------------

test_go_lane_surfaces() {
  local state out
  state=$(fresh_state golane)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$GO" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$GO" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail"
  case "$out" in
    refused' '*) : ;;
    *) fail "a capped Go lane must surface, said: ${out:-<silent>}" ;;
  esac
  stub_called && fail "a capped Go lane has nowhere to move to"
  pass "a capped Go lane surfaces instead of moving"
}

test_secondmate_surfaces() {
  local state out
  state=$(fresh_state secondmate)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" secondmate
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail"
  case "$out" in
    refused' '*) : ;;
    *) fail "a capped secondmate must surface, said: ${out:-<silent>}" ;;
  esac
  stub_called && fail "a secondmate must never be auto-relaunched"
  pass "a capped secondmate surfaces for a firstmate decision"
}

test_off_ladder_silent() {
  local state out
  state=$(fresh_state off)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode 'opencode/glm-5.3' scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 'opencode/glm-5.3' || fail "record refused"
  out=$(run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "an off-ladder model must stay silent, said: $out"
  stub_called && fail "an off-ladder model must never reach the control plane"
  pass "an off-ladder model is never governed"
}

test_unknown_model_surfaces() {
  local state out
  state=$(fresh_state nomodel)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode '' scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail"
  case "$out" in
    refused' '*) : ;;
    *) fail "a lane recording no model must surface, said: ${out:-<silent>}" ;;
  esac
  stub_called && fail "a lane recording no model must never be moved blind"
  pass "a lane recording no model surfaces instead of moving blind"
}

# --- 5. failure and override: loud once, then quiet ----------------------------

test_failed_relaunch_escalates_once() {
  local state out
  state=$(fresh_state relaunchfail)
  stub_env "$state" 1 0
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail"
  case "$out" in
    refused' '*) : ;;
    *) fail "a failed move must surface, said: ${out:-<silent>}" ;;
  esac
  out=$(run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "a failed move must not wake twice, said: $out"
  [ "$(stub_calls | grep -c .)" = 1 ] \
    || fail "a failed move must not be retried blindly"
  # A new cap episode re-arms the attempt: the old evidence expired and fresh
  # refusal evidence arrived with a new vendor timestamp, so the next tick
  # tries again.
  "$RETRY" clear "$state" lane1
  record_cap "$state" lane1 70000 "$FREE" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail"
  case "$out" in
    refused' '*) : ;;
    *) fail "a new cap episode must re-arm the attempt, said: ${out:-<silent>}" ;;
  esac
  [ "$(stub_calls | grep -c .)" = 2 ] \
    || fail "a new cap episode must re-arm the attempt"
  pass "a failed relaunch surfaces once and re-arms on a new episode"
}

test_override_holds() {
  local state out
  state=$(fresh_state override)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(FM_OPENCODE_LADDER_OVERRIDE='captain asked for free' run_tick "$state") \
    || fail "tick must never fail"
  case "$out" in
    override' '*) : ;;
    *) fail "the override must hold the worker, said: ${out:-<silent>}" ;;
  esac
  stub_called && fail "an overridden worker must never be moved"
  out=$(FM_OPENCODE_LADDER_OVERRIDE='captain asked for free' run_tick "$state") \
    || fail "tick must never fail"
  [ -z "$out" ] || fail "an override must not wake twice, said: $out"
  pass "the override holds a capped worker and says so once"
}

# --- 6. the move must be on the record, and the ambiguity owned ----------------

test_unrecorded_move_reported() {
  local state out
  state=$(fresh_state unrecorded)
  stub_env "$state" 0 0
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail"
  case "$out" in
    unrecorded' '*) : ;;
    *) fail "a move the record missed must be reported, said: ${out:-<silent>}" ;;
  esac
  [ -f "$state/lane1.opencode-retry" ] \
    || fail "an unrecorded move must keep its evidence for the investigation"
  out=$(run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "an unrecorded move must not wake twice, said: $out"
  pass "a move the record missed is reported, never claimed"
}

test_unbound_cap_relaunches_with_ambiguity() {
  local state out
  state=$(fresh_state unbound)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 || fail "record refused fixture"
  out=$(run_tick "$state") || fail "tick must never fail past the cap"
  case "$out" in
    relaunched' '*) : ;;
    *) fail "an unbound cap on free must still move, said: ${out:-<silent>}" ;;
  esac
  case "$(stub_calls)" in
    *'unbound'*|*'no model'*) : ;;
    *) fail "the handoff note must own the ambiguity, called: $(stub_calls)" ;;
  esac
  pass "an unbound cap relaunches with the ambiguity owned"
}

# --- 7. the evaluation itself is rate-limited off the watcher poll -------------

test_evaluation_rate_limited() {
  local state out
  state=$(fresh_state ratelimit)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-busy || fail "busy writer refused fixture"
  out=$(FM_OPENCODE_DESCENT_INTERVAL=3600 fm_opencode_descent_tick "$state" 2>/dev/null) \
    || fail "tick must never fail"
  [ -z "$out" ] || fail "a healthy evaluation must stay silent, said: $out"
  # The cap lands inside the rate-limit window: the next poll must not act.
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  out=$(FM_OPENCODE_DESCENT_INTERVAL=3600 fm_opencode_descent_tick "$state" 2>/dev/null) \
    || fail "tick must never fail"
  [ -z "$out" ] || fail "a rate-limited evaluation must stay silent, said: $out"
  stub_called && fail "a rate-limited evaluation must not reach the control plane"
  # Past the window the same evidence moves.
  out=$(run_tick "$state") || fail "tick must never fail"
  case "$out" in
    relaunched' '*) : ;;
    *) fail "evidence past the window must move, said: ${out:-<silent>}" ;;
  esac
  pass "the evaluation is rate-limited off the watcher poll"
}

# --- 1b. the idle shape: capped and idle, with no sidecar --------------------
# The 2026-09-14 blind spot: four lanes took the provider error, ended their
# turn, and went idle with no retry sidecar. Only the pane tail still shows
# the cap verbatim. The descent must move those lanes exactly as it moves an
# actively-retrying one.

test_idle_after_cap_relaunches_to_go() {
  local state out
  state=$(fresh_state idlecap)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_idle "$state" lane1 session-idle || fail "busy writer refused fixture"
  # No record_cap: the sidecar is gone by design. The pane tail carries the
  # cap verbatim, wrapped across rendered lines as the incident showed it.
  printf '%s\n' \
    'working on the task...' \
    'Free usage exceeded, subscri' \
    'be to Go [retrying in 35s attempt #5]' \
    'opencode>' > "$FM_PANE_FIXTURES/pane-lane1.txt"
  out=$(run_tick "$state") || fail "tick must never fail past the cap"
  case "$out" in
    relaunched' '*) : ;;
    *) fail "an idle-after-cap lane must relaunch, said: ${out:-<silent>}" ;;
  esac
  stub_called || fail "an idle-after-cap lane must reach the control plane"
  case "$(stub_calls)" in
    *'relaunch'*"$GO"*) : ;;
    *) fail "the move must be a relaunch onto the Go tier, called: $(stub_calls)" ;;
  esac
  case "$(stub_calls)" in
    *'no retry horizon on record'*) : ;;
    *) fail "the handoff note must own the missing horizon, called: $(stub_calls)" ;;
  esac
  [ "$(fm_meta_model "$state" lane1)" = "$GO" ] \
    || fail "the durable record must name Go after the move"
  # A relaunched lane wakes in a fresh pane: the next evaluation sees clean
  # text and stays silent rather than re-firing on the old capture.
  printf '%s\n' 'fresh session, working' 'opencode>' > "$FM_PANE_FIXTURES/pane-lane1.txt"
  out=$(run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "a relaunched lane with a clean pane must stay silent, said: $out"
  pass "an idle-after-cap lane relaunches onto Go"
}

test_idle_healthy_lane_stays() {
  local state out
  state=$(fresh_state idlehealthy)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_idle "$state" lane1 session-idle || fail "busy writer refused fixture"
  printf '%s\n' 'working on the task...' 'done' 'opencode>' > "$FM_PANE_FIXTURES/pane-lane1.txt"
  out=$(run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "an idle lane with a clean pane must stay silent, said: $out"
  stub_called && fail "an idle lane with a clean pane must never reach the control plane"
  pass "an idle lane with a clean pane stays put"
}

test_healthy_lane_is_silent
test_transient_retry_stays
test_expired_cap_stays
test_stale_sidecar_needs_latch
test_recorded_refusal_relaunches_to_go
test_idle_after_cap_relaunches_to_go
test_idle_healthy_lane_stays
test_go_lane_surfaces
test_secondmate_surfaces
test_off_ladder_silent
test_unknown_model_surfaces
test_failed_relaunch_escalates_once
test_override_holds

test_filed_descent_off_holds_where_the_tick_runs() {
  local state out
  state=$(fresh_state descent-off-file)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  # The off state the watcher actually reads is a state record, because the
  # watcher is a long-lived process that predates the instruction and never
  # inherits firstmate's environment. Every evaluation below runs with the
  # variable absent, so this fails if the file is honoured only where it is
  # set.
  : > "$state/.opencode-descent-off"
  out=$(unset FM_OPENCODE_DESCENT; run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "a filed descent-off must hold the lane, said: ${out:-<silent>}"
  stub_called && fail "a filed descent-off must never reach the control plane"
  # Removing the file returns the evaluation on the same evidence, so the
  # file was what held it rather than the evidence having gone quiet.
  rm -f "$state/.opencode-descent-off"
  out=$(unset FM_OPENCODE_DESCENT; run_tick "$state") || fail "tick must never fail"
  case "$out" in
    relaunched' '*) : ;;
    *) fail "removing the file must return the evaluation, said: ${out:-<silent>}" ;;
  esac
  pass "a filed .opencode-descent-off disables the evaluation where the tick runs"
}

test_recorded_pin_holds_without_the_env_var() {
  local state out
  state=$(fresh_state override-pin-file)
  stub_env "$state" 0 1
  write_meta "$state" lane1 opencode "$FREE" scout
  arm_busy "$state" lane1 session-retry || fail "busy writer refused fixture"
  record_cap "$state" lane1 78840 "$FREE" || fail "record refused fixture"
  # The pin firstmate records when it holds a lane on the captain's word is
  # read back where the tick runs, not from an environment the watcher never
  # inherits. The variable stays absent throughout, so this fails if the hold
  # only sticks where the variable is set. Written directly: the production
  # writer is fm-spawn.sh through fm_opencode_pin_task.
  printf '%s' 'captain: hold free for this demo' > "$state/.opencode-pin-lane1"
  out=$(unset FM_OPENCODE_LADDER_OVERRIDE; run_tick "$state") || fail "tick must never fail"
  case "$out" in
    override' '*) : ;;
    *) fail "a recorded pin must hold the worker, said: ${out:-<silent>}" ;;
  esac
  case "$out" in
    *'captain: hold free for this demo'*) : ;;
    *) fail "the recorded reason must be printed, said: $out" ;;
  esac
  stub_called && fail "a pinned worker must never be moved"
  out=$(unset FM_OPENCODE_LADDER_OVERRIDE; run_tick "$state") || fail "tick must never fail"
  [ -z "$out" ] || fail "a pin must not wake twice, said: $out"
  pass "a recorded pin holds a capped worker where the tick runs and says so once"
}

test_filed_descent_off_holds_where_the_tick_runs
test_recorded_pin_holds_without_the_env_var
test_unrecorded_move_reported
test_unbound_cap_relaunches_with_ambiguity
test_evaluation_rate_limited
