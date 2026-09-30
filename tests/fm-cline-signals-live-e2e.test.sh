#!/usr/bin/env bash
# Live drift guard for the Cline CLI adapter's vendor-controlled surface:
# hook config-file discovery, the rendered busy token, interrupt, and exit.
# Opt-in because it submits real prompts on the captain's ClinePass seat and no
# echo provider exists for cline.
#
# Run after every cline upgrade and before trusting refreshed per-harness
# evidence (docs/verification/cline.md names this as the refresh command).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLINE_BIN=$(command -v cline 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-cline-signals-$$"
SESSION=cline-signals
TARGET="$SESSION:cline"

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

fm_live_gate opt-in FM_CLINE_SIGNALS_LIVE cline tmux
[ -n "$CLINE_BIN" ] || fail "cline is not installed"
[ -n "$REAL_TMUX" ] || fail "tmux is not installed"
[ -s "$HOME/.cline/data/settings/providers.json" ] || fail "no cline credential store to stage"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-cline-signals.XXXXXX") || fail "could not create the isolated cline lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace" "$LAB/home" "$LAB/state" "$LAB/workspace/.cline/hooks" \
  || fail "could not create the isolated cline lab"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated cline workspace"
git -C "$LAB/workspace" config user.email "guard@local" || fail "could not configure the isolated cline workspace"
git -C "$LAB/workspace" config user.name "guard" || fail "could not configure the isolated cline workspace"
git -C "$LAB/workspace" commit -q --allow-empty -m init || fail "could not seed the isolated cline workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated cline workspace"

# A throwaway HOME holding a copy of ~/.cline keeps every cline write - session
# state, splash dismissal, refreshed tokens - inside the lab and away from the
# operator's real store.
cp -R "$HOME/.cline" "$LAB/home/.cline" || fail "could not stage the throwaway cline credential copy"

HOOK_LOG="$LAB/hooks.log"
for ev in TaskStart TaskComplete TaskCancel TaskError SessionShutdown; do
  {
    printf '%s\n' '#!/bin/sh'
    printf 'printf "%%s\\n" %s >>"%s"\n' "$ev" "$HOOK_LOG"
  } > "$WORKSPACE/.cline/hooks/$ev" || fail "could not write the $ev hook"
  chmod +x "$WORKSPACE/.cline/hooks/$ev" || fail "could not arm the $ev hook"
done

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n cline -c "$WORKSPACE" \
  || fail "could not open the isolated cline window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -200 2>/dev/null || true
}

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "HOME=\"$LAB/home\" $CLINE_BIN -i -c \"$WORKSPACE\" --auto-approve true -m cline-pass/deepseek-v4-flash" \
  || fail "could not type the cline launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the cline launch line"

# A fresh profile may render the one-time "Introducing Cline Desktop" splash,
# which consumes the first submitted line. Dismiss it and wait for the idle
# composer, the same shape bin/fm-spawn.sh's readiness gate uses.
ready=0
for _ in $(seq 1 180); do
  screen=$(capture)
  case "$screen" in
    *"Introducing Cline Desktop"*|*"Press Enter to open"*)
      "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape >/dev/null 2>&1 || true
      sleep 1
      continue
      ;;
  esac
  if printf '%s\n' "$screen" | grep -qE 'Ask anything\.\.\.|What can I do for you\?'; then
    ready=1
    break
  fi
  sleep 0.5
done
[ "$ready" -eq 1 ] || fail "cline never reached an idle composer"
pass "cline reaches an idle composer after the splash gate"

# Ask for a computed sum so the awaited token cannot false-positive on the
# echoed launch line.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Add 12345 and 67890 and reply with exactly the sum and nothing else" \
  || fail "could not type the cline prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the cline prompt"

busy_seen=0
for _ in $(seq 1 120); do
  screen=$(capture)
  if printf '%s\n' "$screen" | grep -qE "$FM_DELIVERY_CLINE_BUSY_REGEX_DEFAULT"; then
    busy_seen=1
    break
  fi
  sleep 0.5
done
[ "$busy_seen" -eq 1 ] || fail "the pinned (esc to cancel) busy token never rendered"

done_seen=0
for _ in $(seq 1 240); do
  screen=$(capture)
  if printf '%s\n' "$screen" | grep -q '80235\|80,235'; then
    done_seen=1
    break
  fi
  sleep 0.5
done
[ "$done_seen" -eq 1 ] || fail "the awaited reply never rendered"

# TaskStart/TaskComplete must have fired from the workspace hook directory.
# TaskComplete lands at turn end, which can trail the rendered reply slightly.
start_count=0
complete_count=0
for _ in $(seq 1 40); do
  start_count=$(grep -c '^TaskStart$' "$HOOK_LOG" 2>/dev/null || true)
  complete_count=$(grep -c '^TaskComplete$' "$HOOK_LOG" 2>/dev/null || true)
  if [ "${start_count:-0}" -ge 1 ] && [ "${complete_count:-0}" -ge 1 ]; then break; fi
  sleep 0.5
done
[ "${start_count:-0}" -ge 1 ] || fail "the TaskStart hook never fired"
[ "${complete_count:-0}" -ge 1 ] || fail "the TaskComplete hook never fired"
pass "cline fires the workspace TaskStart/TaskComplete hooks around a turn"

# Interrupt: a second, slow turn cancelled with a single Escape.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Run the shell command: sleep 6. Then reply SLOWDONE." \
  || fail "could not type the interrupt probe"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the interrupt probe"
sleep 4
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not send Escape"
# Give the cancelled turn time to settle back to an idle composer before the
# exit command, so /exit is not queued behind a still-running tool call.
for _ in $(seq 1 60); do
  screen=$(capture)
  printf '%s\n' "$screen" | grep -qE "$FM_DELIVERY_CLINE_BUSY_REGEX_DEFAULT" || break
  sleep 0.5
done

# /exit must return to a shell. Detect it structurally (the pane's foreground
# process becomes the shell) with cline's own summary as a fallback. If the
# first attempt is swallowed (the cancelled turn can still be settling), retry
# the exact exit command once.
exited=0
for _ in 1 2 3; do
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l '/exit' \
    || fail "could not type /exit"
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
    || fail "could not submit /exit"
  for _ in $(seq 1 60); do
    screen=$(capture)
    fg=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
    case "$fg" in bash|zsh|sh|dash|ash|ksh) exited=1 ;; esac
    printf '%s\n' "$screen" | grep -Fq 'Session Summary' && exited=1
    [ "$exited" -eq 1 ] && break
    sleep 0.5
  done
  [ "$exited" -eq 1 ] && break
done
[ "$exited" -eq 1 ] || fail "cline did not exit on /exit"
pass "cline interrupts on Escape and exits on /exit"

printf 'ok - cline live signals guard passed\n'
