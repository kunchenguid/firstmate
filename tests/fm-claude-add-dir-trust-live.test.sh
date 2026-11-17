#!/usr/bin/env bash
# Token-free PTY guard for installed Claude Code's --add-dir trust gate.
# Uses only a synthetic API key, a loopback API endpoint, private HOME/config,
# and disposable repositories. No model prompt is submitted. Set
# FM_CLAUDE_ADD_DIR_TRUST_LIVE=0 to skip or =1 to require installed tools.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate default-on FM_CLAUDE_ADD_DIR_TRUST_LIVE claude python3 node git
TMP_ROOT=$(fm_test_tmproot fm-claude-add-dir-trust-live)
fm_git_worktree "$TMP_ROOT/project" "$TMP_ROOT/wt" live-trust
mkdir -p "$TMP_ROOT/state/operational-inbox" "$TMP_ROOT/state/task.inbox" \
  "$TMP_ROOT/data/task" "$TMP_ROOT/code/.agents/skills" "$TMP_ROOT/config"
python3 -I - "$TMP_ROOT" "$ROOT/bin/fm-claude-trust.sh" "$(command -v claude)" "$PATH" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

root, trust, claude, search_path = sys.argv[1:]
root = Path(root).resolve()
config = root / "config"
channels = [root / "state/operational-inbox", root / "state/task.inbox",
            root / "data/task", root / "code/.agents/skills"]
env = dict(PATH=search_path, HOME=str(config), CLAUDE_CONFIG_DIR=str(config),
           TERM="xterm-256color", ANTHROPIC_API_KEY="sk-ant-synthetic-trust-only",
           ANTHROPIC_BASE_URL="http://127.0.0.1:9", DISABLE_AUTOUPDATER="1",
           CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1")
version = subprocess.check_output([claude, "--version"], env=env, text=True).strip()
(config / ".claude.json").write_text(json.dumps({
    "hasCompletedOnboarding": True, "theme": "dark",
    "customApiKeyResponses": {"approved": ["synthetic-trust-only"], "rejected": []},
}))
args = [trust, str(root / "wt"), str(root / "project")]
subprocess.run(args, env=env, check=True, stdout=subprocess.DEVNULL)


def launch(label, expect_gate):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
    proc = subprocess.Popen([claude, "--add-dir", *map(str, channels),
                             "--settings", '{"disableAllHooks":true}'],
                            cwd=root / "wt", env=env, stdin=slave, stdout=slave,
                            stderr=slave, start_new_session=True)
    os.close(slave)
    output = b""
    exited = False
    sent_exit = False
    started = time.monotonic()
    try:
        while time.monotonic() - started < 20:
            if select.select([master], [], [], .1)[0]:
                try:
                    output += os.read(master, 65536)
                except OSError:
                    break
            text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", output.decode(errors="replace"))
            compact = re.sub(r"\s", "", text)
            if "Addinganewdirectory:" in compact:
                if expect_gate:
                    return
                raise AssertionError("registered --add-dir still prompted")
            if not expect_gate and not sent_exit and time.monotonic() - started > 5:
                os.write(master, b"/exit\r")
                sent_exit = True
            if proc.poll() is not None:
                exited = True
                break
        if not expect_gate and sent_exit:
            try:
                proc.wait(timeout=3)
                exited = True
            except subprocess.TimeoutExpired:
                pass
        if expect_gate:
            raise AssertionError("unregistered --add-dir did not show its trust gate")
        if not exited or proc.returncode != 0 or "ClaudeCodev" not in compact:
            raise AssertionError("registered launch did not reach the composer and exit cleanly")
    finally:
        (root / (label + ".log")).write_bytes(output)
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
        os.close(master)


match = re.match(r"(\d+)\.(\d+)\.(\d+)", version)
if match is None:
    raise SystemExit(f"FAIL: cannot classify claude version: {version}")
needs_gate = tuple(map(int, match.groups())) >= (2, 1, 326)
try:
    launch("unregistered", needs_gate)
    subprocess.run(args + ["--task-channels", str(root / "state"), str(root / "data"),
                           str(root / "code"), "task"], env=env, check=True,
                   stdout=subprocess.DEVNULL)
    launch("registered", False)
except Exception as error:
    raise SystemExit(f"FAIL: claude {version}: {error}; PTY logs: {root}") from error
baseline = "unregistered channel prompts" if needs_gate else "predates added-directory gate"
print(f"ok - claude {version}: {baseline}; registered channels reach composer")
PY
