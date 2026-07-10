#!/usr/bin/env bash
# Opt-in interactive OMP (Oh My Pi) primary regression on a private tmux socket
# and isolated homes. Mirrors tests/fm-pi-primary-live-e2e.test.sh.
#
# OMP has no PI_OFFLINE stub model, so this drives a REAL omp model session (same
# cost profile as the pi live e2e) - hence it is opt-in behind FM_OMP_LIVE_E2E=1.
# It launches omp with explicit `-e` extension paths (the documented trust-free
# path), so it does not depend on an interactive project-trust prompt, and gates
# readiness on the extension-loaded marker files rather than pane text.
set -u

if [ "${FM_OMP_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_OMP_LIVE_E2E=1 to run the isolated interactive OMP regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v omp >/dev/null 2>&1 || { echo "skip: omp not found"; exit 0; }
command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

TMUX=$(command -v tmux)
SOCKET="fm-omp-live-e2e-$$"
SESSION=omp-live-e2e
LAB="$ROOT/.omp-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
OMP_VERSION=$(omp --version 2>/dev/null | head -1)
TURNEND_EXT=".omp/extensions/fm-primary-turnend-guard.ts"
WATCH_EXT=".omp/extensions/fm-primary-omp-watch.ts"

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

wait_for_markers() {
  local attempts=${1:-60} i=0
  while [ "$i" -lt "$attempts" ]; do
    if [ -f "$HOME_DIR/state/.omp-turnend-extension-loaded" ] \
      && [ -f "$HOME_DIR/state/.omp-watch-extension-loaded" ]; then
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
  sleep 0.6
  "$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
  sleep 0.4
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
mkdir -p "$PROJECT/.omp/extensions"
cp "$ROOT/$TURNEND_EXT" "$PROJECT/$TURNEND_EXT"
cp "$ROOT/$WATCH_EXT" "$PROJECT/$WATCH_EXT"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

# Uses the default (already-authed) agent dir, not an isolated PI_CODING_AGENT_DIR:
# a fresh agent dir triggers omp's blocking first-run setup wizard. --no-session keeps
# the run ephemeral. Only FM_HOME (the firstmate home) is isolated.
"$TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; omp --no-session -e $TURNEND_EXT -e $WATCH_EXT; rc=\$?; printf \"OMP_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

# Extensions load early in startup; wait for both markers, then for omp to finish
# starting up (MCP connect) before driving the composer. omp shows no interactive
# project-trust prompt, so no approving keystroke is needed to reach the session.
wait_for_markers 60 || fail "OMP primary extensions did not load (no extension-loaded markers)"
wait_for_text "Connected to MCP" 60 || sleep 8
sleep 2

send_prompt "Use the bash tool to run printf OMP_E2E_BASH_ONE. Then reply exactly BASH-ONE."
wait_for_exact_line "BASH-ONE" || fail "first bash turn did not complete"
send_prompt "Use the read tool to read the first five lines of README.md. Then reply exactly READ-ONE."
wait_for_exact_line "READ-ONE" || fail "read turn did not complete"
send_prompt "Use the bash tool to run printf OMP_E2E_BASH_TWO. Then reply exactly BASH-TWO."
wait_for_exact_line "BASH-TWO" || fail "second bash turn did not complete"

: > "$HOME_DIR/state/omp-e2e.meta"
send_prompt "Reply exactly GUARD-TRIGGER with no tools. When the guard follow-up arrives, use fm_watch_arm_omp and never use bash to arm supervision. After any FIRSTMATE WATCHER WAKE, run bin/fm-wake-drain.sh, read the signaled status, call fm_watch_arm_omp to re-arm, and finish exactly REARMED."
wait_for_text "watcher: started OMP extension arm child 1" || fail "guard follow-up did not render the OMP watcher tool result"

printf 'done: omp live e2e watcher fire\n' > "$HOME_DIR/state/omp-e2e.status"
wait_for_text "watcher: started OMP extension arm child 2" 180 || fail "watcher wake did not drain and re-arm through the OMP tool"
wait_for_exact_line "REARMED" 120 || fail "OMP did not settle after re-arming watcher supervision"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
# omp's guard listens for `turn_end` (omp has no `agent_settled`), so it re-nags on
# EVERY blind turn boundary until supervision is armed - unlike pi's once-per-logical-run
# `agent_settled`. Expect one-or-more injections, not exactly one. The guardFollowupActive
# latch still prevents double-firing on the guard's own injected follow-up turn.
[ "$guard_count" -ge 1 ] || fail "expected at least one guard injection, saw $guard_count"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "OMP used a foreground bash watcher arm"
fi

pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"

"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" -L "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "OMP_EXIT=0" 60 || fail "OMP did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean OMP exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean OMP exit"

printf 'ok - OMP %s live E2E rendered the tool, guarded once, woke, re-armed, and cleaned up on exit\n' "$OMP_VERSION"
