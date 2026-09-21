#!/usr/bin/env bash
# Live drift guard for the Devin CLI adapter's vendor-controlled surface:
# process name, trust dialog, rendered busy/interrupt/exit behavior.
# Opt-in because it submits real prompts on a signed-in account.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVIN_BIN=$(command -v devin 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
TRUST_STORE="$HOME/.local/share/devin/cli/trusted_workspaces.json"
TRUST_BACKUP=
SOCKET="fm-devin-signals-$$"
SESSION=devin-signals
TARGET="$SESSION:devin"

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "$TRUST_BACKUP" ] && [ -f "$TRUST_BACKUP" ]; then
    cp "$TRUST_BACKUP" "$TRUST_STORE" 2>/dev/null || true
    rm -f "$TRUST_BACKUP"
  fi
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

fm_live_gate opt-in FM_DEVIN_SIGNALS_LIVE devin tmux
[ -n "$DEVIN_BIN" ] || fail "devin is not installed"
"$DEVIN_BIN" auth status 2>/dev/null | grep -qi "logged in" \
  || fail "devin is not signed in (devin auth status does not report Logged in)"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-devin-signals.XXXXXX") || fail "could not create the isolated devin lab"
trap cleanup EXIT
WORKSPACE="$LAB/workspace"
mkdir -p "$WORKSPACE" || fail "could not create the isolated devin workspace"
WORKSPACE=$(cd "$WORKSPACE" && pwd -P) || fail "could not resolve the isolated devin workspace"

# The trust answer lands in the operator's real trust store, so snapshot it
# first and restore it on the way out; the lab directory itself is removed, so
# no entry survives the guard either way.
if [ -f "$TRUST_STORE" ]; then
  TRUST_BACKUP="$LAB/trusted_workspaces.json.bak"
  cp "$TRUST_STORE" "$TRUST_BACKUP" || fail "could not snapshot the devin trust store"
fi

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n devin -c "$WORKSPACE" \
  || fail "could not open the isolated devin window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -100 2>/dev/null || true
}

# The launch prompt asks for a computed answer (12345+67890=80235) so the
# awaited token never appears in the echoed launch line itself, where a plain
# reply token would false-positive on the shell echo (including across tmux
# wrapped rows). swe-2-medium is the account's free tier, so the guard spends
# no budget; --permission-mode bypass matches the spawn template's autonomy.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "$DEVIN_BIN --permission-mode bypass --model swe-2-medium -- \"Add 12345 and 67890. Reply with exactly the sum and nothing else\"" \
  || fail "could not type the devin launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the devin launch line"

# A fresh workspace stops on the workspace-trust dialog. Answer the
# preselected safe choice once it renders; the answer appends the workspace to
# trusted_paths in the real store, which the cleanup restores.
screen=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in
    *"Do you trust the authors of this directory?"*|*80235*|*80,235*) break ;;
  esac
  sleep 0.5
done
case "$screen" in
  *"Do you trust the authors of this directory?"*)
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
      || fail "could not answer the devin trust dialog"
    ;;
esac

# The initial turn executes and its reply lands. Trivial turns were observed
# taking under a minute on the free tier, but these windows stay generous; the
# guard is opt-in.
for _ in $(seq 1 240); do
  screen=$(capture)
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 0.5
done
reply=$(capture)
case "$reply" in
  *80235*|*80,235*) pass "the real devin worker processed its launch prompt" ;;
  *) fail "the real devin worker never answered its launch prompt" ;;
esac

# The settled pane must carry the adapter's idle contract: the bare ❭ glyph
# row with its idle placeholder and the model status row.
case "$reply" in
  *"❭ Ask Devin to build features, fix bugs, or work on your code"*) pass "the real devin composer settles on its idle placeholder" ;;
  *) fail "the settled devin composer lacks its idle placeholder row" ;;
esac

# Interrupt a genuinely long turn: submit the prompt (retrying the Enter once,
# because a typed Enter is occasionally swallowed with the text left
# unsubmitted), poll until the running turn names its own interrupt key, then
# send two SEPARATED Escapes - a back-to-back pair in one send-keys call was
# observed not to cancel - and wait for the cancel row it prints.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "Write a 1500-word essay on the history of glass" \
  || fail "could not type the long devin prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the long devin prompt"
sleep 5
screen=$(capture)
case "$screen" in
  *"❭ Write a 1500-word essay on the history of glass"*)
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
      || fail "could not retry the swallowed devin Enter"
    ;;
esac
busy=
for _ in $(seq 1 240); do
  screen=$(capture)
  case "$screen" in *"esc twice to interrupt"*) busy=1; break ;; esac
  sleep 0.5
done
[ -n "$busy" ] || fail "the long devin turn never showed its running row"
pass "the real devin turn names its own interrupt key while running"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not send the first Escape to the real devin turn"
sleep 1
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not send the second Escape to the real devin turn"
cancelled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *"Canceled. What should Devin do?"*) cancelled=1; break ;; esac
  sleep 0.5
done
[ -n "$cancelled" ] || fail "two separated Escapes never cancelled the real devin turn"
pass "two separated Escapes cancel the real devin turn"

# Exit through the adapter's exit command, retrying the Enter once for the
# same documented swallow; the process must leave the pane to its shell.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/exit" \
  || fail "could not type the devin exit command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the devin exit command"
sleep 5
case "$(capture)" in
  *"❭ /exit"*)
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
      || fail "could not retry the swallowed devin exit Enter"
    ;;
esac
gone=
for _ in $(seq 1 60); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$current" in *devin*) sleep 0.5 ;; *) gone=1; break ;; esac
done
[ -n "$gone" ] || fail "/exit never stopped the real devin process"
pass "/exit stops the real devin process"

cleanup
trap - EXIT
