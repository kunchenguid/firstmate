"""Exercise the public control command, real transport and module callbacks."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

root = Path(sys.argv[1])
mod = root / ".claude/mods/firstmate-native-control"
bridge = mod / "bridge.py"


def wait_for(fn):
    for _ in range(150):
        try:
            if fn():
                return
        except (OSError, ValueError):
            pass
        time.sleep(.03)
    raise AssertionError("fixture did not become ready")


def run_case(name, options, success=False, args=None, mutate=None, ready_expected=True):
    with tempfile.TemporaryDirectory(prefix="fm-native-") as tmp:
        path = Path(tmp).resolve()
        home = path / "home"
        subprocess.run(["bash", str(root / "bin/fm-lab-home.sh"), "create", str(home)], check=True, capture_output=True)
        channel = Path(subprocess.check_output([sys.executable, str(bridge), "prepare", str(home / "state"), "t1", "fixture:w1:p1"], text=True).strip())
        config = path / "fixture.json"
        config.write_text(json.dumps(options))
        process = subprocess.Popen(["node", str(root / "tests/fixtures/native-control/engine.mjs"), str(mod), str(channel), str(config)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        threading.Thread(target=process.wait, daemon=True).start()
        try:
            (path / "pid").write_text(str(process.pid))
            subprocess.run([sys.executable, str(bridge), "boot", str(channel), str(process.pid)], check=True)
            wait_for(lambda: (channel / "started.json").exists())
            assert (channel / "ready.json").exists() == ready_expected, (name, "native readiness")
            bin_dir = path / "bin"
            bin_dir.mkdir()
            (bin_dir / "herdr").symlink_to(root / "tests/fixtures/native-control/herdr.py")
            meta = home / "state/t1.meta"
            meta.write_text(f"window=fixture:w1:p1\nbackend=herdr\nendpoint_task_id=t1\nworktree={path}\nproject={path}\nharness=claude\nkind=ship\nnative_control={channel}\nherdr_session=fixture\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\n")
            if mutate:
                mutate(channel, meta)
            env = dict(os.environ, FM_HOME=str(home), NATIVE_FIXTURE=str(path),
                       PATH=f"{bin_dir}:{os.environ['PATH']}", FM_CONTROL_POLL="0.05", FM_CONTROL_EXIT_WAIT=".6", FM_CONTROL_SETTLE_WAIT=".1")
            result = subprocess.run(["bash", str(root / "bin/fm-control.sh"), "t1", *(args or ["exit", "--discard-pending"])], env=env, text=True, capture_output=True, timeout=25)
            assert (result.returncode == 0) == success, (name, result.stdout, result.stderr)
            if success:
                process.wait(timeout=2)
                assert "stopped t1" in result.stdout and process.returncode == 0
                assert json.loads((channel / "box.json").read_text())["text"] == ""
            else:
                assert process.poll() is None, "refusal killed fixture process"
                if not options.get("stubborn") and not options.get("commandError"):
                    assert not (channel / "command.json").exists(), "refusal sent native exit"
                if options.get("conflict"):
                    assert json.loads((channel / "box.json").read_text())["text"] == "NEW EDIT"
                if options.get("holdPoll"):
                    before = (channel / "box.json").read_bytes()
                    (channel / "release-poll").touch()
                    time.sleep(.7)
                    assert (channel / "box.json").read_bytes() == before, "late callback mutated after timeout"
                    assert not (channel / "command.json").exists()
            assert not (path / "unexpected").exists(), "unexpected terminal transport"
            assert not (path / "keys").exists(), "native path sent terminal keys"
            assert not (home / "state/.input-t1.lock").exists(), "input lock leaked"
            print("ok -", name, flush=True)
        finally:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=5)


run_case("full public native discard and real process death", {}, True)
run_case("Claude 2.1.292 public native discard and real process death", {"version": "2.1.292"}, True)
for version in ("2.1.291", "2.1.293", "2.1.292-dev", "unknown"):
    run_case(f"unverified Claude {version} refuses native control", {"version": version}, ready_expected=False)

def unverified_ready(channel, meta):
    path = channel / "ready.json"
    value = json.loads(path.read_text())
    value["version"] = "2.1.293"
    path.write_text(json.dumps(value))

run_case("unverified capability version refuses public control", {}, mutate=unverified_ready)
for name, options in [
    ("dialog refusal", {"refusal": "dialog"}),
    ("headless refusal", {"refusal": "no_composer"}),
    ("unknown native fill refusal", {"refusal": "future-reason"}),
    ("default-empty read cannot prove sentinel", {"redacted": True}),
    ("middleware rewriting fill refuses", {"rewrite": True}),
    ("edit before exit is preserved and refuses", {"conflict": True}),
    ("receipt without process death refuses", {"stubborn": True}),
    ("native command failure refuses", {"commandError": True}),
]:
    run_case(name, options)
run_case("ordinary exit preserves pending text", {}, args=["exit"])
run_case("flag is exit-only", {}, args=["interrupt", "--discard-pending"])
run_case("other harness refused", {}, mutate=lambda c, m: m.write_text(m.read_text().replace("harness=claude", "harness=muse")))
run_case("missing module channel refused", {}, mutate=lambda c, m: (c / "ready.json").unlink())
run_case("wrong task capability refused", {}, mutate=lambda c, m: m.write_text(m.read_text().replace("native_control=", "missing_control=")))
run_case("timeout retires request before delayed callback", {"holdPoll": True})

# Protocol fault cases use the same executable as the module, with no mock of
# authorization, private paths, atomic publication or single-use consumption.
with tempfile.TemporaryDirectory(prefix="fm-native-protocol-") as tmp:
    channel = Path(subprocess.check_output([sys.executable, str(bridge), "prepare", tmp, "t1", "fixture:w1:p1"], text=True).strip())
    subprocess.run([sys.executable, str(bridge), "boot", str(channel), str(os.getpid())], check=True)
    def call(action, value):
        result = subprocess.run([sys.executable, str(bridge), action, str(channel)], input=json.dumps(value), text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    for version in ("2.1.291", "2.1.293", "2.1.292-dev", "unknown"):
        result = subprocess.run([sys.executable, str(bridge), "ready", str(channel)],
                                input=json.dumps({"pid": os.getpid(), "version": version, "session": "one"}),
                                text=True, capture_output=True)
        assert result.returncode != 0 and "unsupported native engine" in result.stderr, version
        assert not (channel / "ready.json").exists(), "unverified version published readiness"
    ready = call("ready", {"pid": os.getpid(), "version": "2.1.288", "session": "one"})
    q = {k: ready[k] for k in ("task", "target", "session", "instance", "pid")}
    q.update(schema=1, discard=True, nonce="a" * 32, caller=os.getpid(), owner=os.getpid(), expires=time.time() + 20)
    req = channel / "request.json"
    def publish(value):
        req.write_text(json.dumps(value)); req.chmod(0o600)
    for field, bad in [("task", "other"), ("target", "wrong:w1:p1"), ("session", "old"),
                       ("instance", "old"), ("pid", 0), ("owner", 0), ("caller", 0),
                       ("discard", False), ("schema", 2), ("nonce", "short"),
                       ("expires", time.time() - 1), ("revoked", True)]:
        publish(dict(q, **{field: bad}))
        assert call("poll", ready) is None, field
    publish(q)
    assert call("poll", ready)["nonce"] == q["nonce"]
    assert call("poll", ready) is None, "request replayed"
    newer = call("ready", {"pid": os.getpid(), "version": "2.1.288", "session": "one"})
    assert call("poll", newer) is None, "old request reached reloaded module"
    req.unlink(); req.symlink_to(channel / "boot.json")
    result = subprocess.run([sys.executable, str(bridge), "poll", str(channel)], input=json.dumps(newer), text=True, capture_output=True)
    assert result.returncode != 0, "symlink request accepted"
    print("ok - wrong bindings, dead owners, expiry, replay, reload and symlink all refuse", flush=True)
