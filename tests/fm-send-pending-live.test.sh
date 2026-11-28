#!/usr/bin/env bash
# fm-send-pending-live.test.sh - real-client typed-plane stale-draft guard.
# Token-free local commands only; never asks a model for a response.
# FM_SEND_PENDING_LIVE=1 forces execution, =0 disables it (tests/lib.sh).
# Runs installed clients in empty HOME/FM_HOME/XDG roots, a private tmux
# socket, and an OS outbound-IP sandbox. No account configuration is read.
# Claude --bare, Codex's offline provider/no-daemon mode, and Grok's private
# leader socket exclude the account/session discovery surfaces of these CLIs.
# Installed clients without a verified isolated launch fail rather than skip.
# Diagnostic captures, argv, exits, and tmux key logs are retained under the
# printed temp root. FM_SEND_PENDING_LIVE_OUTPUT_DIR chooses its parent.
# Refresh docs/verification/runtime-backends.md after running this guard.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_SEND_PENDING_LIVE tmux python3 sandbox-exec

python3 - "$ROOT" <<'PY'
import datetime
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

workspace = Path(sys.argv[1])
root = Path(tempfile.mkdtemp(prefix="fm-send-pending-live-", dir=os.environ.get("FM_SEND_PENDING_LIVE_OUTPUT_DIR")))
# Unix-domain socket paths have a small platform limit; never put this beneath
# a user-selected long diagnostics path.
socket_dir = Path(tempfile.mkdtemp(prefix="fm-send-pending-socket-"))
socket = socket_dir / "tmux.sock"
home = root / "home"
bindir = root / "bin"
lab = root / "lab"
for path in (home / "state", home / "codex", bindir, lab):
    path.mkdir(parents=True, exist_ok=True)
real_tmux = shutil.which("tmux")
python = sys.executable
log = root / "tmux-argv.jsonl"
commands = []
results = {}
current = "inventory"
version = "not probed"
status = 1
profile = '(version 1) (allow default) (deny network-outbound (remote ip "*:*")) (allow network-outbound (remote ip "localhost:*"))'
# No ambient environment survives this allowlist. PATH is executable lookup,
# not a configuration or credential source; HOME and every config root are new.
env = {
    "HOME": str(home), "FM_HOME": str(home), "CODEX_HOME": str(home / "codex"),
    "CLAUDE_CONFIG_DIR": str(home / "claude"), "GROK_CONFIG_DIR": str(home / "grok"),
    "XDG_CONFIG_HOME": str(home / "config"), "XDG_CACHE_HOME": str(home / "cache"),
    "XDG_DATA_HOME": str(home / "data"), "XDG_STATE_HOME": str(home / "xdg-state"),
    "PATH": str(bindir) + os.pathsep + os.environ.get("PATH", os.defpath),
    "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "SHELL": "/bin/bash",
    "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "OPENCODE_DISABLE_AUTOUPDATE": "1",
    "MUSE_NO_AUTO_UPDATE": "1", "ANTHROPIC_API_KEY": "invalid-local-test-only",
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:9", "OPENAI_BASE_URL": "http://127.0.0.1:9/v1",
    "FM_LOCAL_TEST_KEY": "invalid-local-test-only", "GROK_API_KEY": "invalid-local-test-only",
    "XAI_API_KEY": "invalid-local-test-only", "HTTP_PROXY": "http://127.0.0.1:9",
    "HTTPS_PROXY": "http://127.0.0.1:9", "ALL_PROXY": "http://127.0.0.1:9",
    "NO_PROXY": "127.0.0.1,localhost", "FM_GATE_REFUSE_BYPASS": "1",
    "FM_SEND_SETTLE": "0", "FM_SEND_RETRIES": "1", "FM_SEND_SLEEP": "0.2",
}
wrapper = bindir / "tmux"
wrapper.write_text("#!" + python + "\nimport json,os,sys,time\n"
                   + "with open(" + repr(str(log)) + ",'a') as f: f.write(json.dumps({'time':time.time(),'argv':sys.argv[1:]})+'\\n')\n"
                   + "os.execv(" + repr(real_tmux) + ", [" + repr(real_tmux) + ",'-S'," + repr(str(socket)) + "]+sys.argv[1:])\n")
wrapper.chmod(0o755)

def run(argv, timeout=20, check=True):
    argv = [str(a) for a in argv]
    started = datetime.datetime.now().astimezone().isoformat()
    try:
        p = subprocess.run(argv, cwd=lab, env=env, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        p = subprocess.CompletedProcess(argv, 124, exc.stdout or b"", exc.stderr or b"")
    n = len(commands)
    (root / (str(n) + ".stdout")).write_bytes(p.stdout)
    (root / (str(n) + ".stderr")).write_bytes(p.stderr)
    commands.append(dict(argv=argv, cwd=str(lab), start=started,
                         end=datetime.datetime.now().astimezone().isoformat(), raw_exit=p.returncode,
                         stdout_file=str(root / (str(n) + ".stdout")), stderr_file=str(root / (str(n) + ".stderr")),
                         stdout_sha256=hashlib.sha256(p.stdout).hexdigest(), stderr_sha256=hashlib.sha256(p.stderr).hexdigest()))
    if check and p.returncode:
        raise AssertionError("command exit " + str(p.returncode) + ": " + shlex.join(argv) + "\n" + p.stderr.decode(errors="replace"))
    return p

def tm(*argv, check=True):
    return run([real_tmux, "-S", socket, *argv], check=check)

def capture(target):
    return tm("capture-pane", "-e", "-p", "-t", target, "-S", "0", "-E", "-").stdout

def plain(target):
    return tm("capture-pane", "-p", "-t", target).stdout.decode(errors="replace")

def verdict(target):
    return run(["/bin/bash", "-c", '. "$1/bin/fm-tmux-lib.sh"; fm_tmux_composer_state "$2"', "_", workspace, target]).stdout.decode().strip()

def operations():
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

def send(target, *args):
    return run(["/bin/bash", workspace / "bin/fm-send.sh", target, *args], check=False)

def require(condition, message):
    if not condition:
        raise AssertionError(message)

def draft_rows(screen, draft):
    # Compare the entire rendered input row, including anything appended to
    # the draft. Unrelated status/clipboard furniture may legitimately change.
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", screen.decode(errors="replace"))
    return [row for row in text.splitlines() if draft in row]

try:
    # Keep a caller-selected diagnostics root inside a checkout from making
    # vendor project discovery reach that checkout's settings or trust root.
    run(["git", "init", "--quiet", lab])
    # Enumerate the adapter inventory, not just the three expected local tools.
    # A newly installed adapter has to earn an account-free launch recipe.
    names = ["claude", "codex", "opencode", "pi", "pi-signed", "grok", "kimi", "cursor-agent",
             "gemini", "muse", "rovo", "omp", "agy", "devin", "commandcode", "polytoken", "cortex"]
    names[names.index("cursor-agent")] = "cursor"
    binaries = {"cursor": "cursor-agent", "commandcode": "commandcode"}
    installed = {name: shutil.which(binaries.get(name, name)) for name in names}
    for name, path in installed.items():
        if not path:
            print("# absent: " + name + " (" + binaries.get(name, name) + ")", flush=True)
    clients = {name: path for name, path in installed.items() if path}
    require(clients, "no installed client was exercised")
    # All vendor execution, including version/help probes, follows a proven OS
    # boundary. Proxies alone do not stop a vendor ignoring endpoint settings.
    sandbox = shutil.which("sandbox-exec")
    require(sys.platform == "darwin" and sandbox, "installed clients BLOCKED: verified macOS sandbox-exec IP boundary unavailable")
    control = '''import errno,json,socket,tempfile,pathlib
out={}
for name,address in [('external',('1.1.1.1',443)),('loopback',('127.0.0.1',9))]:
 s=socket.socket();s.settimeout(2)
 try:s.connect(address);out[name]=0
 except OSError as e:out[name]=e.errno
 finally:s.close()
p=pathlib.Path(tempfile.mkdtemp())/'s';s=socket.socket(socket.AF_UNIX);s.bind(str(p));s.listen();c=socket.socket(socket.AF_UNIX);c.connect(str(p));c.close();s.close()
print(json.dumps(out))
assert out['external']==errno.EPERM,out
assert out['loopback']==errno.ECONNREFUSED,out
'''
    network = run([sandbox, "-p", profile, python, "-c", control])
    print("# network boundary: " + network.stdout.decode().strip() + "; private Unix connect=0", flush=True)
    print("# native backend: " + run([real_tmux, "-V"]).stdout.decode().strip(), flush=True)
    unsupported = []
    for name, path in clients.items():
        current = name
        version = run([sandbox, "-p", profile, path, "--version"], check=False).stdout.decode(errors="replace").strip() or "version-unknown"
        results[name] = dict(version=version, executable=path)
        if name not in ("claude", "codex", "grok"):
            unsupported.append(name + " (" + version + "): isolated launch recipe not verified")
    # The ambiguous `agent` alias is not assumed to mean Cursor.
    alias = shutil.which("agent")
    if alias and alias not in clients.values():
        help_text = run([sandbox, "-p", profile, alias, "--help"], check=False).stdout.decode(errors="replace")
        if "Cursor Agent" in help_text or "CURSOR_API_ENDPOINT" in help_text or "api2.cursor.sh" in help_text:
            unsupported.append("Cursor agent alias: isolated launch recipe not verified")
        else:
            print("# agent alias is not verified Cursor; no Cursor coverage claimed", flush=True)
    require(not unsupported, "installed clients BLOCKED: " + "; ".join(unsupported))
    tm("-f", "/dev/null", "new-session", "-d", "-s", "lab", "-n", "anchor", "-x", "160", "-y", "45", "/bin/cat")
    tm("set-window-option", "-g", "remain-on-exit", "on")
    for name, path in clients.items():
        current = name
        version = results[name]["version"]
        state_home = root / (name + "-fm-home")
        (state_home / "state").mkdir(parents=True)
        env["FM_HOME"] = str(state_home)
        target = "lab:" + name
        if name == "claude":
            argv = [path, "--bare", "--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                    "--no-chrome", "--permission-mode", "dontAsk", "--tools", ""]
            local_command = "/clear"
        elif name == "codex":
            argv = [path, "--no-daemon", "--no-alt-screen", "--disable", "hooks", "-s", "read-only", "-a", "never",
                    "-c", 'model_provider="offline"', "-c", 'model_providers.offline={name="Offline test",base_url="http://127.0.0.1:9/v1",wire_api="responses",requires_openai_auth=false,env_key="FM_LOCAL_TEST_KEY"}',
                    "-c", "check_for_update_on_startup=false"]
            local_command = "/status"
        else:
            argv = [path, "--no-subagents", "--disable-web-search", "--tools", "", "--leader-socket", str(socket_dir / "grok.sock")]
            local_command = "/clear"
        tm("new-window", "-d", "-t", "lab:", "-n", name, shlex.join([sandbox, "-p", profile, *argv]))
        time.sleep(3)
        # Only known local onboarding choices in the generated empty directory.
        # Any sign-in/account/unknown dialog remains a hard failure below.
        for _ in range(6):
            screen = plain(target)
            if "Choose the text style" in screen or "Press Enter to continue" in screen:
                tm("send-keys", "-t", target, "Enter")
            elif "Do you want to use this API key?" in screen:
                tm("send-keys", "-t", target, "Up"); tm("send-keys", "-t", target, "Enter")
            elif "Yes, I trust this folder" in screen:
                tm("send-keys", "-t", target, "Down"); tm("send-keys", "-t", target, "Enter")
            elif name == "codex" and ("Do you trust" in screen or "Trust this folder?" in screen):
                tm("send-keys", "-t", target, "Enter")
            else:
                break
            time.sleep(1)
        results[name]["empty_before"] = capture(target).decode(errors="replace")
        require(verdict(target) == "empty", "initial composer is not proven empty")
        empty = send(target, local_command)
        time.sleep(.5)
        results[name]["empty_after"] = capture(target).decode(errors="replace")
        require(empty.returncode == 0 and verdict(target) == "empty", "local empty-composer command failed")
        draft = "STALE-" + name.upper() + ":"
        tm("send-keys", "-t", target, "-l", draft)
        time.sleep(.4)
        before = capture(target)
        require(draft in plain(target) and verdict(target) == "pending", "native draft is not proven pending")
        rows = draft_rows(before, draft)
        require(len(rows) == 1, "draft must occupy exactly one identified input row")
        # A marked task proves known-undelivered reply tracking is removed too.
        (state_home / "state" / (name + ".meta")).write_text("window=" + target + "\nkind=secondmate\nharness=" + name + "\nbackend=tmux\n")
        n = len(operations())
        refused = send(name, "/status")
        keys = [a for a in operations()[n:] if a["argv"] and a["argv"][0] == "send-keys"]
        after = capture(target)
        results[name].update(pending_before=before.decode(errors="replace"), pending_after=after.decode(errors="replace"),
                             refusal_exit=refused.returncode, refusal_stderr=refused.stderr.decode(errors="replace"), refused_key_operations=keys)
        require(refused.returncode == 1 and b"pending" in refused.stderr, "typed pending command was not refused for pending")
        require(not keys and rows == draft_rows(after, draft) and verdict(target) == "pending", "refusal changed the draft or pressed keys")
        require(not list((state_home / "state" / "pending-replies").glob("[!.]*")), "known-undelivered reply expectation survived")
        require(not (state_home / "state" / (name + ".inbox")).exists(), "typed refusal fell back to inbox")
        n = len(operations())
        ordinary = send(name, "ordinary local laboratory instruction")
        inbox_keys = [a for a in operations()[n:] if a["argv"] and a["argv"][0] == "send-keys"]
        after_inbox = capture(target)
        records = list((state_home / "state" / (name + ".inbox")).glob("*.msg"))
        require(ordinary.returncode == 0 and len(records) == 1 and not inbox_keys
                and rows == draft_rows(after_inbox, draft) and verdict(target) == "pending",
                "ordinary inbox changed pending composer, pressed keys, or was not durable")
        results[name].update(empty=True, pending_refused=True, inbox_unchanged=True, inbox_exit=ordinary.returncode,
                             inbox_after=after_inbox.decode(errors="replace"), inbox_key_operations=inbox_keys,
                             input_rows_before=rows, input_rows_after=draft_rows(after_inbox, draft))
        # Explicit Enter intentionally submits an existing draft. Use only a
        # native local command so this check cannot request a model response.
        tm("send-keys", "-t", target, "C-u")
        tm("send-keys", "-t", target, "-l", local_command)
        time.sleep(.4)
        require(verdict(target) == "pending", "local command draft is not pending before explicit Enter")
        results[name]["explicit_enter_before"] = capture(target).decode(errors="replace")
        entered = send(target, "--key", "Enter")
        time.sleep(.5)
        results[name]["explicit_enter_after"] = capture(target).decode(errors="replace")
        results[name]["explicit_enter_exit"] = entered.returncode
        require(entered.returncode == 0 and verdict(target) == "empty", "explicit Enter did not submit the local command")
        print("ok - " + name + ": explicit --key Enter intentionally submitted pending local command", flush=True)
        print("ok - " + name + " (" + version + "): pending refused before keys; empty local command and durable inbox preserved", flush=True)
    status = 0
except Exception as exc:
    print("not ok - " + current + " (" + version + "): " + str(exc) + "; diagnostics=" + str(root), file=sys.stderr, flush=True)
finally:
    tm("kill-server", check=False)
    (root / "result.json").write_text(json.dumps(dict(status="PASS" if status == 0 else "FAIL", results=results,
                                                     commands=commands, network_profile=profile, environment=env,
                                                     scope="real tmux and installed clients; local commands only, no model response"), indent=2) + "\n")
    print("# diagnostics: " + str(root / "result.json"), flush=True)
sys.exit(status)
PY
