#!/usr/bin/env bash
# Exercise global role provisioning through its executable interface.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pi-role-agents)
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, tmp = map(Path, sys.argv[1:])
installer = root / "bin/fm-pi-role-agents.py"
home = tmp / "home"
config = tmp / "custom config"
project = tmp / "arbitrary-project"
project.mkdir()
env = {**os.environ, "HOME": str(home), "PI_CODING_AGENT_DIR": str(config)}
roles = {"worker": "gpt-5.6-luna", "explorer": "gpt-5.6-luna",
         "researcher": "gpt-5.6-luna", "tester": "gpt-5.6-luna",
         "reviewer": "gpt-6-astra", "integrator": "gpt-6-astra"}


def run(*args, script=installer, environ=env, ok=True):
    result = subprocess.run([sys.executable, str(script), *args], env=environ, cwd=project,
                            capture_output=True, text=True)
    assert (result.returncode == 0) == ok, result.stderr
    return result


def path(role):
    return config / "agents" / f"fm-orchestrated-{role}.md"


run("--check", ok=False)
assert not config.exists(), "read-only check created state"
run()
assert not (project / ".pi").exists(), "provisioning added project resources"
assert not (config / "trust.json").exists(), "provisioning changed trust"
for role, model in roles.items():
    text = path(role).read_text()
    front = dict(line.split(": ", 1) for line in text.split("---\n")[1].splitlines())
    assert front["name"] == f"fm-orchestrated-{role}"
    assert front["model"] == f"openai-codex/{model}"
    assert "thinking" not in front
    assert front["session-mode"] == "standalone"
    assert front["auto-exit"] == "true"
    assert "subagent_agents" not in front
before = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (config / "agents").iterdir()}
run()
run("--check")
assert before == {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in before}, "not idempotent"
print("ok - exact six role pins, fresh sessions, no project resources, read-only check and idempotent install")

# Default config and an explicit directory both work, leaving generic profiles alone.
default_env = {k: v for k, v in env.items() if k != "PI_CODING_AGENT_DIR"}
generic = home / ".pi/agent/agents/worker.md"
generic.parent.mkdir(parents=True)
generic.write_text("a user's generic worker")
run(environ=default_env)
assert generic.read_text() == "a user's generic worker"
assert (generic.parent / "fm-orchestrated-reviewer.md").exists()
print("ok - default global discovery path and unrelated profiles preserved")

# A second tracked code root represents a previous released definition.
old = tmp / "old-code"
(old / "bin").mkdir(parents=True)
shutil.copy(installer, old / "bin/fm-pi-role-agents.py")
shutil.copytree(root / ".agents/skills/orchestrated-delivery/agents",
                old / ".agents/skills/orchestrated-delivery/agents")
old_worker = old / ".agents/skills/orchestrated-delivery/agents/fm-orchestrated-worker.md"
old_worker.write_text(old_worker.read_text() + "\nPrevious release.\n")
run(script=old / "bin/fm-pi-role-agents.py")
run("--check", ok=False)
run()
run("--check")
assert path("worker").read_bytes() == before[path("worker")][0]
print("ok - intact installed definitions converge across code roots")

# Whole-preflight refusal: a missing file must stay absent when another conflicts.
for kind in ("edited", "unowned", "symlink", "hardlink", "directory"):
    target = path("worker")
    missing = path("explorer")
    original = target.read_bytes()
    target.unlink()
    missing.unlink()
    unrelated = tmp / f"unrelated-{kind}"
    unrelated.write_bytes(b"unrelated content")
    if kind == "edited":
        target.write_bytes(original + b"\nUser edit\n")
    elif kind == "unowned":
        target.write_bytes(b"---\nname: fm-orchestrated-worker\n---\nUser profile\n")
    elif kind == "symlink":
        target.symlink_to(unrelated)
    elif kind == "hardlink":
        os.link(unrelated, target)
    else:
        target.mkdir()
    result = run(ok=False)
    assert "refusing" in result.stderr
    assert not missing.exists(), "partial overwrite despite conflict"
    assert unrelated.read_bytes() == b"unrelated content"
    if kind == "directory":
        target.rmdir()
    else:
        target.unlink()
    target.write_bytes(original)
    run()
print("ok - edited, unowned, symlink, hardlink and directory conflicts preserve all files")

with ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(lambda _: run(), range(8)))
run("--check")
print("ok - concurrent provisioning converges")
PY
