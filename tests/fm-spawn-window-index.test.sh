#!/usr/bin/env bash
# Regression tests for the fm-spawn.sh window-targeting fix.
#
# fm-spawn creates each crewmate window with `tmux new-window`. The pre-fix command
# targeted the bare session name (`-t "$SES"`), which on some tmux versions resolves to
# the session's ACTIVE window and tries to create the new window at that already-occupied
# index, failing "create window failed: index N in use" when low indices are taken.
# The fix appends a colon (`-t "$SES:"`) to force session-only targeting so tmux always
# picks the next free index.
#
# These tests run entirely on a PRIVATE tmux socket (-L) with $TMUX unset, so they never
# touch any live firstmate session. They skip cleanly when tmux is unavailable.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

if ! command -v tmux >/dev/null 2>&1; then
  pass "tmux unavailable; window-index behavior tests skipped"
  exit 0
fi

SOCK="fm-spawn-winidx-$$"
unset TMUX  # detach from any ambient tmux server so probes use only our private socket
cleanup() { tmux -L "$SOCK" kill-server 2>/dev/null || true; }
trap cleanup EXIT
tmux -L "$SOCK" start-server 2>/dev/null || true

# Build the realistic firstmate-inside-tmux condition: a session whose low window
# indices (0,1,2) are occupied and whose ACTIVE window is a low occupied index.
build_session() {
  local ses=$1
  tmux -L "$SOCK" kill-session -t "$ses" 2>/dev/null || true
  tmux -L "$SOCK" set -g base-index 0 2>/dev/null || true  # deterministic regardless of host tmux.conf
  tmux -L "$SOCK" new-session -d -s "$ses" -n w0
  tmux -L "$SOCK" new-window -d -t "$ses:1" -n w1
  tmux -L "$SOCK" new-window -d -t "$ses:2" -n w2
  tmux -L "$SOCK" select-window -t "$ses:0"  # active = occupied low index
}

# 1. The source carries the session-targeting fix (guards the literal one-line change).
test_source_uses_session_target() {
  grep -Fq 'tmux new-window -d -t "$SES:"' "$SPAWN" \
    || fail "fm-spawn.sh must target the session ('\$SES:'), not the bare session/active window"
  if grep -E 'tmux new-window -d -t "\$SES"[^:]' "$SPAWN" >/dev/null 2>&1; then
    fail "fm-spawn.sh still uses the bare-name new-window target"
  fi
  pass "fm-spawn.sh issues new-window against the session target (\$SES:)"
}

# 2. The fixed form lands the crewmate window at the next free index and never errors,
#    even with low indices occupied and the active window on a low occupied index.
test_session_target_picks_next_free() {
  local ses=FIX out st idx
  build_session "$ses"
  # Exactly the command fm-spawn.sh issues, with the same flags.
  out=$(tmux -L "$SOCK" new-window -d -t "$ses:" -n fm-crew-test -c "$ROOT" 2>&1)
  st=$?
  [ "$st" -eq 0 ] || fail "session-target new-window failed (exit $st): $out"
  idx=$(tmux -L "$SOCK" list-windows -t "$ses" -F '#{window_index} #{window_name}' \
    | awk '$2=="fm-crew-test"{print $1}')
  [ -n "$idx" ] || fail "crewmate window was not created"
  [ "$idx" -ge 3 ] || fail "crewmate window landed at occupied index $idx instead of next free (>=3)"
  pass "session-target form creates the crewmate window at the next free index ($idx)"
}

# 3. The failure the fix avoids is real: targeting an occupied window index fails with the
#    exact "index N in use" error from the bug report, which session-only targeting sidesteps.
test_occupied_index_target_is_rejected() {
  local ses=BUG out st
  build_session "$ses"
  out=$(tmux -L "$SOCK" new-window -d -t "$ses:0" -n fm-crew-test -c "$ROOT" 2>&1)
  st=$?
  [ "$st" -ne 0 ] || fail "targeting occupied index 0 should fail, but it succeeded"
  printf '%s\n' "$out" | grep -Fq 'index 0 in use' \
    || fail "expected 'index N in use' failure, got: $out"
  pass "targeting an occupied window index fails 'index 0 in use' (the bug the fix avoids)"
}

test_source_uses_session_target
test_session_target_picks_next_free
test_occupied_index_target_is_rejected
