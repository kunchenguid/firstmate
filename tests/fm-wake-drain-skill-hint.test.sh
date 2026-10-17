#!/usr/bin/env bash
# tests/fm-wake-drain-skill-hint.test.sh - the drain names the agent-only skill
# to load beside each presented wake that AGENTS.md section 8 (or the skill's own
# description) maps to one, and prints no hint for a wake with no mapped skill.
# A portable tests/ regression: the real drain over crafted queue rows and status
# logs, no harness.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-skill-hint-tests)

# Keep the supervision host's BRANCH OUTCOMES section out of these drains on
# every primary (bin/fm-supervision-engine-lib.sh owns the gate).
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# drain_case <name> <status-line-or-empty> <meta-or-empty> <kind> <key> <payload>
# Queue one wake (with an unread status line for a signal) and drain it into
# $CASE_OUT.
drain_case() {
  local name=$1 line=$2 meta=$3 kind=$4 key=$5 payload=$6 dir state
  dir=$(make_case "$name")
  state="$dir/state"
  CASE_OUT="$dir/drain.out"
  [ -z "$line" ] || printf '%s\n' "$line" > "$state/${key%.status}.status"
  [ -z "$meta" ] || printf '%s\n' "$meta" > "$state/${key%.status}.meta"
  append_wake "$state" "$kind" "$key" "$payload" || fail "$name: queueing the wake failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$CASE_OUT" 2>/dev/null || fail "$name: drain failed"
}

# assert_hint_after <pattern> <hint>: the line right after the first line
# matching <pattern> is exactly <hint>.
assert_hint_after() {
  local pattern=$1 hint=$2 next
  next=$(grep -F -A1 -- "$pattern" "$CASE_OUT" | sed -n 2p)
  [ "$next" = "$hint" ] || fail "expected '$hint' right after '$pattern', got '$next': $(cat "$CASE_OUT")"
}

test_stale_wake_names_stuck_crewmate_recovery() {
  drain_case stale '' '' stale fm:task1 'stale: fm:task1'
  assert_hint_after "$(printf '\tstale\tfm:task1\t')" 'load: stuck-crewmate-recovery'
  pass "a stale wake names stuck-crewmate-recovery beside its row"
}

test_procevent_check_names_process_event_sources() {
  drain_case procevent '' '' check procevent:board:7 'check: procevent lavish board 7'
  assert_hint_after "$(printf '\tcheck\tprocevent:board:7\t')" 'load: process-event-sources'
  pass "a procevent check wake names process-event-sources beside its row"
}

test_relay_check_names_fmx_respond() {
  drain_case relay '' '' check /home/state/x-watch.check.sh 'check: /home/state/x-watch.check.sh: x-mention r1'
  assert_hint_after "$(printf '\tcheck\t/home/state/x-watch.check.sh\t')" 'load: fmx-respond'
  pass "a Relay mention check wake names fmx-respond beside its row"
}

test_contributions_check_names_bearings() {
  drain_case contributions '' '' check contribution-0a1b2c 'check: contributions task8 0a1b2c'
  assert_hint_after "$(printf '\tcheck\tcontribution-0a1b2c\t')" 'load: bearings'
  pass "a contributions check wake names bearings beside its row"
}

test_ready_pr_signal_names_ship_landing() {
  drain_case ready-pr 'done: PR https://github.com/o/r/pull/9 checks green' '' \
    signal task2.status 'signal: task2.status'
  assert_hint_after 'task2.status: done: PR https://github.com/o/r/pull/9' 'load: ship-landing'
  pass "a ready-PR signal names ship-landing beside its status line"
}

test_ready_branch_signal_names_ship_landing() {
  drain_case ready-branch 'done: ready in branch fm/x' '' signal task3.status 'signal: task3.status'
  assert_hint_after 'task3.status: done: ready in branch fm/x' 'load: ship-landing'
  pass "a ready local branch signal names ship-landing beside its status line"
}

test_scout_done_signal_names_scout_completion() {
  drain_case scout-done 'done: report written' 'kind=scout' signal task4.status 'signal: task4.status'
  assert_hint_after 'task4.status: done: report written' 'load: scout-completion'
  pass "a scout's done signal names scout-completion beside its status line"
}

test_ask_user_signal_names_ask_user_skills() {
  drain_case ask-user 'needs-decision [key=nm-1-review]: ask-user findings=f1 file=/x/f.txt' '' \
    signal task5.status 'signal: task5.status'
  assert_hint_after 'task5.status: needs-decision [key=nm-1-review]' 'load: ask-user-authority, validation-supervision'
  pass "an ask-user finding signal names ask-user-authority and validation-supervision"
}

test_unmapped_wakes_print_no_hint() {
  drain_case unmapped-signal 'working: setup complete' '' signal task6.status 'signal: task6.status'
  ! grep -q '^load:' "$CASE_OUT" || fail "a routine working signal printed a skill hint: $(cat "$CASE_OUT")"
  drain_case unmapped-heartbeat '' '' heartbeat heartbeat heartbeat
  ! grep -q '^load:' "$CASE_OUT" || fail "a heartbeat printed a skill hint: $(cat "$CASE_OUT")"
  drain_case unmapped-done 'done: implemented and committed' '' signal task7.status 'signal: task7.status'
  ! grep -q '^load:' "$CASE_OUT" || fail "a ship's pre-PR done signal printed a skill hint: $(cat "$CASE_OUT")"
  pass "wakes with no mapped skill print no hint"
}

test_stale_wake_names_stuck_crewmate_recovery
test_procevent_check_names_process_event_sources
test_relay_check_names_fmx_respond
test_contributions_check_names_bearings
test_ready_pr_signal_names_ship_landing
test_ready_branch_signal_names_ship_landing
test_scout_done_signal_names_scout_completion
test_ask_user_signal_names_ask_user_skills
test_unmapped_wakes_print_no_hint
