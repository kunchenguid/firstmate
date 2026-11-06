#!/usr/bin/env bash
# Live guard for the real, installed Rovo CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping: it drives the real
# binary through a raw PTY (the same TTY contract tmux/herdr allocate) rather
# than requiring tmux, so it runs on hosts without tmux installed. It exercises
# the EXACT production launch-then-send shape - bare `rovo run --yolo` with NO
# positional brief, a readiness gate on the `Welcome to Rovo!` banner, a typed
# absolute brief pointer, then a delivery gate - and proves the
# harness-dependent facts bin/fm-busy-lib.sh and bin/fm-control-lib.sh encode for
# rovo: that the "Rovo is thinking" busy line renders for a real tool call, that
# an Escape sent mid-tool-call prints "Agent cancelled" without wedging the
# session, and that /exit then exits cleanly with rovo's resume hint.
#
# A positional brief is deliberately NOT used: it is dead-on-arrival (rovo loads,
# never enters a working state, and drops back to an idle shell within ~10-15s;
# confirmed live four times over raw PTY and once under real tmux with the exact
# send-keys shape). The launch-then-send shape is what fm-spawn.sh actually
# places, so it is what this guard drives.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROVO_BIN=$(command -v rovo 2>/dev/null || true)
[ -x "${ROVO_BIN:-}" ] || ROVO_BIN="$HOME/.local/bin/rovo"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_ROVO_SIGNALS_LIVE python3

[ -x "$ROVO_BIN" ] || fail "FM_ROVO_SIGNALS_LIVE=1 but no real rovo executable is installed"

VERSION_OUT=$("$ROVO_BIN" --version 2>&1) || fail "rovo --version failed: $VERSION_OUT"
echo "BOOTSTRAP_INFO: live rovo version: $VERSION_OUT"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-rovo-signals.XXXXXX") || fail "could not create the isolated Rovo lab"
cleanup() { rm -rf -- "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated Rovo workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated Rovo workspace"
TRANSCRIPT="$LAB/transcript.log"

# The brief the typed pointer will reference. It triggers a slow bash tool call
# so the busy line and the interrupt window are both long enough to observe.
BRIEF="$LAB/brief.md"
printf 'Run this exact bash command and nothing else: sleep 25\n' > "$BRIEF"
BRIEF_REAL=$(cd "$LAB" && pwd -P)/brief.md

# Drive the real binary over a raw PTY through the exact production
# launch-then-send shape: launch bare, wait for the readiness banner, type the
# absolute brief pointer, confirm delivery, observe the busy line, interrupt with
# Escape, and exit cleanly. Bytes are dumped raw to TRANSCRIPT for the shell-side
# substring checks below.
python3 - "$ROVO_BIN" "$WORKSPACE" "$TRANSCRIPT" "$BRIEF_REAL" <<'PY' || fail "the PTY driver reported a failure"
import os
import pty
import select
import subprocess
import sys
import time

rovo_bin, workspace, transcript_path, brief_real = sys.argv[1:5]

pointer = "Read the brief at %s and follow it exactly." % brief_real

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    # Bare launch: NO positional brief. A message is typed in after readiness.
    os.execvp(rovo_bin, [rovo_bin, "run", "--yolo"])
    os._exit(127)

transcript = open(transcript_path, "wb")

def pump(timeout, want=None):
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            transcript.write(chunk)
            transcript.flush()
            buf += chunk
        if want and want in buf:
            return buf
    return buf

# 1. Readiness gate: wait for rovo's fresh-launch welcome banner.
ready = pump(60, want=b"Welcome to Rovo!")
if b"Welcome to Rovo!" not in ready:
    sys.exit("rovo never rendered its 'Welcome to Rovo!' readiness banner")

# 2. Type the absolute brief pointer and submit it, then let the brief drive the
# slow bash tool call. The busy line proves both delivery and the working state.
os.write(fd, pointer.encode() + b"\r")
busy = pump(90, want=b"Rovo is thinking")
if b"Rovo is thinking" not in busy:
    sys.exit("rovo never rendered its busy line after the typed brief pointer")

# 3. Interrupt with Escape while the tool call is genuinely in flight. Real rovo
# prints "Agent cancelled" and stays controllable (confirmed live here and under
# real tmux 3.6a); hold the guard to that render. The exact instant the interrupt
# lands is timing-sensitive over a raw PTY - a single fixed-timer Escape can fall
# between states - so send Escape across the tool-call window until the cancel
# renders. This is a deterministic way to reproduce a timing-sensitive interrupt,
# not a weakening of the claim: a session that never rendered the cancel would
# exhaust every attempt and fail.
cancelled = b""
for _ in range(15):
    os.write(fd, b"\x1b")
    cancelled = pump(2, want=b"Agent cancelled")
    if b"Agent cancelled" in cancelled:
        break
if b"Agent cancelled" not in cancelled:
    sys.exit("rovo did not print 'Agent cancelled' after a mid-tool-call Escape")

# 4. Exit cleanly, proving Escape left the session controllable.
time.sleep(1)
os.write(fd, b"/exit\r")
for _ in range(60):
    try:
        done_pid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        done_pid = pid
        status = 0
    if done_pid == pid:
        break
    pump(1)
else:
    subprocess.run(["kill", "-9", str(pid)])
    sys.exit("rovo did not exit after /exit, sent after a mid-tool-call Escape")

transcript.close()
PY

grep -aFq 'Welcome to Rovo!' "$TRANSCRIPT" \
  || fail "real rovo never rendered its readiness banner"
pass "real rovo launches bare and renders its 'Welcome to Rovo!' readiness banner"

grep -aFq 'Rovo is thinking' "$TRANSCRIPT" \
  || fail "real rovo never rendered its busy line from the typed brief pointer"
printf '%s\n' "Rovo is thinking..." | fm_busy_rovo_tail_busy \
  || fail "fm_busy_rovo_tail_busy did not classify the real busy line as busy"
pass "real rovo delivers the typed brief pointer and renders its busy line"

grep -aFq 'Agent cancelled' "$TRANSCRIPT" \
  || fail "real rovo did not print 'Agent cancelled' on a mid-tool-call Escape"
pass "real rovo's session prints 'Agent cancelled' and survives a mid-tool-call Escape"

grep -aFq 'resume your' "$TRANSCRIPT" \
  || fail "real rovo did not print its resume hint after /exit"
pass "real rovo exits cleanly on /exit"

# --- allowedExternalPaths: prove the standard crewmate flow's brief-read and
# status/report-write against real files OUTSIDE the worktree, mirroring
# fm-spawn.sh's rovo_config_override_flag grant, and that the same access is
# blocked by default (AGENTS.md fm-rovo-external-paths finding). rovo's
# --config-override must be set at launch; there is no live escalation once
# the process is running.
EXT_DATA="$LAB/external/data/task"
EXT_STATE="$LAB/external/state"
mkdir -p "$EXT_DATA" "$EXT_STATE"
EXT_DATA_REAL=$(cd "$EXT_DATA" && pwd -P) || fail "could not resolve the external brief directory"
EXT_STATE_REAL=$(cd "$EXT_STATE" && pwd -P) || fail "could not resolve the external state directory"
EXT_STATUS="$EXT_STATE_REAL/task.status"
printf 'existing: seed line\n' > "$EXT_STATUS"
EXT_TOKEN="ROVO_EXT_WRITE_$$_$RANDOM"
cat > "$EXT_DATA_REAL/brief.md" <<EOF
Append the exact line "working: $EXT_TOKEN" to the file $EXT_STATUS,
preserving its existing content exactly as-is, then reply with exactly the
word CONFIRMED and nothing else.
EOF
CONFIG_OVERRIDE_JSON='{"toolPermissions":{"allowedExternalPaths":["'"$EXT_DATA_REAL"'","'"$EXT_STATUS"'"]}}'

mkdir -p "$LAB/workspace2"
git -C "$LAB/workspace2" init -q || fail "could not initialize the second isolated workspace"
WORKSPACE2=$(cd "$LAB/workspace2" && pwd -P) || fail "could not resolve the second isolated workspace"
TRANSCRIPT2="$LAB/transcript2.log"

python3 - "$ROVO_BIN" "$WORKSPACE2" "$TRANSCRIPT2" "$EXT_DATA_REAL/brief.md" "$CONFIG_OVERRIDE_JSON" <<'PY' || fail "the allowedExternalPaths grant PTY driver reported a failure"
import os
import pty
import select
import subprocess
import sys
import time

rovo_bin, workspace, transcript_path, brief_real, config_override = sys.argv[1:6]

pointer = "Read the brief at %s and follow it exactly." % brief_real

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    os.execvp(rovo_bin, [rovo_bin, "run", "--yolo", "--config-override", config_override])
    os._exit(127)

transcript = open(transcript_path, "wb")

def pump(timeout, want=None):
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            transcript.write(chunk)
            transcript.flush()
            buf += chunk
        if want and want in buf:
            return buf
    return buf

ready = pump(60, want=b"Welcome to Rovo!")
if b"Welcome to Rovo!" not in ready:
    sys.exit("rovo (grant session) never rendered its 'Welcome to Rovo!' readiness banner")

os.write(fd, pointer.encode() + b"\r")
reply = pump(90, want=b"CONFIRMED")
if b"CONFIRMED" not in reply:
    sys.exit("rovo (grant session) never confirmed the external brief-read/status-write")

time.sleep(1)
os.write(fd, b"/exit\r")
for _ in range(60):
    try:
        done_pid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        done_pid = pid
        status = 0
    if done_pid == pid:
        break
    pump(1)
else:
    subprocess.run(["kill", "-9", str(pid)])
    sys.exit("rovo (grant session) did not exit after /exit")

transcript.close()
PY

grep -aFq 'CONFIRMED' "$TRANSCRIPT2" \
  || fail "real rovo with the allowedExternalPaths grant never confirmed the external brief-read/status-write"
grep -aFq "working: $EXT_TOKEN" "$EXT_STATUS" \
  || fail "real rovo with the grant did not actually append to the external status file"
grep -aFq 'existing: seed line' "$EXT_STATUS" \
  || fail "real rovo with the grant clobbered the external status file's existing content instead of appending"
pass "real rovo with the allowedExternalPaths grant reads an external brief and appends to an external status file"

# Negative control: the exact same shape, launched WITHOUT the grant, proves
# the standard flow is genuinely blocked by default rather than merely
# untested - the concrete problem this fix closes.
NOGRANT_TOKEN="ROVO_NOGRANT_$$_$RANDOM"
cat > "$EXT_DATA_REAL/brief-nogrant.md" <<EOF
Append the exact line "working: $NOGRANT_TOKEN" to the file $EXT_STATUS,
preserving its existing content exactly as-is, then reply with exactly the
word CONFIRMED and nothing else.
EOF

mkdir -p "$LAB/workspace3"
git -C "$LAB/workspace3" init -q || fail "could not initialize the third isolated workspace"
WORKSPACE3=$(cd "$LAB/workspace3" && pwd -P) || fail "could not resolve the third isolated workspace"
TRANSCRIPT3="$LAB/transcript3.log"

python3 - "$ROVO_BIN" "$WORKSPACE3" "$TRANSCRIPT3" "$EXT_DATA_REAL/brief-nogrant.md" <<'PY' || fail "the no-grant control PTY driver reported a failure"
import os
import pty
import select
import subprocess
import sys
import time

rovo_bin, workspace, transcript_path, brief_real = sys.argv[1:5]

pointer = "Read the brief at %s and follow it exactly." % brief_real

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    os.execvp(rovo_bin, [rovo_bin, "run", "--yolo"])
    os._exit(127)

transcript = open(transcript_path, "wb")

def pump(timeout, want=None):
    deadline = time.time() + timeout
    buf = b""
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.5)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            transcript.write(chunk)
            transcript.flush()
            buf += chunk
        if want and want in buf:
            return buf
    return buf

ready = pump(60, want=b"Welcome to Rovo!")
if b"Welcome to Rovo!" not in ready:
    sys.exit("rovo (no-grant session) never rendered its 'Welcome to Rovo!' readiness banner")

os.write(fd, pointer.encode() + b"\r")
# No grant: rovo cannot read the external brief at all, so it settles back to
# an idle composer instead of ever confirming. Wait long enough for the
# refusal to render, then move on regardless.
pump(30)

time.sleep(1)
os.write(fd, b"/exit\r")
for _ in range(60):
    try:
        done_pid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        done_pid = pid
        status = 0
    if done_pid == pid:
        break
    pump(1)
else:
    subprocess.run(["kill", "-9", str(pid)])
    sys.exit("rovo (no-grant session) did not exit after /exit")

transcript.close()
PY

grep -aFq "working: $NOGRANT_TOKEN" "$EXT_STATUS" \
  && fail "real rovo without the allowedExternalPaths grant still wrote to the external status file - the confinement this fix relies on is gone"
grep -aiFq 'outside the' "$TRANSCRIPT3" \
  || fail "real rovo without the grant did not visibly refuse the external brief/status access"
pass "real rovo without the allowedExternalPaths grant cannot read the external brief or write the external status file"
