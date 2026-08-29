#!/usr/bin/env bash
# GATE h4 - steering and observing a herdr crewmate, routed by the meta.
#
# THE SELF-LOBOTOMY RISK. fm-send.sh and fm-peek.sh are the channel firstmate
# uses to steer and observe every direct report. If they break, the supervisor
# loses the ability to steer or observe ANY crewmate - including the one sent to
# fix them. So both drivers are pinned here, and the tmux path is pinned in the
# same file as the herdr one so neither can be "fixed" by breaking the other.
#
# WHAT ROUTING MEANS. window= is an OPAQUE target: `session:window` under tmux, a
# pane id under herdr. Which verbs address it is not something to guess from its
# shape - it is recorded as mux= by fm-spawn when the target is minted. A
# crewmate spawned as a herdr tab must stay steerable from a process where herdr
# no longer resolves, and a tmux crewmate must never be probed with herdr verbs.
#
# WHAT ACKNOWLEDGMENT MEANS. `herdr agent prompt --wait` returns only once the
# agent has actually consumed the prompt. That is the acknowledgment tmux cannot
# give, and it is the entire reason this seam exists - so a send that drops
# --wait is a regression this gate treats as a failure, not a style question.
set -u

# shellcheck source=tests/herdr-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/herdr-helpers.sh"

SEND="$ROOT/bin/fm-send.sh"
PEEK="$ROOT/bin/fm-peek.sh"
TMP_ROOT=$(fm_test_tmproot fm-mux-h4)

FB=$(fm_herdr_fake_server "$TMP_ROOT")
fm_herdr_fake_tmux "$TMP_ROOT" >/dev/null   # same fakebin dir; adds tmux
CALLS="$TMP_ROOT/calls"; export CALLS
PANE="$TMP_ROOT/pane.txt"

HOME_DIR="$TMP_ROOT/home"; mkdir -p "$HOME_DIR/state"
# Two crewmates, minted by different drivers - the situation routing must survive.
cat > "$HOME_DIR/state/herdrcrew.meta" <<META
window=wM:p2
worktree=/wt
project=/p/archify
harness=claude
mux=herdr
name=archify-fleet-view
kind=ship
META
cat > "$HOME_DIR/state/tmuxcrew.meta" <<META
window=firstmate:fm-tmuxcrew
worktree=/wt
project=/p/archify
harness=claude
mux=tmux
kind=ship
META
# A meta written before the seam existed: no mux= line at all.
cat > "$HOME_DIR/state/legacycrew.meta" <<META
window=firstmate:fm-legacycrew
worktree=/wt
harness=claude
kind=ship
META

reset() { : > "$CALLS"; : > "$PANE"; }

run() {  # <script> <args...>
  env -u FM_MUX FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" \
    HERDR_SERVER="${HERDR_SERVER:-running}" \
    HERDR_PANE_FILE="$PANE" PANE_FILE="$PANE" \
    CALLS="$CALLS" PATH="$FB:$PATH" "$@" 2>&1
}

# --- fm-send: acknowledged delivery -----------------------------------------

test_send_to_a_herdr_crewmate_is_acknowledged() {
  reset
  local out rc=0
  out=$(run "$SEND" fm-herdrcrew 'do the thing') || rc=$?
  expect_code 0 "$rc" "send to a herdr crewmate failed: $out"
  assert_grep "agent prompt wM:p2 do the thing --wait" "$CALLS" \
    "the steer was not delivered through the acknowledged prompt path"
  assert_no_grep "send-keys" "$CALLS" "the steer fell back to blind keystrokes"
  pass "send: a herdr crewmate is steered with one acknowledged agent prompt"
}

# --wait is the acknowledgment FROM A NON-WORKING AGENT, and that is the case
# this file covers. It is deliberately not asserted for a working agent: there
# the binary "does not track turns" and --wait can be satisfied by the turn that
# was already running, so requiring it would be requiring the wrong evidence.
# Busy delivery has its own gate, tests/fm-herdr-h10-busy-ack.
test_an_idle_steer_keeps_the_acknowledgment() {
  reset
  HERDR_STATES=idle run "$SEND" fm-herdrcrew 'another instruction' >/dev/null
  assert_grep "--wait" "$CALLS" "an idle steer stopped using the acknowledged prompt"
  pass "send: a steer to an idle crewmate carries the acknowledgment"
}

# A blocked agent is sitting at an approval dialog. Typing over it is how a
# prompt gets eaten and a decision gets answered by accident.
test_send_to_a_blocked_agent_fails_loudly() {
  reset
  local out rc=0
  out=$(HERDR_BLOCKED=1 run "$SEND" fm-herdrcrew 'do the thing') || rc=$?
  if [ "$rc" = 0 ]; then fail "a steer at a blocked agent reported success"; fi
  assert_contains "$out" "approval dialog" "the refusal does not say the agent was blocked"
  assert_contains "$out" "refused, not delivered" "the refusal does not say the steer did not land"
  pass "send: a blocked agent is refused loudly, never typed over"
}

# A stall is NOT a failure. herdr accepts the submission before it waits for a
# state change, so agent_prompt_stalled means the text went in and the
# acknowledgment did not come back. Reporting that as "not submitted" would make
# firstmate re-send a steer the crewmate already has - the worse of the two
# available errors, and the opposite of what the tmux path's lenient rule says.
test_an_unconfirmed_delivery_is_not_reported_as_a_failure() {
  reset
  local out rc=0
  out=$(HERDR_STALLED=1 run "$SEND" fm-herdrcrew 'do the thing') || rc=$?
  expect_code 0 "$rc" "an unconfirmed delivery was reported as a failed steer"
  assert_contains "$out" "did not acknowledge" "the warning does not say the acknowledgment was missing"
  assert_contains "$out" "not re-sending" "the warning does not say the steer will not be repeated"
  # Exactly one prompt: a stall must never trigger a retry.
  if [ "$(grep -cF 'agent prompt' "$CALLS")" != 1 ]; then
    fail "a stalled delivery was re-sent; the crewmate would be steered twice"
  fi
  pass "send: an unconfirmed delivery warns and is assumed sent, never re-sent"
}

# AN UNDETECTED AGENT IS NOT A DELIVERY AT ALL. This case previously blessed a
# hazard: on agent_not_found the steer was forwarded to `herdr pane run`, whose
# job is running SHELL COMMAND LINES. A crewmate instruction like
# `git reset --hard origin/main` would therefore EXECUTE in the worktree, and
# fm-send reported it as merely unacknowledged - exit 0, a warning, work
# destroyed. Blind delivery into a TUI composer and blind delivery into a shell
# are not the same risk, and the seam was treating them as one.
#
# The honest answer is that there is no agent to steer: refuse, say so, and let
# the supervisor peek or relaunch.
test_an_undetected_agent_is_refused_not_executed() {
  reset
  local out rc=0
  out=$(HERDR_NO_AGENT=1 run "$SEND" fm-herdrcrew 'git reset --hard origin/main') || rc=$?
  if [ "$rc" = 0 ]; then fail "a steer into a pane with no agent was reported as delivered"; fi
  assert_contains "$out" "no agent" "the refusal does not say why nothing was delivered"
  assert_no_grep "pane run" "$CALLS" \
    "the steer was forwarded to 'pane run' and would have EXECUTED as a shell command"
  pass "send: a pane with no detected agent is refused, never shell-executed"
}

# A hard herdr failure - a dropped socket, a CLI error, an envelope the pattern
# list has never seen - must never surface as a delivered steer.
test_a_hard_herdr_failure_is_reported_as_failure() {
  reset
  local out rc=0
  out=$(HERDR_PROMPT_RC=7 HERDR_PROMPT_OUT='socket closed: connection reset by peer' \
        run "$SEND" fm-herdrcrew 'do the thing') || rc=$?
  if [ "$rc" = 0 ]; then fail "a failed steer exited 0; firstmate would believe it landed"; fi
  assert_contains "$out" "not submitted" "the failure does not say the steer did not land"
  pass "send: a hard herdr failure exits non-zero and says the steer did not land"
}

# --- fm-peek: reads back through the same driver ----------------------------

test_peek_reads_a_herdr_crewmate() {
  reset
  printf 'line-one\nagent is working\n' > "$PANE"
  local out
  out=$(run "$PEEK" fm-herdrcrew 25)
  assert_contains "$out" "agent is working" "peek returned nothing from the herdr pane"
  assert_grep "agent read wM:p2" "$CALLS" "peek did not read through the herdr driver"
  pass "peek: a herdr crewmate's pane is read back through herdr"
}

# --- routing is by the meta, not by ambience --------------------------------

# The load-bearing case. With a herdr server up, a TMUX crewmate must still be
# addressed with tmux verbs - otherwise every pre-existing crewmate becomes
# unsteerable the moment the fleet's default flips.
test_a_tmux_crewmate_is_still_addressed_with_tmux() {
  reset
  run "$SEND" fm-tmuxcrew 'steer the old one' >/dev/null
  assert_grep "send-keys" "$CALLS" "a tmux crewmate was not steered with tmux verbs"
  assert_no_grep "agent prompt" "$CALLS" \
    "a tmux crewmate was probed with herdr verbs because a server happened to be up"
  pass "routing: a tmux-minted target is steered with tmux, even with herdr reachable"
}

# A meta from before the seam has no mux= line. It is a tmux target by
# definition, and must be treated as one rather than guessed at.
test_a_pre_seam_meta_is_treated_as_tmux() {
  reset
  run "$SEND" fm-legacycrew 'steer the legacy one' >/dev/null
  assert_grep "send-keys" "$CALLS" "a pre-seam meta was not treated as tmux"
  assert_no_grep "agent prompt" "$CALLS" "a pre-seam meta was addressed with herdr verbs"
  pass "routing: a meta with no mux= is tmux by definition, not by guess"
}

# The other direction: a herdr crewmate stays addressable when the server that
# minted it is no longer reachable. It fails as herdr - loudly - rather than
# silently succeeding at typing into a tmux window that does not exist.
test_a_herdr_crewmate_is_never_rerouted_to_tmux() {
  reset
  local rc=0
  HERDR_SERVER=stopped run "$SEND" fm-herdrcrew 'do the thing' >/dev/null 2>&1 || rc=$?
  assert_no_grep "send-keys" "$CALLS" \
    "a herdr crewmate was rerouted to tmux keystrokes aimed at a pane id"
  pass "routing: a herdr-minted target is never silently rerouted to tmux"
}

# --- the raw escape hatch ----------------------------------------------------

# `session:window` is documented as a tmux address, so a raw target with no meta
# behind it means tmux. Ambient resolution here would answer a tmux address with
# herdr verbs and quietly return nothing.
# A colon-bearing argument is an explicit target and is checked BEFORE the
# fm-<id> name shape, exactly as the pre-seam resolve() had it. Reversing that
# order would make a session literally named `fm-something` get looked up as a
# task id and fail, instead of addressing `fm-something:window`.
test_an_explicit_target_wins_over_the_name_shape() {
  reset
  printf 'colon target content\n' > "$PANE"
  local out
  out=$(run "$PEEK" "fm-sess:win" 20)
  assert_contains "$out" "colon target content" "a colon-bearing target was not treated as an explicit address"
  assert_not_contains "$out" "no metadata" "a colon-bearing target was looked up as a task id"
  pass "routing: an explicit <scope>:<window> wins over the fm-<id> name shape"
}

test_a_raw_target_is_a_tmux_address() {
  reset
  printf 'raw pane content\n' > "$PANE"
  local out
  out=$(run "$PEEK" "sess:win" 20)
  assert_contains "$out" "raw pane content" "a raw session:window peek returned nothing"
  assert_grep "capture-pane" "$CALLS" "a raw session:window was not read with tmux"
  pass "routing: a raw session:window is a tmux address; nothing overrides that"
}

test_send_to_a_herdr_crewmate_is_acknowledged
test_an_idle_steer_keeps_the_acknowledgment
test_send_to_a_blocked_agent_fails_loudly
test_an_unconfirmed_delivery_is_not_reported_as_a_failure
test_an_undetected_agent_is_refused_not_executed
test_a_hard_herdr_failure_is_reported_as_failure
test_peek_reads_a_herdr_crewmate
test_a_tmux_crewmate_is_still_addressed_with_tmux
test_a_pre_seam_meta_is_treated_as_tmux
test_a_herdr_crewmate_is_never_rerouted_to_tmux
test_an_explicit_target_wins_over_the_name_shape
test_a_raw_target_is_a_tmux_address
