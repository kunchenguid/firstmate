#!/usr/bin/env bash
# Opt-in live Prime Agent adapter regression in an isolated Herdr lab.
# It drives the production spawn-generated extension against a real Prime Agent
# process and never touches the shared default Herdr session or daemon.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_PRIME_AGENT_LIVE_E2E prime-agent herdr jq node

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
PRIME_AGENT=$(command -v prime-agent || true)
[ -n "$PRIME_AGENT" ] || fail "FM_PRIME_AGENT_LIVE_E2E=1 but prime-agent is not on PATH"
PRIME_VERSION=$("$PRIME_AGENT" --version 2>&1 | head -1 || true)
[ -n "$PRIME_VERSION" ] || fail "could not read the installed Prime Agent version"
printf '%s\n' "$PRIME_VERSION" | grep -Eq '^[vV]?[0-9]+([.][0-9]+)+' \
  || fail "Prime Agent reported a non-numeric version: $PRIME_VERSION"
[ -x "$LAB_HELPER" ] || fail "FM_PRIME_AGENT_LIVE_E2E=1 but the Herdr lab helper is not executable: $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-prime-agent-lib.sh
. "$ROOT/bin/fm-prime-agent-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-prime-agent-live.XXXXXX")
HOME_DIR="$LAB/home"
PROJECT="$LAB/project"
WT="$LAB/worktree"
ID=prime-agent-live
PROVIDER=openai-codex
MODEL=gpt-5.6-terra
EFFORT=low
FAKEBIN=
LAUNCH_LOG="$LAB/launch.log"
SESSION=$("$LAB_HELPER" name prime-adapter-solid)
PANE=

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$PANE" ]; then
    "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" escape >/dev/null 2>&1 || true
    "$LAB_HELPER" run "$SESSION" pane send-text "$PANE" '/quit' >/dev/null 2>&1 || true
    "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null 2>&1 || true
  fi
  fm_prime_agent_stop_sessions_under "$WT" >/dev/null 2>&1 || true
  "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT

fm_test_spawn_home "$HOME_DIR" prime-agent
fm_git_worktree "$PROJECT" "$WT" "wt-prime-agent-live"
fm_test_spawn_brief "$HOME_DIR" "$ID" 'Run the requested live adapter checks and reply with PRIME_AGENT_BOOT_OK.'
FAKEBIN=$(make_spawn_fakebin "$LAB/fake" prime-agent)
# Fake tmux lets production fm-spawn render the exact extension and busy record.
# The real process is launched below in the isolated Herdr pane instead.
out=$(FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID" "$PROJECT" \
  --harness prime-agent --provider "$PROVIDER" --model "$MODEL" --effort "$EFFORT" \
  --mode direct-PR --yolo off 2>&1) || fail "production spawn generation failed: $out"
[ -f "$HOME_DIR/state/$ID.prime-ext.ts" ] || fail "production spawn did not generate the Prime Agent extension"
LAUNCH=$(sed "s#'$FAKEBIN/prime-agent'#'$PRIME_AGENT'#" "$LAUNCH_LOG")
[ "$LAUNCH" != "$(cat "$LAUNCH_LOG")" ] || fail "could not replace the fake Prime Agent executable in the generated launch"
printf '%s\n' "$LAUNCH" | grep -Fq -- "--provider '$PROVIDER'" \
  || fail "generated launch omitted the requested provider: $LAUNCH"
printf '%s\n' "$LAUNCH" | grep -Fq -- "--model '$MODEL'" \
  || fail "generated launch omitted the requested model: $LAUNCH"
model_version=${MODEL#gpt-}
model_major=${model_version%-*}
model_name=${model_version##*-}
expected_model="GPT-${model_major} ${model_name^}"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab"
WS=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$WT" --label prime-agent-live --no-focus) \
  || fail "could not create isolated Herdr workspace"
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
"$LAB_HELPER" run "$SESSION" pane run "$PANE" "$LAUNCH" >/dev/null \
  || fail "could not launch the generated Prime Agent command"

for _ in $(seq 1 120); do
  screen=$("$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -Fq "$expected_model" \
    && printf '%s\n' "$screen" | grep -Fq "$EFFORT"; then
    break
  fi
  sleep 0.5
done
printf '%s\n' "$screen" | grep -Fq "$expected_model" \
  || fail "generated launch did not render the requested model $expected_model; launch=$LAUNCH screen=$screen"
printf '%s\n' "$screen" | grep -Fq "$EFFORT" \
  || fail "generated launch did not render the requested effort $EFFORT; launch=$LAUNCH screen=$screen"
pass "Prime Agent rendered the production model, provider, and thinking launch"

for _ in $(seq 1 120); do
  [ "$(fm_busy_classify tmux fake:w prime-agent "$ID" "$HOME_DIR/state")" = "idle prime-ext" ] && break
  sleep 0.5
done
[ "$(fm_busy_classify tmux fake:w prime-agent "$ID" "$HOME_DIR/state")" = "idle prime-ext" ] \
  || fail "generated Prime Agent extension did not settle the launch turn"
[ -f "$HOME_DIR/state/$ID.turn-ended" ] || fail "generated Prime Agent extension did not write turn-end notification"
pass "Prime Agent $PRIME_VERSION loaded the production extension and settled its first turn"

send() {
  "$LAB_HELPER" run "$SESSION" pane send-text "$PANE" "$1" >/dev/null || return 1
  "$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" enter >/dev/null || return 1
}
wait_busy() {
  for _ in $(seq 1 80); do
    [ "$(fm_busy_classify tmux fake:w prime-agent "$ID" "$HOME_DIR/state")" = "busy prime-ext" ] && return 0
    sleep 0.5
  done
  return 1
}
wait_idle() {
  for _ in $(seq 1 100); do
    [ "$(fm_busy_classify tmux fake:w prime-agent "$ID" "$HOME_DIR/state")" = "idle prime-ext" ] && return 0
    sleep 0.5
  done
  return 1
}
send 'Run the shell command sleep 12, then reply with exactly PRIME_AGENT_SLEEP_OK.' || fail "could not submit the busy probe"
wait_busy || fail "generated Prime Agent extension did not report busy during a real tool call"
agent_busy=$("$LAB_HELPER" run "$SESSION" agent get "$PANE")
printf '%s\n' "$agent_busy" | jq -e '.result.agent.agent_status == "working"' >/dev/null \
  || fail "Herdr did not report working during the real busy probe: $agent_busy"
wait_idle || fail "generated Prime Agent extension did not report idle after the real tool call"
pass "Prime Agent $PRIME_VERSION agent_start/agent_end wiring reports busy and idle"

send 'Run the shell command sleep 20, then reply with exactly PRIME_AGENT_CANCELLED_NO.' || fail "could not submit interrupt probe"
wait_busy || fail "interrupt probe never became busy"
"$LAB_HELPER" run "$SESSION" pane send-keys "$PANE" escape >/dev/null || fail "could not send Escape"
wait_idle || fail "Prime Agent did not settle after Escape"
screen=$("$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200)
printf '%s\n' "$screen" | grep -q 'Operation aborted' || fail "Escape did not abort the Prime Agent turn: $screen"
pass "Prime Agent $PRIME_VERSION cancels a running turn with one Escape"

send '/quit' || fail "could not submit /quit"
for _ in $(seq 1 60); do
  info=$("$LAB_HELPER" run "$SESSION" pane process-info --pane "$PANE" 2>/dev/null || true)
  printf '%s\n' "$info" | jq -e '.result.process_info.foreground_processes[0].name == "bash"' >/dev/null 2>&1 && break
  sleep 0.5
done
printf '%s\n' "$info" | jq -e '.result.process_info.foreground_processes[0].name == "bash"' >/dev/null \
  || fail "Prime Agent /quit did not return the pane to bash"
pass "Prime Agent $PRIME_VERSION exits cleanly and leaves the detached worker for retirement"

"$LAB_HELPER" run "$SESSION" pane run "$PANE" "$LAUNCH" >/dev/null \
  || fail "could not relaunch Prime Agent in the same pane"
for _ in $(seq 1 120); do
  screen=$("$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -Fq "$expected_model"; then break; fi
  sleep 0.5
done
printf '%s\n' "$screen" | grep -Fq "$expected_model" || fail "Prime Agent did not relaunch in the same pane"
pass "Prime Agent $PRIME_VERSION relaunches in the same Herdr pane"

send '/quit' || fail "could not submit the cleanup quit"
for _ in $(seq 1 60); do
  info=$("$LAB_HELPER" run "$SESSION" pane process-info --pane "$PANE" 2>/dev/null || true)
  printf '%s\n' "$info" | jq -e '.result.process_info.foreground_processes[0].name == "bash"' >/dev/null 2>&1 && break
  sleep 0.5
done
for _ in $(seq 1 60); do
  fm_prime_agent_stop_sessions_under "$WT" >/dev/null 2>&1 || true
  left=$(fm_prime_agent_session_ids_under "$(CDPATH='' cd -- "$WT" && pwd -P)" 2>/dev/null || true)
  [ -z "$left" ] && break
  sleep 0.5
done
[ -z "$left" ] || fail "resident detached Prime Agent sessions remain after cleanup: $left"
pass "Prime Agent detached worker retirement was confirmed"
