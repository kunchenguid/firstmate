#!/usr/bin/env bash
# G2: busy-guard. A pane whose tail shows a busy footer ("esc to interrupt") must
# NOT fire, even though its sentinel is over threshold. Uses a DISPOSABLE scratch
# tmux session (never a real fleet pane). Mutation (LEDGER_MUTATE=1): make the same
# pane idle instead of busy — fm_ctx_can_fire then returns true, so the "must be
# blocked" assertion fails (proving the guard, not a constant, drives the result).
# HERMETICITY-WAIVER: outside the tests/lib.sh deny net on purpose. The context
# watchdog is a tmux-only subsystem and this case drives a DISPOSABLE scratch
# session it creates and kills itself, so the refusing shim would deny the very
# server under test. The migration this marks: opt in with FM_TEST_ALLOW_LIVE_TMUX=1
# before sourcing lib.sh and export FM_TEST_LIVE_TMUX_SESSION="$SESS", which scopes
# its kills to its own session instead of trusting them.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { pass "G2 busy-guard (skipped: no tmux)"; exit 0; }

# shellcheck source=bin/fm-context-watch.sh
. "$ROOT/bin/fm-context-watch.sh"

STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctx-g2.XXXXXX")
SESS="fmctxg2-$$"
cleanup() { tmux kill-session -t "$SESS" 2>/dev/null || true; rm -rf "$STATE"; }
trap cleanup EXIT

tmux new-session -d -s "$SESS" -x 200 -y 50 2>/dev/null || { pass "G2 busy-guard (skipped: tmux new-session failed)"; exit 0; }
PANE=$(tmux display-message -p -t "$SESS" '#{pane_id}')
[ -n "$PANE" ] || fail "could not resolve scratch pane id"

# Treat the disposable scratch session as the managed firstmate session so the
# fire-time _ctx_target_in_session re-confirmation passes and the busy-guard (not
# the session check) is the deciding factor under test.
export FM_TMUX_SESSION="$SESS"

# Plant an over-threshold captain sentinel pointing at the scratch pane.
printf '{"window":"%s","tmux_target":"%s","role":"captain","total_tokens":195000,"used_pct":98,"exceeds_200k":false,"managed":true,"ts":0}' \
  "g2win" "$PANE" > "$STATE/ctx-g2win.json"

# Make the pane busy (normal) or idle (mutation).
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  tmux send-keys -t "$PANE" -l 'echo idle-and-ready'; tmux send-keys -t "$PANE" Enter
else
  tmux send-keys -t "$PANE" -l 'echo esc to interrupt'; tmux send-keys -t "$PANE" Enter
fi
sleep 0.6

# Sanity: eligibility holds regardless of busy state.
_ctx_eligible "$STATE" g2win || fail "sentinel should be eligible (over threshold, no cooldown)"

if fm_ctx_can_fire "$STATE" g2win "$PANE"; then
  fail "busy pane must NOT fire (busy-guard failed to hold)"
fi
pass "G2 busy-guard holds (over-threshold + busy pane does not fire)"
