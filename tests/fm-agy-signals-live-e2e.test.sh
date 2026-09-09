#!/usr/bin/env bash
# Live guard for the real, installed Antigravity CLI (bin/fm-test-run.sh's
# live-harness-optin family). Env-gated and self-skipping: it drives the real
# binary through a raw PTY (the same TTY contract tmux/herdr allocate) rather
# than requiring tmux, so it runs on hosts without tmux installed. It exercises
# the EXACT production launch shape - `agy --dangerously-skip-permissions
# --model <model> --prompt-interactive "<brief>"` with NO positional brief
# (which agy rejects outright) - and proves the harness-dependent facts
# bin/fm-busy-lib.sh, bin/fm-composer-lib.sh, and bin/fm-control-lib.sh encode
# for agy: that the `esc to cancel` busy token renders for a real tool call,
# that an Escape sent mid-tool-call prints `Interrupted` without wedging the
# session, that /exit then exits cleanly with agy's resume hint, and that the
# worktree hooks.json triple (PreInvocation/PostInvocation/Stop) fires for a
# completed turn while an interrupted turn fires only the opener.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
[ -x "${AGY_BIN:-}" ] || AGY_BIN="$HOME/.local/bin/agy"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_AGY_SIGNALS_LIVE python3

[ -x "$AGY_BIN" ] || fail "FM_AGY_SIGNALS_LIVE=1 but no real agy executable is installed"

VERSION_OUT=$("$AGY_BIN" --version 2>&1) || fail "agy --version failed: $VERSION_OUT"
echo "BOOTSTRAP_INFO: live agy version: $VERSION_OUT"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-signals.XXXXXX") || fail "could not create the isolated agy lab"
cleanup() { rm -rf -- "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/workspace"
git -C "$LAB/workspace" init -q || fail "could not initialize the isolated agy workspace"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated agy workspace"
TRANSCRIPT="$LAB/transcript.log"
HOOKLOG="$LAB/hook-fires.log"

# The worktree hooks triple under test, in the exact install shape
# bin/fm-agy-lib.sh writes (our named key, flat handler lists, JSON-object
# stdout contract), firing into an outside-the-worktree log.
mkdir -p "$WORKSPACE/.agents"
cat > "$WORKSPACE/.agents/hooks.json" <<EOF
{"fm-busy-state": {"PreInvocation": [{"type": "command", "command": "echo PREINV >> $HOOKLOG; printf '{}'"}], "PostInvocation": [{"type": "command", "command": "echo POSTINV >> $HOOKLOG; printf '{}'"}], "Stop": [{"type": "command", "command": "echo STOP >> $HOOKLOG; printf '{}'"}]}}
EOF

# Drive the real binary over a raw PTY through the exact production launch
# shape: --prompt-interactive carrying a sleep-25 brief, trust dialog answered
# with Enter (its default is the safe Yes), busy token observed, Escape
# mid-tool-call, a second quick turn to completion, then /exit. Bytes are
# dumped raw to TRANSCRIPT for the shell-side substring checks below.
python3 - "$AGY_BIN" "$WORKSPACE" "$TRANSCRIPT" <<'PY' || fail "the PTY driver reported a failure"
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

agy_bin, workspace, transcript_path = sys.argv[1:4]

pid, fd = pty.fork()
if pid == 0:
    os.chdir(workspace)
    os.execvp(agy_bin, [agy_bin, "--model", "gemini-3.8-flash-low",
                        "--dangerously-skip-permissions",
                        "--prompt-interactive", "run the command sleep 25 then reply exactly: SLEPT-OK"])
    os._exit(127)

# A raw pty.fork starts at 0x0, on which agy's TUI never renders past terminal
# setup (verified: 82 setup bytes, then silence). Size it like a real
# tmux/herdr pane and re-signal, after which the trust dialog and the turn
# render normally.
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
time.sleep(1)
os.kill(pid, signal.SIGWINCH)

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

# 1. Fresh-lab trust dialog: answer Yes with Enter when it appears. The lab
# path is never pre-trusted, so this also proves the dialog's default accepts.
seen = pump(60, want=b"Do you trust the contents of this project?")
if b"Do you trust the contents of this project?" in seen:
    os.write(fd, b"\r")

# 2. The slow tool call proves delivery and the working state via the busy token.
busy = pump(120, want=b"esc to cancel")
if b"esc to cancel" not in busy:
    sys.exit("agy never rendered its 'esc to cancel' busy token for the sleep-25 turn")

# 2b. The token alone can precede the model invocation, and interrupting a
# queued-but-uninvoked prompt fires no hook at all. Hold the interrupt until
# the tool itself is observably running, so the interrupted turn provably owns
# a PreInvocation opener.
running = pump(60, want=b"Running command")
if b"Running command" not in running:
    sys.exit("agy never showed the sleep-25 tool call running before the interrupt")

# 3. Interrupt with Escape while the tool call is genuinely in flight. Real agy
# prints `Interrupted` and stays controllable; send Escape across the window
# until it renders, the same deterministic shape the rovo guard uses.
cancelled = b""
for _ in range(15):
    os.write(fd, b"\x1b")
    cancelled = pump(2, want=b"Interrupted")
    if b"Interrupted" in cancelled:
        break
if b"Interrupted" not in cancelled:
    sys.exit("agy did not print 'Interrupted' after a mid-tool-call Escape")

# 4. A second quick turn to completion proves the session survived the
# interrupt and fires the full hooks triple for a finished turn.
time.sleep(1)
os.write(fd, b"say exactly: AFTER-INTERRUPT\r")
done = pump(120, want=b"AFTER-INTERRUPT")
if b"AFTER-INTERRUPT" not in done:
    sys.exit("agy did not answer a turn sent after the interrupt")
pump(10)

# 5. Exit cleanly, proving Escape left the session controllable.
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
    sys.exit("agy did not exit after /exit, sent after a mid-tool-call Escape")

transcript.close()
PY

grep -aFq 'esc to cancel' "$TRANSCRIPT" \
  || fail "real agy never rendered its busy token for the sleep-25 turn"
printf 'esc to cancel\n' | fm_busy_lines_match agy \
  || fail "fm_busy_lines_match agy did not classify the real busy token as busy"
pass "real agy delivers the --prompt-interactive brief and renders its busy token"

grep -aFq 'Interrupted' "$TRANSCRIPT" \
  || fail "real agy did not print 'Interrupted' on a mid-tool-call Escape"
pass "real agy prints 'Interrupted' and survives a mid-tool-call Escape"

grep -aFq 'AFTER-INTERRUPT' "$TRANSCRIPT" \
  || fail "real agy did not answer a turn sent after the interrupt"
[ -f "$HOOKLOG" ] || fail "real agy never fired the worktree hooks triple"
hook_seq=$(tr '\n' ' ' < "$HOOKLOG")
[ "$hook_seq" = "PREINV PREINV POSTINV STOP " ] \
  || fail "agy hooks fired '$hook_seq', expected the interrupted opener then the completed-turn triple"
pass "real agy fires only the opener for an interrupted turn and the full triple for a completed one"

grep -aFq 'Resume with' "$TRANSCRIPT" \
  || fail "real agy did not print its resume hint after /exit"
pass "real agy exits cleanly on /exit"
