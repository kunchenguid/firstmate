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

# fake-term.py <cap-file> <slave-name-file> <answer|silent> [cmd...] - a
# terminal emulator on a pty: writes the slave path, appends every output byte
# to the capture file, and in "answer" mode replies to the OSC 7501 capability
# query like a 7501-aware terminal would. A trailing command runs as the
# pane's shell: its own session with the pty as controlling terminal, so its
# /dev/tty is this terminal. Runs until killed.
cat >"$DRIVER" <<'PY'
import fcntl, os, pty, select, sys, termios, time

cap_path, slave_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
master, slave = pty.openpty()
with open(slave_path, "w") as f:
    f.write(os.ttyname(slave))
if len(sys.argv) > 4 and os.fork() == 0:
    os.close(master)
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    os.execvp(sys.argv[4], sys.argv[4:])
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
start_term() { # <dir> <mode> [cmd...]
  local dir=$1 mode=$2
  shift 2
  : >"$dir/cap"
  python3 "$DRIVER" "$dir/cap" "$dir/slave" "$mode" "$@" &
  TERM_PID=$!
  local i=0
  while [ ! -s "$dir/slave" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$dir/slave" ] || fail "fake terminal did not create the pty"
  TERM_SLAVE=$(cat "$dir/slave")
}
stop_term() { kill "$TERM_PID" 2>/dev/null; wait "$TERM_PID" 2>/dev/null || true; }

# Strip every env var that could make the pane look known-aware or
# known-unaware, so the tests below control detection explicitly.
CLEAN_UNSET=(-u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE -u HC_SESSION
  -u HC_SOCKET -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION
  -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID
  -u REX_BLOCK -u REX_SESSION -u TERM_PROGRAM)
clean_env() { # <cmd...>
  env "${CLEAN_UNSET[@]}" "$@"
}

mkhome() { # <dir>: a minimal config/state pair
  mkdir -p "$1/config" "$1/state"
}

busy_rec() { # <state-dir> <id> <busy|idle> [ts]: one armed busy-state record
  printf 'g1\n' >"$1/$2.busy-gen"
  printf 'v1 gen=g1 seq=1 state=%s source=fm-spawn event=test ts=%s\n' \
    "$3" "${4:-$(date +%s)}" >"$1/$2.busy-state"
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
    --task t1 --harness opencode --backend tmux --kind ship \
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
    --task t2 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  assert_present "$(echo "$d/state"/.osc7501watch-* | head -1)" "aware: watcher pidfile recorded"
  busy_rec "$d/state" t2 busy
  wait_cap 'state=working' "$d/cap" 60 || fail "aware: no working record emitted"
  grep -F -- 'state=working:app=firstmate-opencode' "$d/cap" >/dev/null \
    || fail "aware: working record missing app=firstmate-opencode"
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
    bash "$SCRIPT" watch --task t3 --kind ship --state "$d/state" --harness opencode \
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
  busy_rec "$d/state" t4 busy
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t4 --kind ship --state "$d/state" --harness opencode \
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
    --task t7 --harness opencode --backend tmux --kind ship \
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
    --task t8 --harness opencode --backend tmux --kind ship \
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
    --task t9 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  sleep 0.3
  assert_present "$(echo "$d/state"/.osc7501watch-* | head -1)" "hc env: watcher armed without a query"
  local cap
  cap=$(cat "$d/cap" 2>/dev/null)
  assert_equals "" "$cap" "hc env: no capability probe sent to a known-aware terminal"
  stop_term
  pass "known-aware: HC_TERMINAL_ID arms with no capability probe"
}

# --- watcher lifecycle -------------------------------------------------------

watcher_pid() { # <state-dir> -> the one recorded watcher pid
  local f
  for f in "$1"/.osc7501watch-*; do
    [ -f "$f" ] || continue
    read -r pid _ <"$f" && printf '%s' "$pid"
    return 0
  done
  return 1
}

wait_gone() { # <pid>
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done
  ! kill -0 "$1" 2>/dev/null
}

# Two panes of one home, each arming through its own real controlling
# terminal (/dev/tty, no stand-in): the second launch must not retire the
# first pane's reporter, and each terminal reports its own task.
t_concurrent_panes_keep_their_reporters() {
  local d=$TMP_ROOT/twopanes a b pane
  mkhome "$d"
  busy_rec "$d/state" ta busy
  busy_rec "$d/state" tb busy
  for pane in a b; do
    mkdir -p "$d/$pane"
    # shellcheck disable=SC2016
    start_term "$d/$pane" silent env "${CLEAN_UNSET[@]}" HC_TERMINAL_ID="$pane" FM_OSC7501_INTERVAL=1 \
      bash -c 'echo $$ >"$5"; bash "$1" arm --task "$4" --harness opencode --backend tmux --kind ship --state "$2" --config "$3"; exec sleep 300' \
      _ "$SCRIPT" "$d/state" "$d/config" "t$pane" "$d/$pane/shell"
    eval "$pane=\$TERM_PID"
    wait_cap "$(printf 'fm-t%s' "$pane" | base64 | tr -d '\n')" "$d/$pane/cap" 60 || fail "pane $pane: no record for t$pane"
  done
  local pids pid
  pids=$(cat "$d/state"/.osc7501watch-* 2>/dev/null | awk '{print $1}')
  assert_equals 2 "$(printf '%s\n' "$pids" | grep -c .)" "one reporter per controlling terminal"
  for pid in $pids; do kill -0 "$pid" 2>/dev/null || fail "a pane's reporter was retired by the other pane's launch"; done
  for pid in $pids; do kill "$pid" 2>/dev/null; done
  kill "$(cat "$d/a/shell")" "$(cat "$d/b/shell")" 2>/dev/null || true
  TERM_PID=$a stop_term
  TERM_PID=$b stop_term
  pass "concurrent panes: each controlling terminal keeps its own reporter"
}

# The pane shell outlives the agent: the launch's disarm after the agent
# returns must retire the reporter and park the record, not leave working.
t_disarm_after_agent_exit_parks_idle() {
  local d=$TMP_ROOT/disarm
  mkhome "$d"
  start_term "$d" answer
  busy_rec "$d/state" t10 busy
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 bash "$SCRIPT" arm \
    --task t10 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  local wpid
  wpid=$(watcher_pid "$d/state") || fail "disarm: no watcher armed"
  wait_cap 'state=working' "$d/cap" 60 || fail "disarm: no working record"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" disarm --state "$d/state"
  wait_gone "$wpid" || fail "disarm left the reporter running"
  local tail
  tail=$(tail -c 4000 "$d/cap" | grep -o 'state=[a-z]*' | tail -1)
  assert_equals "state=idle" "$tail" "disarm parks the record at idle"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] || fail "disarm left the pidfile behind"
  stop_term
  pass "lifecycle: disarm after the agent exits retires the reporter"
}

# A relaunch on the same pane retires the old reporter before any gate: a
# same-task relaunch rebinds a fresh reporter, and a natively reporting agent
# gets the pane with no firstmate writer left.
t_rearm_retires_previous_reporter() {
  local d=$TMP_ROOT/rearm
  mkhome "$d"; mkfake "$d" claude 'claude 2.1.295'
  start_term "$d" answer
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x bash "$SCRIPT" arm \
    --task t11 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  local first second
  first=$(watcher_pid "$d/state") || fail "rearm: no first watcher"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x bash "$SCRIPT" arm \
    --task t11 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  second=$(watcher_pid "$d/state") || fail "rearm: same-task relaunch armed no watcher"
  [ "$first" != "$second" ] || fail "rearm: same-task relaunch kept the old reporter"
  wait_gone "$first" || fail "rearm: old reporter still running after same-task relaunch"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x PATH="$d/bin:$PATH" \
    bash "$SCRIPT" arm --task t11 --harness claude --backend tmux --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin claude
  wait_gone "$second" || fail "rearm: native relaunch left the firstmate reporter running"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] || fail "rearm: native relaunch armed a watcher"
  stop_term
  pass "lifecycle: relaunch retires the previous reporter before native/off gates"
}

# A done declaration yields to a steer that came after it: a newer busy turn
# reads as working, and a pending message beside an idle record as steering.
t_activity_after_done_and_idle_inbox() {
  local d=$TMP_ROOT/steer now
  mkhome "$d"
  start_term "$d" answer
  sleep 300 &
  local holder=$!
  now=$(date +%s)
  busy_rec "$d/state" t12 busy "$((now - 20))"
  printf 'done [at=%s]: PR https://example.test/pr/2\n' "$((now - 10))" >"$d/state/t12.status"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t12 --kind ship --state "$d/state" --harness opencode \
    --parent "$holder" &
  local wpid=$!
  wait_cap 'state=done' "$d/cap" 60 || fail "steer: done not reported"
  busy_rec "$d/state" t12 busy "$now"
  wait_cap 'state=working' "$d/cap" 60 || fail "steer: a busy turn after done still reads done"
  : >"$d/cap"
  busy_rec "$d/state" t12 idle "$((now + 1))"
  wait_cap 'state=idle' "$d/cap" 60 || fail "steer: the finished follow-up turn did not read idle"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  local states
  states=$(grep -o 'state=[a-z]*' "$d/cap" | sort -u | tr '\n' ' ')
  assert_equals "state=idle " "$states" "a retired done never reappears, live or as the final record"
  : >"$d/cap"
  rm -f "$d/state/t12.status"
  busy_rec "$d/state" t12 idle "$now"
  mkdir -p "$d/state/t12.inbox"
  printf 'steer\n' >"$d/state/t12.inbox/1.msg"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t12 --kind ship --state "$d/state" --harness opencode \
    --parent "$holder" &
  wpid=$!
  wait_cap "msg=$(printf 'Steering received' | base64 | tr -d '\n')" "$d/cap" 60 \
    || fail "steer: a pending message beside an idle record did not read as steering"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  stop_term
  pass "mapping: later activity overrides done; idle + inbox reads as steering"
}

tty_input_mode() { # <tty> -> canonical-input and echo flags as stty names them
  stty -a <"$1" | tr -s ' \t;' '\n' | grep -Ex -- '-?(icanon|echo)' | sort
}

# A steer the worker acknowledged and finished between two polls - the busy
# snapshot never observed - still retires the earlier failure.
t_handled_steer_retires_failure() {
  local d=$TMP_ROOT/handled now
  mkhome "$d"
  start_term "$d" answer
  sleep 300 &
  local holder=$!
  now=$(date +%s)
  busy_rec "$d/state" t15 idle "$((now - 20))"
  printf 'failed [at=%s]: tests red\n' "$((now - 10))" >"$d/state/t15.status"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t15 --kind ship --state "$d/state" --harness opencode \
    --parent "$holder" &
  local wpid=$!
  wait_cap 'state=error' "$d/cap" 60 || fail "handled: failed not reported"
  : >"$d/cap"
  mkdir -p "$d/state/t15.inbox/handled"
  printf 'retry\n' >"$d/state/t15.inbox/handled/1.msg"
  busy_rec "$d/state" t15 idle "$((now + 1))"
  wait_cap 'state=idle' "$d/cap" 60 || fail "handled: an acknowledged follow-up left the old error up"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  assert_equals "state=idle " "$(grep -o 'state=[a-z]*' "$d/cap" | sort -u | tr '\n' ' ')" \
    "a retired failure never reappears, live or as the final record"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  stop_term
  pass "mapping: an acknowledged follow-up steer retires an earlier failure"
}

# Cursor arms no busy-state record; its own conversation transcript is the
# activity source, and the worker's working: line supplies the message.
t_cursor_transcript_drives_activity() {
  local d=$TMP_ROOT/cursor proj conv
  mkhome "$d"
  start_term "$d" answer
  sleep 300 &
  local holder=$!
  proj=$d/cursor-projects/p1
  conv=$proj/agent-transcripts/c1/c1.jsonl
  mkdir -p "${conv%/*}"
  printf '{"workspacePath":"%s"}\n' "$d/ws" >"$proj/.workspace-trusted"
  printf 'projects_root=%s\nworkspace_root=%s\n' "$d/cursor-projects" "$d/ws" >"$d/state/t16.cursor-session"
  printf '{"role":"user"}\n' >"$conv"
  printf 'working [at=%s]: rebasing\n' "$(date +%s)" >"$d/state/t16.status"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t16 --kind ship --state "$d/state" --harness cursor \
    --parent "$holder" &
  local wpid=$!
  wait_cap "state=working:app=firstmate-cursor:title=$(printf 'fm-t16' | base64 | tr -d '\n'):msg=$(printf 'rebasing' | base64 | tr -d '\n')" "$d/cap" 60 \
    || fail "cursor: an open transcript turn did not read as working with the working: note"
  printf '{"type":"turn_ended"}\n' >>"$conv"
  wait_cap 'state=idle' "$d/cap" 60 || fail "cursor: a closed transcript turn did not read as idle"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  stop_term
  pass "activity: a cursor worker reports from its transcript, with its working: note"
}

set_mtime_ns() { # <file> <ns>: exact file time, to order events inside one second
  python3 -c 'import os, sys; n = int(sys.argv[2]); os.utime(sys.argv[1], ns=(n, n))' "$1" "$2"
}

# A pulled cursor transcript records no turn start: a done posted inside a
# follow-up turn the reporter first sees busy must stand, not be retired by
# the poll that happened to observe the turn.
t_cursor_done_inside_observed_turn() {
  local d=$TMP_ROOT/cursordone proj conv
  mkhome "$d"
  start_term "$d" answer
  sleep 300 &
  local holder=$!
  proj=$d/cursor-projects/p1
  conv=$proj/agent-transcripts/c1/c1.jsonl
  mkdir -p "${conv%/*}"
  printf '{"workspacePath":"%s"}\n' "$d/ws" >"$proj/.workspace-trusted"
  printf 'projects_root=%s\nworkspace_root=%s\n' "$d/cursor-projects" "$d/ws" >"$d/state/t18.cursor-session"
  printf '{"role":"user"}\n{"type":"turn_ended"}\n' >"$conv"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t18 --kind ship --state "$d/state" --harness cursor \
    --parent "$holder" &
  local wpid=$!
  wait_cap 'state=idle' "$d/cap" 60 || fail "cursordone: idle transcript not reported"
  : >"$d/cap"
  printf 'done [at=%s]: PR https://example.test/pr/3\n' "$(($(date +%s) - 1))" >"$d/state/t18.status"
  printf '{"role":"user"}\n' >>"$conv"
  wait_cap 'state=done' "$d/cap" 60 || fail "cursordone: done inside the observed turn was not reported"
  printf '{"type":"turn_ended"}\n' >>"$conv"
  sleep 2
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  assert_equals "state=done " "$(grep -o 'state=[a-z]*' "$d/cap" | sort -u | tr '\n' ' ')" \
    "a done posted in the observed turn stands, live and as the final record"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  stop_term
  pass "mapping: a cursor turn observed busy never retires a done posted inside it"
}

# A retry steer enqueued, acknowledged, and finished within the failure's own
# second still retires it: ordering uses the files' nanosecond times.
t_same_second_steer_retires_failure() {
  local d=$TMP_ROOT/samesec t
  mkhome "$d"
  start_term "$d" answer
  sleep 300 &
  local holder=$!
  t=$(date +%s)
  busy_rec "$d/state" t19 idle "$t"
  set_mtime_ns "$d/state/t19.busy-state" "${t}900000000"
  printf 'failed [at=%s]: tests red\n' "$t" >"$d/state/t19.status"
  set_mtime_ns "$d/state/t19.status" "${t}100000000"
  mkdir -p "$d/state/t19.inbox/handled"
  printf 'retry\n' >"$d/state/t19.inbox/handled/1.msg"
  set_mtime_ns "$d/state/t19.inbox/handled/1.msg" "${t}500000000"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t19 --kind ship --state "$d/state" --harness opencode \
    --parent "$holder" &
  local wpid=$!
  wait_cap 'state=idle' "$d/cap" 60 || fail "samesec: the same-second retry left the failure up"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  assert_equals "state=idle " "$(grep -o 'state=[a-z]*' "$d/cap" | sort -u | tr '\n' ' ')" \
    "a failure retired within its own second never shows"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  stop_term
  pass "mapping: a steer within the failure's own second still retires it"
}

# A reporter still folding a long status history when its pane is relaunched
# finishes that fold and its final record late; the replacement must not arm
# until it is gone, so none of its writes can land after the handoff.
t_retire_waits_for_slow_reporter() {
  local d=$TMP_ROOT/slow first second i
  mkhome "$d"
  start_term "$d" answer
  for i in $(seq 1 100); do
    printf 'needs-decision [at=%s] [key=k%s]: q%s\nresolved [at=%s] [key=k%s]: a%s\n' "$i" "$i" "$i" "$i" "$i" "$i"
  done >"$d/state/t17.status"
  busy_rec "$d/state" t17 busy
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x FM_OSC7501_INTERVAL=1 bash "$SCRIPT" arm \
    --task t17 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  first=$(watcher_pid "$d/state") || fail "slow: no first watcher"
  wait_cap 'state=working' "$d/cap" 200 || fail "slow: the first reporter never reported"
  clean_env env FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x FM_OSC7501_INTERVAL=1 bash "$SCRIPT" arm \
    --task t17 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  if kill -0 "$first" 2>/dev/null; then
    kill -KILL "$first" 2>/dev/null
    fail "slow: replacement armed while the old reporter could still write"
  fi
  second=$(watcher_pid "$d/state") || fail "slow: no replacement watcher"
  [ "$first" != "$second" ] || fail "slow: replacement reused the old reporter"
  kill -KILL "$second" 2>/dev/null
  wait_gone "$second" || true
  stop_term
  pass "lifecycle: relaunch confirms the old reporter is gone before arming"
}

# A launch interrupted while the capability query holds the terminal raw
# must leave the pane's canonical input and echo as it found them.
t_interrupted_query_restores_mode() {
  local d=$TMP_ROOT/intr before after apid
  mkhome "$d"
  start_term "$d" silent
  before=$(tty_input_mode "$TERM_SLAVE")
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_QUERY_DS=20 bash "$SCRIPT" arm \
    --task t13 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config" &
  apid=$!
  wait_cap "$Q" "$d/cap" 60 || fail "interrupt: query never sent"
  kill -TERM "$apid"
  wait "$apid" 2>/dev/null || true
  after=$(tty_input_mode "$TERM_SLAVE")
  assert_equals "$(printf 'echo\nicanon')" "$before" "pane starts canonical with echo"
  assert_equals "$before" "$after" "interrupted query restores canonical input and echo"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] || fail "interrupt: an interrupted arm spawned a watcher"
  stop_term
  pass "query safety: an interrupted probe restores the terminal mode"
}

# An hc terminal opened from inside a herdr session inherits HERDR_* markers;
# its own HC_TERMINAL_ID still makes it a known-aware reporter.
t_hc_terminal_with_inherited_herdr_markers() {
  local d=$TMP_ROOT/hcinherit
  mkhome "$d"
  start_term "$d" silent
  clean_env env HC_TERMINAL_ID=t-2 HERDR_ENV=1 HERDR_PANE_ID=p-1 \
    FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" arm \
    --task t14 --harness opencode --backend hc --kind ship \
    --state "$d/state" --config "$d/config"
  local wpid
  wpid=$(watcher_pid "$d/state") || fail "hc inside herdr: no watcher armed"
  assert_equals "" "$(cat "$d/cap" 2>/dev/null)" "hc inside herdr: no capability probe"
  kill "$wpid" 2>/dev/null
  wait_gone "$wpid" || true
  stop_term
  pass "known-aware: an hc terminal reports despite inherited HERDR markers"
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
  t_known_aware_skips_query \
  t_concurrent_panes_keep_their_reporters \
  t_disarm_after_agent_exit_parks_idle \
  t_rearm_retires_previous_reporter \
  t_activity_after_done_and_idle_inbox \
  t_handled_steer_retires_failure \
  t_cursor_transcript_drives_activity \
  t_cursor_done_inside_observed_turn \
  t_same_second_steer_retires_failure \
  t_retire_waits_for_slow_reporter \
  t_interrupted_query_restores_mode \
  t_hc_terminal_with_inherited_herdr_markers
