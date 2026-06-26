#!/usr/bin/env bash
# tests/fm-guardian-present-e2e.test.sh - the always-on supervisor daemon's
# PRESENT-mode (afk OFF) liveness guardian, end to end through the real
# fm_super_main loop on a private tmux socket. This is the operator-visible proof
# of the structural fix: with work in flight and no watcher, the running daemon
# restores the watcher itself and nudges firstmate exactly once, then keeps quiet.
#
# Covers:
#   criterion 1  a missing beacon (firstmate's re-arm lapsed) is restored within a
#                tick AND firstmate gets exactly one re-arm/drain nudge.
#   criterion 3  no routine-wake injection: after the single lapse nudge, the
#                guardian stays silent while the restored watcher beats.
#   criterion 6  clean signal shutdown: SIGTERM removes the pidfile, releases the
#                lock, and tears down the forked watcher (no leak).
#
# Mode A (afk ON) injection behavior is covered by fm-afk-inject-e2e; the
# deterministic decision/cooldown/singleton units are in fm-guardian.test.sh.
#
# Isolation: a dedicated tmux socket (tmux -L) + a shim that redirects the
# daemon's bare `tmux` to it. Nothing touches the live fleet.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
SOCKET="fm-guardian-e2e-$$"
STATE_DIR=
TMUX_SHIM_DIR=
LOG_FILE=
DAEMON_PID=
SUPERVISOR_PANE=
LOOP_SCRIPT=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  # Kill any watcher the guardian forked into this throwaway state.
  if [ -n "${STATE_DIR:-}" ] && [ -f "$STATE_DIR/.watch.lock/pid" ]; then
    kill "$(cat "$STATE_DIR/.watch.lock/pid" 2>/dev/null || true)" 2>/dev/null || true
  fi
  if [ -n "${SOCKET:-}" ] && [ -n "${REAL_TMUX:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  rm -rf "${TMUX_SHIM_DIR:-}" "${STATE_DIR:-}" 2>/dev/null || true
}
trap cleanup_all EXIT

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-guardian-e2e.XXXXXX")
LOG_FILE="$STATE_DIR/submitted.log"
: > "$LOG_FILE"

# Private tmux server + a supervisor pane that logs each submitted line verbatim,
# classifying a sentinel-marked (0x1f) line as an injection. Same approach as
# fm-afk-inject-e2e; the hex is computed without a PATH `od` (an Open Design `od`
# shim can shadow coreutils octal-dump).
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
SUPERVISOR_PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\x1f'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() { [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
_hex_bytes() {
  if [ -x /usr/bin/od ]; then /usr/bin/od -An -tx1
  elif command -v hexdump >/dev/null 2>&1; then hexdump -v -e '/1 "%02x"'
  else xxd -p
  fi
}
_buf=
redraw() { printf '\r\033[K%s' "$_buf"; }
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then _c="injection"; else _c="user"; fi
  _hex=$(printf '%s' "$_line" | _hex_bytes | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then submit_line; continue; fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP_SCRIPT"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$SUPERVISOR_PANE" "bash '$LOOP_SCRIPT' '$LOG_FILE'" Enter
sleep 1

TMUX_SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-guardian-shim.XXXXXX")
cat > "$TMUX_SHIM_DIR/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$TMUX_SHIM_DIR/tmux"

nudge_count() { grep -c 'supervision liveness lapsed' "$LOG_FILE" 2>/dev/null || true; }

start_daemon_present() {
  # afk deliberately NOT set: the daemon runs in Mode B (present, liveness
  # guardian). Small tick + grace so a missing beacon is an immediate lapse; a
  # long nudge cooldown so exactly-one-nudge is the logic, not test timing.
  PATH="$TMUX_SHIM_DIR:$PATH" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR_PANE" \
  FM_GUARDIAN_TICK=2 \
  FM_GUARD_GRACE=2 \
  FM_GUARDIAN_NUDGE_COOLDOWN=9999 \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_STALE_ESCALATE_SECS=999999 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.2 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2; i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file)"
  }
}

test_present_lapse_restores_and_nudges_once() {
  # Work in flight, no watcher, no beacon: firstmate's present-mode re-arm has
  # lapsed. The running daemon must restore the watcher and nudge exactly once.
  printf 'project=x\nkind=ship\n' > "$STATE_DIR/task-c1.meta"
  rm -f "$STATE_DIR/.last-watcher-beat"

  start_daemon_present

  # Within a couple guardian ticks: the beacon comes back (watcher restored) and
  # exactly one liveness nudge is submitted.
  local i=0
  while [ "$i" -lt 40 ]; do
    [ -e "$STATE_DIR/.last-watcher-beat" ] && [ "$(nudge_count)" -ge 1 ] && break
    sleep 0.5; i=$((i + 1))
  done
  [ -e "$STATE_DIR/.last-watcher-beat" ] \
    || fail "guardian did not restore the watcher beacon while present"
  [ "$(nudge_count)" -eq 1 ] \
    || fail "expected exactly one liveness nudge, got $(nudge_count)"

  # The nudge is sentinel-marked (classified injection), not a captain message.
  grep 'supervision liveness lapsed' "$LOG_FILE" | grep -q 'injection$' \
    || fail "liveness nudge was not a sentinel-marked injection"

  # criterion 3: no routine spam. The restored watcher keeps beating; over the
  # next several seconds the guardian must NOT nudge again.
  sleep 6
  [ "$(nudge_count)" -eq 1 ] \
    || fail "guardian re-nudged while the watcher was healthy (routine injection - criterion 3), count=$(nudge_count)"
  # And no spurious captain-message (user) line was ever submitted.
  [ "$(grep -c $'\tuser$' "$LOG_FILE" 2>/dev/null || true)" -eq 0 ] \
    || fail "guardian submitted a non-injection line while present"

  pass "present: a liveness lapse restores the watcher and nudges exactly once, then stays silent (criteria 1, 3)"
}

# criterion 4: afk is a policy toggle inside the ONE running process. Turning afk
# on must transition the live daemon to away mode (own the watcher, self-handle +
# escalate); turning it back off must return it to present/liveness-guardian.
test_afk_toggle_in_one_process() {
  : > "$LOG_FILE"                                   # clear the lapse nudge
  # B -> A: afk on. The same daemon takes watcher ownership and self-handles.
  date +%s > "$STATE_DIR/.afk"
  sleep 3                                           # let the 1s poll notice + take over
  echo "done: PR https://example.test/pr/777 checks green" > "$STATE_DIR/task-c1.status"
  local i=0
  while [ "$i" -lt 40 ]; do
    grep -q 'Supervisor escalate' "$LOG_FILE" && break
    sleep 0.5; i=$((i + 1))
  done
  grep -q 'Supervisor escalate' "$LOG_FILE" \
    || fail "B->A: daemon did not escalate a captain status after afk turned on (transition or away mode broke)"

  # A -> B: afk off. The same process returns to present mode and must NOT escalate
  # a routine status (present mode never injects a routine wake).
  rm -f "$STATE_DIR/.afk"
  sleep 3
  : > "$LOG_FILE"
  echo "working: still compiling" > "$STATE_DIR/task-c1.status"
  sleep 5
  grep -q 'Supervisor escalate' "$LOG_FILE" \
    && fail "A->B: daemon escalated while present (afk off) - did not return to liveness-guardian mode"
  pass "afk toggles mode in one running process: B->A self-handles+escalates, A->B returns to present (criterion 4)"
}

test_clean_shutdown_releases_and_reaps() {
  # criterion 6: SIGTERM the running daemon -> clean exit. The pidfile is removed,
  # the singleton lock is released, and the forked watcher is torn down.
  local watcher_pid
  watcher_pid=$(cat "$STATE_DIR/.watch.lock/pid" 2>/dev/null || true)
  kill -TERM "$DAEMON_PID" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 60 ] && kill -0 "$DAEMON_PID" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$DAEMON_PID" 2>/dev/null && fail "daemon did not exit on SIGTERM"
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  [ ! -e "$STATE_DIR/.supervise-daemon.pid" ] || fail "daemon left its pidfile behind after shutdown"
  [ ! -e "$STATE_DIR/.supervise-daemon.lock" ] || fail "daemon left its singleton lock behind after shutdown"
  # The forked watcher should be gone too (cleanup kills the guardian's child).
  if [ -n "$watcher_pid" ]; then
    i=0
    while [ "$i" -lt 40 ] && kill -0 "$watcher_pid" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
    kill -0 "$watcher_pid" 2>/dev/null && fail "guardian-forked watcher leaked after daemon shutdown"
  fi
  pass "clean shutdown: SIGTERM removes the pidfile + lock and reaps the forked watcher (criterion 6)"
}

test_present_lapse_restores_and_nudges_once
test_afk_toggle_in_one_process
test_clean_shutdown_releases_and_reaps

echo "all present-mode guardian e2e tests passed"
