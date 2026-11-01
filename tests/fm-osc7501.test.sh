#!/usr/bin/env bash
# tests/fm-osc7501.test.sh - behavioral tests for the worker-side OSC 7501
# reporter (bin/fm-osc7501.sh). Every assertion is on observable terminal
# behavior: the bytes a real terminal would receive across a pty, the
# presence or absence of the watcher process, and the records emitted as
# firstmate's durable signals (status file, busy-state, inbox) change. The
# pty fake-terminal captures output without sending capability replies.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (pty fake-terminal)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-osc7501-tests)
SCRIPT=$ROOT/bin/fm-osc7501.sh
DRIVER=$TMP_ROOT/fake-term.py

# fake-term.py <cap-file> <slave-name-file> [cmd...] - a terminal emulator
# on a pty: writes the slave path and captures output. A command runs as the
# pane's shell: its own session with the pty as controlling terminal, so its
# /dev/tty is this terminal. Runs until killed.
cat >"$DRIVER" <<'PY'
import fcntl, os, pty, select, sys, termios, time

cap_path, slave_path = sys.argv[1:3]
master, slave = pty.openpty()
with open(slave_path, "w") as f:
    f.write(os.ttyname(slave))
if len(sys.argv) > 3 and os.fork() == 0:
    os.close(master)
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    for fd in (0, 1, 2):
        os.dup2(slave, fd)
    os.execvp(sys.argv[3], sys.argv[3:])
cap = open(cap_path, "ab", buffering=0)
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
PY

# start_term <dir> [cmd...] -> sets TERM_SLAVE + TERM_CAP, leaves the
# emulator running. TERM_PID kills it; run from a test's subshell scope.
start_term() { # <dir> [cmd...]
  local dir=$1
  shift
  : >"$dir/cap"
  python3 "$DRIVER" "$dir/cap" "$dir/slave" "$@" &
  TERM_PID=$!
  local i=0
  while [ ! -s "$dir/slave" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$dir/slave" ] || fail "fake terminal did not create the pty"
  TERM_SLAVE=$(cat "$dir/slave")
}
stop_term() { kill "$TERM_PID" 2>/dev/null; wait "$TERM_PID" 2>/dev/null || true; }

# Strip every env var that could make the pane look known-aware or
# known-unaware, so the tests below control detection explicitly. Callers run
# `env "${CLEAN_UNSET[@]}" ...` directly so a backgrounded watcher's $! is the
# watcher itself.
CLEAN_UNSET=(-u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE -u HC_SESSION
  -u HC_SOCKET -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION
  -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID
  -u REX_BLOCK -u REX_SESSION -u TERM_PROGRAM)

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

# --- passive terminal eligibility -------------------------------------------

# Contract: unknown terminals get no bytes, no watcher, and no input reads.
# Queue actual worker input before arm; the next consumer must receive it
# unchanged. This rejects the former capability probe consuming typed input.
t_unknown_terminal_preserves_input() {
  local d=$TMP_ROOT/unaware
  mkhome "$d"
  if ! env "${CLEAN_UNSET[@]}" python3 - "$SCRIPT" "$d" <<'PYTEST'
import os, pty, select, subprocess, sys, termios
script, home = sys.argv[1:]
master, slave = pty.openpty()
mode = termios.tcgetattr(slave)
mode[3] &= ~termios.ECHO
termios.tcsetattr(slave, termios.TCSANOW, mode)
typed = b"worker input must survive startup\n"
os.write(master, typed)
env = dict(os.environ, FM_OSC7501_TTY=os.ttyname(slave))
subprocess.run(["bash", script, "arm", "--task", "t1", "--harness", "opencode",
                "--backend", "tmux", "--kind", "ship", "--state", home + "/state",
                "--config", home + "/config"], env=env, check=True, timeout=5)
assert termios.tcgetattr(slave) == mode, "arm changed terminal modes"
assert not select.select([master], [], [], 0.3)[0], "unknown terminal received output"
assert select.select([slave], [], [], 0.3)[0], "arm consumed queued worker input"
assert os.read(slave, 4096) == typed, "arm corrupted queued worker input"
os.close(slave)
os.close(master)
PYTEST
  then
    fail "unknown terminal: output or input contract violated"
  fi
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] || fail "unaware terminal spawned a watcher"
  pass "unknown terminal: no output or watcher, queued worker input untouched"
}

# A passive Ghostty marker arms the watcher, which reports the worker's
# state derived from the busy-state signal without a terminal query.
t_ghostty_arms_watcher() {
  local d=$TMP_ROOT/aware
  mkhome "$d"
  start_term "$d"
  env "${CLEAN_UNSET[@]}" TERM_PROGRAM=ghostty FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" arm \
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
  pass "passive detection: Ghostty arms watcher emitting working"
}

# --- emission / state mapping ------------------------------------------------

# The durable status line drives the record: needs-decision -> blocked
# kind=question, then done survives worker exit as the final record.
t_status_transitions_and_final_done() {
  local d=$TMP_ROOT/trans
  mkhome "$d"
  start_term "$d"
  local holder
  sleep 300 &
  holder=$!
  busy_rec "$d/state" t3 idle
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
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
  start_term "$d"
  sleep 300 &
  local holder=$!
  busy_rec "$d/state" t4 busy
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
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
  start_term "$d"
  env "${CLEAN_UNSET[@]}" HC_TERMINAL_ID=x FM_OSC7501_TTY="$TERM_SLAVE" \
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
  start_term "$d"
  env "${CLEAN_UNSET[@]}" HC_TERMINAL_ID=x FM_OSC7501_TTY="$TERM_SLAVE" \
    PATH="$d/bin:$PATH" bash "$SCRIPT" arm \
    --task t6 --harness claude --backend tmux --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin claude
  assert_present "$(echo "$d/state"/.osc7501watch-* | head -1)" "old claude armed the generic watcher"
  stop_term
  pass "native gate: claude below the floor uses the generic reporter"
}

# A natively reporting harness whose launched executable was not named must
# not get a competing reporter, even when an old copy sits on PATH.
t_native_harness_without_agent_bin_skips() {
  local d=$TMP_ROOT/noagentbin
  mkhome "$d"; mkfake "$d" claude 'claude 1.9.9'
  start_term "$d"
  env "${CLEAN_UNSET[@]}" HC_TERMINAL_ID=x FM_OSC7501_TTY="$TERM_SLAVE" \
    PATH="$d/bin:$PATH" bash "$SCRIPT" arm \
    --task t29 --harness claude --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] \
    || fail "a claude with no named executable armed a watcher from the PATH copy"
  stop_term
  pass "native gate: a native-capable harness without --agent-bin arms nothing"
}

# A harness upgraded in place across the native floor - the same symlink, its
# target rewritten with a newer binary - must be re-probed at the next launch,
# so the generic reporter stands down instead of competing with native records.
t_inplace_upgrade_reprobes_native() {
  local d=$TMP_ROOT/upgrade
  mkhome "$d"
  mkdir -p "$d/bin" "$d/install"
  printf '#!/usr/bin/env bash\necho "pi 1.0.9"\n' >"$d/install/pi"
  chmod +x "$d/install/pi"
  ln -s "$d/install/pi" "$d/bin/pi"
  start_term "$d"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x PATH="$d/bin:$PATH" \
    bash "$SCRIPT" arm --task t22 --harness pi --backend tmux --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin pi
  local first
  first=$(watcher_pid "$d/state") || fail "upgrade: pi below the floor armed no generic watcher"
  printf '#!/usr/bin/env bash\necho "pi 1.1.0"\n' >"$d/install/pi"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x PATH="$d/bin:$PATH" \
    bash "$SCRIPT" arm --task t22 --harness pi --backend tmux --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin pi
  wait_gone "$first" || fail "upgrade: the old generic reporter survived the relaunch"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] \
    || fail "upgrade: a native pi after an in-place upgrade still got a generic reporter"
  stop_term
  pass "native gate: an in-place harness upgrade is re-probed at the next launch"
}

# codex-cli first shipped native OSC 7501 records in 0.163.0
# (openai/codex#52725, absent from rust-v0.162.1): 0.163.0 arms nothing,
# 0.162.1 still gets the generic reporter, and a codex whose version cannot be
# read is treated as native.
t_native_codex_threshold() {
  local d=$TMP_ROOT/nativecodex
  mkhome "$d"; mkfake "$d" codex 'codex-cli 0.163.0'
  start_term "$d"
  env "${CLEAN_UNSET[@]}" REX_BLOCK=b1 FM_OSC7501_TTY="$TERM_SLAVE" \
    PATH="$d/bin:$PATH" bash "$SCRIPT" arm \
    --task t26 --harness codex --backend rex --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin codex
  sleep 0.3
  assert_equals "" "$(cat "$d/cap" 2>/dev/null)" "native codex: terminal sees zero bytes"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] || fail "native codex 0.163.0 armed a watcher"
  mkfake "$d" codex 'codex-cli 0.162.1'
  env "${CLEAN_UNSET[@]}" REX_BLOCK=b1 FM_OSC7501_TTY="$TERM_SLAVE" \
    PATH="$d/bin:$PATH" bash "$SCRIPT" arm \
    --task t26 --harness codex --backend rex --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin codex
  local wpid
  wpid=$(watcher_pid "$d/state") || fail "codex 0.162.1 armed no generic watcher"
  mkfake "$d" codex 'codex-cli unknown build'
  env "${CLEAN_UNSET[@]}" REX_BLOCK=b1 FM_OSC7501_TTY="$TERM_SLAVE" \
    PATH="$d/bin:$PATH" bash "$SCRIPT" arm \
    --task t26 --harness codex --backend rex --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin codex
  wait_gone "$wpid" || fail "codex relaunch left the old generic reporter running"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] || fail "a codex with an unreadable version armed a watcher"
  stop_term
  pass "native gate: codex >= 0.163.0 or of unreadable version arms nothing, older codex keeps the generic reporter"
}

# --- shared root record --------------------------------------------------------

# A native writer and the bridge share one root record. Codex's own working
# record must stay the root record: with codex activity unknown, an open
# decision and an old done line give the bridge no grounds to write, the
# heartbeat never replaces the native record, and neither do the ordinary
# exits - a TERM (what disarm sends) or the launch shell's death.
t_unknown_activity_leaves_native_root() {
  local d=$TMP_ROOT/sharedroot native exit holder wpid
  mkhome "$d"
  : >"$d/cap"
  native=$(printf '\033]7501;state=working:app=codex\033\134')
  printf 'done [at=1]: PR https://example.test/pr/7\nneeds-decision [at=2]: ship it?\n' >"$d/state/t27.status"
  for exit in term parent; do
    sleep 300 &
    holder=$!
    printf '%s' "$native" >>"$d/cap"
    env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$d/cap" FM_OSC7501_INTERVAL=1 FM_OSC7501_HEARTBEAT=1 \
      bash "$SCRIPT" watch --task t27 --kind ship --state "$d/state" --harness codex \
      --parent "$holder" &
    wpid=$!
    sleep 3
    printf '%s' "$native" >>"$d/cap"
    sleep 2
    case "$exit" in
      term) kill "$wpid" 2>/dev/null ;;
      parent) kill "$holder" 2>/dev/null ;;
    esac
    wait_gone "$wpid" || fail "shared root: the watcher did not exit on $exit"
    wait "$wpid" 2>/dev/null || true
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
    assert_equals "app=codex " "$(grep -o 'app=[a-z-]*' "$d/cap" | sort -u | tr '\n' ' ')" \
      "the bridge wrote no record over the native root record through $exit"
  done
  pass "shared root: unknown activity never overwrites a native record, live or at exit"
}

# Once activity turns unknown the bridge stops writing: no heartbeat, no
# retirement record over whatever now owns the root, and no final record at
# TERM. Known activity resumes reporting.
t_unknown_activity_stops_writing() {
  local d=$TMP_ROOT/unknownstop n
  mkhome "$d"
  : >"$d/cap"
  sleep 300 &
  local holder=$!
  busy_rec "$d/state" t28 idle
  printf 'needs-decision [at=1] [key=k1]: ship it?\n' >"$d/state/t28.status"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$d/cap" FM_OSC7501_INTERVAL=1 FM_OSC7501_HEARTBEAT=1 \
    bash "$SCRIPT" watch --task t28 --kind ship --state "$d/state" --harness opencode \
    --parent "$holder" &
  local wpid=$!
  wait_cap 'state=blocked:kind=question' "$d/cap" 60 || fail "unknown: no blocked record while activity was known"
  rm -f "$d/state/t28.busy-state" "$d/state/t28.busy-gen"
  sleep 2
  n=$(grep -o 'state=' "$d/cap" | wc -l | tr -d ' ')
  printf 'resolved [at=2] [key=k1]: yes\n' >>"$d/state/t28.status"
  sleep 3
  assert_equals "$n" "$(grep -o 'state=' "$d/cap" | wc -l | tr -d ' ')" "unknown activity: no heartbeat or retirement record"
  busy_rec "$d/state" t28 idle
  wait_cap 'state=idle' "$d/cap" 60 || fail "unknown: known activity did not resume reporting"
  rm -f "$d/state/t28.busy-state" "$d/state/t28.busy-gen"
  sleep 2
  n=$(grep -o 'state=' "$d/cap" | wc -l | tr -d ' ')
  kill "$wpid" 2>/dev/null
  wait_gone "$wpid" || fail "unknown: the watcher did not exit on TERM"
  wait "$wpid" 2>/dev/null || true
  assert_equals "$n" "$(grep -o 'state=' "$d/cap" | wc -l | tr -d ' ')" "unknown activity: no final record at TERM"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  pass "unknown activity: the bridge writes nothing until activity is known again"
}

# --- config gate ---------------------------------------------------------------

t_config_off_disables() {
  local d=$TMP_ROOT/cfgoff
  mkhome "$d"; printf 'off\n' >"$d/config/osc7501-status"
  start_term "$d"
  env "${CLEAN_UNSET[@]}" HC_TERMINAL_ID=x FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" arm \
    --task t8 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  sleep 0.3
  stop_term
  local cap
  cap=$(cat "$d/cap" 2>/dev/null)
  assert_equals "" "$cap" "config off: terminal sees nothing at all"
  pass "config gate: osc7501-status=off disables arm entirely"
}

# A known-aware environment (herdr-core's HC_TERMINAL_ID) arms the watcher
# without sending any probe bytes on the wire.
t_hc_marker_arms_watcher() {
  local d=$TMP_ROOT/hc
  mkhome "$d"
  start_term "$d"
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
    start_term "$d/$pane" env "${CLEAN_UNSET[@]}" HC_TERMINAL_ID="$pane" FM_OSC7501_INTERVAL=1 \
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
  start_term "$d"
  busy_rec "$d/state" t10 busy
  env "${CLEAN_UNSET[@]}" HC_TERMINAL_ID=x FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 bash "$SCRIPT" arm \
    --task t10 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  local wpid
  wpid=$(watcher_pid "$d/state") || fail "disarm: no watcher armed"
  wait_cap 'state=working' "$d/cap" 60 || fail "disarm: no working record"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" bash "$SCRIPT" disarm --state "$d/state"
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
  start_term "$d"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x bash "$SCRIPT" arm \
    --task t11 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  local first second
  first=$(watcher_pid "$d/state") || fail "rearm: no first watcher"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x bash "$SCRIPT" arm \
    --task t11 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  second=$(watcher_pid "$d/state") || fail "rearm: same-task relaunch armed no watcher"
  [ "$first" != "$second" ] || fail "rearm: same-task relaunch kept the old reporter"
  wait_gone "$first" || fail "rearm: old reporter still running after same-task relaunch"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x PATH="$d/bin:$PATH" \
    bash "$SCRIPT" arm --task t11 --harness claude --backend tmux --kind ship \
    --state "$d/state" --config "$d/config" --agent-bin claude
  wait_gone "$second" || fail "rearm: native relaunch left the firstmate reporter running"
  [ -z "$(ls "$d/state"/.osc7501watch-* 2>/dev/null)" ] || fail "rearm: native relaunch armed a watcher"
  stop_term
  pass "lifecycle: relaunch retires the previous reporter before native/off gates"
}

# Cursor arms no busy-state record; its own conversation transcript is the
# activity source.
t_cursor_transcript_drives_activity() {
  local d=$TMP_ROOT/cursor proj conv
  mkhome "$d"
  start_term "$d"
  sleep 300 &
  local holder=$!
  proj=$d/cursor-projects/p1
  conv=$proj/agent-transcripts/c1/c1.jsonl
  mkdir -p "${conv%/*}"
  printf '{"workspacePath":"%s"}\n' "$d/ws" >"$proj/.workspace-trusted"
  printf 'projects_root=%s\nworkspace_root=%s\n' "$d/cursor-projects" "$d/ws" >"$d/state/t16.cursor-session"
  printf '{"role":"user"}\n' >"$conv"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t16 --kind ship --state "$d/state" --harness cursor \
    --parent "$holder" &
  local wpid=$!
  wait_cap "state=working:app=firstmate-cursor" "$d/cap" 60 \
    || fail "cursor: an open transcript turn did not read as working"
  printf '{"type":"turn_ended"}\n' >>"$conv"
  wait_cap 'state=idle' "$d/cap" 60 || fail "cursor: a closed transcript turn did not read as idle"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  stop_term
  pass "activity: a cursor worker reports working and idle from its transcript"
}

# Grok has no busy-state writer; the classifier reads its rendered pane through
# the backend, so a follow-up turn showing Grok's busy footer reads as working
# over an earlier done, and done returns once the footer clears.
t_grok_pane_drives_activity() {
  local d=$TMP_ROOT/grok
  mkhome "$d"
  mkdir -p "$d/bin"
  : >"$d/cap"
  : >"$d/pane"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[ "$1" = capture-pane ] && cat %q\n' "$d/pane" >"$d/bin/tmux"
  chmod +x "$d/bin/tmux"
  sleep 300 &
  local holder=$!
  printf 'done [at=%s]: PR https://example.test/pr/6\n' "$(date +%s)" >"$d/state/t25.status"
  printf 'working on it\n  Ctrl+c:cancel\n' >"$d/pane"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$d/cap" FM_OSC7501_INTERVAL=1 PATH="$d/bin:$PATH" \
    bash "$SCRIPT" watch --task t25 --kind ship --state "$d/state" --harness grok \
    --backend tmux --target '%9' --parent "$holder" &
  local wpid=$!
  wait_cap 'state=working:app=firstmate-grok' "$d/cap" 300 \
    || fail "grok: a pane showing the busy footer did not read as working"
  printf 'ready\n> \n' >"$d/pane"
  wait_cap 'state=done' "$d/cap" 300 || fail "grok: done did not return once the footer cleared"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  pass "activity: a grok worker reports working from its rendered pane"
}

# Single-source precedence: a running turn reads as working even after a done
# line, the done returns once the turn ends, and the final record keeps it
# even when the agent died with its busy record still open.
t_turn_then_terminal_line() {
  local d=$TMP_ROOT/precedence
  mkhome "$d"
  : >"$d/cap"
  sleep 300 &
  local holder=$!
  busy_rec "$d/state" t23 busy
  printf 'done [at=%s]: PR https://example.test/pr/5\n' "$(date +%s)" >"$d/state/t23.status"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$d/cap" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t23 --kind ship --state "$d/state" --harness opencode \
    --parent "$holder" &
  local wpid=$!
  wait_cap 'state=working' "$d/cap" 300 || fail "precedence: a running turn did not read as working"
  busy_rec "$d/state" t23 idle
  wait_cap 'state=done' "$d/cap" 300 || fail "precedence: the done line did not return after the turn"
  : >"$d/cap"
  busy_rec "$d/state" t23 busy
  wait_cap 'state=working' "$d/cap" 300 || fail "precedence: a second turn did not read as working"
  : >"$d/cap"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  assert_equals "state=done " "$(grep -o 'state=[a-z]*' "$d/cap" | sort -u | tr '\n' ' ')" \
    "the final record keeps done although the busy record was left open"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  pass "mapping: working while a turn runs, done after it, done as the final record"
}

# A paused worker reports from its busy state like any other worker.
t_paused_reads_from_busy_state() {
  local d=$TMP_ROOT/paused
  mkhome "$d"
  : >"$d/cap"
  sleep 300 &
  local holder=$!
  busy_rec "$d/state" t24 idle
  printf 'paused [at=%s]: waiting on CI\n' "$(date +%s)" >"$d/state/t24.status"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$d/cap" FM_OSC7501_INTERVAL=1 \
    bash "$SCRIPT" watch --task t24 --kind ship --state "$d/state" --harness opencode \
    --parent "$holder" &
  local wpid=$!
  wait_cap 'state=idle' "$d/cap" 300 || fail "paused: an idle paused worker did not read as idle"
  busy_rec "$d/state" t24 busy
  wait_cap 'state=working' "$d/cap" 300 || fail "paused: a busy paused worker did not read as working"
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null || true
  assert_equals "state=idle state=working " "$(grep -o 'state=[a-z]*' "$d/cap" | sort -u | tr '\n' ' ')" \
    "a paused worker never reports a separate waiting state"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true
  pass "mapping: a paused worker reports working or idle from its busy state"
}

# A reporter still folding a long status history when its pane is relaunched
# finishes that fold and its final record late; the replacement must not arm
# until it is gone, so none of its writes can land after the handoff.
t_retire_waits_for_slow_reporter() {
  local d=$TMP_ROOT/slow first second i
  mkhome "$d"
  start_term "$d"
  for i in $(seq 1 100); do
    printf 'needs-decision [at=%s] [key=k%s]: q%s\nresolved [at=%s] [key=k%s]: a%s\n' "$i" "$i" "$i" "$i" "$i" "$i"
  done >"$d/state/t17.status"
  busy_rec "$d/state" t17 busy
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x FM_OSC7501_INTERVAL=1 bash "$SCRIPT" arm \
    --task t17 --harness opencode --backend tmux --kind ship \
    --state "$d/state" --config "$d/config"
  first=$(watcher_pid "$d/state") || fail "slow: no first watcher"
  wait_cap 'state=working' "$d/cap" 200 || fail "slow: the first reporter never reported"
  env "${CLEAN_UNSET[@]}" FM_OSC7501_TTY="$TERM_SLAVE" HC_TERMINAL_ID=x FM_OSC7501_INTERVAL=1 bash "$SCRIPT" arm \
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

# An hc terminal opened from inside a herdr session inherits HERDR_* markers;
# its own HC_TERMINAL_ID still makes it a known-aware reporter.
t_hc_terminal_with_inherited_herdr_markers() {
  local d=$TMP_ROOT/hcinherit
  mkhome "$d"
  start_term "$d"
  env "${CLEAN_UNSET[@]}" HC_TERMINAL_ID=t-2 HERDR_ENV=1 HERDR_PANE_ID=p-1 \
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
  t_unknown_terminal_preserves_input \
  t_ghostty_arms_watcher \
  t_status_transitions_and_final_done \
  t_final_idle_after_working \
  t_native_claude_skips_everything \
  t_old_claude_uses_generic \
  t_native_harness_without_agent_bin_skips \
  t_inplace_upgrade_reprobes_native \
  t_native_codex_threshold \
  t_unknown_activity_leaves_native_root \
  t_unknown_activity_stops_writing \
  t_config_off_disables \
  t_hc_marker_arms_watcher \
  t_concurrent_panes_keep_their_reporters \
  t_disarm_after_agent_exit_parks_idle \
  t_rearm_retires_previous_reporter \
  t_cursor_transcript_drives_activity \
  t_grok_pane_drives_activity \
  t_turn_then_terminal_line \
  t_paused_reads_from_busy_state \
  t_retire_waits_for_slow_reporter \
  t_hc_terminal_with_inherited_herdr_markers
