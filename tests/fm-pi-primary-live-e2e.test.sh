#!/usr/bin/env bash
# Opt-in interactive Pi primary regression on a private tmux socket and isolated homes.
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v pi >/dev/null 2>&1 || { echo "skip: pi not found"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

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

wait_for_exact_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fxq " $expected"; then
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

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$PI_DIR"

"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env PI_CODING_AGENT_DIR='$PI_DIR' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 PI_OFFLINE=1 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

wait_for_text "Trust project folder?" 40 || fail "Pi trust prompt did not appear"
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "fm-primary-turnend-guard.ts" 60 || fail "Pi primary extensions did not load"

send_prompt "Use the bash tool to run printf PI_E2E_BASH_ONE. Then reply exactly BASH-ONE."
wait_for_exact_line "BASH-ONE" || fail "first bash turn did not complete"
send_prompt "Use the read tool to read the first five lines of README.md. Then reply exactly READ-ONE."
wait_for_exact_line "READ-ONE" || fail "read turn did not complete"
send_prompt "Use the bash tool to run printf PI_E2E_BASH_TWO. Then reply exactly BASH-TWO."
wait_for_exact_line "BASH-TWO" || fail "second bash turn did not complete"

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Reply exactly GUARD-TRIGGER with no tools. When the guard follow-up arrives, use fm_watch_arm_pi and never use bash to arm supervision. After any FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh, read the signaled status, call fm_watch_arm_pi to re-arm, and finish exactly REARMED."
wait_for_text "watcher: started Pi extension arm child 1" || fail "guard follow-up did not render the Pi watcher tool result"

printf 'done: pi live e2e watcher fire\n' > "$HOME_DIR/state/pi-e2e.status"
wait_for_text "watcher: started Pi extension arm child 2" 180 || fail "watcher wake did not drain and re-arm through the Pi tool"
wait_for_exact_line "REARMED" 120 || fail "Pi did not settle after re-arming watcher supervision"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 1 ] || fail "expected one guard injection, saw $guard_count"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi

pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

printf 'ok - Pi %s live E2E rendered the tool, guarded once, woke, re-armed, and cleaned up on exit\n' "$PI_VERSION"
