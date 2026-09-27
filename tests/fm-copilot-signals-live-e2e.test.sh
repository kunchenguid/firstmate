#!/usr/bin/env bash
# Live drift guard for the GitHub Copilot CLI adapter's vendor-controlled
# surface: trust dialog, model routing, session event schema, busy fold,
# interrupt, and exit behavior.
# Opt-in because it submits real prompts (no echo provider exists for
# copilot); each run spends a few AI credits on the account's plan.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COPILOT_BIN=$(command -v copilot 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
SOCKET="fm-copilot-signals-$$"
SESSION=copilot-signals
TARGET="$SESSION:copilot"

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

fm_live_gate opt-in FM_COPILOT_SIGNALS_LIVE copilot tmux
[ -n "$COPILOT_BIN" ] || fail "copilot is not installed"
# Auth stays with the operator's own login: copilot binds its credential to
# the signed-in account (a whole-~/.copilot copy under a throwaway HOME
# still parked on /login, verified live), and COPILOT_GITHUB_TOKEN only
# accepts non-classic tokens while `gh auth token` mints a classic PAT the
# CLI ignores (verified live). So this guard runs under the real HOME and
# keeps its footprint to fresh temp workspaces, session-only trust answers
# that are never persisted, and its own session history. Sign in first with
# `copilot login`; an unauthenticated run fails loudly at the reply poll,
# which names the /login screen when that is the cause.

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-copilot-signals.XXXXXX") || fail "could not create the isolated copilot lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated copilot workspace"
git -C "$LAB/workspace" config user.email "guard@local" || fail "could not configure the isolated copilot workspace"
git -C "$LAB/workspace" config user.name "guard" || fail "could not configure the isolated copilot workspace"
git -C "$LAB/workspace" commit -q --allow-empty -m init || fail "could not seed the isolated copilot workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated copilot workspace"

# Workspaces are fresh temp directories under the lab; the copilot HOME is
# the operator's own (see above), so session history from earlier runs is
# expected and the launch's session is whichever directory was NOT here
# before, never "the newest by mtime".
GUARD_HOME="$HOME"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$WORKSPACE" \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n copilot -c "$WORKSPACE" \
  || fail "could not open the isolated copilot window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -100 2>/dev/null || true
}

poll_for() {  # <seconds> <needle> — 0 when the needle renders in the pane
  local deadline=$(($(date +%s) + $1)) needle=$2 screen
  while [ "$(date +%s)" -lt "$deadline" ]; do
    screen=$(capture)
    case "$screen" in
      *"$needle"*) return 0 ;;
    esac
    sleep 3
  done
  return 1
}

# Type text, settle past the composer race (references/harness/copilot.md
# "Composer settle race"), and submit until the busy status row proves the
# turn started. The proof is the busy token, never the absence of the text:
# a submitted prompt stays visible in the transcript above the composer, so
# a text-absence check would re-submit into a running turn.
guard_submit() {  # <text>
  local text=$1 screen deadline
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "$text" \
    || fail "could not type into the copilot pane"
  sleep 4
  for _ in 1 2; do
    "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
      || fail "could not submit into the copilot pane"
    deadline=$(($(date +%s) + 15))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      screen=$(capture)
      case "$screen" in
        *"esc interrupt"*) return 0 ;;
      esac
      sleep 3
    done
  done
  fail "a steered prompt never started its turn"
}

# --- case 1: the trust dialog renders without the bypass, answered once ---

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "HOME=\"$GUARD_HOME\" $COPILOT_BIN -i \"Add 12345 and 67890. Reply with exactly the sum and nothing else\" --model auto --yolo" \
  || fail "could not type the copilot launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the copilot launch line"

# A fresh workspace stops on the folder-trust dialog. Answer the preselected
# safe choice once it renders.
poll_for 60 "Do you trust the files in this folder?" \
  || fail "a fresh workspace never rendered the folder-trust dialog"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not answer the folder-trust dialog"

# The launch prompt asks for a computed answer (12345+67890=80235) so the
# awaited token never appears in the echoed launch line itself, where a plain
# reply token would false-positive on the shell echo (including across tmux
# wrapped rows).
if ! poll_for 180 "80235"; then
  screen=$(capture)
  case "$screen" in
    *"/login"*)
      fail "the trusted turn never rendered its reply: the pane asks for /login, so no signed-in copilot account is reachable from this environment" ;;
  esac
  fail "the trusted turn never rendered its reply"
fi
pass "live: the folder-trust dialog renders without the bypass and one Enter answers it"

# --- case 2: COPILOT_ALLOW_ALL=true suppresses the dialog ---

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/exit" || fail "could not type /exit"
sleep 2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not submit /exit"
sleep 2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not confirm /exit"
sleep 5

mkdir -p "$LAB/workspace2"
WORKSPACE2=$(cd "$LAB/workspace2" && pwd -P) || fail "could not resolve the second lab workspace"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" "cd $(printf '%q' "$WORKSPACE2")" \
  || fail "could not type the cd line"
sleep 1
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not submit the cd line"
sleep 2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "HOME=\"$GUARD_HOME\" COPILOT_ALLOW_ALL=true $COPILOT_BIN -i \"Reply with exactly BYPASS_OK and nothing else\" --model auto --yolo" \
  || fail "could not type the bypass launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the bypass launch line"
poll_for 180 "BYPASS_OK" || fail "the bypassed turn never rendered its reply"
screen=$(capture)
case "$screen" in
  *"Do you trust the files in this folder?"*)
    fail "COPILOT_ALLOW_ALL=true rendered the trust dialog anyway" ;;
esac
pass "live: COPILOT_ALLOW_ALL=true suppresses the trust dialog and the turn runs"

# --- case 3: the session-events fold tracks the turn ---

# Resolve the launch's session the same way the classifier does: the one
# session whose recorded workspace is the fresh lab directory. No timestamp
# or before/afterSnapshot is involved, so operator history cannot confuse it.
match=$(fm_busy_copilot_matching_sessions "$GUARD_HOME/.copilot" "$WORKSPACE2")
[ -n "$match" ] || fail "no session directory recorded the lab workspace"
[ "$(printf '%s\n' "$match" | wc -l)" -eq 1 ] \
  || fail "more than one session recorded the lab workspace"
SID=$(basename "$match")
WS_CWD=$(sed -n 's/^cwd: *//p' "$GUARD_HOME/.copilot/session-state/$SID/workspace.yaml" | head -1)
[ "$WS_CWD" = "$WORKSPACE2" ] \
  || fail "the session recorded cwd '$WS_CWD', not the lab workspace '$WORKSPACE2'"
# The fold must see the close: assistant boundaries can lag the visible
# reply (verified live: a rendered reply with turn_end still unflushed half
# a minute later, and a just-rendered reply with no boundary flushed at
# all), so poll for the convergence rather than asserting it once.
# session.shutdown also closes, so even a turn whose end never flushes
# while the session lives converges at the latest when it exits. The live
# open-tracking proof sits in case 4, which folds a running turn.
fold_deadline=$(($(date +%s) + 120))
while [ "$(date +%s)" -lt "$fold_deadline" ]; do
  [ "$(fm_busy_copilot_turn_state "$GUARD_HOME/.copilot/session-state/$SID/events.jsonl")" = settled ] && break
  sleep 5
done
[ "$(fm_busy_copilot_turn_state "$GUARD_HOME/.copilot/session-state/$SID/events.jsonl")" = settled ] \
  || fail "a completed turn must fold settled"
pass "live: session events bind the workspace and fold busy/settled"

# --- case 4: steering delivers, Ctrl+C interrupts, /exit exits ---

guard_submit "run the shell command sleep 60, then reply with exactly the word SLEPT"
# The submit is proven by the busy row; the fold must agree while the turn
# runs. Event flush can lag the visible turn, so poll briefly instead of
# asserting once.
fold_busy_deadline=$(($(date +%s) + 30))
while [ "$(date +%s)" -lt "$fold_busy_deadline" ]; do
  [ "$(fm_busy_copilot_turn_state "$GUARD_HOME/.copilot/session-state/$SID/events.jsonl")" = busy ] && break
  sleep 3
done
[ "$(fm_busy_copilot_turn_state "$GUARD_HOME/.copilot/session-state/$SID/events.jsonl")" = busy ] \
  || fail "a running turn must fold busy"
sleep 15
screen=$(capture)
case "$screen" in
  *"esc interrupt"*) ;;
  *) fail "a running turn never rendered the busy status row" ;;
esac
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" C-c || fail "could not send Ctrl+C"
sleep 10
if grep -q '"type":"abort"' "$GUARD_HOME/.copilot/session-state/$SID/events.jsonl" 2>/dev/null; then
  :
elif poll_for 30 "SLEPT"; then
  fail "Ctrl+C did not abort the turn; it completed normally"
else
  fail "Ctrl+C left the turn in an unrecognized state"
fi
fold_settled_deadline=$(($(date +%s) + 60))
while [ "$(date +%s)" -lt "$fold_settled_deadline" ]; do
  [ "$(fm_busy_copilot_turn_state "$GUARD_HOME/.copilot/session-state/$SID/events.jsonl")" = settled ] && break
  sleep 3
done
[ "$(fm_busy_copilot_turn_state "$GUARD_HOME/.copilot/session-state/$SID/events.jsonl")" = settled ] \
  || fail "an aborted turn must fold settled"
pass "live: steering delivers and Ctrl+C aborts the turn"

"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/exit" || fail "could not type /exit"
sleep 2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not submit /exit"
sleep 2
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not confirm /exit"
poll_deadline=$(($(date +%s) + 30))
while [ "$(date +%s)" -lt "$poll_deadline" ]; do
  cmd=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  case "$cmd" in
    copilot|node) sleep 2; continue ;;
  esac
  break
done
cmd=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
case "$cmd" in
  copilot|node) fail "/exit left the agent running (foreground: $cmd)" ;;
esac
pass "live: /exit stops the agent and returns the pane to its shell"

cleanup
trap - EXIT
printf 'ok - copilot live signals verified end to end\n'
