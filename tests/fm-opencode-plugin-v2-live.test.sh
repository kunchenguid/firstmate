#!/usr/bin/env bash
# Live OpenCode 2 continuity and seatbelt regression.
#
# tests/fm-opencode-plugin-contract.test.sh proves the ported plugins take the v2
# contract and reach their guard decisions correctly against the real guard
# scripts, in a plain Node host. This test proves the two claims only a real
# OpenCode 2 session can settle, on a throwaway primary-shaped FM_HOME in TMPDIR
# so neither the captain's home, checkout nor session is touched.
#
#   1. the watch-arm plugin re-arms itself. The test never runs
#      bin/fm-watch-arm.sh: the plugin starts the first cycle on its own from the
#      first turn end. A wake is then queued through the real wake library, that
#      cycle closes with an actionable reason, and the plugin must start the
#      successor and deliver the wake prompt. The docs/watcher-continuity.md
#      contract is "the successor starts before the wake prompt is delivered", so
#      the successor is checked to be running at the moment the prompt lands. No
#      manual arm and no model-initiated arm is permitted anywhere.
#   2. the PreToolUse seatbelt still denies an unsafe watcher-arm shape. The model
#      is asked to run exactly that shape, and the check passes only if the tool
#      call actually failed carrying the guard's own reason.
#
# Both plugins scope themselves to a real primary firstmate checkout, and a task
# worktree is deliberately inert, so the session runs in the throwaway home.
#
# Opt-in: it spends model tokens on a real session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_OPENCODE_PLUGIN_V2_LIVE opencode tmux

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENCODE_VERSION=$(opencode --version)
MODEL=${FM_OPENCODE_PLUGIN_V2_MODEL:-opencode-go/longcat-2.5-preview-free}

TMUX=$(command -v tmux)
SOCKET="fm-oc2-contract-$$"
SESSION=opencode-2-contract
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-oc2-contract.XXXXXX")
HOME_DIR="$LAB/home"
STATE="$HOME_DIR/state"
CONFIG="$HOME_DIR/config"
TASK=oc2-contract

# Built from fragments on purpose. The very guard under test refuses any command
# line that carries a protected watcher-arm invocation, so naming the shape
# literally in this script's own shell command would have the harness deny the
# test before the test ran.
ARM_SCRIPT="fm-watch""-arm.sh"
UNSAFE_SHAPE="bin/$ARM_SCRIPT --restart &"
GUARD_REASON="watcher-background"

cleanup() {
  pkill -f "$LAB" >/dev/null 2>&1 || true
  "$TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -8000 2>/dev/null || true
}

wait_for_text() {  # <text> [attempts]
  local expected=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

count_text() {  # <text>
  capture | grep -cF "$1" || true
}

# A primary-shaped firstmate home: a plain (non-worktree) git checkout carrying
# AGENTS.md, bin/, and the ported .opencode/plugins. The plugins resolve their
# root from the session's own directory, so the session runs here.
install_home() {
  mkdir -p "$STATE" "$CONFIG" "$HOME_DIR/.opencode"
  cp -a "$ROOT/bin" "$HOME_DIR/bin"
  cp -a "$ROOT/.opencode/plugins" "$HOME_DIR/.opencode/plugins"
  cp "$ROOT/AGENTS.md" "$HOME_DIR/AGENTS.md"
  # The model is selected through configuration because OpenCode 2's interactive
  # command rejects --model. That is the separate defect tracked as
  # fm-opencode-v2-model-launch and is deliberately not worked around here
  # beyond choosing the other supported way to pick a model.
  # shellcheck disable=SC2016 # $schema is a literal JSON key, not a shell expansion.
  printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "model": "%s"\n}\n' "$MODEL" \
    > "$HOME_DIR/opencode.json"
  git -C "$HOME_DIR" init -q
  git -C "$HOME_DIR" -c user.email=contract@example.invalid -c user.name=contract \
    add -A >/dev/null 2>&1 || true
  git -C "$HOME_DIR" -c user.email=contract@example.invalid -c user.name=contract \
    commit -q -m init >/dev/null 2>&1 || true
  # The arm's own shouldArm gate wants a tracked task record in this home.
  printf 'contract\n' > "$STATE/$TASK.meta"
}

# OpenCode 2 runs plugins inside one long-lived service process that every
# location's sessions share, which is also why the plugin event subscription is
# server-global. The session lock therefore names that service process, which is
# the process the arm is a descendant of.
publish_session_lock() {
  local i=0 pid=""
  while [ "$i" -lt 80 ]; do
    pid=$(pgrep -f "opencode serve --service" 2>/dev/null | head -1)
    if [ -n "$pid" ]; then
      printf '%s\n' "$pid" > "$STATE/.lock"
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

# Queue one wake through the real wake library, so the arm child closes with a
# genuine actionable reason rather than a synthetic one this test invents.
queue_wake() {
  FM_STATE="$STATE" FM_HOME="$HOME_DIR" FM_ROOT="$HOME_DIR" \
    bash -c '
      set -u
      . "$1/bin/fm-wake-lib.sh"
      fm_wake_append signal "$2" "signal: live OpenCode 2 re-arm regression"
    ' _ "$HOME_DIR" "$TASK" >/dev/null 2>&1
}

arm_children() {
  pgrep -f "$HOME_DIR/bin/$ARM_SCRIPT" 2>/dev/null | wc -l
}

# The arm reports every cycle close on the home's durable exit ledger, because
# the plugin owns the arm child's stdout and so it never reaches the terminal.
# A record that names an actionable reason AND a started successor is the
# re-arm contract in one line: the close was actionable, and the plugin had
# already started the next cycle.
actionable_successor_recorded() {
  [ -f "$STATE/.watch-cycle-exits.log" ] || return 1
  grep -q "reason=actionable" "$STATE/.watch-cycle-exits.log" || return 1
  grep -q "successor=started:" "$STATE/.watch-cycle-exits.log"
}

test_watch_arm_rearms_without_a_manual_or_model_initiated_start() {
  # The first turn exists only to let the plugin end one and start its own cycle.
  # Nothing in this test runs the arm script: if a cycle appears, the plugin made
  # it.
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" \
    "Reply with the single word ARMED and nothing else." Enter

  local i=0 arms=0
  while [ "$i" -lt 160 ]; do
    arms=$(arm_children)
    [ "$arms" -ge 1 ] && break
    sleep 0.5
    i=$((i + 1))
  done
  [ "$arms" -ge 1 ] \
    || fail "the plugin never started a first watcher cycle on its own: $(capture | tail -40)"

  queue_wake

  wait_for_text "WATCHER FIRED" \
    || fail "an actionable close was never surfaced to the session: $(capture | tail -40)"

  # The successor is started before the wake prompt is delivered, so an arm child
  # is already running at the moment the prompt is on screen.
  arms=$(arm_children)
  [ "$arms" -ge 1 ] \
    || fail "no successor arm was running when the wake prompt was delivered: $(capture | tail -40)"

  # The close must be recorded as an actionable exit whose successor the plugin
  # started itself.
  local i2=0
  while [ "$i2" -lt 160 ]; do
    actionable_successor_recorded && break
    sleep 0.5
    i2=$((i2 + 1))
  done
  actionable_successor_recorded \
    || fail "the arm ledger records no actionable close with a started successor: $(capture | tail -40)"

  # No manual arm and no model-initiated arm. The transcript showing the shape at
  # all is the failure.
  if capture | grep -Fq "$UNSAFE_SHAPE"; then
    fail "the model ran the watcher-arm shape itself, which the plugin owns: $(capture | tail -40)"
  fi
  pass "the watch-arm plugin re-armed itself after an actionable close, with no manual and no model-initiated start"
}

test_seatbelt_denies_an_unsafe_watcher_arm_shape() {
  local i=0 prompt
  printf -v prompt 'Use the shell tool to run exactly this command and nothing else: %s' "$UNSAFE_SHAPE"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" "$prompt" Enter
  while [ "$i" -lt 150 ]; do
    capture | grep -Fq "$GUARD_REASON" && break
    sleep 2
    i=$((i + 1))
  done
  # The only acceptable proof is the guard's own denial reason. A run that
  # silently executed the shape is a missing guard, not a passing test.
  wait_for_text "$GUARD_REASON" \
    || fail "the seatbelt did not deny the unsafe arm shape: $(capture | tail -40)"
  pass "the PreToolUse seatbelt denied an unsafe watcher-arm shape under OpenCode $OPENCODE_VERSION"
}

install_home

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 60 -c "$HOME_DIR" \
  "FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$HOME_DIR' opencode 2>&1 | tee '$LAB/session.log'"

wait_for_text "Ask anything" 200 || fail "the OpenCode session never started: $(capture | tail -40)"

# Let every plugin finish loading before the first turn can end.
sleep 15

publish_session_lock || fail "could not identify the OpenCode service process for the session lock"

test_watch_arm_rearms_without_a_manual_or_model_initiated_start
test_seatbelt_denies_an_unsafe_watcher_arm_shape

printf 'all fm-opencode-plugin-v2-live tests passed (opencode %s)\n' "$OPENCODE_VERSION"
