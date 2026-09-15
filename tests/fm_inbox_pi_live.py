"""Native Pi responsiveness proof, with synthetic inbox data and real model answers."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
base = ROOT / ".no-mistakes"
base.mkdir(exist_ok=True)
lab = Path(tempfile.mkdtemp(prefix="pi-inbox-live-", dir=base))
(lab / "state").mkdir()
(lab / "config").mkdir()
(lab / "config/backend").write_text("tmux\n")
(lab / "config/wedge-alarm").write_text("off\n")
env = {key: value for key, value in os.environ.items()
       if not key.startswith(("FM_", "PI_SESSION_")) and key != "NO_MISTAKES_GATE"}
env.update(FM_HOME=str(lab), FM_STATE_OVERRIDE=str(lab / "state"),
           FM_ROOT_OVERRIDE=str(ROOT), FM_PI_INBOX_LAB=str(lab),
           FM_POLL="1", FM_HEARTBEAT="999999", FM_CHECK_INTERVAL="999999",
           FM_WEDGE_ALARM_EXEC="discard", PI_OFFLINE="1", PI_TELEMETRY="0")
model = os.environ.get("FM_PI_INBOX_MODEL", "openai-codex/gpt-5.6-sol")
version = subprocess.check_output(["pi", "--version"], text=True).strip()
events_path = lab / "events.jsonl"
report = {"pi": version, "model": model, "lab": str(lab), "transport": "synthetic inbox only"}


def events():
    if not events_path.exists():
        return []
    # A concurrent append can leave the last line incomplete; only complete
    # JSONL records are evidence, just as in the native RPC protocol.
    return [json.loads(line) for line in events_path.read_text().split("\n")[:-1] if line]


def wait_for(predicate, label, ticks=1800):
    for _ in range(ticks):
        if proc.poll() is not None:
            raise RuntimeError(f"Pi exited {proc.returncode} while waiting for {label}; {lab}")
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(f"Pi {version} timed out waiting for {label}; evidence {lab}")


def send(command):
    proc.stdin.write((json.dumps(command) + "\n").encode())
    proc.stdin.flush()


def note(key, body):
    at = time.time() * 1000
    result = subprocess.run([str(ROOT / "bin/fm-inbox.sh"), "note", "--key", key, "-"],
                            input=body, text=True, capture_output=True, env=env, check=True)
    note_id = result.stdout.split("\n", 1)[0].removeprefix("queued ")
    return note_id, {"intake_started_ms": at, "published_ms": time.time() * 1000}


def matching(kind, note_id=None):
    return [event for event in events() if event["kind"] == kind and
            (note_id is None or note_id in json.dumps(event["data"]))]


def answer(note_id, started, expected):
    result = wait_for(lambda: matching("reply", note_id), f"substantive answer for {note_id}")
    wait_for(lambda: matching("acknowledged", note_id), f"handled acknowledgement for {note_id}")
    if len(result) != 1 or result[0]["data"]["answer"].strip() != str(expected):
        raise RuntimeError(f"invalid or duplicate model answer: {result}")
    incoming = matching("input", note_id)
    consumed = matching("consumed", note_id)
    if not incoming or not consumed:
        raise RuntimeError("answer was not preceded by native watcher input and consumption")
    return {"note": note_id, **started, "input_ms": incoming[0]["at"],
            "consumed_ms": consumed[0]["at"], "reply_ms": result[0]["at"],
            "reply_latency_ms": round(result[0]["at"] - started["intake_started_ms"]),
            "answer": result[0]["data"]["answer"]}


prompt = ("This is an isolated Firstmate native-delivery regression. "
          "On every FIRSTMATE WATCHER WAKE, call probe_read, calculate the answer "
          "for every pending synthetic note, then call probe_reply with its id and "
          "only the numeric answer. Do not confuse a receipt with an answer. "
          "If there are no notes, finish without other work. On the explicit busy "
          "probe prompt call probe_busy exactly once, then finish that task. "
          "Use only the three probe tools. Never run shell commands or modify files.")
stdout = (lab / "rpc.jsonl").open("wb")
stderr = (lab / "stderr.log").open("wb")
proc = subprocess.Popen([
    "pi", "--mode", "rpc", "--no-session", "--offline", "--no-context-files",
    "--no-skills", "--no-prompt-templates", "--no-extensions",
    "-e", str(ROOT / "tests/fixtures/pi-inbox/probe.ts"),
    "-e", str(ROOT / ".pi/extensions/fm-primary-pi-watch.ts"),
    "--model", model, "--thinking", "low", "--system-prompt", prompt,
    "--tools", "probe_read,probe_reply,probe_busy",
], cwd=lab, env=env, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr)
passed = False
try:
    wait_for(lambda: matching("locked"), "native lock ownership")
    wait_for(lambda: (lab / "state/.last-watcher-beat").exists(), "initial watcher")
    first_pid = (lab / "state/.watch.lock/pid").read_text().strip()
    first, started = note("native-prime", "How much is 17 plus 25? Reply with the number only.")
    report["prime"] = answer(first, started, 42)
    wait_for(lambda: matching("settled"), "first run settled")
    wait_for(lambda: (lab / "state/.watch.lock/pid").read_text().strip() != first_pid,
             "real extension successor")
    # This second idle arrival is the original missing-handoff reproduction.
    # A fresh watcher alone would accidentally pass through generic recovery.
    settled_before = len(matching("settled"))
    idle, started = note("native-idle", "How much is 23 plus 14? Reply with the number only.")
    report["idle_successor"] = answer(idle, started, 37)
    wait_for(lambda: len(matching("settled")) > settled_before, "idle successor settled")

    send({"type": "prompt", "message": "Run the controlled busy probe now."})
    wait_for(lambda: matching("busy-start"), "native busy tool")
    busy, started = note("native-busy", "How much is 31 minus 12? Reply with the number only.")
    received = wait_for(lambda: matching("input", busy), "native busy follow-up enqueue")
    if received[0]["data"].get("streamingBehavior") != "followUp":
        raise RuntimeError("busy wake did not use native followUp")
    if matching("reply", busy) or matching("busy-end"):
        raise RuntimeError("busy proof did not hold the original tool until explicit release")
    (lab / "release-busy").touch()
    report["busy"] = answer(busy, started, 19)
    report["busy"]["tool_released_ms"] = matching("busy-end")[0]["at"]
    wait_for(lambda: len(matching("settled")) > settled_before + 1, "busy run settled")
    if any(len(matching("reply", request)) != 1 for request in (first, idle, busy)):
        raise RuntimeError("a request was answered twice")
    if list((lab / "state/inbox").glob("*.note")) or (lab / "state/.wake-queue").stat().st_size:
        raise RuntimeError("handled requests left pending notes or wake rows")
    report["outcome"] = "passed"
    passed = True
finally:
    (lab / "release-busy").touch()
    watcher_file = lab / "state/.watch.lock/pid"
    watcher_pid = int(watcher_file.read_text().strip()) if watcher_file.exists() else None
    if proc.poll() is None:
        send({"type": "prompt", "message": "/probe-quit"})
        try:
            proc.wait(timeout=15)
        except subprocess.TimeoutExpired:
            proc.terminate()
            proc.wait(timeout=15)
    stdout.close()
    stderr.close()
    if watcher_pid:
        # Pi can exit just before the shell arm finishes its TERM trap and
        # reaps the watcher. Observe that bounded cleanup rather than racing it.
        for _ in range(150):
            try:
                os.kill(watcher_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.1)
        else:
            report["outcome"] = "watcher cleanup failed"
            passed = False
    (lab / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    output = os.environ.get("FM_PI_INBOX_EVIDENCE")
    if output:
        destination = Path(output)
        destination.mkdir(parents=True, exist_ok=True)
        for name in ("events.jsonl", "rpc.jsonl", "stderr.log", "report.json"):
            if (lab / name).exists():
                shutil.copy2(lab / name, destination / name)
    if passed:
        shutil.rmtree(lab)
if not passed:
    raise RuntimeError(f"native Pi {version} proof failed; evidence {lab}")
print(f"ok - native Pi {version} answers inbox notes on idle and busy successor cycles: "
      f"idle={report['idle_successor']['reply_latency_ms']}ms busy={report['busy']['reply_latency_ms']}ms")
