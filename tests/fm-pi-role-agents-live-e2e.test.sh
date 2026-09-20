#!/usr/bin/env bash
# Opt-in, credentialed proof of actual roster discovery and execution, not mocks.
# Needs installed pi-interactive-subagents, Pi credentials, and tmux on PATH.
# Uses only a private tmux socket, an unrelated temporary git worktree, and an
# isolated HOME. Credentials are copied privately for this test and deleted with
# the fixture; the real config, trust store, and projects remain untouched.
# TMPDIR selects the fixture parent. Completion is an explicit tmux event, not a
# loop reading sessions. Session evidence is read once after that event.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_PI_ROLE_AGENTS_LIVE tmux pi python3
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile

root = Path(sys.argv[1])
real_config = Path(os.environ.get("PI_CODING_AGENT_DIR", str(Path.home() / ".pi/agent"))).expanduser()
package = Path(os.environ.get("FM_PI_SUBAGENTS_PACKAGE", str(real_config / "git/github.com/amosblomqvist/pi-interactive-subagents")))
extension = package / "pi-extension/subagents/index.ts"
roles = {"explorer": "gpt-5.6-luna", "researcher": "gpt-5.6-luna",
         "worker": "gpt-5.6-luna", "tester": "gpt-5.6-luna",
         "reviewer": "gpt-6-astra", "integrator": "gpt-6-astra"}
parent_thinking = "xhigh"
assert shutil.which("tmux"), "tmux is required"
assert shutil.which("pi"), "pi is required, including for children of pi-signed"
assert extension.is_file(), f"installed sub-agent package not found: {extension}"
assert (real_config / "auth.json").is_file(), "Pi auth.json is required"


def command(args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs).stdout.strip()


def entries(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line]


def messages(data):
    return [entry["message"] for entry in data if entry.get("type") == "message"]


def calls(msgs, name):
    return [part for msg in msgs if msg["role"] == "assistant" for part in msg.get("content", [])
            if part.get("type") == "toolCall" and part.get("name") == name]


print("tmux=" + command(["tmux", "-V"]), flush=True)
print("package=" + command(["git", "-C", str(package), "rev-parse", "HEAD"]), flush=True)
checked = 0
for harness in ("pi", "pi-signed"):
    binary = shutil.which(harness)
    if not binary:
        print(f"absent: {harness}", flush=True)
        continue
    version = command([binary, "--version"])
    print(f"testing: {harness} {version}", flush=True)
    with tempfile.TemporaryDirectory(prefix="fm-role-live-") as tmp:
        lab = Path(tmp).resolve()
        home = lab / "home"
        config = home / ".pi/agent"
        config.mkdir(parents=True, mode=0o700)
        for filename in ("auth.json", "models.json"):
            source = real_config / filename
            if source.is_file():
                shutil.copyfile(source, config / filename)
                (config / filename).chmod(0o600)
        (config / "settings.json").write_text(json.dumps({
            "defaultProjectTrust": "ask", "enableInstallTelemetry": False,
            "quietStartup": True, "enableSkillCommands": False,
        }))
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("PI_", "FM_", "HERDR_")) and k not in ("TMUX", "TMUX_PANE")}
        env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
                   PI_OFFLINE="1", PI_TELEMETRY="0", TMPDIR=str(lab), SHELL="/bin/bash")
        project = lab / "unrelated-project"
        worktree = lab / "task-worktree"
        command(["git", "init", "-q", str(project)], env=env)
        command(["git", "-C", str(project), "-c", "user.name=Proof", "-c", "user.email=proof@example.invalid",
                 "commit", "--allow-empty", "-qm", "fixture"], env=env)
        command(["git", "-C", str(project), "worktree", "add", "--detach", str(worktree)], env=env)
        assert Path(command(["git", "-C", str(worktree), "rev-parse", "--show-toplevel"])) == worktree
        assert not worktree.is_relative_to(root), "proof must be outside the Firstmate repo"
        # This is the exact provisioner invoked by fm-spawn. The portable dispatch
        # suite additionally executes fm-spawn's emitted launch command itself.
        command([sys.executable, str(root / "bin/fm-pi-role-agents.py")], env=env, cwd=worktree)
        parent_session = lab / "orchestrator.jsonl"
        child_command = "python3 -c " + shlex.quote(
            'import os,json; print("FM_ROLE_OBSERVED " + json.dumps({'
            'k:os.environ.get(k) for k in ["PI_SUBAGENT_AGENT","PI_PROVIDER","PI_MODEL",'
            '"PI_REASONING_LEVEL","PI_SESSION_ID","PI_SESSION_FILE"]} | {"cwd":os.getcwd()}))')
        handoff = (f"This is a read-only roster identity smoke, not a code task. Stay in {worktree}. "
                   f"Use bash to execute exactly: {child_command} . "
                   "Then summarize the observed identity in your final response and stop. "
                   "No other work, writes, model switches, or configuration changes.")
        channel = "roster-complete"
        canary = "PARENT_CONTEXT_CANARY_not_for_any_child"
        model_pins = ", ".join(f"{role}=openai-codex/{model}:{parent_thinking}" for role, model in roles.items())
        prompt = (f"You are the orchestrator of a bounded roster runtime smoke. {canary}. "
                  "This canary belongs only to your context; do not include it in any handoff. "
                  "Call subagents_list once. Then spawn ALL six roles one at a time, awaiting each "
                  "automatically delivered completion before the next: " + ", ".join(roles) + ". "
                  "Each call must use agent='fm-orchestrated-ROLE', name='proof-ROLE', "
                  f"cwd={worktree}, model as pinned here ({model_pins}), and this exact task text: {json.dumps(handoff)}. "
                  "Do not poll, read session logs, alter files, or perform other tasks. "
                  "Use fresh subagent calls, never subagent_message. Do not claim completion from acknowledgements. "
                  f"After receiving all six results, run bash command `tmux wait-for -S {channel}`. "
                  f"If any step fails, also signal that channel, then report the failure; the test verifies evidence independently.")
        prompt_file = lab / "prompt.md"
        prompt_file.write_text(prompt)
        launch = lab / "launch.sh"
        launch.write_text("#!/bin/bash\nset -eu\ncd " + shlex.quote(str(worktree)) + "\nexec " +
                          shlex.join([binary, "--no-extensions", "-e", str(extension), "--no-skills",
                                      "--no-context-files", "--no-prompt-templates", "--session", str(parent_session),
                                      "--model", "openai-codex/gpt-6-astra", "--thinking", "xhigh",
                                      "@" + str(prompt_file)]) + "\n")
        socket = str(lab / "tmux.sock")
        tmux_config = lab / "tmux.conf"
        tmux_config.write_text('set -g default-shell /bin/bash\nset -g default-command "/bin/bash --noprofile --norc"\n')
        try:
            command(["tmux", "-S", socket, "-f", str(tmux_config), "new-session", "-d", "-s", "proof",
                     "-x", "220", "-y", "55", "/bin/bash " + shlex.quote(str(launch))], env=env)
            # An event sent before the waiter attaches is retained by tmux.
            command(["tmux", "-S", socket, "wait-for", channel], timeout=600, env=env)
            parent = entries(parent_session)
            parent_msgs = messages(parent)
            launches = calls(parent_msgs, "subagent")
            assert len(launches) == 6, f"expected six real spawns, got {len(launches)}"
            assert {c["arguments"]["agent"] for c in launches} == {f"fm-orchestrated-{r}" for r in roles}
            for call in launches:
                role = call["arguments"]["agent"].removeprefix("fm-orchestrated-")
                assert call["arguments"]["model"] == f"openai-codex/{roles[role]}:{parent_thinking}"
            assert not calls(parent_msgs, "subagent_message"), "a session was resumed"
            discovery = [m for m in parent_msgs if m.get("toolName") == "subagents_list"]
            assert len(discovery) == 1
            discovered = {a["name"]: a for a in discovery[0]["details"]["agents"]}
            child_files = list((config / "sessions").glob("*/*.jsonl"))
            assert len(child_files) == 6, f"expected six real sessions, got {len(child_files)}"
            seen = set()
            for child in child_files:
                data = entries(child)
                msgs = messages(data)
                loadout = json.loads(Path(str(child) + ".loadout.json").read_text())
                role = loadout["agent"].removeprefix("fm-orchestrated-")
                model = roles[role]
                thinking = parent_thinking
                assert role not in seen
                seen.add(role)
                definition = discovered[f"fm-orchestrated-{role}"]
                assert definition["source"] == "global"
                assert definition["model"] == f"openai-codex/{model}"
                assert not definition.get("thinking") and definition["sessionMode"] == "standalone"
                assert loadout["model"] == f"openai-codex/{model}:{thinking}"
                assert not loadout.get("thinking")
                assert data[0]["cwd"] == str(worktree) and not data[0].get("parentSession")
                assert canary not in child.read_text(), "parent context was copied"
                model_events = [e for e in data if e["type"] == "model_change"]
                effort_events = [e for e in data if e["type"] == "thinking_level_change"]
                assert model_events and all(e["provider"] == "openai-codex" and e["modelId"] == model for e in model_events)
                assert effort_events and all(e["thinkingLevel"] == thinking for e in effort_events)
                assistant = [m for m in msgs if m["role"] == "assistant"]
                assert assistant and all(m["model"] == model and m["provider"] == "openai-codex" for m in assistant)
                assert assistant[-1]["stopReason"] == "stop", f"{role} did not finish successfully"
                observed = []
                for msg in msgs:
                    if msg.get("toolName") == "bash" and not msg.get("isError"):
                        for part in msg["content"]:
                            for line in part.get("text", "").splitlines():
                                if line.startswith("FM_ROLE_OBSERVED "):
                                    observed.append(json.loads(line.removeprefix("FM_ROLE_OBSERVED ")))
                assert len(observed) == 1, f"{role} has no unique shell identity evidence"
                obs = observed[0]
                assert obs["PI_PROVIDER"] == "openai-codex" and obs["PI_MODEL"] == model
                assert obs["PI_REASONING_LEVEL"] == thinking
                assert obs["PI_SUBAGENT_AGENT"] == f"fm-orchestrated-{role}"
                assert obs["PI_SESSION_ID"] == data[0]["id"]
                assert Path(obs["PI_SESSION_FILE"]) == child and obs["cwd"] == str(worktree)
                print(f"ok - {harness} {role}: openai-codex/{model} thinking={thinking} global standalone live", flush=True)
            assert seen == set(roles)
            assert not (config / "trust.json").exists(), "trust decision was saved"
            assert not (worktree / ".pi").exists(), "project resources were added"
            assert not command(["git", "-C", str(worktree), "status", "--porcelain"])
            print(f"ok - {harness}: six completed roles; fresh reviewer; no project trust or project changes", flush=True)
            checked += 1
        except Exception:
            # Diagnostic only, after failure, never a completion poll.
            result = subprocess.run(["tmux", "-S", socket, "capture-pane", "-p", "-t", "proof:0.0", "-S", "-100"],
                                    text=True, capture_output=True)
            print(result.stdout, file=sys.stderr)
            raise
        finally:
            subprocess.run(["tmux", "-S", socket, "kill-server"], capture_output=True)
assert checked, "no installed Pi-family harness was tested"
print(f"ok - roster live proof passed for {checked} installed Pi-family harness(es)")
PY
