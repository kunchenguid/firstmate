#!/usr/bin/env bash
# Opt-in credentialed Grok regression proving one tracked long-runner spends no
# primary turn for quiet recovery and completes once for an actionable wake.
set -u

if [ "${FM_GROK_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_GROK_LIVE_E2E=1 to run the interactive Grok continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v grok >/dev/null 2>&1 || fail "grok not found"
command -v jq >/dev/null 2>&1 || fail "jq not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMUX=$(command -v tmux)
SOCKET="fm-grok-live-e2e-$$"
SESSION=grok-live-e2e
LAB="$ROOT/.grok-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
GROK_VERSION=$(grok --version)

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -1200 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    capture | grep -Fq "$expected" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

chat_history() {
  find "$HOME/.grok/sessions" -type f \
    -path "*${LAB##*/}%2Fproject/*/chat_history.jsonl" -print 2>/dev/null \
    | head -1
}

assistant_turn_count() {
  local chat=$1
  jq -r 'select(.type == "assistant" and .model_id != null) | 1' "$chat" 2>/dev/null \
    | wc -l | tr -d ' '
}

completion_count() {
  local chat=$1 command=$2
  jq -r --arg command "$command" '
    select(.type == "user" and .synthetic_reason == "task_completed")
    | .content[]?
    | select(.type == "text" and (.text | contains($command)))
    | 1
  ' "$chat" 2>/dev/null | wc -l | tr -d ' '
}

wait_for_assistant_text() {
  local chat=$1 expected=$2 attempts=${3:-240} i=0
  while [ "$i" -lt "$attempts" ]; do
    jq -e --arg expected "$expected" \
      'select(.type == "assistant" and .content == $expected)' "$chat" >/dev/null 2>&1 \
      && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local watcher_pid arm_pid longrun_pid
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  longrun_pid=$(ps -p "$arm_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.2
  for pid in "$watcher_pid" "$arm_pid" "$longrun_pid"; do
    if [ -n "$pid" ] && lab_pid_is_safe "$pid"; then
      kill -TERM "$pid" 2>/dev/null || true
      kill -CONT "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
for file in fm-watch-arm.sh fm-watch.sh fm-watch-grok-longrun.sh; do
  cp "$ROOT/bin/$file" "$PROJECT/bin/$file"
  chmod +x "$PROJECT/bin/$file"
done
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'project=fixture\n' > "$HOME_DIR/state/grok-e2e.meta"
FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c \
  '. "$1"; fm_recovery_transition "$2" publish downtime' _ \
  "$PROJECT/bin/fm-wake-lib.sh" "$HOME_DIR/state/.watcher-down" \
  || fail "could not publish the isolated quiet recovery episode"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 FM_CHECK_INTERVAL=999999 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; exec grok --trust --always-approve --reasoning-effort low'"

wait_for_text "Grok Build" 180 || fail "Grok did not reach its ready composer"
wait_for_text "❯" 180 || fail "Grok did not render its ready composer input"
sleep 1
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Use run_terminal_command with background=true to run exactly `bin/fm-watch-grok-longrun.sh`. Never use a shell ampersand. Once the tracked task is running, respond exactly ARM_READY. When its task-completed reminder arrives, run `bin/fm-wake-drain.sh`, handle the one wake, run the exact WAKE_ACK_REQUIRED acknowledgement, and respond exactly ACTIONABLE_HANDLED. Do not re-arm during this test.'
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$PROMPT"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter

i=0
chat=
while [ "$i" -lt 120 ]; do
  chat=$(chat_history)
  [ -n "$chat" ] && [ -f "$chat" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -n "$chat" ] && [ -f "$chat" ] || fail "Grok chat history was not created for the live cell"
wait_for_text "ARM_READY" 240 || fail "Grok did not start the tracked long-runner"
wait_for_assistant_text "$chat" ARM_READY 120 \
  || fail "Grok readiness response was not durably recorded"

i=0
watcher_pid=
while [ "$i" -lt 120 ]; do
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$watcher_pid" ] && kill -0 "$watcher_pid" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
if [ -z "$watcher_pid" ] || ! kill -0 "$watcher_pid" 2>/dev/null; then
  fail "tracked long-runner did not establish a live watcher"
fi
arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
longrun_pid=$(ps -p "$arm_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
if [ -z "$longrun_pid" ] || ! kill -0 "$longrun_pid" 2>/dev/null; then
  fail "tracked long-runner process was not live"
fi

baseline_turns=$(assistant_turn_count "$chat")
baseline_longrun_completions=$(completion_count "$chat" 'fm-watch-grok-longrun.sh')
baseline_arm_completions=$(completion_count "$chat" 'fm-watch-arm.sh')
[ "$baseline_longrun_completions" -eq 0 ] \
  || fail "quiet recovery completed the tracked long-runner before its ready response"
sleep 4
[ "$(assistant_turn_count "$chat")" -eq "$baseline_turns" ] \
  || fail "quiet recovery spent a primary turn"
[ "$(completion_count "$chat" 'fm-watch-grok-longrun.sh')" -eq "$baseline_longrun_completions" ] \
  || fail "quiet recovery completed the tracked long-runner"
[ "$(completion_count "$chat" 'fm-watch-arm.sh')" -eq "$baseline_arm_completions" ] \
  || fail "an internal watcher cycle leaked as its own tracked completion"
kill -0 "$longrun_pid" 2>/dev/null || fail "quiet recovery closed the tracked long-runner"

printf 'done: grok live long-runner actionable fire\n' > "$HOME_DIR/state/grok-e2e.status"
wait_for_assistant_text "$chat" ACTIONABLE_HANDLED 600 \
  || fail "Grok actionable response was not durably recorded"
[ "$(completion_count "$chat" 'fm-watch-grok-longrun.sh')" -eq $((baseline_longrun_completions + 1)) ] \
  || fail "actionable wake did not produce exactly one long-runner completion prompt"
[ "$(completion_count "$chat" 'fm-watch-arm.sh')" -eq "$baseline_arm_completions" ] \
  || fail "actionable path leaked an internal arm completion prompt"
grep -Eq 'reason=actionable-signal' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "actionable cycle was not classified in the lifecycle ledger"
[ ! -s "$HOME_DIR/state/.wake-queue" ] || fail "Grok did not acknowledge the one durable signal row"
! capture | grep -Fq 'bin/fm-watch-grok-longrun.sh &' \
  || fail "Grok used a shell ampersand instead of its tracked background task"

printf 'ok - %s kept quiet recovery inside one tracked task and woke once for actionable work\n' "$GROK_VERSION"
