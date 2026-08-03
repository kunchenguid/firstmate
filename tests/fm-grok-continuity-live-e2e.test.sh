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

count_text() {
  local expected=$1
  capture | grep -Fc "$expected" || true
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
  if [ -n "${FM_GROK_LIVE_E2E_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_GROK_LIVE_E2E_EVIDENCE_DIR"
    capture > "$FM_GROK_LIVE_E2E_EVIDENCE_DIR/grok-pane.txt"
    {
      printf 'grok_version=%s\n' "$GROK_VERSION"
      printf 'watcher_pid=%s\n' "$watcher_pid"
      printf 'arm_pid=%s\n' "$arm_pid"
      printf '%s\n' 'cycle_ledger:'
      cat "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null || true
      printf '%s\n' 'wake_queue:'
      cat "$HOME_DIR/state/.wake-queue" 2>/dev/null || true
    } > "$FM_GROK_LIVE_E2E_EVIDENCE_DIR/grok-state.txt"
  fi
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
PROMPT='Use run_terminal_command with background=true to run exactly `bin/fm-watch-arm.sh`. Never use a shell ampersand. Once it reports started, respond exactly FM_GROK_ARMED_READY.'
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
wait_for_text "FM_GROK_ARMED_READY" 240 || fail "Grok did not settle the arming turn before the away-mode transition"

arm_pid=$(ps -p "$initial_watcher" -o ppid= 2>/dev/null | tr -d ' ' || true)
[ -n "$arm_pid" ] && kill -0 "$arm_pid" 2>/dev/null \
  || fail "Grok tracked arm process was not live"
completion_count=$(count_text "Task completed in")
date '+%s' > "$HOME_DIR/state/.afk"
printf 'done: grok away-mode watcher fire\n' > "$HOME_DIR/state/grok-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "Grok action cycle was not classified in the lifecycle ledger"
sleep 5
[ "$(count_text "Task completed in")" = "$completion_count" ] || {
  capture >&2
  fail "Grok surfaced a tracked-task completion while away mode was active"
}
kill -0 "$arm_pid" 2>/dev/null || {
  capture >&2
  ps -o pid=,ppid=,state=,command= -p "$arm_pid" 2>/dev/null >&2 || true
  fail "Grok tracked arm completed instead of parking"
}
grep -q 'grok-e2e.status' "$HOME_DIR/state/.wake-queue" 2>/dev/null \
  || fail "away-mode wake was not preserved in the durable queue"

rm -f "$HOME_DIR/state/.afk"
i=0
resumed_watcher=
while [ "$i" -lt 240 ]; do
  resumed_watcher=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$resumed_watcher" ] && [ "$resumed_watcher" != "$initial_watcher" ] \
    && kill -0 "$resumed_watcher" 2>/dev/null; then
    break
  fi
  sleep 0.5
  i=$((i + 1))
done
if [ -z "$resumed_watcher" ] || [ "$resumed_watcher" = "$initial_watcher" ] \
  || ! kill -0 "$resumed_watcher" 2>/dev/null; then
  fail "Grok tracked arm did not resume supervision after away mode"
fi
resumed_arm_pid=$(ps -p "$resumed_watcher" -o ppid= 2>/dev/null | tr -d ' ' || true)
[ "$resumed_arm_pid" = "$arm_pid" ] || fail "Grok resumed under a different tracked arm process"
printf 'done: grok normal watcher fire\n' > "$HOME_DIR/state/grok-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  [ "$(count_text "Task completed in")" -gt "$completion_count" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ "$(count_text "Task completed in")" -gt "$completion_count" ] || {
  capture >&2
  fail "Grok did not restore native background-task completion after away mode"
}
pane=$(capture)
if printf '%s\n' "$pane" | grep -Fq 'bin/fm-watch-arm.sh &'; then
  fail "Grok used a shell ampersand instead of its tracked background task"
fi

printf 'ok - %s live E2E suppressed away-mode completion and restored normal wake delivery\n' "$GROK_VERSION"
