"""Real embedded Codex lifecycle guard with a credential-free Responses fixture.

Only the vendor runtime, hook transport, queue and production supervision code
supply lifecycle verdicts. The fixture supplies deterministic assistant output
and wake-consumption tool calls, never a simulated Codex process or queue.
"""
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

ROOT, LAB, VERSION = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
VERIFIED = VERSION in {"codex-cli 0.163.0", "codex-cli 0.167.0"}


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def run_case(name, fail_arm=False):
    case = LAB / name
    home = case / "home"
    # The real arm refuses unmarked homes inside disposable gate checkouts.
    # Mint the supported lab rather than bypassing that production boundary.
    subprocess.run([str(ROOT / "bin/fm-lab-home.sh"), "create", str(home)],
                   check=True, stdout=subprocess.DEVNULL)
    for directory in ["bin", "docs"]:
        shutil.copytree(ROOT / directory, home / directory)
    for directory in [".codex", "state", "config", "data", "projects"]:
        (home / directory).mkdir(exist_ok=True)
    shutil.copy2(ROOT / ".codex/hooks.json", home / ".codex/hooks.json")
    if not VERIFIED:
        # Observe completion of the real asynchronous hook, not just absence
        # of a park before Stop has had a chance to run.
        hooks = json.loads((home / ".codex/hooks.json").read_text())
        for group in hooks["hooks"]["Stop"]:
            for hook in group["hooks"]:
                if hook.get("async"):
                    hook["command"] += '; rc=$?; printf "%s\\n" "$rc" >> stop-exits; exit "$rc"'
        (home / ".codex/hooks.json").write_text(json.dumps(hooks))
    (home / "AGENTS.md").write_text("Isolated native supervision transport fixture.\n")
    subprocess.run(["git", "init", "-q", str(home)], check=True)
    (home / "config/backlog-backend").write_text("manual\n")
    (home / "config/backend").write_text("tmux\n")
    (home / "config/codex-stop-park").touch()
    # Keep the real bounded digest and harness detection; unrelated startup
    # sweeps and external network checks are not this transport guard's scope.
    for script in ["fm-bootstrap.sh", "fm-startup-network.sh"]:
        (home / "bin" / script).write_text("#!/usr/bin/env bash\nexit 0\n")
    check = home / "state/lab.check.sh"
    check.write_text('''#!/usr/bin/env bash
if [ -f "$FM_HOME/trigger" ]; then
  event=$(< "$FM_HOME/trigger")
  rm "$FM_HOME/trigger"
  printf '%s\n' "$event"
fi
''')
    check.chmod(0o700)
    env = {key: os.environ[key] for key in ["PATH", "LANG", "LC_ALL"] if key in os.environ}
    env.update(HOME=str(case / "login"), CODEX_HOME=str(case / "codex"),
               FM_HOME=str(home), TERM="xterm-256color", OTEL_SDK_DISABLED="true",
               FM_CHECK_INTERVAL="1", FM_POLL="1", FM_HEARTBEAT="999999",
               FM_SIGNAL_GRACE="1")
    for directory in [env["HOME"], env["CODEX_HOME"]]:
        Path(directory).mkdir()
    subprocess.run([str(home / "bin/fm-check-register.sh"), "lab"], env=env,
                   check=True, stdout=subprocess.DEVNULL)
    (home / "consume.sh").write_text('''#!/usr/bin/env bash
set -eu
bin/fm-wake-drain.sh > drain.latest 2>&1
cat drain.latest >> drains.log
ack=$(awk '/^WAKE_ACK_REQUIRED:/ {sub(/^.*after handling completes run /, ""); print}' drain.latest)
[ -z "$ack" ] || bash -c "$ack" >> drains.log 2>&1
[ ! -s state/.wake-queue ]
printf 'consumed\n' >> consumed.log
''')
    if fail_arm:
        (home / "bin/fm-watch-arm.sh").write_text(
            "#!/usr/bin/env bash\necho 'watcher: FAILED - injected lab arm failure'\nexit 1\n")

    requests = []

    class Responses(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            requests.append(body)
            number = len(requests)
            (case / f"request-{number}.json").write_text(json.dumps(body))
            user = next((json.dumps(item) for item in reversed(body.get("input", []))
                         if item.get("role") == "user"), "")
            queue = home / "state/.wake-queue"
            # Codex also sends title-generation requests containing the wake
            # text, but those requests cannot execute tools. Do not feed them
            # unsupported calls while the real interactive turn drains.
            can_execute = any(tool.get("name") == "exec_command" for tool in body.get("tools", []))
            consume = can_execute and "Firstmate watcher wake:" in user \
                and queue.exists() and queue.stat().st_size
            if consume:
                message = {"type": "function_call", "name": "exec_command",
                           "call_id": f"call_{number}", "arguments": json.dumps({
                               "cmd": "bash ./consume.sh", "workdir": str(home), "login": False})}
            else:
                message = {"id": f"msg_{number}", "type": "message", "role": "assistant",
                           "status": "completed", "phase": "final_answer", "content": [
                               {"type": "output_text", "text": "NATIVE_PARK_OK", "annotations": []}]}
            events = [
                {"type": "response.created", "response": {"id": f"resp_{number}",
                 "status": "in_progress", "output": []}},
                {"type": "response.output_item.added", "output_index": 0,
                 "item": {**message, "status": "in_progress", "content": []}},
                {"type": "response.output_item.done", "output_index": 0, "item": message},
                {"type": "response.completed", "response": {"id": f"resp_{number}",
                 "status": "completed", "output": [message], "usage": {
                     "input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}},
            ]
            data = "".join("event: " + event["type"] + "\ndata: " + json.dumps(event)
                           + "\n\n" for event in events).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Responses)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    (Path(env["CODEX_HOME"]) / "config.toml").write_text(f'''model="fixture"
model_provider="fixture"
model_context_window=1000000
[model_providers.fixture]
name="Loopback native park fixture"
base_url="http://127.0.0.1:{server.server_port}/v1"
wire_api="responses"
requires_openai_auth=false
[features]
hooks=true
shell_snapshot=false
daemon_auto_start=false
[analytics]
enabled=false
''')
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(home)
        os.execvpe("codex", ["codex", "--no-daemon", "--no-alt-screen",
                            "--dangerously-bypass-hook-trust", "-a", "never",
                            "-s", "danger-full-access", "-C", str(home),
                            "Reply NATIVE_PARK_OK."], env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 180, 0, 0))
    captured = b""
    consent_at = None
    consent_sends = 0
    consent_last = 0
    park_pids = set()
    owned_pids = set()
    closed = False
    native_reaped = False
    log = (case / "terminal.log").open("wb")
    actions = (case / "input.log").open("w")

    def pump():
        nonlocal captured, consent_at, consent_sends, consent_last, closed
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                closed = True
                return
            log.write(data)
            log.flush()
            captured += data
            if b"\x1b[6n" in data:
                os.write(fd, b"\x1b[1;1R")
            if b"\x1b[?u" in data:
                os.write(fd, b"\x1b[?0u")
            plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", captured)
            trust_prompt = any(text in plain for text in [
                b"Trust this folder?", b"Do you trust the contents of this directory?"])
            footer = any(text in plain for text in [b"enter continue", b"enter to continue"])
            if consent_at is None and trust_prompt and footer:
                consent_at = time.monotonic()
        # The startup lock is a structural postcondition of dialog dismissal;
        # do not send another Enter while the accepted session runs its digest.
        consent_done = bool(requests) or (home / "state/.lock").exists()
        if consent_at and not consent_done and time.monotonic() - consent_at > 1 \
                and time.monotonic() - consent_last > 3 and consent_sends < 3:
            os.write(fd, b"\r")
            consent_sends += 1
            consent_last = time.monotonic()
            actions.write(f"settled folder consent Enter {consent_sends}\n")
            actions.flush()

    def wait_for(predicate, label, seconds=60):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            pump()
            if predicate():
                return
            if closed:
                break
        raise AssertionError(f"{label}; evidence: {case}")

    def record():
        try:
            data = json.loads((home / "state/.codex-park.json").read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}
        if data.get("pid"):
            park_pids.add(data["pid"])
        return data

    def parked_tree():
        data = record()
        if data.get("outcome") != "waiting":
            return False
        try:
            watcher = int((home / "state/.watch.lock/pid").read_text())
        except (FileNotFoundError, ValueError):
            return False
        # Walk only this private home's locked watcher ancestors. The path to
        # the recorded hook includes the arm and its timeout even when they
        # use separate process groups; never select processes by name.
        chain = set()
        child = watcher
        while child > 1 and child not in chain:
            chain.add(child)
            if child == data["pid"]:
                assert len(chain) >= 4, f"missing watcher/arm/timeout ownership: {chain}"
                owned_pids.update(chain)
                (case / "owned-pids.json").write_text(json.dumps(sorted(owned_pids)))
                return True
            parent = subprocess.run(["ps", "-o", "ppid=", "-p", str(child)],
                                    capture_output=True, text=True, check=False)
            if not parent.stdout.strip():
                return False
            child = int(parent.stdout.strip())
        return False

    def consumed():
        path = home / "consumed.log"
        return len(path.read_text().splitlines()) if path.exists() else 0

    try:
        wait_for(lambda: requests, "native SessionStart did not reach the provider")
        context = json.dumps(requests[0])
        assert "primary harness: codex" in context, "native startup selected the wrong harness"
        if VERIFIED:
            assert "Mode: Codex asynchronous Stop-hook-owned supervision." in context, \
                f"{VERSION}: native session did not select the verified park"
            assert (home / "state/.codex-park-session").exists(), "native session was not registered"
        if not VERIFIED:
            assert "Mode: Codex foreground checkpoint." in context, \
                "unverified native session did not retain foreground supervision"
            wait_for(lambda: (home / "stop-exits").exists()
                     and (home / "stop-exits").stat().st_size,
                     "native asynchronous Stop did not finish")
            assert set((home / "stop-exits").read_text().splitlines()) == {"0"}, \
                "unsupported asynchronous Stop failed instead of remaining inert"
            for artifact in [".codex-park-session", ".codex-park.lock", ".codex-park.json",
                             ".codex-park-fallback", ".watch.lock"]:
                assert not (home / "state" / artifact).exists(), \
                    f"unverified native session created {artifact}"
        elif fail_arm:
            wait_for(lambda: (home / "state/.codex-park-fallback").exists()
                     and "attempt 2/2" in json.dumps(requests)
                     and "foreground fallback" in json.dumps(requests),
                     "arm failures were not delivered with visible fallback")
            assert record().get("outcome") == "failed", "repeated arm failure was not recorded"
        else:
            wait_for(parked_tree, "async Stop did not establish its owned watcher/arm/timeout")
            owner = record()["pid"]
            before = len(requests)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                pump()
            assert len(requests) == before, "a quiet native park called the provider"
            for event in [1, 2]:
                (home / "trigger").write_text(f"LAB_ACTIONABLE_WAKE_{event}\n")
                wait_for(lambda: consumed() >= event and record().get("pid") != owner
                         and parked_tree(),
                         f"actionable wake {event} was not consumed and rearmed")
                assert not (home / "state/.wake-queue").read_text(), "wake was not acknowledged"
                assert f"LAB_ACTIONABLE_WAKE_{event}" in (home / "drains.log").read_text()
                owner = record()["pid"]
            assert not (home / "state/.codex-park-fallback").exists(), "healthy delivery latched fallback"
        # Normal native exit must stop the owned hook and watcher, not leave a
        # second supervisor running after the test. No shared daemon is used.
        os.write(fd, b"/quit")
        deadline = time.monotonic() + 1.3
        while time.monotonic() < deadline:
            pump()
        os.write(fd, b"\r")
        wait_for(lambda: closed, "native /quit did not exit", seconds=10)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if not native_reaped:
                native_reaped = os.waitpid(pid, os.WNOHANG)[0] == pid
            if native_reaped and not any(alive(owner) for owner in park_pids | owned_pids):
                break
            time.sleep(0.1)
        assert native_reaped, f"native child survived /quit: {case}"
        survivors = [owner for owner in park_pids | owned_pids if alive(owner)]
        assert not survivors, f"native park/watcher/arm/timeout survived exit: {survivors}; {case}"
    finally:
        try:
            os.killpg(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        # Emergency cleanup also covers the captured children that used a
        # separate process group. This runs only after the natural-exit verdict.
        for owner in owned_pids:
            try:
                os.kill(owner, signal.SIGTERM)
            except ProcessLookupError:
                pass
        if not native_reaped:
            os.waitpid(pid, 0)
        os.close(fd)
        log.close()
        actions.close()
        server.shutdown()
        server.server_close()
        thread.join()
    print(f"ok - {VERSION}: native park {name}")


try:
    if VERIFIED:
        run_case("delivery-rearm")
        run_case("failure-fallback", fail_arm=True)
    else:
        run_case("unsupported-foreground")
except Exception as error:
    raise SystemExit(f"not ok - {VERSION}: native park lifecycle: {error}") from error
