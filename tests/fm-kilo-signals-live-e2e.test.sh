#!/usr/bin/env bash
# Live drift guard for the kilo (Kilo Code) adapter's vendor-controlled surface:
# process name, rendered busy footer, interrupt, and exit behavior.
# Opt-in because it submits real prompts (no echo provider exists for kilo).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KILO_BIN=$(command -v kilo 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-kilo-signals-$$"
SESSION=kilo-signals
TARGET="$SESSION:kilo"

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

fm_live_gate opt-in FM_KILO_SIGNALS_LIVE kilo tmux
[ -n "$KILO_BIN" ] || fail "kilo is not installed"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-kilo-signals.XXXXXX") || fail "could not create the isolated kilo lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated kilo workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated kilo workspace"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n kilo -c "$WORKSPACE" \
  || fail "could not open the isolated kilo window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -100 2>/dev/null || true
}

# A computed answer keeps the awaited token out of the echoed launch line.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "$KILO_BIN --auto --prompt \"Add 12345 and 67890. Reply with exactly the sum and nothing else\"" \
  || fail "could not type the kilo launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the kilo launch line"

busy_live=
for _ in $(seq 1 240); do
  screen=$(capture)
  if printf '%s' "$screen" | fm_busy_kilo_tail_busy; then busy_live=1; break; fi
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 1
done
[ -n "$busy_live" ] || fail "fm_busy_kilo_tail_busy never matched the real kilo turn in flight"
pass "the real kilo busy footer matches fm_busy_kilo_tail_busy in flight"

for _ in $(seq 1 480); do
  screen=$(capture)
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 0.5
done
case "$(capture)" in
  *80235*|*80,235*) pass "the real kilo worker processed its launch prompt" ;;
  *) fail "the real kilo worker never answered its launch prompt" ;;
esac

# Wait for the settled idle footer before asserting it is not busy.
idle_settled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *"Ask anything"*) idle_settled=1; break ;; esac
  sleep 0.5
done
[ -n "$idle_settled" ] || fail "the kilo composer never settled to its idle footer after the reply"
printf '%s' "$screen" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match kilo \
  && fail "harness=kilo matched its own idle footer as busy" || true
printf '%s' "$screen" | fm_busy_kilo_tail_busy \
  && fail "the settled kilo footer still matches the busy signature" || true

# Interrupt a genuinely long turn with a DOUBLE Escape.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Write a 1500-word essay on the history of glass" \
  || fail "could not type the long kilo prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the long kilo prompt"
for _ in $(seq 1 120); do
  screen=$(capture)
  printf '%s' "$screen" | fm_busy_kilo_tail_busy && break
  sleep 0.5
done
printf '%s' "$screen" | fm_busy_kilo_tail_busy \
  || fail "the long kilo turn never showed its busy footer"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not send the first Escape to the real kilo turn"
sleep 0.2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not send the second Escape to the real kilo turn"
interrupted=
for _ in $(seq 1 160); do
  screen=$(capture)
  if ! printf '%s' "$screen" | fm_busy_kilo_tail_busy && printf '%s' "$screen" | grep -qi 'interrupt\|cancel\|interrupted'; then
    interrupted=1; break
  fi
  sleep 0.5
done
[ -n "$interrupted" ] || fail "a double Escape never interrupted the real kilo turn"
pass "a double Escape interrupts the real kilo turn"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/exit" \
  || fail "could not type the kilo exit command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the kilo exit command"
gone=
for _ in $(seq 1 60); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$current" in *kilo*) sleep 0.5 ;; *) gone=1; break ;; esac
done
[ -n "$gone" ] || fail "/exit never stopped the real kilo process"
pass "/exit stops the real kilo process"

cleanup
trap - EXIT
