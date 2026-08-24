#!/usr/bin/env bash
# tests/fm-totmann.test.sh - the dead-man revival must judge liveness from
# structural evidence and only ever touch its one target window:
#
#   1. A live session-lock pid means alive - even with a bare-shell pane.
#   2. A pane with a live child process means alive without any lock.
#   3. A bare-shell pane plus a dead lock pid means dead; `check` types the
#      relaunch into the target window exactly once (debounce), and the
#      unrelated worker window never receives it.
#   4. Divergence is asserted in both directions (alive cases revive nothing).
#   5. A missing tmux session is recreated and revived (the reboot path).
#   6. A present fleet stop does not block the revival (leadership returns;
#      the stop keeps everything else down).
#
# Isolation: throwaway FM_HOME and a private tmux server (-L socket); the
# notifier is disabled. Nothing touches the live fleet.
# shellcheck disable=SC2015 # ok/fail are echo-only, so `A && ok || fail` cannot misfire.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOTMANN="$REPO/bin/fm-totmann.sh"
TMP="$(mktemp -d)"
SOCK="totmann-test-$$"
trap 'tmux -L "$SOCK" kill-server 2>/dev/null; rm -rf "$TMP"' EXIT
HOME_A="$TMP/home"
mkdir -p "$HOME_A/state"

FAILS=0
fail() { echo "FAIL: $1" >&2; FAILS=$((FAILS + 1)); }
ok() { echo "ok: $1"; }

run() {
  FM_HOME="$HOME_A" FM_TOTMANN_TMUX="-L $SOCK" FM_TOTMANN_TARGET="fmtest:0" \
  FM_TOTMANN_RELAUNCH_CMD="echo REVIVED >> $TMP/revive.log" FM_TOTMANN_NOTIFY="" \
  FM_TOTMANN_DEBOUNCE=1800 "$TOTMANN" "$@"
}
revive_count() { [ -f "$TMP/revive.log" ] && wc -l < "$TMP/revive.log" | tr -d ' ' || echo 0; }
wait_for_count() { # wait_for_count <n> -> 0 when revive.log reaches n lines
  for _ in $(seq 1 50); do
    [ "$(revive_count)" = "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

tmux -L "$SOCK" new-session -d -s fmtest -c "$TMP" || { echo "tmux unavailable" >&2; exit 1; }
tmux -L "$SOCK" new-window -t fmtest:1 -n worker -c "$TMP"

# --- 1. live lock pid -> alive, even with a bare-shell pane ----------------
sleep 300 &
LOCK_PID=$!
echo "$LOCK_PID" > "$HOME_A/state/.lock"
if run status >/dev/null; then
  ok "live lock pid reads as alive"
else
  fail "a live lock pid must read as alive"
fi
run check >/dev/null || fail "check on an alive session must exit 0"
[ "$(revive_count)" = 0 ] && ok "an alive session is never revived" \
  || fail "check must not revive an alive session"

# --- 2. pane child process -> alive without any lock -----------------------
kill "$LOCK_PID" 2>/dev/null; wait "$LOCK_PID" 2>/dev/null
tmux -L "$SOCK" send-keys -t fmtest:0 'sleep 300' Enter
for _ in $(seq 1 50); do
  pane_pid="$(tmux -L "$SOCK" display-message -p -t fmtest:0 '#{pane_pid}')"
  pgrep -P "$pane_pid" >/dev/null 2>&1 && break
  sleep 0.1
done
if run status >/dev/null; then
  ok "a pane with a live child reads as alive (dead lock pid ignored)"
else
  fail "a pane child must read as alive"
fi
tmux -L "$SOCK" send-keys -t fmtest:0 C-c

# --- 3. bare shell + dead lock -> dead; revive once, target window only ----
for _ in $(seq 1 50); do
  pane_pid="$(tmux -L "$SOCK" display-message -p -t fmtest:0 '#{pane_pid}')"
  pgrep -P "$pane_pid" >/dev/null 2>&1 || break
  sleep 0.1
done
if run status >/dev/null 2>&1; then
  fail "a bare shell with a dead lock pid must read as dead"
else
  ok "bare shell plus dead lock pid reads as dead"
fi
run check >/dev/null || fail "check on a dead session must revive and exit 0"
wait_for_count 1 && ok "the relaunch command reached the target window" \
  || fail "the relaunch command must reach the target window (got $(revive_count))"
run check >/dev/null || fail "the debounced second check must exit 0"
sleep 0.5
[ "$(revive_count)" = 1 ] && ok "the debounce prevents a second revival" \
  || fail "a second check inside the debounce must not revive again"
if tmux -L "$SOCK" capture-pane -p -t fmtest:1 | grep -q REVIVED; then
  fail "the worker window must never receive the relaunch"
else
  ok "the worker window stays untouched"
fi

# --- 5. missing session is recreated (the reboot path) ---------------------
tmux -L "$SOCK" kill-server 2>/dev/null
rm -f "$HOME_A/state/.totmann-last-restart" "$TMP/revive.log"
run check >/dev/null || fail "check after a server loss must revive and exit 0"
tmux -L "$SOCK" has-session -t fmtest 2>/dev/null && ok "the session is recreated after a reboot" \
  || fail "check must recreate the missing session"
wait_for_count 1 && ok "the recreated session receives the relaunch" \
  || fail "the recreated session must receive the relaunch"

# --- 6. a fleet stop does not block the leadership revival -----------------
FM_HOME="$HOME_A" "$REPO/bin/fm-fleet-stop.sh" set --wortlaut "Alle Heime alles stoppen." >/dev/null
rm -f "$HOME_A/state/.totmann-last-restart" "$TMP/revive.log"
tmux -L "$SOCK" kill-server 2>/dev/null
run check >/dev/null || fail "check under a fleet stop must still revive"
wait_for_count 1 && ok "the fleet stop does not block the leadership revival" \
  || fail "the revival must run under a fleet stop"

echo
if [ "$FAILS" -eq 0 ]; then
  echo "fm-totmann.test.sh: all checks passed"
  exit 0
fi
echo "fm-totmann.test.sh: $FAILS check(s) FAILED"
exit 1
