#!/usr/bin/env bash
# tests/fm-osc7501.test.sh - behavioral tests for the worker-side OSC 7501
# reporter (bin/fm-osc7501.sh). Every assertion is on observable terminal
# behavior: the bytes a real terminal would receive across a pty, the
# presence or absence of the watcher process, and the records emitted as
# firstmate's durable signals (status file, busy-state, inbox) change. The
# pty fake-terminal both captures output and answers the capability query.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (pty fake-terminal)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-osc7501-tests)
SCRIPT=$ROOT/bin/fm-osc7501.sh
DRIVER=$TMP_ROOT/fake-term.py
Q=$'\033]7501;?\033\\'

# fake-term.py <cap-file> <slave-name-file> <answer|silent> - a terminal
# emulator on a pty: writes the slave path, appends every output byte to the
# capture file, and in "answer" mode replies to the OSC 7501 capability query
# like a 7501-aware terminal would. Runs until killed.
cat >"$DRIVER" <<'PY'
import os, pty, select, sys, time

cap_path, slave_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
master, slave = pty.openpty()
with open(slave_path, "w") as f:
    f.write(os.ttyname(slave))
cap = open(cap_path, "ab", buffering=0)
seen = 0
query = b"\x1b]7501;?\x1b\\"
reply = b"\x1b]7501;state=idle\x1b\\"
answered = False
buf = b""
while True:
    r, _, _ = select.select([master], [], [], 0.1)
    if not r:
        continue
    try:
        data = os.read(master, 65536)
    except OSError:
        break
    if not data:
        break
    cap.write(data)
    buf += data
    if mode == "answer" and not answered and query in buf:
        os.write(master, reply)
        answered = True
        buf = b""
PY

# start_term <dir> <answer|silent> -> sets TERM_SLAVE + TERM_CAP, leaves the
# emulator running. TERM_PID kills it; run from a test's subshell scope.
start_term() { # <dir> <mode>
  local dir=$1
  : >"$dir/cap"
  python3 "$DRIVER" "$dir/cap" "$dir/slave" "$2" &
  TERM_PID=$!
  local i=0
  while [ ! -s "$dir/slave" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$dir/slave" ] || fail "fake terminal did not create the pty"
  TERM_SLAVE=$(cat "$dir/slave")
}
stop_term() { kill "$TERM_PID" 2>/dev/null; wait "$TERM_PID" 2>/dev/null || true; }

# Strip every env var that could make the pane look known-aware or
# known-unaware, so the tests below control detection explicitly.
clean_env() { # <cmd...>
  env -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE -u HC_SESSION \
    -u HC_SOCKET -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
    -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u REX_BLOCK -u REX_SESSION -u TERM_PROGRAM "$@"
}

mkhome() { # <dir>: a minimal config/state pair
  mkdir -p "$1/config" "$1/state"
}

wait_cap() { # <needle-file-content> <cap> <seconds>: fixed string appears
  local needle=$1 cap=$2 tries=${3:-40} i=0
  while ! grep -F -- "$needle" "$cap" >/dev/null 2>&1; do
    [ "$i" -ge "$tries" ] && return 1
    sleep 0.1; i=$((i + 1))
  done
}

# --- capability query -------------------------------------------------------

# An unaware terminal (never answers the query) gets exactly one probe and no
# watcher; the probe is the only byte the terminal ever sees.
t_query_unaware_terminal_silent() {
  local d=$TMP_ROOT/unaware
  mkhome "$d"
  start_term "$d" silent
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" arm \
    --task t1 --harness codex --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  sleep 0.3
  stop_term
  assert_present "$d/cap" "unaware: capture file"
  local cap
  cap=$(cat "$d/cap")
  assert_equals "$Q" "$cap" "unaware terminal sees only the one capability probe"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] || fail "unaware terminal spawned a watcher"
  pass "capability query: silent terminal gets one probe, no watcher"
}

# A terminal that answers the query arms the watcher, which reports the
# worker's state derived from the busy-state signal.
t_query_answered_arms_watcher() {
  local d=$TMP_ROOT/aware
  mkhome "$d"
  start_term "$d" answer
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" arm \
    --task t2 --harness codex --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  assert_present "$(echo "$d/state"/.osc7501watch-* | head -1)" "aware: watcher pidfile recorded"
  printf 'state=busy\n' >"$d/state/t2.busy-state"
  wait_cap 'state=working' "$d/cap" 60 || fail "aware: no working record emitted"
  grep -F -- 'state=working:app=firstmate-codex' "$d/cap" >/dev/null \
    || fail "aware: working record missing app=firstmate-codex"
  wait_cap "$(printf 'title=%s' "$(printf 'fm-t2' | base64 | tr -d '\n')")" "$d/cap" 10 \
    || fail "aware: working record missing title=fm-t2"
  stop_term
  pass "capability query: answering terminal arms watcher emitting working"
}

# --- emission / state mapping ------------------------------------------------

# The durable status line drives the record: needs-decision -> blocked
# kind=question, then done survives worker exit as the final record.
t_status_transitions_and_final_done() {
  local d=$TMP_ROOT/trans
  mkhome "$d"
  start_term "$d" answer
  local holder
  sleep 300 &
  holder=$!
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t3 --kind ship --state "$d/state" --harness codex \
    --parent "$holder" &
  local wpid=$!
  printf 'needs-decision [at=1]: ship it?\n' >"$d/state/t3.status"
  wait_cap 'state=blocked:kind=question' "$d/cap" 60 \
    || fail "transition: needs-decision did not emit blocked kind=question"
  printf 'done [at=2]: PR https://example.test/pr/1\n' >"$d/state/t3.status"
  wait_cap 'state=done' "$d/cap" 60 || fail "transition: done did not emit state=done"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  local i=0
  while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$wpid" 2>/dev/null && fail "watcher did not exit after parent death"
  wait "$wpid" 2>/dev/null || true
  local tail
  tail=$(tail -c 4000 "$d/cap" | grep -o 'state=[a-z]*' | tail -1)
  assert_equals "state=done" "$tail" "final record keeps the done result"
  stop_term
  pass "status transitions: blocked->done, final record survives parent death"
}

# A worker that dies mid-task leaves no working/blocked ghost: the watcher's
# final record parks the pane at idle.
t_final_idle_after_working() {
  local d=$TMP_ROOT/park
  mkhome "$d"
  start_term "$d" answer
  sleep 300 &
  local holder=$!
  printf 'state=busy\n' >"$d/state/t4.busy-state"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t4 --kind ship --state "$d/state" --harness codex \
    --parent "$holder" &
  local wpid=$!
  wait_cap 'state=working' "$d/cap" 60 || fail "park: no working record"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  local i=0
  while kill -0 "$wpid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
  wait "$wpid" 2>/dev/null || true
  local tail
  tail=$(tail -c 4000 "$d/cap" | grep -o 'state=[a-z]*' | tail -1)
  assert_equals "state=idle" "$tail" "worker exit parks the record at idle"
  stop_term
  pass "cleanup: worker exit emits a final idle, no stale working ghost"
}

# --- native reporting gate ----------------------------------------------------

mkfake() { # <dir> <name> <version-out>
  mkdir -p "$1/bin"
  printf '#!/usr/bin/env bash\necho "%s"\n' "$3" >"$1/bin/$2"
  chmod +x "$1/bin/$2"
}

# A claude new enough to report natively must not trigger the generic
# reporter - not even the capability probe reaches the terminal.
t_native_claude_skips_everything() {
  local d=$TMP_ROOT/native
  mkhome "$d"; mkfake "$d" claude 'claude 2.1.295'
  start_term "$d" answer
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" \
    PATH="$d/bin:$PATH" bash "$SCRIPT" arm \
    --task t5 --harness claude --backend tmux --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin claude
  sleep 0.3
  stop_term
  local cap
  cap=$(cat "$d/cap" 2>/dev/null)
  assert_equals "" "$cap" "native claude: terminal must see zero bytes (no query, no record)"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] || fail "native claude spawned a watcher"
  pass "native gate: claude >= 2.1.295 emits no probe and arms no watcher"
}

# An old claude below the native floor falls through to the generic reporter.
t_old_claude_uses_generic() {
  local d=$TMP_ROOT/oldclaude
  mkhome "$d"; mkfake "$d" claude 'claude 1.9.9'
  start_term "$d" answer
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" \
    PATH="$d/bin:$PATH" bash "$SCRIPT" arm \
    --task t6 --harness claude --backend tmux --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin claude
  assert_present "$(echo "$d/state"/.osc7501watch-* | head -1)" "old claude armed the generic watcher"
  stop_term
  pass "native gate: claude below the floor uses the generic reporter"
}

# --- no corruption ------------------------------------------------------------

# A terminal that answers late-ish still has its whole reply consumed inside
# the query window: whatever a program reads next sees no escape-shaped
# leftovers. The emulator's reply is written as one burst; a second read
# after arm must get nothing.
t_reply_drained_for_next_program() {
  local d=$TMP_ROOT/drain
  mkhome "$d"
  start_term "$d" answer
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" arm \
    --task t7 --harness codex --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  # the arm armed a watcher; everything since must be complete records only:
  # each sequence is ESC ] 7501 ; ... ESC \ with no bare ESC or split junk.
  sleep 1
  stop_term
  local bad
  bad=$(python3 - "$d/cap" <<'PY'
import re, sys
data = open(sys.argv[1], "rb").read()
stripped = re.sub(rb"\x1b\]7501;[^\x1b]*\x1b\\", b"", data)
sys.stdout.write("clean" if stripped == b"" else repr(stripped))
PY
)
  assert_equals "clean" "$bad" "output stream contains only complete OSC 7501 records"
  pass "no corruption: capture holds only whole OSC 7501 records, no stray escapes"
}

# --- config gate ---------------------------------------------------------------

t_config_off_disables() {
  local d=$TMP_ROOT/cfgoff
  mkhome "$d"; printf 'off\n' >"$d/config/osc7501-status"
  start_term "$d" answer
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" arm \
    --task t8 --harness codex --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  sleep 0.3
  stop_term
  local cap
  cap=$(cat "$d/cap" 2>/dev/null)
  assert_equals "" "$cap" "config off: terminal sees nothing at all"
  pass "config gate: osc7501-status=off disables arm entirely"
}

# A known-aware environment (herdr-core's HC_TERMINAL_ID) skips the query and
# still arms the watcher: no probe bytes on the wire.
t_known_aware_skips_query() {
  local d=$TMP_ROOT/hc
  mkhome "$d"
  start_term "$d" silent
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u REX_BLOCK -u REX_SESSION \
    -u TERM_PROGRAM \
    HC_TERMINAL_ID=t-1 FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" arm \
    --task t9 --harness codex --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  sleep 0.3
  assert_present "$(echo "$d/state"/.osc7501watch-* | head -1)" "hc env: watcher armed without a query"
  local cap
  cap=$(cat "$d/cap" 2>/dev/null)
  assert_equals "" "$cap" "hc env: no capability probe sent to a known-aware terminal"
  stop_term
  pass "known-aware: HC_TERMINAL_ID arms with no capability probe"
}

fm_test_run \
  t_query_unaware_terminal_silent \
  t_query_answered_arms_watcher \
  t_status_transitions_and_final_done \
  t_final_idle_after_working \
  t_native_claude_skips_everything \
  t_old_claude_uses_generic \
  t_reply_drained_for_next_program \
  t_config_off_disables \
  t_known_aware_skips_query
