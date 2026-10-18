#!/usr/bin/env bash
# Opt-in real Claude auto-mode permission prompt through generated worker hooks.
# Uses a plain PTY; never sends keys or changes a shared runtime.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_CLAUDE_PERMISSION_LIVE claude python3 jq git

TMP_ROOT=$(fm_test_tmproot fm-claude-permission-live)
REAL_CLAUDE=$(command -v claude)
VERSION=$(claude --version)
PRIMARY="$TMP_ROOT/primary"
PROJECT="$TMP_ROOT/project"
WORKER="$TMP_ROOT/worker"
FAKEBIN=$(make_spawn_fakebin "$TMP_ROOT/fake" claude)
fm_test_spawn_home "$PRIMARY" claude
fm_test_spawn_brief "$PRIMARY" permission
fm_git_worktree "$PROJECT" "$WORKER" permission-live
fm_test_run_spawn "$PRIMARY" "$WORKER" "$FAKEBIN" permission "$PROJECT" claude \
  --mode no-mistakes --yolo off > "$TMP_ROOT/spawn.out" \
  || fail "claude $VERSION: worker hook setup failed: $(cat "$TMP_ROOT/spawn.out")"
mkdir -p "$PRIMARY/config" "$WORKER/nested"
: > "$PRIMARY/config/supervision-host-off"
printf 'harmless probe\n' > "$WORKER/nested/example.txt"
jq '.permissions.ask = ["Bash"]' "$WORKER/.claude/settings.local.json" > "$TMP_ROOT/settings.json"
mv "$TMP_ROOT/settings.json" "$WORKER/.claude/settings.local.json"

python3 - "$ROOT" "$TMP_ROOT" "$REAL_CLAUDE" "$VERSION" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

root, lab, claude, version = sys.argv[1:]
lab = Path(lab)
worker = lab / "worker"
primary = lab / "primary"
state = primary / "state"
config = lab / "claude-config"
config.mkdir(mode=0o700)
source = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
source_preferences = source / ".claude.json" if os.environ.get("CLAUDE_CONFIG_DIR") else Path.home() / ".claude.json"
preferences = json.loads(source_preferences.read_text()) if source_preferences.exists() else {}
preferences["projects"] = {str(worker): {"hasTrustDialogAccepted": True}}
(config / ".claude.json").write_text(json.dumps(preferences))
credentials = source / ".credentials.json"
if credentials.exists():
    credential_data = credentials.read_bytes()
elif sys.platform == "darwin":
    result = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"], capture_output=True, timeout=10)
    if result.returncode:
        sys.exit(f"not ok - claude {version}: no readable credentials for the isolated live guard")
    credential_data = result.stdout
else:
    credential_data = None
if credential_data:
    destination = config / ".credentials.json"
    destination.touch(mode=0o600)
    destination.write_bytes(credential_data)
env = dict(os.environ, CLAUDE_CONFIG_DIR=str(config), DISABLE_AUTOUPDATER="1", TERM="xterm-256color")
env.pop("CLAUDECODE", None)
env.pop("CLAUDE_CODE_ENTRYPOINT", None)
prompt = f"Execute this exact Bash command once: `cd '{worker}/nested' && cat example.txt`. Do not split or change it. Do not use any other tools."
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 160, 0, 0))
started = time.monotonic()
child = subprocess.Popen([claude, "--permission-mode", "auto", "--ax-screen-reader", "--tools", "Bash", "--", prompt], cwd=worker, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
os.close(slave)
screen = bytearray()
try:
    status = state / "permission.status"
    while time.monotonic() - started < 90:
        if select.select([master], [], [], 0.1)[0]:
            try:
                screen.extend(os.read(master, 65536))
            except OSError:
                break
        if status.exists() and "Claude permission prompt" in status.read_text():
            break
        if child.poll() is not None:
            break
    (lab / "claude-screen.txt").write_bytes(screen)
    if not status.exists() or "Claude permission prompt" not in status.read_text():
        sys.exit(f"not ok - claude {version}: no real PermissionRequest within 90s; screen:\n{screen.decode(errors='replace')[-6000:]}")
    if child.poll() is not None:
        sys.exit(f"not ok - claude {version}: worker exited before its permission decision")
    dialog_deadline = time.monotonic() + 8
    while b"Do you want to proceed?" not in screen and time.monotonic() < dialog_deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                screen.extend(os.read(master, 65536))
            except OSError:
                break
    if b"Do you want to proceed?" not in screen:
        sys.exit(f"not ok - claude {version}: PermissionRequest did not render its approval prompt: {screen.decode(errors='replace')[-4000:]}")
    (lab / "claude-screen.txt").write_bytes(screen)
    watcher_env = dict(os.environ, FM_HOME=str(primary), FM_STATE_OVERRIDE=str(state), FM_BACKEND="tmux", FM_POLL="1", FM_SIGNAL_GRACE="0", FM_CHECK_INTERVAL="999999", FM_HEARTBEAT="999999", FM_SECONDMATE_LIVENESS_SECS="99999999")
    watcher_env["PATH"] = str(lab / "fake" / "fakebin") + os.pathsep + watcher_env["PATH"]
    result = subprocess.run(["bash", str(Path(root) / "bin/fm-watch-checkpoint.sh"), "--seconds", "15"], env=watcher_env, capture_output=True, text=True, timeout=25)
    if result.returncode or f"signal: {status}" not in result.stdout:
        sys.exit(f"not ok - claude {version}: permission decision did not wake the watcher: {result.stdout} {result.stderr}")
    rows = (state / ".wake-queue").read_text()
    if "\tsignal\tpermission.status\tneeds-decision:" not in rows:
        sys.exit(f"not ok - claude {version}: permission wake lost decision routing")
    elapsed = time.monotonic() - started
    if elapsed >= 120:
        sys.exit(f"not ok - claude {version}: permission wake exceeded the 120s live bound")
    print(f"ok - claude {version}: real auto-mode PermissionRequest produces a decision signal within 120s, before the 3600s busy bound; no keys sent")
finally:
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
    os.close(master)
PY
