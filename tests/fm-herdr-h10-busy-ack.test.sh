#!/usr/bin/env bash
# GATE h10 - the acknowledgment is real for a BUSY agent, or it is not claimed.
#
# THE DEFECT THIS FREEZES (Quarterdeck reject, attempt 3). From `herdr agent
# prompt --help`, the binary's own words:
#
#   "It does not track turns: if the agent is already working, that active
#    turn's completion may match."
#
# fm_herdr_prompt called `--wait` with no `--until` and no check of the agent's
# state before submitting. So steering a crewmate that was ALREADY WORKING - the
# ordinary case, because that is exactly when a steer is needed - could match the
# PREVIOUS turn's completion and return 0: "delivered AND acknowledged, the agent
# consumed it", before the new steer had started.
#
# That is the one property this whole seam was built for. AGENTS.md asserted it
# as fact ("returns only once the agent has consumed the prompt - real
# acknowledgment, where tmux could only guess") while the binary documented the
# opposite, and no gate covered it: h4 froze only that the --wait FLAG is
# present, and h5's live case runs against an idle agent.
#
# WHAT A HONEST ANSWER LOOKS LIKE. From a non-working state, --wait is
# trustworthy: the binary requires an observed state change first, so a match
# means the agent moved because of our prompt. From a WORKING state it is not,
# so the seam must not lean on it. A queued prompt is consumed when the current
# turn ends and a new one begins, so that transition - settle, then working
# again - is the acknowledgment, and its absence within the budget is reported
# as delivered-but-unconfirmed (4) rather than invented as success.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"
# shellcheck source=bin/fm-herdr.sh
. "$ROOT/bin/fm-herdr.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-herdr-h10)
FB=$(fm_herdr_fake_server "$TMP_ROOT")
PATH="$FB:$PATH"; export PATH
CALLS="$TMP_ROOT/calls"; export CALLS
export HERDR_STATE_CURSOR="$TMP_ROOT/cursor"
export FM_HERDR_SEND_TIMEOUT_MS=2000
export FM_HERDR_ACK_POLL=0.02

reset() { : > "$CALLS"; : > "$HERDR_STATE_CURSOR"; }

# --- the busy case, which is the whole gate ---------------------------------

# THE CASE THE BINARY WARNS ABOUT. The agent is working when the steer is sent;
# the current turn then ends and the agent stays idle - the prompt was swallowed.
# The fake's `agent prompt --wait` SUCCEEDS here, exactly as the real one would
# by matching the old turn's completion. Returning 0 on that is the defect.
test_a_swallowed_steer_to_a_busy_agent_is_not_acknowledged() {
  reset
  local rc=0
  HERDR_STATES='working,idle,idle,idle,idle,idle' \
    fm_herdr_prompt w9:p2 'stop and re-read the brief' >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    fail "a steer to a busy agent was reported as ACKNOWLEDGED off the previous turn's completion"
  fi
  expect_code 4 "$rc" "a swallowed steer to a busy agent should be delivered-but-unconfirmed"
  pass "busy: a steer that never started a turn is NOT reported as acknowledged"
}

# The other half: the queued prompt IS consumed - the turn ends and a new one
# starts. That transition is caused by our steer, so it is real acknowledgment.
test_a_consumed_steer_to_a_busy_agent_is_acknowledged() {
  reset
  local rc=0
  HERDR_STATES='working,idle,working,working' \
    fm_herdr_prompt w9:p2 'stop and re-read the brief' >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a steer that demonstrably started a new turn was not acknowledged"
  pass "busy: a steer that starts a new turn IS acknowledged"
}

# The seam must consult the agent's state BEFORE submitting. Without that it
# cannot know which of the two answers above applies, and the binary's caveat
# applies silently.
test_the_state_is_read_before_submitting() {
  reset
  HERDR_STATES='working,idle,working' fm_herdr_prompt w9:p2 'x' >/dev/null 2>&1
  local first
  first=$(head -1 "$CALLS")
  case "$first" in
    "agent get"*) : ;;
    *) fail "the first herdr call was '$first'; the agent's state was not read before submitting" ;;
  esac
  pass "busy: the agent's state is read before the steer is submitted"
}

# --- the idle case still uses --wait, and says which states it means ---------

test_an_idle_agent_uses_wait_with_explicit_until() {
  reset
  local rc=0
  HERDR_STATES='idle,idle,idle' fm_herdr_prompt w9:p2 'do the thing' >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "a steer to an idle agent was not acknowledged"
  assert_grep "--wait" "$CALLS" "the idle path stopped using the acknowledged prompt"
  # Explicit --until so a change to herdr's default cannot silently alter what
  # "acknowledged" means here.
  assert_grep "--until" "$CALLS" "the idle path does not say which states it accepts"
  pass "idle: --wait is used, with the accepted states named explicitly"
}

# --- through fm-send, which is what firstmate actually calls -----------------

test_fm_send_does_not_report_a_swallowed_busy_steer_as_delivered() {
  reset
  local home out rc=0
  home="$TMP_ROOT/home"; mkdir -p "$home/state"
  printf 'window=w9:p2\nmux=herdr\nkind=ship\n' > "$home/state/busy.meta"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        HERDR_STATES='working,idle,idle,idle,idle,idle' \
        "$SEND" fm-busy 'stop and re-read the brief' 2>&1) || rc=$?
  # Exit 0 is allowed - an unconfirmed delivery is assumed sent and not re-sent -
  # but it must SAY the acknowledgment did not arrive rather than claiming one.
  assert_contains "$out" "did not acknowledge" \
    "fm-send reported a steer to a busy agent as delivered with no caveat"
  pass "busy: fm-send says the acknowledgment did not arrive instead of inventing one"
}

test_a_swallowed_steer_to_a_busy_agent_is_not_acknowledged
test_a_consumed_steer_to_a_busy_agent_is_acknowledged
test_the_state_is_read_before_submitting
test_an_idle_agent_uses_wait_with_explicit_until
test_fm_send_does_not_report_a_swallowed_busy_steer_as_delivered
