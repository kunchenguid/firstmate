#!/usr/bin/env bash
# Portable Hermes worker contracts: profile/idle-only gateway coexistence, generation
# hooks, structural process identity, composer draft safety, and spawn argv.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-hermes-lib.sh
. "$ROOT/bin/fm-hermes-lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-hermes-process-lib.sh
. "$ROOT/bin/fm-hermes-process-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$ROOT/bin/fm-agent-process-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-hermes-harness)
unset HERMES_HOME HERMES_MANAGED_DIR
[ "$(fm_control_interrupt_transport hermes)" = key ] || fail 'interrupt transport'
[ "$(fm_control_interrupt_key hermes)" = Escape ] || fail 'interrupt key'
[ "$(fm_control_interrupt_repeat hermes)" = 2 ] || fail 'interrupt count'
[ "$(fm_control_exit_command hermes)" = /quit ] || fail 'exit command'
fm_control_harness_supports_kind hermes ship || fail 'ship refused'
fm_control_harness_supports_kind hermes scout || fail 'scout refused'
! fm_control_harness_supports_kind hermes secondmate || fail 'secondmate accepted'
! fm_control_harness_supports_kind hermes primary || fail 'primary accepted'
! "$ROOT/bin/fm-supervision-instructions.sh" --harness hermes >/dev/null 2>&1 || fail 'primary supervision accepted'
for args in 'node /opt/hermes-agent/ui-tui/dist/entry.js' 'python3 -m tui_gateway.entry' '/usr/bin/hermes --tui'; do
  fm_hermes_process_matches "$args" || fail "structural identity lost: $args"
done
for args in 'node /tmp/server.js /opt/hermes-agent/ui-tui/dist/entry.js' 'python3 -c tui_gateway.entry' 'node -e hermes' 'hermes-helper'; do
  ! fm_hermes_process_matches "$args" || fail "false identity: $args"
done
# Use a real interpreter process so kernel-name loss and argv loss are
# independent regressions, not expectations encoded into a fake harness.
mkdir -p "$TMP_ROOT/process/tui_gateway"
printf 'import time\nfrom pathlib import Path\nPath(__file__).with_name("ready").touch()\ntime.sleep(30)\n' > "$TMP_ROOT/process/tui_gateway/entry.py"
PYTHONPATH="$TMP_ROOT/process" python3 -m tui_gateway.entry &
process_pid=$!
for _ in $(seq 1 100); do [ -f "$TMP_ROOT/process/tui_gateway/ready" ] && break; sleep 0.05; done
native_args=$(ps -o args= -p "$process_pid")
native_name=$(ps -o comm= -p "$process_pid")
[ "$native_name" != hermes ] || fail 'identity fixture failed to separate name and module argv'
[ "$(fm_agent_process_classify unrelated unrelated '' "$process_pid")" = agent ] || fail 'NUL argv identity lost when names/ps args are blind'
[ "$(fm_agent_process_classify "$native_name" '' "$native_args")" = agent ] || fail 'ps argv identity lost when NUL argv is absent'
[ "$(fm_agent_process_classify "$native_name" '' '')" = other ] || fail 'bare interpreter falsely identified without either argv source'
kill "$process_pid"
wait "$process_pid" 2>/dev/null || true
pass 'worker-only capability and anchored process identity'

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/profile"
cat > "$TMP_ROOT/bin/hermes" <<'SH'
#!/bin/sh
case "$*" in
  *'config path') printf '%s/config.yaml\n' "$FM_TEST_HERMES_HOME" ;;
  *'config get hooks --json --raw') printf '%s\n' '{"pre_llm_call":[{"command":"existing-hook"}]}' ;;
  *) exit 1 ;;
esac
SH
cat > "$TMP_ROOT/bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_GATEWAY_SERVICE:-inactive}"
exit 3
SH
chmod +x "$TMP_ROOT/bin/hermes" "$TMP_ROOT/bin/systemctl"
export FM_TEST_HERMES_HOME="$TMP_ROOT/profile" HERMES_GATEWAY_LOCK_DIR="$TMP_ROOT/gateway-locks"
PATH="$TMP_ROOT/bin:$PATH"
[ "$(fm_hermes_profile_home "$TMP_ROOT/bin/hermes" example)" = "$TMP_ROOT/profile" ] || fail 'profile path'
! fm_hermes_profile_home "$TMP_ROOT/bin/hermes" '../escape' >/dev/null 2>&1 || fail 'path traversal profile accepted'
! fm_hermes_profile_home "$TMP_ROOT/bin/hermes" $'\ninvalid' >/dev/null 2>&1 || fail 'newline profile accepted'
fm_hermes_gateway_check "$TMP_ROOT/profile" worker || fail 'stopped profile refused'
gateway_state() {
  printf '{"pid":%s,"gateway_state":"%s","restart_requested":false,"active_agents":%s,"active_work":null,"updated_at":"%s"}\n' \
    "$1" "$2" "$3" "${4:-$(date -u +%Y-%m-%dT%H:%M:%S+00:00)}" > "${5:-$TMP_ROOT/profile}/gateway_state.json"
}
gateway_state "$$" running 0
fm_hermes_gateway_check "$TMP_ROOT/profile" worker || fail 'idle own gateway refused'
FM_TEST_GATEWAY_SERVICE=active fm_hermes_gateway_check "$TMP_ROOT/profile" worker || fail 'idle systemd gateway refused'
gateway_state "$$" running 1
! fm_hermes_gateway_check "$TMP_ROOT/profile" worker 2>/dev/null || fail 'mid-turn gateway accepted'
gateway_state "$$" draining 0
! fm_hermes_gateway_check "$TMP_ROOT/profile" worker 2>/dev/null || fail 'draining gateway accepted'
gateway_state "$$" running 0 2000-01-01T00:00:00+00:00
! fm_hermes_gateway_check "$TMP_ROOT/profile" worker 2>/dev/null || fail 'stale gateway heartbeat accepted'
gateway_state "$$" running '"0"'
! fm_hermes_gateway_check "$TMP_ROOT/profile" worker 2>/dev/null || fail 'malformed active agent count accepted'
printf '{"pid":%s,"active_agents":0}\n' "$$" > "$TMP_ROOT/profile/gateway_state.json"
! fm_hermes_gateway_check "$TMP_ROOT/profile" worker 2>/dev/null || fail 'gateway without serving state accepted'
printf 'broken' > "$TMP_ROOT/profile/gateway_state.json"
! fm_hermes_gateway_check "$TMP_ROOT/profile" worker 2>/dev/null || fail 'corrupt gateway state accepted'
rm "$TMP_ROOT/profile/gateway_state.json"
! FM_TEST_GATEWAY_SERVICE=active fm_hermes_gateway_check "$TMP_ROOT/profile" worker 2>/dev/null || fail 'systemd gateway without status accepted'
! FM_TEST_GATEWAY_SERVICE=activating fm_hermes_gateway_check "$TMP_ROOT/profile" worker 2>/dev/null || fail 'transitional systemd gateway accepted'
# Native-style lock ownership must be checked without creating or changing it.
python3 - "$TMP_ROOT/profile/gateway.lock" "$TMP_ROOT/lock-ready" <<'PY_LOCK' &
import fcntl, sys, time
from pathlib import Path
with open(sys.argv[1], 'wb') as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    Path(sys.argv[2]).touch()
    time.sleep(30)
PY_LOCK
lock_pid=$!
for _ in $(seq 1 100); do [ -f "$TMP_ROOT/lock-ready" ] && break; sleep 0.05; done
[ -f "$TMP_ROOT/lock-ready" ] || fail 'native lock fixture did not start'
! fm_hermes_gateway_check "$TMP_ROOT/profile" worker 2>/dev/null || fail 'held native lock without status accepted'
gateway_state "$lock_pid" running 0
fm_hermes_gateway_check "$TMP_ROOT/profile" worker || fail 'held native lock with idle status refused'
rm "$TMP_ROOT/profile/gateway_state.json"
kill "$lock_pid"
wait "$lock_pid" 2>/dev/null || true
fm_hermes_gateway_check "$TMP_ROOT/profile" worker || fail 'unowned stale lock refused'
mkdir -p "$HERMES_GATEWAY_LOCK_DIR" "$TMP_ROOT/root/profiles/worker"
gateway_state "$$" running 0 '' "$TMP_ROOT/root"
! fm_hermes_gateway_check "$TMP_ROOT/root/profiles/worker" worker 2>/dev/null || fail 'live default-root gateway accepted for a named profile'
rm "$TMP_ROOT/root/gateway_state.json"
printf '{"pid":%s,"home":"%s","profiles":["worker"]}\n' "$$" "$TMP_ROOT/root" > "$HERMES_GATEWAY_LOCK_DIR/host-gateway.json"
! fm_hermes_gateway_check "$TMP_ROOT/root/profiles/worker" worker 2>/dev/null || fail 'other-home multiplexer accepted'
fm_hermes_gateway_check "$TMP_ROOT/profile" worker || fail 'different-root multiplexer blocked an isolated profile'
printf '{"pid":%s,"home":"%s","profiles":["worker"]}\n' "$$" "$TMP_ROOT/root/profiles/worker" > "$HERMES_GATEWAY_LOCK_DIR/host-gateway.json"
! fm_hermes_gateway_check "$TMP_ROOT/root/profiles/worker" worker 2>/dev/null || fail 'own host gateway without status accepted'
gateway_state "$$" running 0 '' "$TMP_ROOT/root/profiles/worker"
fm_hermes_gateway_check "$TMP_ROOT/root/profiles/worker" worker || fail 'idle own host gateway refused'
rm "$HERMES_GATEWAY_LOCK_DIR/host-gateway.json" "$TMP_ROOT/root/profiles/worker/gateway_state.json"
pass 'profile validation and read-only idle-gateway coexistence check'
consent=$'Help improve Hermes?\n (○) Collect and send to Nous\n (○) Collect locally only\n → (●) No thanks'
[ "$(fm_hermes_startup_screen "$consent")" = decline ] || fail 'native selected decline offer not recognized'
positive=${consent//'(●) No thanks'/'(○) No thanks'}
[ "$(fm_hermes_startup_screen "$positive")" = wait ] || fail 'unselected decline option was answered'
[ "$(fm_hermes_startup_screen 'Help improve Hermes?')" = wait ] || fail 'incomplete consent text answered'
pass 'startup consent only confirms a complete native offer with No thanks already selected'


state="$TMP_ROOT/hook state"
mkdir -p "$state"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" worker)
fm_hermes_write_hooks "$TMP_ROOT/bin/hermes" "$TMP_ROOT/profile" "$state" worker "$gen" || fail 'hook staging'
config="$state/worker.hermes-hooks/config.yaml"
jq -e '.hooks.pre_llm_call[0].command == "existing-hook"' "$config" >/dev/null || fail 'user hook lost'
run_hook() {
  local event=$1 session=$2 command
  command=$(jq -r --arg event "$event" '.hooks[$event][-1].command' "$config")
  printf '{"session_id":"%s","extra":{"platform":"tui","turn_id":"%s"}}\n' "$session" "$session" | bash -c "$command"
}
run_hook pre_llm_call main
[ "$(fm_busy_classify tmux test:w hermes worker "$state")" = 'busy hermes-hook' ] || fail 'native busy not trusted'
run_hook on_session_end child
[ "$(fm_busy_classify tmux test:w hermes worker "$state")" = 'busy hermes-hook' ] || fail 'child end cleared main'
run_hook on_session_end main
[ "$(fm_busy_classify tmux test:w hermes worker "$state")" = 'idle hermes-hook' ] || fail 'native end not idle'
assert_present "$state/worker.turn-ended" 'missing turn-end notification'
"$ROOT/bin/fm-busy-event.sh" arm "$state" worker >/dev/null
rm "$state/worker.turn-ended"
run_hook on_session_end main
[ "$(fm_busy_classify tmux test:w hermes worker "$state")" = 'busy fm-spawn' ] || fail 'stale hook cleared replacement'
assert_absent "$state/worker.turn-ended" 'stale hook emitted notification'
! HERMES_MANAGED_DIR=/existing fm_hermes_write_hooks "$TMP_ROOT/bin/hermes" "$TMP_ROOT/profile" "$state" worker "$gen" 2>/dev/null || fail 'managed scope replaced'
pass 'native hook overlay preserves hooks and enforces session/generation binding'

caps=$'styled=1\ncursor=0\nidentity=1'
esc=$'\033'
idle=$(printf ' ─ ready │ model │ 1s\n worker ❯ %s[2mAsk me anything…%s[0m\n' "$esc" "$esc")
draft=$(printf ' ─ ready │ model │ 1s\n worker ❯ real draft\n')
[ "$(fm_composer_classify_screen "$caps" "$idle" '' $'hermes\tidle')" = empty ] || fail 'native idle composer'
[ "$(fm_composer_classify_screen "$caps" "$draft" '' $'hermes\tidle')" = pending ] || fail 'draft erased'
[ "$(fm_composer_classify_screen "$caps" "$idle" '' $'pi\tidle')" != empty ] || fail 'foreign identity claimed Hermes composer'
[ "$(fm_composer_classify_screen "$caps" "$idle"$'\n dialog' '' $'hermes\tidle')" = unknown ] || fail 'dialog accepted'
busy=$(printf ' ─ computing… · 0s │ model │ 1s\n worker ❯ %s[38;5;231m%s[48;5;178mC%s[38;5;178m%s[49mtrl+C to interrupt…%s[39m\n' "$esc" "$esc" "$esc" "$esc" "$esc")
[ "$(fm_composer_classify_screen "$caps" "$busy" '' $'hermes\tworking')" = empty ] || fail 'native busy hint not empty'
bright=$(printf ' ─ computing… · 0s │ model │ 1s\n worker ❯ %s[38;5;230mCtrl+C to interrupt…%s[39m\n' "$esc" "$esc")
[ "$(fm_composer_classify_screen "$caps" "$bright" '' $'hermes\tworking')" = pending ] || fail 'typed hint words erased'
printf ' ─ (⊙_⊙) computing… · 0s │ model │ 32s\n' | fm_busy_lines_match hermes || fail 'native elapsed busy footer not recognized'
printf ' worker ❯ Ctrl+C to interrupt…\n' | fm_busy_lines_match hermes || fail 'native independent interrupt hint not recognized'
! printf ' worker ❯ draft\n' | fm_busy_lines_match hermes || fail 'draft classified busy'
pass 'profile-prefixed composer requires native ready status and preserves drafts'

case_dir="$TMP_ROOT/spawn"
fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
cp "$TMP_ROOT/bin/hermes" "$TMP_ROOT/bin/systemctl" "$fakebin/"
mv "$fakebin/tmux" "$fakebin/tmux-base"
cat > "$fakebin/tmux" <<'SH_TMUX'
#!/bin/sh
if [ "$1" = capture-pane ]; then
  if [ -n "${FM_FAKE_HERMES_STALL_META:-}" ]; then
    printf ' Provider setup\n Paste an API key to continue\n'
  else
    printf ' ─ ready │ model │ 1s\n worker ❯ \n'
  fi
  exit 0
fi
if [ "$1" = kill-window ] && [ -n "${FM_FAKE_HERMES_STALL_META:-}" ]; then
  if [ -e "$FM_FAKE_HERMES_STALL_META" ]; then echo "kill-window record=present" >> "$FM_FAKE_HERMES_KILL_LOG"
  else echo "kill-window record=absent" >> "$FM_FAKE_HERMES_KILL_LOG"; fi
  [ -z "${FM_FAKE_HERMES_KILL_FAIL:-}" ] || exit 1
fi
exec "$(dirname "$0")/tmux-base" "$@"
SH_TMUX
chmod +x "$fakebin/tmux"

home="$case_dir/home"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_test_spawn_home "$home" hermes
fm_git_worktree "$proj" "$wt" hermes-test
fm_test_spawn_brief "$home" hermes-worker
if ! out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch" fm_test_run_spawn "$home" "$wt" "$fakebin" hermes-worker "$proj" --scout --harness hermes --hermes-profile example --effort high 2>&1); then fail "spawn: $out"; fi
launch=$(cat "$case_dir/launch")
assert_contains "$launch" "-p 'example' chat --tui --yolo --accept-hooks" 'native interactive launch missing'
assert_contains "$launch" 'encode launch-brief' 'typed brief missing'
assert_contains "$launch" 'FM_HERMES_HARNESS=hermes' 'worker marker missing'
assert_grep 'hermes_profile=example' "$home/state/hermes-worker.meta" 'profile not recorded'
assert_present "$home/state/hermes-worker.hermes-hooks/config.yaml" 'native hooks not staged'
if out=$(fm_test_run_spawn "$home" "$wt" "$fakebin" sm "$proj" --secondmate --harness hermes 2>&1); then fail 'secondmate launch accepted'; fi
assert_contains "$out" 'crewmate/scout adapter only' 'secondmate diagnostic'
pass 'scout spawn carries native profile, interactive brief, hook overlay and metadata'

fm_test_spawn_brief "$home" hermes-stalled
if out=$(FM_FAKE_HERMES_STALL_META="$home/state/hermes-stalled.meta" FM_FAKE_HERMES_KILL_LOG="$case_dir/kill" \
  FM_HERMES_READY_POLLS=2 FM_HERMES_POLL_INTERVAL=0 \
  fm_test_run_spawn "$home" "$wt" "$fakebin" hermes-stalled "$proj" --scout --harness hermes --hermes-profile example 2>&1); then
  fail 'stalled Hermes launch accepted'
fi
assert_contains "$out" 'Hermes did not reach its TUI' 'stalled launch diagnostic'
assert_contains "$(cat "$case_dir/kill" 2>/dev/null)" 'kill-window record=present' 'stalled worker not stopped before its record was removed'
[ ! -e "$home/state/hermes-stalled.meta" ] || fail 'stalled fresh spawn kept its task record'
pass 'stalled Hermes launch stops its pane before the task record is removed'

fm_test_spawn_brief "$home" hermes-unclosed
if out=$(FM_FAKE_HERMES_STALL_META="$home/state/hermes-unclosed.meta" FM_FAKE_HERMES_KILL_LOG="$case_dir/kill-unclosed" \
  FM_FAKE_HERMES_KILL_FAIL=1 FM_HERMES_READY_POLLS=2 FM_HERMES_POLL_INTERVAL=0 \
  fm_test_run_spawn "$home" "$wt" "$fakebin" hermes-unclosed "$proj" --scout --harness hermes --hermes-profile example 2>&1); then
  fail 'unclosed stalled Hermes launch accepted'
fi
assert_contains "$out" 'Hermes did not reach its TUI' 'unclosed stalled launch diagnostic'
assert_contains "$(cat "$case_dir/kill-unclosed" 2>/dev/null)" 'kill-window record=present' 'unclosed stalled worker close not attempted'
assert_contains "$out" 'task record is kept' 'unclosed stalled launch warning'
assert_grep 'hermes_profile=example' "$home/state/hermes-unclosed.meta" 'unclosed stalled worker lost its task record'
pass 'stalled Hermes launch whose pane cannot be closed keeps its task record'
