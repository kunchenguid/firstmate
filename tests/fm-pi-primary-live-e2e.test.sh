#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Opt-in interactive Pi primary regression on a private tmux socket and isolated homes.
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v pi >/dev/null 2>&1 || { echo "skip: pi not found"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

AUTH_DIR=${FM_PI_LIVE_AUTH_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}}
AUTH_FILE="$AUTH_DIR/auth.json"
[ -f "$AUTH_FILE" ] || {
  echo "not ok - live Pi auth is unavailable at $AUTH_FILE" >&2
  exit 1
}

TMUX=$(command -v tmux)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
LAB="$ROOT/.pi-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
PI_DIR="$LAB/pi-agent"
PI_VERSION=$(pi --version)

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

capture() {
  "$TMUX" -L "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
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
  local pid_file watcher_pid arm_pid
  pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
  watcher_pid=
  arm_pid=
  if [ -n "$pid_file" ]; then
    watcher_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
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

send_prompt() {
  local prompt=$1
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

current_watcher_pid() {
  cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true
}

wait_for_successor() {
  local prior=$1 attempts=${2:-200} i=0 candidate
  while [ "$i" -lt "$attempts" ]; do
    candidate=$(current_watcher_pid)
    if [ -n "$candidate" ] && [ "$candidate" != "$prior" ] && kill -0 "$candidate" 2>/dev/null; then
      printf '%s\n' "$candidate"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  printf 'successor diagnostic: prior=%s current=%s queue=%s\n' \
    "$prior" "$(current_watcher_pid)" "$(cat "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)" >&2
  find "$HOME_DIR/state" -maxdepth 2 -type f -print -exec sh -c 'printf "%s\\n" "--- $1 ---"; tail -5 "$1" 2>/dev/null || true' _ {} \; >&2
  ps -p "$prior" -o pid=,ppid=,etime=,command= >&2 || true
  capture >&2
  return 1
}

wait_for_queue_empty() {
  local attempts=${1:-200} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ ! -s "$HOME_DIR/state/.wake-queue" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

watcher_beacon_is_fresh() {
  local beacon="$HOME_DIR/state/.last-watcher-beat" mtime now
  [ -f "$beacon" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mtime=$(stat -f %m "$beacon" 2>/dev/null || true)
  else
    mtime=$(stat -c %Y "$beacon" 2>/dev/null || true)
  fi
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ "$((now - mtime))" -lt 5 ]
}

custom_wake_count() {
  python3 - "$PI_DIR" <<'PY'
import json
import pathlib
import sys

count = 0
for session in pathlib.Path(sys.argv[1]).glob("sessions/**/*.jsonl"):
    for line in session.read_text(encoding="utf-8").splitlines():
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") == "custom_message" and entry.get("customType") == "firstmate-watcher-wake":
            count += 1
print(count)
PY
}

answered_custom_wake_count() {
  python3 - "$PI_DIR" <<'PY'
import json
import pathlib
import sys

answered = 0
for session in pathlib.Path(sys.argv[1]).glob("sessions/**/*.jsonl"):
    entries = []
    for line in session.read_text(encoding="utf-8").splitlines():
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    wakes = [
        index for index, entry in enumerate(entries)
        if entry.get("type") == "custom_message" and entry.get("customType") == "firstmate-watcher-wake"
    ]
    for offset, wake in enumerate(wakes):
        end = wakes[offset + 1] if offset + 1 < len(wakes) else len(entries)
        if any(
            entry.get("type") == "message"
            and entry.get("message", {}).get("role") == "assistant"
            and entry["message"].get("stopReason") == "stop"
            for entry in entries[wake + 1:end]
        ):
            answered += 1
print(answered)
PY
}

wait_for_answered_custom_wakes() {
  local expected=$1 attempts=${2:-360} i=0
  while [ "$i" -lt "$attempts" ]; do
    [ "$(answered_custom_wake_count)" -ge "$expected" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$PI_DIR"
touch "$HOME_DIR/state/.last-report-retention-attempt" \
  "$HOME_DIR/state/.last-account-session-sync" \
  "$HOME_DIR/state/.last-check" \
  "$HOME_DIR/state/.last-heartbeat"
cp "$AUTH_FILE" "$PI_DIR/auth.json"
chmod 600 "$PI_DIR/auth.json"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env PI_CODING_AGENT_DIR='$PI_DIR' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi --approve --provider openai-codex --model gpt-5.6-sol --thinking low; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

wait_for_text "fm-primary-turnend-guard.ts" 120 || fail "Pi primary extensions did not load"

send_prompt "Use the bash tool to run printf PI_E2E_BASH_ONE. Then reply exactly BASH-ONE."
wait_for_text "BASH-ONE" || fail "first bash turn did not complete"
send_prompt "Use the read tool to read the first five lines of README.md. Then reply exactly READ-ONE."
wait_for_text "READ-ONE" || fail "read turn did not complete"
send_prompt "Use the bash tool to run printf PI_E2E_BASH_TWO. Then reply exactly BASH-TWO."
wait_for_text "BASH-TWO" || fail "second bash turn did not complete"

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Reply exactly GUARD-TRIGGER with no tools. When the guard follow-up arrives, use fm_watch_arm_pi exactly once and never use bash to arm supervision. After each FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh and read the signaled status, but do not call fm_watch_arm_pi because the extension has already self-rearmed. Reply exactly WAKE-ONE after the status says fire one, and exactly WAKE-TWO after it says fire two."
wait_for_text "watcher: started Pi extension arm child 1" || fail "guard follow-up did not render the Pi watcher tool result"
initial_watcher_pid=$(wait_for_successor 0) \
  || fail "initial watcher was not live after the Pi arm tool"

printf 'done: pi live e2e watcher fire one\n' > "$HOME_DIR/state/pi-e2e.status"
first_successor_pid=$(wait_for_successor "$initial_watcher_pid") \
  || fail "extension did not start a live successor after the first actionable exit"
kill -0 "$first_successor_pid" 2>/dev/null || fail "first successor watcher was not live"
watcher_beacon_is_fresh || fail "first successor did not publish a fresh beacon"
wait_for_answered_custom_wakes 1 || fail "first custom watcher wake did not trigger and finish a model turn"
wait_for_queue_empty || fail "first model turn did not drain the durable wake queue"
kill -0 "$first_successor_pid" 2>/dev/null || fail "first successor did not remain live after queue drain"

printf 'done: pi live e2e watcher fire two\n' >> "$HOME_DIR/state/pi-e2e.status"
second_successor_pid=$(wait_for_successor "$first_successor_pid") \
  || fail "extension did not continue supervision through the second actionable exit"
kill -0 "$second_successor_pid" 2>/dev/null || fail "second successor watcher was not live"
watcher_beacon_is_fresh || fail "second successor did not publish a fresh beacon"
wait_for_answered_custom_wakes 2 || fail "second custom watcher wake did not trigger and finish a model turn"
wait_for_queue_empty || fail "second model turn did not drain the durable wake queue"
kill -0 "$second_successor_pid" 2>/dev/null || fail "second successor did not remain live after queue drain"

wake_count=$(custom_wake_count)
[ "$wake_count" -eq 2 ] || fail "expected two persisted custom watcher wakes, saw $wake_count"
pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 1 ] || fail "expected one guard injection, saw $guard_count"
arm_tool_count=$(printf '%s\n' "$pane" | grep -Fc "watcher: started Pi extension arm child" || true)
[ "$arm_tool_count" -eq 1 ] || fail "model re-armed manually instead of relying on the persistent extension cycle ($arm_tool_count tool results)"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi

watcher_pid=$second_successor_pid
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "second successor watcher parent was not live"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

printf 'ok - Pi %s live E2E persisted two custom wakes, self-rearmed both successors, and cleaned up on exit\n' "$PI_VERSION"
