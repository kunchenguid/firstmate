#!/usr/bin/env bash
# Opt-in live managed-policy probe. The classifier verdict must come from real
# current CLIs, not a synthetic vendor transcript. Runs only where the operator
# expects the policy described in docs/verification/runtime-backends.md.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_MANAGED_APPROVAL_LIVE python3 codex claude
TMP_ROOT=$(fm_test_tmproot fm-managed-approval-live)
CODEX_VERSION=$(codex --version)
CLAUDE_VERSION=$(claude --version)
export FM_APPROVAL_PROBE_OUTPUT="$TMP_ROOT/codex.txt"
# A PTY is required: exec mode does not reproduce the interactive approval
# prompt. This own child is terminated after evidence or the bounded timeout;
# it is not a fleet endpoint and no lifecycle action is sent to a shared backend.
python3 - <<'PY'
import fcntl, os, pty, select, signal, struct, subprocess, termios, time
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 48, 180, 0, 0))
env = dict(os.environ)
for key in ('CLAUDECODE', 'PI_CODING_AGENT', 'FM_PI_HARNESS'):
    env.pop(key, None)
env['FM_TASK_ID'] = 'managed-approval-live-probe'
prompt = 'You are a launch-mode verification worker, not a supervisor. Do not run session startup, supervise, or delegate. Run pwd -P exactly once with your shell tool, then reply OK. Do not edit files.'
process = subprocess.Popen(['codex', '--dangerously-bypass-approvals-and-sandbox', '--disable', 'hooks', prompt], env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
result = bytearray()
try:
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline and process.poll() is None:
        ready, _, _ = select.select([master], [], [], 1)
        if ready:
            try:
                chunk = os.read(master, 65536)
                result.extend(chunk)
                if b'\x1b[6n' in chunk:
                    os.write(master, b'\x1b[1;1R')
                if b'\x1b[c' in chunk:
                    os.write(master, b'\x1b[?1;2c')
            except OSError:
                break
        if b'Yes, proceed' in result and b'Would you like to run the following command?' in result:
            break
finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    os.close(master)
with open(os.environ['FM_APPROVAL_PROBE_OUTPUT'], 'wb') as f:
    f.write(result)
PY
"$ROOT/bin/fm-approval-failover.sh" classify codex < "$TMP_ROOT/codex.txt" >/dev/null \
  || { tail -c 6000 "$TMP_ROOT/codex.txt" >&2; fail "codex $CODEX_VERSION: managed bypass did not show the recognized approval prompt"; }
printf 'ok - %s live bypass refusal matches the approval classifier\n' "$CODEX_VERSION"
# Print mode exercises the actual policy request without sending shell tools.
env -u CLAUDECODE FM_TASK_ID=managed-approval-live-probe claude -p \
  --dangerously-skip-permissions --output-format text 'Reply OK without tools.' > "$TMP_ROOT/claude.txt" 2>&1 || true
"$ROOT/bin/fm-approval-failover.sh" classify claude < "$TMP_ROOT/claude.txt" >/dev/null \
  || fail "claude $CLAUDE_VERSION: managed bypass did not expose the policy 403; generic auth errors must not cause failover"
printf 'ok - %s live policy refusal matches the 403 classifier\n' "$CLAUDE_VERSION"
