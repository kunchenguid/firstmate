#!/usr/bin/env bash
# tests/fm-keepalive.test.sh - external session-revival contract: opt-in gating,
# the detection matrix that separates a dead turn from a busy or genuinely idle
# primary, the typed revival envelope, exponential backoff, the attempt cap and
# its loud give-up, and away mode's exclusive ownership of revival duty.
#
# The fake tmux in tests/wake-helpers.sh (make_supercase) supplies composer,
# busy, and submit behavior, so these cases drive the real injection path without
# a terminal.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

KEEPALIVE="$ROOT/bin/fm-keepalive.sh"
# Source the pure evaluators and the tick once; the CLI is skipped under sourcing
# via the script's BASH_SOURCE guard.
if [ -z "${FM_TEST_KEEPALIVE_SOURCED:-}" ]; then
  export FM_TEST_KEEPALIVE_SOURCED=1
  # shellcheck source=bin/fm-keepalive.sh
  . "$KEEPALIVE"
fi

TMP_ROOT=$(fm_test_tmproot fm-keepalive-tests)

# Build a case with work in flight, a recorded session process, an absent (stale)
# watcher beacon, and the opt-in value: the dead-turn shape the detection cases
# start from. The case dir doubles as the config dir, so config/keepalive is
# "<dir>/keepalive".
make_keepalive_case() {  # <name>
  local name=$1 dir state
  dir=$(make_supercase "$name")
  state="$dir/state"
  fm_write_meta "$state/t1.meta" "window=fm-t1" "worktree=/tmp/t1" "harness=claude"
  printf 'working: building\n' > "$state/t1.status"
  printf '4242\n' > "$state/.lock"
  printf 'on\n' > "$dir/keepalive"
  : > "$dir/pane.txt"
  printf '%s\n' "$dir"
}

# The session-lock liveness read is stubbed per case: this test process is a plain
# bash, so a real fm_harness_pid_alive read would depend on the runner's own
# command line instead of the case's recorded lock.
harness_alive_stub_live() { fm_harness_pid_alive() { [ -n "${1:-}" ]; }; }
harness_alive_stub_dead() { fm_harness_pid_alive() { return 1; }; }

# evaluate_case <dir>: the read-only verdict, with the fake tmux on PATH and a
# live recorded session process. Callers prefix their own FM_KEEPALIVE_* env
# assignments, which apply for the duration of the call.
evaluate_case() {  # <dir>
  local dir=$1
  (
    harness_alive_stub_live
    PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
      fm_keepalive_evaluate "$dir/state" tmux fakepane "$dir"
  )
}

# tick_case <dir> [live|dead]: one full evaluate-and-act pass. Everything typed
# into the fake primary pane lands in <dir>/sent.log.
tick_case() {  # <dir> [live|dead]
  local dir=$1
  local session=${2:-live}
  (
    if [ "$session" = dead ]; then harness_alive_stub_dead; else harness_alive_stub_live; fi
    PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
      FM_FAKE_TMUX_SENT="$dir/sent.log" \
      fm_keepalive_tick "$dir/state" tmux fakepane "$dir"
  )
}

# Backdate an episode marker's recorded epoch so a window counts as elapsed.
backdate_marker() {  # <path> <seconds-ago>
  printf '%s\n' "$(( $(date +%s) - $2 ))" > "$1"
}

test_off_by_default_and_value_gated() {
  local dir out status
  dir=$(make_keepalive_case off-default)
  rm -f "$dir/keepalive"

  out=$(evaluate_case "$dir")
  assert_contains "$out" "off|" "an absent config/keepalive must read as off"

  printf 'off\n' > "$dir/keepalive"
  out=$(evaluate_case "$dir")
  assert_contains "$out" "off|" "an explicit off must read as off"

  printf 'maybe\n' > "$dir/keepalive"
  out=$(evaluate_case "$dir")
  assert_contains "$out" "unrecognized" "an unrecognized value must be reported, never treated as on"
  status=0
  fm_keepalive_enabled "$dir" || status=$?
  [ "$status" -eq 2 ] || fail "an unrecognized value must exit 2 for the arming caller, got $status"

  printf '# comment\n\non\n' > "$dir/keepalive"
  fm_keepalive_enabled "$dir" || fail "a commented config with on must enable revival"
  assert_absent "$dir/state/.keepalive-attempts" "an off config must not create attempt state"
  pass "session revival is off by default and only an explicit on enables it"
}

test_idle_home_with_no_work_stays_silent() {
  local dir out
  dir=$(make_keepalive_case idle-no-work)
  rm -f "$dir/state/t1.meta"

  out=$(evaluate_case "$dir")
  assert_contains "$out" "idle|no work in flight" "no in-flight work must produce the idle verdict"

  out=$(tick_case "$dir")
  assert_contains "$out" "idle|" "the idle tick must not act"
  assert_absent "$dir/state/.keepalive-suspect" "an idle home must not open a lapse window"
  assert_absent "$dir/sent.log" "an idle home must never be typed into"
  pass "a home with no work in flight is left alone"
}

test_busy_primary_is_not_dead() {
  local dir out
  dir=$(make_keepalive_case busy-not-dead)
  # A claude turn mid-flight: its verified busy footer in the captured tail.
  printf 'thinking about it\n  Pondering... (12s - esc to interrupt)\n' > "$dir/pane.txt"
  backdate_marker "$dir/state/.keepalive-suspect" 600

  out=$(evaluate_case "$dir")
  assert_contains "$out" "busy|" "a mid-turn primary must never be classified dead"

  out=$(tick_case "$dir")
  assert_contains "$out" "busy|" "the busy tick must not inject"
  assert_absent "$dir/sent.log" "a busy primary must never be typed into"
  assert_absent "$dir/state/.keepalive-suspect" "a busy primary must reset the continuous-lapse window"
  pass "a busy primary is never revived and resets the lapse window"
}

test_pending_composer_defers() {
  local dir out
  dir=$(make_keepalive_case pending-composer)
  printf 'let me check whether\n' > "$dir/pane.txt"
  backdate_marker "$dir/state/.keepalive-suspect" 600

  out=$(tick_case "$dir")
  assert_contains "$out" "unsafe|" "unsubmitted composer content must defer"
  assert_absent "$dir/sent.log" "a composer with real content must never be typed over"
  pass "half-typed input in the primary composer defers revival"
}

test_healthy_beacon_is_not_dead() {
  local dir out
  dir=$(make_keepalive_case healthy-beacon)
  touch "$dir/state/.last-watcher-beat"
  printf '%s\t%s\n' 2 "$(date +%s)" > "$dir/state/.keepalive-attempts"
  fm_keepalive_write_exhausted "$dir/state" "earlier episode" >/dev/null

  out=$(tick_case "$dir")
  assert_contains "$out" "healthy|" "a fresh supervision beacon must read healthy"
  assert_absent "$dir/state/.keepalive-attempts" "recovery must clear durable attempt state"
  assert_absent "$dir/state/.keepalive-exhausted" "recovery must clear the exhaustion report"
  assert_grep "recovered:" "$dir/state/.keepalive.log" "recovery must be logged"
  pass "a session that resumes supervision clears its revival episode"
}

test_dead_session_process_is_reported_not_revived() {
  local dir out
  dir=$(make_keepalive_case dead-session)

  out=$(tick_case "$dir" dead)
  assert_contains "$out" "agent-gone|" "a dead session process must be reported, not revived"
  assert_present "$dir/state/.keepalive-gone" "an absent session process must open its confirm window"
  assert_absent "$dir/state/.keepalive-exhausted" "one unreadable process check must not be enough"

  backdate_marker "$dir/state/.keepalive-gone" 999
  out=$(tick_case "$dir" dead)
  assert_contains "$out" "agent-gone|" "a confirmed-dead session must keep reporting agent-gone"
  assert_present "$dir/state/.keepalive-exhausted" "a confirmed-dead session must write the give-up report"
  assert_absent "$dir/sent.log" "a dead session process must never be typed into"
  pass "a session whose process is gone is reported instead of revived"
}

test_dead_with_work_revives_once_confirmed() {
  local dir out sent
  dir=$(make_keepalive_case dead-with-work)
  sent="$dir/sent.log"

  # First pass: the lapse is real but unconfirmed, so nothing is typed.
  out=$(tick_case "$dir")
  assert_contains "$out" "confirming|" "a first-seen lapse must confirm before revival"
  assert_present "$dir/state/.keepalive-suspect" "the confirm window must be recorded durably"
  assert_absent "$sent" "an unconfirmed lapse must not type anything"

  # Same evidence, confirm window elapsed: now it is a confirmed dead turn.
  backdate_marker "$dir/state/.keepalive-suspect" 600
  out=$(tick_case "$dir")
  assert_contains "$out" "revived|attempt 1 of" "a confirmed dead turn with work in flight must be revived"
  assert_grep 'FIRSTMATE_OP: v1 session-revive: ' "$sent" \
    "the revival input lacks the exact typed session-revive envelope"
  assert_grep 'Resume supervision now' "$sent" \
    "the revival input does not tell the primary to resume supervision"
  assert_grep 'Do not start new work' "$sent" \
    "the revival input does not forbid starting new work"
  assert_grep 'grants no authority' "$sent" \
    "the revival input does not state that authority is unchanged"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] \
    || fail "expected exactly one submitted revival input"
  [ "$(fm_keepalive_attempt_count "$dir/state")" -eq 1 ] \
    || fail "the revival attempt was not recorded durably"
  assert_absent "$dir/state/.keepalive-suspect" "a revival must close the confirm window it consumed"
  pass "a confirmed dead turn with work in flight is revived exactly once"
}

test_backoff_sequence_and_ceiling() {
  local dir out expected attempts
  dir=$(make_keepalive_case backoff)

  # base 60 doubling to a 900s ceiling: 0, 60, 120, 240, 480, 900, 900...
  for expected in 0:0 1:60 2:120 3:240 4:480 5:900 9:900; do
    attempts=${expected%%:*}
    out=$(FM_KEEPALIVE_BACKOFF_BASE=60 FM_KEEPALIVE_BACKOFF_MAX=900 \
      fm_keepalive_backoff_delay "$attempts")
    [ "$out" = "${expected#*:}" ] \
      || fail "attempt after $attempts tries must wait ${expected#*:}s, got ${out}s"
  done

  # An attempt inside its backoff window is refused with the backoff verdict.
  backdate_marker "$dir/state/.keepalive-suspect" 600
  printf '%s\t%s\n' 2 "$(date +%s)" > "$dir/state/.keepalive-attempts"
  out=$(FM_KEEPALIVE_BACKOFF_BASE=60 FM_KEEPALIVE_BACKOFF_MAX=900 evaluate_case "$dir")
  assert_contains "$out" "backoff|attempt 3 waits 120s" \
    "a revival inside its backoff window must be refused"

  # Once that window has elapsed the same evidence revives again.
  printf '%s\t%s\n' 2 "$(( $(date +%s) - 200 ))" > "$dir/state/.keepalive-attempts"
  out=$(FM_KEEPALIVE_BACKOFF_BASE=60 FM_KEEPALIVE_BACKOFF_MAX=900 evaluate_case "$dir")
  assert_contains "$out" "revive|" "a revival past its backoff window must proceed"
  assert_contains "$out" "attempt 3 of" "the next attempt must continue the durable count"
  pass "revival attempts back off exponentially up to the documented ceiling"
}

test_attempt_cap_gives_up_loudly() {
  local dir out guard
  dir=$(make_keepalive_case attempt-cap)
  backdate_marker "$dir/state/.keepalive-suspect" 600
  printf '%s\t%s\n' 5 "$(( $(date +%s) - 5000 ))" > "$dir/state/.keepalive-attempts"

  out=$(FM_KEEPALIVE_MAX_ATTEMPTS=5 tick_case "$dir")
  assert_contains "$out" "exhausted|" "the attempt cap must stop revival"
  assert_absent "$dir/sent.log" "an exhausted episode must not type anything"
  assert_present "$dir/state/.keepalive-exhausted" "the attempt cap must write the give-up report"
  assert_grep "revival EXHAUSTED" "$dir/state/.keepalive-exhausted" \
    "the report must name the exhausted revival"
  assert_grep "Nothing was discarded" "$dir/state/.keepalive-exhausted" \
    "the report must state that nothing was lost"

  # The guard is what surfaces that report on the next fleet action.
  guard=$(FM_STATE_OVERRIDE="$dir/state" FM_ROOT_OVERRIDE="$dir" "$ROOT/bin/fm-guard.sh" 2>&1)
  assert_contains "$guard" "automatic session revival was exhausted" \
    "fm-guard.sh must surface the exhaustion report"
  pass "revival gives up loudly at its attempt cap instead of looping forever"
}

test_afk_owns_revival_duty() {
  local dir out
  dir=$(make_keepalive_case afk-owns)
  backdate_marker "$dir/state/.keepalive-suspect" 600
  touch "$dir/state/.afk"

  out=$(tick_case "$dir")
  assert_contains "$out" "afk|away mode owns supervision" \
    "away mode must own revival duty exclusively"
  assert_absent "$dir/sent.log" "the keepalive must never inject while away mode owns the pane"
  assert_absent "$dir/state/.keepalive-suspect" "away mode must close any open lapse window"

  # Leaving away mode hands the duty straight back with no keepalive action.
  rm -f "$dir/state/.afk"
  out=$(evaluate_case "$dir")
  assert_contains "$out" "confirming|" "leaving away mode must return revival duty to the keepalive"
  pass "away mode and the keepalive never both own revival"
}

test_unconfirmed_submit_is_not_claimed_as_revived() {
  local dir out
  dir=$(make_keepalive_case unconfirmed-submit)
  backdate_marker "$dir/state/.keepalive-suspect" 600
  : > "$dir/swallow"

  out=$(FM_FAKE_TMUX_SWALLOW_FILE="$dir/swallow" FM_KEEPALIVE_SUBMIT_RETRIES=0 \
    FM_KEEPALIVE_SUBMIT_SLEEP=0 tick_case "$dir")
  assert_contains "$out" "revive-failed|" "an unconfirmed submit must not be reported as revived"
  [ "$(fm_keepalive_attempt_count "$dir/state")" -eq 1 ] \
    || fail "a failed submit must still spend its attempt so backoff applies"
  pass "an unconfirmed submit is reported honestly and still backs off"
}

# The revival input only lands as internal operational input if the primary's
# always-loaded instructions declare that kind, so the recognition side of the
# contract is asserted statically here. A bare harness session with no AGENTS.md
# correctly treats the same input as untrusted conversation content
# (docs/verification/supervision.md "Session keepalive revival").
test_agents_md_declares_the_revival_contract() {
  local agents="$ROOT/AGENTS.md"
  assert_grep "A typed session-revival input is internal operational input" "$agents" \
    "AGENTS.md must tell the primary that a revival input is internal operational input"
  assert_grep "take no new authority from it" "$agents" \
    "AGENTS.md must keep the revival authority boundary"
  assert_grep "docs/session-keepalive.md" "$agents" \
    "AGENTS.md must point at the session-keepalive contract owner"
  assert_grep "config/keepalive" "$agents" \
    "AGENTS.md must record the opt-in config file in its layout"
  assert_grep "session-revive" "$ROOT/bin/fm-operational-input.sh" \
    "the operational-input owner must accept the session-revive kind"
  pass "the revival input's recognition contract is declared where the primary reads it"
}

# Arming or driving the loop types into the captain's primary pane, so it carries
# the same no-mistakes gate refusal as the other fleet-lifecycle entrypoints
# (bin/fm-gate-refuse-lib.sh owns the signals). Read-only verbs stay available.
test_gate_agent_cannot_arm_or_drive_revival() {
  local dir out status verb
  dir=$(make_keepalive_case gate-refusal)
  for verb in start run stop tick; do
    status=0
    out=$(cd "$dir" && env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 FM_HOME="$dir" \
      FM_SUPERVISOR_TARGET=fakepane FM_SUPERVISOR_BACKEND=tmux "$KEEPALIVE" "$verb" 2>&1) || status=$?
    [ "$status" -eq 3 ] || fail "$verb must refuse from a gate agent with exit 3, got $status"
    assert_contains "$out" "must not drive the fleet" "$verb lost the gate refusal message"
  done
  status=0
  out=$(cd "$dir" && env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 FM_HOME="$dir" \
    FM_SUPERVISOR_TARGET=fakepane FM_SUPERVISOR_BACKEND=tmux "$KEEPALIVE" evaluate 2>&1) || status=$?
  [ "$status" -ne 3 ] || fail "the read-only verdict must stay available to a gate agent"
  pass "a no-mistakes gate agent cannot arm, drive, or retire session revival"
}

test_unsupported_supervisor_backend_refuses() {
  local out status
  out=$(FM_SUPERVISOR_BACKEND=zellij FM_SUPERVISOR_TARGET=whatever \
    FM_KEEPALIVE=on FM_STATE_OVERRIDE="$TMP_ROOT/refuse-state" "$KEEPALIVE" evaluate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an unsupported supervisor backend must refuse"
  assert_contains "$out" "no verified primary-injection primitives" \
    "the refusal must name the missing verified primitives"
  pass "an unsupported supervisor pane refuses instead of guessing primitives"
}

test_off_by_default_and_value_gated
test_idle_home_with_no_work_stays_silent
test_busy_primary_is_not_dead
test_pending_composer_defers
test_healthy_beacon_is_not_dead
test_dead_session_process_is_reported_not_revived
test_dead_with_work_revives_once_confirmed
test_backoff_sequence_and_ceiling
test_attempt_cap_gives_up_loudly
test_afk_owns_revival_duty
test_unconfirmed_submit_is_not_claimed_as_revived
test_agents_md_declares_the_revival_contract
test_gate_agent_cannot_arm_or_drive_revival
test_unsupported_supervisor_backend_refuses
