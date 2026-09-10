#!/usr/bin/env bash
# Live drift guard for the Antigravity CLI adapter's vendor-controlled surface:
# process name, trust dialog, rendered busy/interrupt/exit behavior.
# Opt-in because it submits real prompts (no echo provider exists for agy).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-agy-signals-$$"
SESSION=agy-signals
TARGET="$SESSION:agy"

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

fm_live_gate opt-in FM_AGY_SIGNALS_LIVE agy tmux
[ -n "$AGY_BIN" ] || fail "agy is not installed"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX") || fail "could not create the isolated agy lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated agy workspace"
git -C "$LAB/workspace" config user.email "guard@local" || fail "could not configure the isolated agy workspace"
git -C "$LAB/workspace" config user.name "guard" || fail "could not configure the isolated agy workspace"
git -C "$LAB/workspace" commit -q --allow-empty -m init || fail "could not seed the isolated agy workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated agy workspace"

# The worker runs under a throwaway HOME holding a copy of ~/.gemini (the
# method recorded in docs/verification/agy.md), so its trust answer and every
# other agy write land in the lab store, never the operator's real one.
AGY_HOME="$LAB/home"
mkdir -p "$AGY_HOME" || fail "could not create the throwaway agy HOME"
[ -d "$HOME/.gemini" ] || fail "no ~/.gemini to stage for the throwaway agy HOME"
cp -R "$HOME/.gemini" "$AGY_HOME/.gemini" || fail "could not stage the throwaway agy credential copy"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n agy -c "$WORKSPACE" \
  || fail "could not open the isolated agy window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -100 2>/dev/null || true
}

# The launch prompt asks for a computed answer (12345+67890=80235) so the
# awaited token never appears in the echoed launch line itself, where a plain
# reply token would false-positive on the shell echo (including across tmux
# wrapped rows).
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "HOME=\"$AGY_HOME\" $AGY_BIN --prompt-interactive \"Add 12345 and 67890. Reply with exactly the sum and nothing else\" --model gemini-3.8-flash-low --effort low --dangerously-skip-permissions" \
  || fail "could not type the agy launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the agy launch line"

# A fresh workspace stops on the folder-trust dialog. Answer the preselected
# safe choice once it renders. The answer appends the workspace to
# trustedWorkspaces in the throwaway HOME's copy of the agy settings store.
screen=
for _ in $(seq 1 150); do
  screen=$(capture)
  case "$screen" in
    *"Do you trust the contents of this project?"*|*80235*|*80,235*) break ;;
  esac
  sleep 0.5
done
case "$screen" in
  *"Do you trust the contents of this project?"*)
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
      || fail "could not answer the agy trust dialog"
    ;;
esac

# The initial turn executes and its reply lands; the busy footer must render
# while it is in flight so the portable matcher has live text to prove.
# Trivial turns were observed taking one to two minutes (cold start plus model
# latency), so these windows are generous; the guard is opt-in.
busy_live=
for _ in $(seq 1 240); do
  screen=$(capture)
  if printf '%s' "$screen" | fm_busy_agy_tail_busy; then busy_live=1; break; fi
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 1
done
[ -n "$busy_live" ] || fail "fm_busy_agy_tail_busy never matched the real agy turn in flight"
pass "the real agy busy footer matches fm_busy_agy_tail_busy in flight"

for _ in $(seq 1 480); do
  screen=$(capture)
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 0.5
done
reply=$(capture)
case "$reply" in
  *80235*|*80,235*) pass "the real agy worker processed its launch prompt" ;;
  *) fail "the real agy worker never answered its launch prompt" ;;
esac
# Scope to the visible tail the same way the owners do: mid-turn busy rows stay
# in scrollback after the turn settles and must not count as still busy.
printf '%s' "$screen" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match agy \
  && fail "harness=agy matched its own idle footer as busy" || true
printf '%s' "$screen" | fm_busy_agy_tail_busy \
  && fail "the settled agy footer still matches the busy signature" || true

# The dialog can outlive the turn it gated, so a still-rendered dialog must be
# dismissed before steering anything: typed text would land in it instead of
# the composer.
if case "$(capture)" in *"Do you trust the contents of this project?"*) true ;; *) false ;; esac; then
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
    || fail "could not dismiss the residual agy trust dialog"
  idle=
  for _ in $(seq 1 120); do
    case "$(capture)" in *"? for shortcuts"*) idle=1; break ;; esac
    sleep 0.5
  done
  [ -n "$idle" ] || fail "the agy composer never went idle after the trust answer"
fi

# Interrupt a genuinely long turn: poll until busy is observed, then send
# exactly one Escape and wait only for the Interrupted row it prints; a busy
# footer that merely disappears is not cancellation and no further Escape is
# sent, so a turn that survives one Escape fails this guard.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Write a 1500-word essay on the history of glass" \
  || fail "could not type the long agy prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the long agy prompt"
for _ in $(seq 1 100); do
  screen=$(capture)
  printf '%s' "$screen" | fm_busy_agy_tail_busy && break
  sleep 0.5
done
printf '%s' "$screen" | fm_busy_agy_tail_busy \
  || fail "the long agy turn never showed its busy footer"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not send Escape to the real agy turn"
cancelled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *Interrupted*) cancelled=1; break ;; esac
  sleep 0.5
done
[ -n "$cancelled" ] || fail "a single Escape never cancelled the real agy turn"
pass "a single Escape cancels the real agy turn"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/quit" \
  || fail "could not type the agy exit command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the agy exit command"
gone=
for _ in $(seq 1 60); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$current" in *agy*) sleep 0.5 ;; *) gone=1; break ;; esac
done
[ -n "$gone" ] || fail "/quit never stopped the real agy process"
pass "/quit stops the real agy process"

cleanup
trap - EXIT
