#!/usr/bin/env bash
# Opt-in credentialed Grok regression proving the shared arm wrapper still works
# through Grok's tracked background-task notification path.
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
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMUX=$(command -v tmux)
SOCKET="fm-grok-live-e2e-$$"
SESSION=grok-live-e2e
LAB="$ROOT/.grok-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
GROK_VERSION=$(grok --version)

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -900 2>/dev/null || true
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

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local watcher_pid arm_pid
  watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  "$TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'project=fixture\n' > "$HOME_DIR/state/grok-e2e.meta"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; grok --trust --always-approve --reasoning-effort low; rc=\$?; printf \"GROK_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

wait_for_text "Grok Build" 180 || fail "Grok did not reach its ready composer"
sleep 1
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Use run_terminal_command with background=true to run exactly `bin/fm-watch-arm.sh`. Never use a shell ampersand. Once it reports started, respond briefly.'
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$PROMPT"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter

i=0
initial_watcher=
while [ "$i" -lt 240 ]; do
  initial_watcher=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$initial_watcher" ] && kill -0 "$initial_watcher" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
if [ -z "$initial_watcher" ] || ! kill -0 "$initial_watcher" 2>/dev/null; then
  fail "Grok did not start the tracked background watcher"
fi

printf 'done: grok live e2e watcher fire\n' > "$HOME_DIR/state/grok-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "Grok action cycle was not classified in the lifecycle ledger"
wait_for_text "Task completed in" 120 || fail "Grok did not surface its native background-task completion notification"
pane=$(capture)
if printf '%s\n' "$pane" | grep -Fq 'bin/fm-watch-arm.sh &'; then
  fail "Grok used a shell ampersand instead of its tracked background task"
fi

printf 'ok - %s live E2E preserved tracked background completion and shared ledger classification\n' "$GROK_VERSION"
