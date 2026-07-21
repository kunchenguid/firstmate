#!/usr/bin/env bash
# Opt-in Pi regressions on a private tmux socket and isolated project/home state.
# FM_PI_SESSION_LIVE_E2E needs no credentials and isolates Pi's config while it
# exercises logical session replacement. FM_PI_LIVE_E2E additionally uses the
# existing shared Pi auth store for the model-driven continuity path.
set -u

SESSION_ONLY=0
if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  if [ "${FM_PI_SESSION_LIVE_E2E:-0}" = 1 ]; then
    SESSION_ONLY=1
  else
    echo "skip: set FM_PI_SESSION_LIVE_E2E=1 or FM_PI_LIVE_E2E=1 to run an isolated interactive Pi regression"
    exit 0
  fi
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v pi >/dev/null 2>&1 || fail "pi not found"
command -v tmux >/dev/null 2>&1 || fail "tmux not found"

TMUX=$(command -v tmux)
PI_BIN=$(command -v pi)
SOCKET="fm-pi-live-e2e-$$"
SESSION=pi-live-e2e
LAB="$ROOT/.pi-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
PI_AGENT_DIR="$LAB/pi-agent"
PI_VERSION=$("$PI_BIN" --version)

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
  pid_file="$HOME_DIR/state/.watch.lock/pid"
  watcher_pid=
  arm_pid=
  if [ -f "$pid_file" ]; then
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

wait_for_ready_watcher() {
  local previous_pid=${1:-} i=0 candidate
  while [ "$i" -lt 100 ]; do
    candidate=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" FM_GUARD_GRACE=300 bash -c '
      . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
      if fm_watcher_healthy "$FM_HOME/state" "$FM_ROOT_OVERRIDE/bin/fm-watch.sh" "$FM_GUARD_GRACE" "$FM_HOME"; then
        printf "%s\n" "$FM_WATCHER_HEALTHY_PID"
      fi
    ')
    if [ -n "$candidate" ] && [ "$candidate" != "$previous_pid" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

if [ "$SESSION_ONLY" -eq 1 ]; then
  mkdir -p "$PI_AGENT_DIR"
  "$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
    "env PI_CODING_AGENT_DIR='$PI_AGENT_DIR' FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -c 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; \"$PI_BIN\" --offline --approve --no-session --no-context-files --no-extensions --no-skills --no-prompt-templates -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 10'"
else
  "$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
    "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -c 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; \"$PI_BIN\" --approve --no-session --no-context-files --no-extensions -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts --model openai-codex/gpt-5.6-sol --thinking low; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"
fi

i=0
while [ "$i" -lt 120 ]; do
  [ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] && [ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] || fail "Pi turn-end extension did not load"
[ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] || fail "Pi watcher extension did not load"
if [ "$SESSION_ONLY" -eq 1 ]; then
  wait_for_text "No models available" 120 || fail "isolated Pi did not reach its ready composer"
  sleep 1

  : > "$HOME_DIR/state/pi-session-e2e.meta"
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/fm-watch-arm-pi'
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
  wait_for_text "watcher: started Pi extension arm child 1" 60 || fail "initial logical session did not arm supervision"
  watcher_pid=$(wait_for_ready_watcher) || fail "initial logical session did not establish a healthy watcher"
  arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
  [ -n "$arm_pid" ] || fail "initial logical session watcher parent was not live"

  for expected_arm in 2 3; do
    previous_watcher_pid=$watcher_pid
    previous_arm_pid=$arm_pid
    "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/new'
    "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
    wait_for_text "New session started" 60 || fail "Pi did not start replacement logical session $expected_arm"
    wait_pid_dead "$previous_watcher_pid" || fail "watcher child survived logical session replacement $expected_arm"
    wait_pid_dead "$previous_arm_pid" || fail "arm child survived logical session replacement $expected_arm"
    interrupted_count=$(grep -c $'reason=arm-interrupted\t' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null || true)
    [ "$interrupted_count" -ge "$((expected_arm - 1))" ] \
      || fail "logical session replacement $expected_arm did not record an interrupted arm close"

    "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/fm-watch-arm-pi'
    "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
    wait_for_text "watcher: started Pi extension arm child $expected_arm" 60 \
      || fail "Pi logical session $expected_arm did not arm supervision"
    watcher_pid=$(wait_for_ready_watcher "$previous_watcher_pid") \
      || fail "Pi logical session $expected_arm did not establish a new healthy watcher"
    arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
    [ -n "$arm_pid" ] || fail "Pi logical session $expected_arm watcher parent was not live"
  done

  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
  wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly after logical session replacements"
  wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
  wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"
  printf 'ok - Pi %s isolated live E2E re-armed after two /new commands and cleaned up on exit\n' "$PI_VERSION"
  exit 0
fi

wait_for_text "(openai-codex)" 120 || fail "Pi did not reach its ready composer"
sleep 1

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Call fm_watch_arm_pi exactly once and never use bash to arm supervision. After the watcher wake arrives, run bin/fm-wake-drain.sh, do not call fm_watch_arm_pi again, and reply exactly HANDLED."
wait_for_text "watcher: started Pi extension arm child 1" || fail "Pi did not render the initial watcher tool result"

printf 'done: pi live e2e watcher fire\n' > "$HOME_DIR/state/pi-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "Pi extension did not start and ledger-link a successor after the actionable close"
wait_for_exact_line "HANDLED" 120 || fail "Pi did not drain and settle after its extension-owned successor started"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 0 ] || fail "successor was not protecting Pi before its next turn end (guard count $guard_count)"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi
arm_tool_count=$(printf '%s\n' "$pane" | grep -Fc 'started Pi extension arm child' || true)
[ "$arm_tool_count" -eq 1 ] || fail "Pi model re-armed from memory instead of the extension (tool-result count $arm_tool_count)"

watcher_pid=$(wait_for_ready_watcher) || fail "re-armed watcher was not healthy"
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

printf 'ok - Pi %s live E2E used shared Codex auth, auto-started one successor before turn end, and cleaned up\n' "$PI_VERSION"
