#!/usr/bin/env bash
# Live drift guard for the OpenHands adapter's driver-owned surface: the
# working/idle/cancelled rows, the run-log fold, the turn-end touch, the
# SIGINT cancel path, and the /exit command, all against the real SDK venv
# and the real credential profile. Opt-in because it submits real prompts
# and spends the configured provider's tokens; it asserts the firstmate-owned
# mechanics, so whatever LLM_MODEL the profile carries is the right model.
# The pane carries firstmate rows alone: the driver redirects the SDK's own
# cli_mode rendering to <run-log>.sdk.log (bin/fm-openhands-worker.py owns
# that contract), so the SDK's answer is asserted there, not on the pane.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$ROOT/bin/fm-openhands-worker.py"
VENV_PY=${FM_OPENHANDS_PY:-$HOME/.config/openhands/venv/bin/python}
LLM_ENV=${FM_OPENHANDS_LLM_ENV:-$HOME/.config/openhands/llm.env}
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-openhands-signals-$$"
SESSION=openhands-signals
TARGET="$SESSION:driver"

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

# The gate names only real commands this guard shells out to; the SDK surface
# is a venv, not a command, so the venv interpreter and the profile are checked
# directly below with the same fail-loud contract.
fm_live_gate opt-in FM_OPENHANDS_SIGNALS_LIVE tmux
[ -n "$REAL_TMUX" ] || fail "tmux is not installed"
[ -x "$VENV_PY" ] || fail "the OpenHands venv python is not installed at $VENV_PY"
[ -r "$LLM_ENV" ] || fail "no readable OpenHands profile at $LLM_ENV"
[ -f "$DRIVER" ] || fail "the firstmate driver is missing at $DRIVER"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-openhands-signals.XXXXXX") || fail "could not create the isolated openhands lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated workspace"
git -C "$LAB/workspace" config user.email "guard@local" || fail "could not configure the isolated workspace"
git -C "$LAB/workspace" config user.name "guard" || fail "could not configure the isolated workspace"
git -C "$LAB/workspace" commit -q --allow-empty -m init || fail "could not seed the isolated workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated workspace"
LOG="$LAB/driver.openhands-run"
SDK_LOG="$LOG.sdk.log"
TURNEND="$LAB/driver.turn-ended"
rm -f "$TURNEND"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n driver -c "$WORKSPACE" \
  || fail "could not open the isolated driver window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -100 2>/dev/null || true
}

# The launch prompt asks for a computed answer (12345+67890=80235) so the
# awaited token never appears in the echoed launch line itself, where a plain
# reply token would false-positive on the shell echo.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "FM_OPENHANDS_HARNESS=openhands $VENV_PY $DRIVER --llm-env $LLM_ENV --run-log $LOG --turn-end $TURNEND \"Add 12345 and 67890. Reply with exactly the sum and nothing else.\"" \
  || fail "could not type the driver launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the driver launch line"

# The SDK run folds its pair open while it works, and the working row prints
# exactly once at run open, BEFORE the SDK's own streaming output can scroll
# it away - which is the delivery contract: a submit is acknowledged by
# reading the pane at Enter time, not minutes into a turn. The window is
# generous: a cold SDK start spawns the agent runtime before the first record.
busy_live=
row_live=
for _ in $(seq 1 300); do
  if [ "$(fm_busy_openhands_run_state "$LOG" 2>/dev/null)" = busy ]; then
    busy_live=1
    # Read the pane in the same poll that first saw the open pair, so the
    # row is checked where a submit core would read it: at run open.
    printf '%s' "$(capture)" | fm_busy_lines_match openhands && row_live=1
    break
  fi
  sleep 1
done
[ -n "$busy_live" ] || fail "the run log never folded busy while the real SDK turn ran"
pass "the real run log folds busy while the SDK turn is in flight"
[ -n "$row_live" ] || fail "the working delivery row never rendered at run open"

for _ in $(seq 1 600); do
  [ "$(fm_busy_openhands_run_state "$LOG" 2>/dev/null)" = settled ] && break
  sleep 1
done
[ "$(fm_busy_openhands_run_state "$LOG" 2>/dev/null)" = settled ] \
  || fail "the run log never folded settled after the SDK turn"
[ -e "$TURNEND" ] || fail "the finished run never touched the turn-end marker"
# The SDK answer is asserted in the sdk log: quiet-pane keeps the pane for
# firstmate rows alone, and the SDK's cli_mode rendering (answer included)
# lands there. Scope to the tail so banner/tool-call noise cannot false-pass.
reply=$(tail -c 200000 "$SDK_LOG" 2>/dev/null || true)
case "$reply" in
  *80235*|*80,235*) pass "the real SDK worker answered its launch prompt" ;;
  *) fail "the real SDK worker never answered its launch prompt (see $SDK_LOG)" ;;
esac
# The settled pane must not acknowledge a submit. The working row is the
# only literal that matches (bin/fm-composer-lib.sh's fm_busy_lines_match
# greps its whole input), and the driver writes it as the pane's last row
# only while a run is genuinely open; on settlement it writes idle, which
# never matches. So the last firstmate literal in the capture decides: idle
# or cancelled means a read here cannot be faked by the working row sitting
# above it in scrollback.
last_row=$(printf '%s' "$(capture)" | grep '\[fm-openhands\]' | tail -1)
case "$last_row" in
  '[fm-openhands] idle')
    pass "the settled pane's last firstmate row is idle, not an acknowledgement" ;;
  '[fm-openhands] cancelled')
    pass "the settled pane's last firstmate row is cancelled, not an acknowledgement" ;;
  *)
    fail "the settled pane's last firstmate row was '$last_row'" ;;
esac
pass "the settled run folds idle, touches turn-end, and stops acknowledging"

# Interrupt a genuinely long run: wait for the open pair, send exactly one
# C-c, and require the cancelled close and the 130 exit the contract names.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Write a 1500-word essay on the history of glass" \
  || fail "could not type the long steering line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the long steering line"
open_seen=
for _ in $(seq 1 120); do
  [ "$(fm_busy_openhands_run_state "$LOG" 2>/dev/null)" = busy ] && { open_seen=1; break; }
  sleep 1
done
[ -n "$open_seen" ] || fail "the steered long run never opened its pair"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-c \
  || fail "could not send C-c to the real driver run"
cancelled=
for _ in $(seq 1 120); do
  grep -q '"terminal": "cancelled"' "$LOG" 2>/dev/null && { cancelled=1; break; }
  sleep 1
done
[ -n "$cancelled" ] || fail "a single C-c never closed the real run pair as cancelled"
[ "$(fm_busy_openhands_run_state "$LOG" 2>/dev/null)" = settled ] \
  || fail "the cancelled close never folded settled"
# The interrupted driver must actually exit. SIGINT lands the bounded close
# on the main thread (up to a few seconds: bin/fm-openhands-worker.py's
# close_converation_bounded) before the hard os._exit(130), so poll rather
# than single-check, or a scheduler delay could false-fail.
driver_gone=
for _ in $(seq 1 30); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$current" in
    *python*) sleep 1 ;;
    *) driver_gone=1; break ;;
  esac
done
[ -n "$driver_gone" ] || fail "the interrupted driver never exited (still running as $current)"
pass "a single C-c cancels the real run and stops the driver"

cleanup
trap - EXIT
