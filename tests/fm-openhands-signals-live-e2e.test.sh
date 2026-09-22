#!/usr/bin/env bash
# Live drift guard for the OpenHands CLI adapter's vendor-controlled surface:
# process name, rendered busy/interrupt/exit behavior, and Fireworks model path.
# Opt-in because it submits real prompts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OH_BIN=$(command -v openhands 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-oh-signals-$$"
SESSION=oh-signals
TARGET="$SESSION:oh"

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_OPENHANDS_SIGNALS_LIVE openhands tmux
[ -n "$OH_BIN" ] || fail "openhands is not installed"

# Credentials: environment first, then the home-local env file the spawn uses.
if [ -z "${LLM_API_KEY:-}" ] && [ -f "${FM_HOME:-$HOME/firstmate}/config/openhands-llm.env" ]; then
  LLM_API_KEY=$(awk -F= '/^LLM_API_KEY=/{sub(/^LLM_API_KEY=/,""); print; exit}' \
    "${FM_HOME:-$HOME/firstmate}/config/openhands-llm.env")
  export LLM_API_KEY
fi
[ -n "${LLM_API_KEY:-}" ] || fail "LLM_API_KEY is not set and config/openhands-llm.env has no key"
export LLM_MODEL="${LLM_MODEL:-fireworks_ai/accounts/fireworks/models/deepseek-v4p1-flash}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-oh-signals.XXXXXX") || fail "could not create the isolated openhands lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace" "$LAB/home/.openhands" || fail "could not create the isolated openhands directories"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated openhands workspace"
git -C "$LAB/workspace" config user.email "guard@local" || fail "could not configure the isolated openhands workspace"
git -C "$LAB/workspace" config user.name "guard" || fail "could not configure the isolated openhands workspace"
git -C "$LAB/workspace" commit -q --allow-empty -m init || fail "could not seed the isolated openhands workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated openhands workspace"
OH_HOME="$LAB/home"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" -x 120 -y 36 \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n oh -c "$WORKSPACE" \
  || fail "could not open the isolated openhands window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -200 2>/dev/null || true
}

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "HOME=\"$OH_HOME\" OPENHANDS_SUPPRESS_BANNER=1 OPENHANDS_PERSISTENCE_DIR=\"$OH_HOME/.openhands\" OPENHANDS_WORK_DIR=\"$WORKSPACE\" $OH_BIN --override-with-envs --always-approve --exit-without-confirmation" \
  || fail "could not type the openhands launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the openhands launch line"

ready=
for _ in $(seq 1 60); do
  screen=$(capture)
  case "$screen" in *'Type your message'*) ready=1; break ;; esac
  sleep 0.5
done
[ -n "$ready" ] || fail "the real openhands TUI never showed its idle composer"
pass "the real openhands TUI reached an idle composer without -f/--task/--headless"

sleep 0.4
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Add 12345 and 67890. Reply with exactly the sum and nothing else. Do not use tools." \
  || fail "could not type the brief pointer"
sleep 0.4
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the brief pointer"

busy_live=
for _ in $(seq 1 90); do
  screen=$(capture)
  if printf '%s' "$screen" | fm_busy_openhands_tail_busy; then busy_live=1; break; fi
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 1
done
[ -n "$busy_live" ] || fail "fm_busy_openhands_tail_busy never matched the real openhands turn in flight"
pass "the real openhands busy footer matches fm_busy_openhands_tail_busy in flight"

for _ in $(seq 1 90); do
  screen=$(capture)
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 0.5
done
reply=$(capture)
case "$reply" in
  *80235*|*80,235*) pass "the real openhands worker processed the submitted brief" ;;
  *) fail "the real openhands worker never answered the submitted brief" ;;
esac

pane_pid=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_pid}')
oh_pid=
for child in $(ps -o pid= --ppid "$pane_pid" 2>/dev/null | tr -d ' '); do
  comm=$(ps -o comm= -p "$child" 2>/dev/null | tr -d ' ')
  [ "$comm" = openhands ] && oh_pid=$child && break
done
[ -n "$oh_pid" ] || fail "the live pane has no child whose comm is openhands"
pass "the live openhands process name is the anchored comm openhands"

# Wait until idle so Escape is a no-op on a finished turn, then start a new
# turn to interrupt. A follow-up that needs tools gives the busy row time to
# appear.
for _ in $(seq 1 20); do
  screen=$(capture)
  printf '%s' "$screen" | fm_busy_openhands_tail_busy || break
  sleep 0.3
done
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Count slowly from 1 to 80, printing each number. Then write counted.txt." \
  || fail "could not type the interrupt probe"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the interrupt probe"
busy_again=
for _ in $(seq 1 40); do
  screen=$(capture)
  if printf '%s' "$screen" | fm_busy_openhands_tail_busy; then busy_again=1; break; fi
  sleep 0.5
done
[ -n "$busy_again" ] || fail "the follow-up turn never showed ESC: pause"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not deliver Escape"
paused=
for _ in $(seq 1 20); do
  screen=$(capture)
  case "$screen" in
    *"Pausing conversation"*) paused=1; break ;;
  esac
  printf '%s' "$screen" | fm_busy_openhands_tail_busy || { paused=1; break; }
  sleep 0.3
done
[ -n "$paused" ] || fail "Escape did not pause the running openhands turn"
ps -p "$oh_pid" >/dev/null 2>&1 || fail "Escape must leave the openhands process alive"
pass "a single Escape pauses the live openhands turn and leaves the process running"

for _ in $(seq 1 20); do
  screen=$(capture)
  printf '%s' "$screen" | fm_busy_openhands_tail_busy || break
  sleep 0.3
done
sleep 0.4
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l '/exit' \
  || fail "could not type /exit"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.4
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
sleep 0.4
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
exited=
for _ in $(seq 1 20); do
  if ! ps -p "$oh_pid" >/dev/null 2>&1; then exited=1; break; fi
  sleep 0.3
done
if [ -z "$exited" ]; then
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-c
  for _ in $(seq 1 10); do
    if ! ps -p "$oh_pid" >/dev/null 2>&1; then exited=1; break; fi
    sleep 0.3
  done
fi
[ -n "$exited" ] || fail "the live openhands process did not exit after /exit (with Enter retries) or Ctrl+C"
pass "the live openhands process exits under --exit-without-confirmation"
