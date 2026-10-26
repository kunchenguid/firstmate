#!/usr/bin/env bash
# Real Claude same-conversation collision, isolated from user configuration.
# Uses two unauthenticated Haiku sessions and bash mode to persist a conversation;
# no credentials are copied and no model response is needed. Opt-in because it
# submits a bash-mode prompt to Claude. The portable counterpart is the foreign-owner repro.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_LOCK_RESUME_LIVE claude tmux python3
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])
lab = None
version = "Claude Code (version unavailable)"
sessions = []
socket = os.environ.get("FM_CLAUDE_LOCK_TEST_SOCKET", f"fm-lock-resume-{os.getpid()}")

def tmux(*args):
    return subprocess.check_output(["tmux", "-L", socket, *args], text=True)

def wait(check, label):
    for _ in range(300):
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(f"{version}: {label}")

def event(pid, source):
    p = home / "state" / f"{pid}-{source}.json"
    try:
        return json.loads(p.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None

def send(name, text):
    tmux("send-keys", "-t", name, "-l", text)
    tmux("send-keys", "-t", name, "Enter")

def launch(label):
    name = f"lock-test-{os.getpid()}-{label}"
    command = ["env", "-i", *(f"{k}={v}" for k, v in env.items()),
               "claude", "--model", "haiku", "--setting-sources", "project",
               "--settings", str(settings), "--strict-mcp-config"]
    tmux("new-session", "-d", "-s", name, "-c", str(home), shlex.join(command))
    sessions.append(name)
    def started():
        rows = list((home / "state").glob("*-startup.json"))
        if len(rows) != len(sessions):
            return None
        try:
            return [json.loads(p.read_text()) for p in rows]
        except (FileNotFoundError, json.JSONDecodeError):
            return None
    records = wait(started, f"{label} SessionStart did not run")
    return name, next(row for row in records if row["pid"] not in known)

known = set()
try:
    lab = Path(tempfile.mkdtemp(prefix="fm-lock-resume-"))
    home = lab / "home"
    config = lab / "config"
    home.mkdir()
    config.mkdir()
    (home / "state").mkdir()
    (home / "bin").symlink_to(repo / "bin")
    (home / "CLAUDE.md").write_text("Isolated session identity test. Do not run tools.\n")
    (config / ".claude.json").write_text(json.dumps({
        "hasCompletedOnboarding": True, "theme": "dark",
        "projects": {str(home): {"hasTrustDialogAccepted": True}},
    }))
    version = subprocess.check_output(["claude", "--version"], text=True).strip()
    print(f"harness: {version}", flush=True)
    # A separate config keeps hooks, transcripts, and daemon discovery away from
    # real sessions. The empty credential environment makes bash mode token-free.
    env = {key: os.environ[key] for key in ("HOME", "PATH", "TERM") if key in os.environ}
    env.update(CLAUDE_CONFIG_DIR=str(config), DISABLE_AUTOUPDATER="1")
    probe = lab / "probe.py"
    probe.write_text('''import json,os,subprocess,sys
from pathlib import Path
p=json.load(sys.stdin); h=Path(os.environ["FM_HOME"]); s=h/"state"
r=subprocess.run(["bash",str(h/"bin/fm-lock.sh")],capture_output=True,text=True)
d={"id":os.environ.get("CLAUDE_CODE_SESSION_ID"),"pid":os.environ.get("CLAUDE_PID"),"rc":r.returncode,"output":r.stdout+r.stderr}
(s/(d["pid"]+"-"+p["source"]+".json")).write_text(json.dumps(d))
''')
    settings = lab / "settings.json"
    settings.write_text(json.dumps({"hooks": {"SessionStart": [{"hooks": [{
        "type": "command", "command": f"python3 {shlex.quote(str(probe))}",
    }]}]}}))
    env["FM_HOME"] = str(home)
    first, owner = launch("owner")
    known.add(owner["pid"])
    assert owner["rc"] == 0, owner
    # Bash mode persists a vendor-authored conversation without a paid turn.
    send(first, "! printf LOCK_RESUME_PROBE")
    wait(lambda: list((config / "projects").glob(f"*/{owner['id']}.jsonl")), "owner conversation not persisted")
    second, foreign = launch("second")
    assert foreign["rc"] == 1, foreign
    before = {p: p.read_bytes() for p in (home / "state/.lock", home / "state/.lock-session")}
    send(second, f"/resume {owner['id']}")
    resumed = wait(lambda: event(foreign["pid"], "resume"), "resume hook did not run")
    assert resumed["id"] == owner["id"] and resumed["pid"] != owner["pid"], resumed
    os.kill(int(owner["pid"]), 0)
    assert resumed["rc"] == 1, resumed
    assert all(p.read_bytes() == data for p, data in before.items()), "resume changed ownership"
    send(first, "/clear")
    cleared = wait(lambda: event(owner["pid"], "clear"), "clear hook did not run")
    assert cleared["rc"] == 0 and cleared["id"] != owner["id"], cleared
    print(f"ok - {version}: second live resume refused; owner /clear retained ownership")
except Exception as exc:
    raise RuntimeError(f"{version}: {exc}") from exc
finally:
    for session in sessions:
        subprocess.run(["tmux", "-L", socket, "kill-session", "-t", session], capture_output=True)
    if lab is not None:
        shutil.rmtree(lab)
PY
