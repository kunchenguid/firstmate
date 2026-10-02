#!/usr/bin/env python3
"""Task-bound Codex/TraeX lifecycle and recovery evidence reader.

Usage: init STATE ID HARNESS CWD SESSIONS BACKEND TARGET
       activate STATE ID
       read STATE ID HARNESS BACKEND TARGET
       recover-check STATE ID ORIGINAL_TERMINAL ORIGINAL_PID
       recover-apply STATE ID RECEIPT (internal fm-busy-event recovery writer)

Owns <id>.busy-session; its writer emits v1 JSON, while readers bind the
semantic identity fields and treat the version label and additive diagnostics
as descriptive. The existing busy-gen and busy-state.lock serialize reads with
arm/retire. No vendor file is written.
The optional process_binding records the original terminal, native PID/start,
shell PID/start and kernel boot identity after in-place recovery. Every later
read/text/key guard verifies that seal against Herdr and Linux /proc. Recovery
restores the original gen only, under fm-busy-event's writer authority; its
shell owner also holds lease/control/meta locks and reconciles the backlog.
The check command writes no records. Apply must receive its exact receipt and
never replaces an existing conflicting gen, process binding or spawn_gen.
The launch prompt carries FIRSTMATE_BUSY_GENERATION=<gen>. Only a root CLI
session whose FIRST typed UserMessage contains that whole line may bind. Cwd,
session id, metadata generation and endpoint must match.
Binding is sticky: inode replacement, truncation or rewriting any observed prefix
is unknown, never permission to choose a different session. Duplicate candidates
are unknown at discovery; after binding only that exact file is read. No timestamps or rendered output decide state.
Metadata comments, including indented history, are ignored; duplicate effective
assignments still refuse identity verification.

Spawn and bounded recovery paths call this reader; ordinary busy classification
and message submission do not. This reader observes retained lifecycle evidence,
and transcript identity, launch history, typed UserMessage matching and old
pending-input fields are not transport prerequisites or delivery receipts.
last_refusal retains only a bounded stage/category, never exception or input
text; stderr exposes the same categories even when identity prevents writing.
Unreadable/corrupt evidence, malformed metadata and individual records over 32
MiB fail closed. Transcript length is not an admission boundary: records are
validated and hashed incrementally without retaining the whole log in memory.
This is a pull source, not a busy-state event writer or turn-end notifier.
"""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import time


HARNESSES = frozenset(("codex", "traex"))
LIMIT = 32 * 1024 * 1024


class Unknown(Exception):
    pass


class BrokenBinding(Unknown):
    pass


REFUSALS = {"identity-mismatch", "malformed-record", "partial-record",
            "record-too-large",
            "transient-read", "missing-evidence", "lock-busy"}


def refusal(error):
    if isinstance(error, BrokenBinding):
        return "identity-mismatch"
    if isinstance(error, OSError):
        return "transient-read"
    if isinstance(error, subprocess.SubprocessError):
        return "identity-mismatch"
    if isinstance(error, Unknown):
        return str(error) if str(error) in REFUSALS else "identity-mismatch"
    return "malformed-record"


def note_refusal(data, stage, reason):
    data["last_refusal"] = {"stage": stage, "reason": reason}
    print("transcript " + stage + " refused: " + reason, file=sys.stderr)


def require(ok, reason=""):
    if not ok:
        raise Unknown(reason)


def metadata(state, task):
    values = {}
    for line in (state / (task + ".meta")).read_text().splitlines():
        if line.lstrip().startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if sep:
            require(key not in values)
            values[key] = value
    return values


def save(path, data):
    tmp = path.with_name(path.name + ".tmp." + str(os.getpid()))
    try:
        with tmp.open("x") as stream:
            json.dump(data, stream)
            stream.write("\n")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


class Lock:
    def __init__(self, state, task):
        self.path = state / (task + ".busy-state.lock")
        self.inherited = False

    def __enter__(self):
        holder = os.environ.get("FM_BUSY_RECOVERY_LOCK_HOLDER")
        if holder is not None:
            expected_owner = os.environ.get("FM_BUSY_RECOVERY_LOCK_OWNER")
            require(holder.isascii() and holder.isdigit() and int(holder) == os.getppid(),
                    "recovery lock holder does not match the verifier parent")
            require(expected_owner and self.path.is_symlink()
                    and os.readlink(self.path) == expected_owner,
                    "recovery lock is not the shared lock acquired by the parent")
            owner = self.path.resolve(strict=True)
            require(owner.is_dir() and owner.stat().st_uid == os.getuid(),
                    "recovery lock owner is unavailable")
            require((owner / "pid").read_text().strip() == holder,
                    "recovery lock ownership changed before verification")
            self.inherited = True
            return self
        for _ in range(40):
            try:
                self.path.mkdir()
                (self.path / "pid").write_text(str(os.getpid()))
                return self
            except FileExistsError:
                time.sleep(0.05)
        raise Unknown("lock-busy")

    def __exit__(self, *_):
        if self.inherited:
            return
        (self.path / "pid").unlink(missing_ok=True)
        self.path.rmdir()


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "malformed-record")
        result[key] = value
    return result


def load(state, task, recovery=False):
    data = json.loads((state / (task + ".busy-session")).read_text(), object_pairs_hook=unique_fields)
    meta = metadata(state, task)
    # The writer label is diagnostic. Admission is bound to the task, launch,
    # process and transcript evidence below, including pending input accounting.
    require(isinstance(data, dict), "malformed-record")
    gen_path = state / (task + ".busy-gen")
    require(not gen_path.is_symlink())
    if not recovery or gen_path.exists():
        require(data["gen"] == gen_path.read_text().strip())
    require(data["gen"] == meta.get("busy_gen"))
    require(data["harness"] == meta.get("harness"))
    require(data["cwd"] == str(Path(meta["worktree"]).resolve()))
    require(data["backend"] == meta.get("backend", "tmux"))
    require(data["target"] == meta.get("window"))
    if not recovery:
        require(meta.get("launch_state") not in ("prepared", "unconfirmed"))
        if "process_binding" in data:
            require(process_binding(state, task, data) == data["process_binding"])
    return data


def herdr_snapshot(target):
    # Route through the backend owner, including its session/transport checks.
    # Tests can wrap the CLI through the guarded lab helper like fm-spawn.
    owner = Path(__file__).with_name("fm-backend.sh")
    script = '''set -eu
source "$1"
fm_backend_source herdr
fm_backend_herdr_parse_target "$2"
fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE"
fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane process-info --pane "$FM_BACKEND_HERDR_PANE"
'''
    result = subprocess.run(["bash", "-c", script, "busy-provenance", str(owner), target],
                            capture_output=True, text=True, timeout=15, check=True)
    # CLI JSON can be compact or pretty-printed. Require exactly two complete
    # documents, not two physical lines; chatter or a third response still fails.
    decoder = json.JSONDecoder(object_pairs_hook=unique_fields)
    raw = result.stdout.lstrip()
    pane, end = decoder.raw_decode(raw)
    raw = raw[end:].lstrip()
    info, end = decoder.raw_decode(raw)
    require(not raw[end:].strip(), "malformed-record")
    return pane["result"]["pane"], info["result"]["process_info"]


def process_start(pid):
    require(isinstance(pid, int) and pid > 1)
    proc = Path("/proc") / str(pid)
    require(proc.stat().st_uid == os.getuid())
    fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    require(fields[0] not in ("Z", "X"))
    return fields[19]


def launch_generation_in_argv(argv, gen):
    prompts = [arg for arg in argv if isinstance(arg, str) and arg.startswith("\u2063FIRSTMATE_OP: v1 launch-brief:")]
    return len(prompts) == 1 and "FIRSTMATE_BUSY_GENERATION=" + gen in prompts[0].splitlines()


def process_binding(state, task, data):
    # Narrow recovery capability: Linux-local Herdr Codex/TraeX only. A saved
    # transcript by itself never proves which live process owns an endpoint.
    require(sys.platform == "linux" and data["backend"] == "herdr")
    require(data["harness"] in HARNESSES)
    meta = metadata(state, task)
    require(meta.get("kind") in ("ship", "scout") and not meta.get("remote_host"))
    require(meta.get("endpoint_task_id", task) == task, "recorded endpoint task identity differs from the task")
    session, workspace, pane_number = data["target"].split(":")
    pane_id = workspace + ":" + pane_number
    require(meta.get("herdr_session") == session)
    require(meta.get("herdr_workspace_id") == workspace)
    require(meta.get("herdr_pane_id") == pane_id)
    pane, info = herdr_snapshot(data["target"])
    require(pane["pane_id"] == info["pane_id"] == pane_id)
    require(pane["tab_id"] == meta.get("herdr_tab_id"))
    require(pane["workspace_id"] == workspace)
    require(pane["agent"] == data["harness"], "Herdr agent does not match the recorded harness")
    require(str(Path(pane["foreground_cwd"]).resolve()) == data["cwd"], "Herdr foreground cwd differs from the original task copy")
    terminal = pane["terminal_id"]
    require(isinstance(terminal, str) and terminal.startswith("term_"))
    candidates = [p for p in info["foreground_processes"]
                  if p.get("name") == data["harness"] and launch_generation_in_argv(p.get("argv", []), data["gen"])]
    require(len(candidates) == 1, "no unique native harness process in the foreground")
    process = candidates[0]
    pid = process["pid"]
    start = process_start(pid)
    proc = Path("/proc") / str(pid)
    fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    require(int(fields[2]) == info["foreground_process_group_id"], "native process is no longer in the recorded foreground group")
    parent = int(fields[1])
    for _ in range(128):
        if parent == info["shell_pid"]:
            break
        require(parent > 1)
        parent = int((Path("/proc") / str(parent) / "stat").read_text().rsplit(")", 1)[1].split()[1])
    else:
        raise Unknown()
    argv = (proc / "cmdline").read_bytes().decode().strip("\0").split("\0")
    require(argv == process["argv"], "kernel and Herdr process arguments disagree")
    require(Path((proc / "exe").readlink()).name == data["harness"], "native executable name does not match the harness")
    require(str((proc / "cwd").resolve()) == data["cwd"], "native process cwd differs from the original task copy")
    require(launch_generation_in_argv(argv, data["gen"]), "original generation is absent from the live launch prompt")
    env = dict(item.split(b"=", 1) for item in (proc / "environ").read_bytes().split(b"\0") if b"=" in item)
    require(env.get(b"FM_TASK_ID") == task.encode(), "native process task environment does not match")
    require(env.get(b"GOTMPDIR") == ("/tmp/fm-" + task + "/gotmp").encode(), "native process temporary directory binding does not match")
    require(process_start(pid) == start)
    return {"terminal": terminal, "pid": pid, "start": start,
            "shell_pid": info["shell_pid"], "shell_start": process_start(info["shell_pid"]),
            "boot": Path("/proc/sys/kernel/random/boot_id").read_text().strip()}


def recovery_evidence(state, task, terminal, original_pid):
    for suffix in ("meta", "busy-session", "busy-gen", "busy-state"):
        path = state / (task + "." + suffix)
        require(not path.is_symlink())
        require(not path.exists() or (path.is_file() and path.stat().st_uid == os.getuid()))
    data = load(state, task, recovery=True)
    require(bool(data["gen"]) and all(c.isascii() and (c.isalnum() or c in "._-") for c in data["gen"]))
    record = state / (task + ".busy-state")
    if record.exists():
        require("gen=" + data["gen"] in record.read_text().split())
    current = observe(data)
    process = process_binding(state, task, data)
    require(process["terminal"] == terminal)
    require(process["pid"] == int(original_pid))
    if "process_binding" in data:
        require(data["process_binding"] == process)
    meta = metadata(state, task)
    proof = {"version": 1, "state": str(state.resolve()), "task": task,
             "gen": data["gen"], "spawn_gen": meta.get("spawn_gen", ""),
             "harness": data["harness"], "cwd": data["cwd"], "target": data["target"],
             "session_id": current["sid"], "process": process}
    return data, proof


def identity(payload, data):
    return (
        payload.get("source") == "cli"
        and payload.get("thread_source") == "user"
        and payload.get("originator") == data["harness"] + "-tui"
        and isinstance(payload.get("cli_version"), str)
        and bool(payload.get("cli_version"))
        and payload.get("id") == payload.get("session_id")
        and isinstance(payload.get("id"), str)
        and bool(payload.get("id"))
        and str(Path(payload.get("cwd", "")).resolve()) == data["cwd"]
    )


def inspect(path, data, prefix_size=0):
    # Reject unrelated sessions using only their first record. In particular,
    # child transcripts and other tasks never contribute lifecycle evidence.
    with path.open("rb") as stream:
        first = stream.readline(LIMIT + 1)
        require(len(first) <= LIMIT, "record-too-large")
        try:
            head = json.loads(first)
        except (ValueError, UnicodeError):
            return None
        if head.get("type") != "session_meta" or not identity(head.get("payload", {}), data):
            return None
        stat = os.fstat(stream.fileno())
        stream.seek(0)
        digest = hashlib.sha256()
        prefix_digest = hashlib.sha256()
        prefix_remaining = prefix_size
        sid = head["payload"]["id"]
        marker = "FIRSTMATE_BUSY_GENERATION=" + data["gen"]
        first_user_turn = None
        turn = None
        seen = set()
        state = "unknown"
        previous = -1
        user_ids = set()
        size = 0
        while True:
            raw = stream.readline(LIMIT + 1)
            if not raw:
                break
            require(len(raw) <= LIMIT, "record-too-large")
            require(raw.endswith(b"\n"), "partial-record")
            digest.update(raw)
            if prefix_remaining:
                part = raw[:prefix_remaining]
                prefix_digest.update(part)
                prefix_remaining -= len(part)
            size += len(raw)
            record = json.loads(raw)
            ordinal = record.get("ordinal")
            require(type(ordinal) is int and ordinal > previous, "malformed-record")
            previous = ordinal
            payload = record.get("payload", {})
            if record.get("type") == "session_meta":
                require(identity(payload, data) and payload["id"] == sid)
            if record.get("type") != "event_msg":
                continue
            event = payload.get("type")
            if event == "item_completed" and payload.get("item", {}).get("type") == "UserMessage":
                content = payload["item"]["content"]
                if first_user_turn is None:
                    text = "\n".join(part.get("text", "") for part in content
                                     if part.get("type") == "text")
                    if marker not in text.splitlines():
                        return None
                    first_user_turn = payload.get("turn_id")
                require(payload.get("thread_id") == sid and payload.get("turn_id") == turn
                        and state == "busy", "identity-mismatch")
                item_id = payload["item"].get("id")
                require(isinstance(item_id, str) and bool(item_id) and item_id not in user_ids,
                        "malformed-record")
                user_ids.add(item_id)
                require(isinstance(content, list), "malformed-record")
            if event not in ("task_started", "task_complete", "turn_aborted"):
                continue
            tid = payload.get("turn_id")
            require(isinstance(tid, str) and bool(tid))
            require(payload.get("thread_id", sid) == sid)
            if event == "task_started":
                require(payload.get("root_turn_id") == tid and tid not in seen)
                require(state != "busy")
                seen.add(tid)
                turn, state = tid, "busy"
            else:
                require(tid == turn)
                state = "idle"
    if first_user_turn is None:
        return None
    require(first_user_turn in seen)
    return {"path": str(path), "sid": sid, "dev": stat.st_dev, "ino": stat.st_ino,
            "size": size, "digest": digest.hexdigest(),
            "prefix_digest": prefix_digest.hexdigest() if not prefix_remaining else None,
            "state": state, "ordinal": previous}


def observe(data):
    require(not data.get("broken_binding"))
    old = data.get("bound")
    if old:
        path = Path(old["path"])
        require(not path.is_symlink() and path.resolve().is_relative_to(Path(data["sessions"])))
        try:
            stat = path.stat()
        except FileNotFoundError as error:
            raise BrokenBinding() from error
        if stat.st_ino != old["ino"] or stat.st_dev != old["dev"] or stat.st_size < old["size"]:
            raise BrokenBinding()
        current = inspect(path, data, old["size"])
        if not current or any(current[key] != old[key] for key in ("sid", "dev", "ino")):
            raise BrokenBinding()
        if current["prefix_digest"] != old["digest"]:
            raise BrokenBinding()
    else:
        root = Path(data["sessions"])
        require(root.is_dir())
        candidates = []
        # Discovery is bounded and happens only until the exact session binds.
        prior = set(data.get("prior_logs", []))
        fresh = (path for path in root.glob("*/*/*/rollout-*.jsonl") if str(path) not in prior)
        for index, path in enumerate(fresh):
            require(index < 256 and not path.is_symlink())
            candidate = inspect(path, data)
            if candidate:
                candidates.append(candidate)
                require(len(candidates) == 1)
        require(len(candidates) == 1, "missing-evidence")
        current = candidates[0]
    data["bound"] = {key: current[key] for key in ("path", "sid", "dev", "ino", "size", "digest")}
    return current


def read(state, task, harness, backend, target):
    with Lock(state, task):
        data = load(state, task)
        require((data["harness"], data["backend"], data["target"]) == (harness, backend, target))
        try:
            current = observe(data)
        except (Unknown, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
            if isinstance(error, BrokenBinding):
                data["broken_binding"] = True
            note_refusal(data, "read", refusal(error))
            save(state / (task + ".busy-session"), data)
            raise
        verdict = current["state"]
        save(state / (task + ".busy-session"), data)
        print(verdict + " " + harness + "-transcript")


def main():
    command, state_arg, *args = sys.argv[1:]
    state = Path(state_arg)
    if command in ("recover-check", "recover-apply"):
        if command == "recover-check":
            task, value, original_pid = args
            # No state writes, including no discovered transcript watermark.
            _, proof = recovery_evidence(state, task, value, original_pid)
            print(json.dumps(proof, sort_keys=True))
        else:
            task, value = args
            try:
                expected = json.loads(value)
                require(isinstance(expected, dict))
            except (ValueError, TypeError, Unknown):
                expected = json.loads(Path(value).read_text())
                require(isinstance(expected, dict))
            def interrupted(signum, _frame):
                raise SystemExit(128 + signum)
            signal.signal(signal.SIGTERM, interrupted)
            signal.signal(signal.SIGHUP, interrupted)
            with Lock(state, task):
                data, proof = recovery_evidence(state, task, expected["process"]["terminal"], expected["process"]["pid"])
                require(proof == expected)
                data["process_binding"] = proof["process"]
                # Publish the restriction first. Interruption leaves either the
                # old refusal or a fully proven original-generation binding.
                save(state / (task + ".busy-session"), data)
                gen_path = state / (task + ".busy-gen")
                if not gen_path.exists():
                    tmp = gen_path.with_name(gen_path.name + ".recover." + str(os.getpid()))
                    try:
                        with tmp.open("x") as stream:
                            stream.write(data["gen"] + "\n")
                        os.replace(tmp, gen_path)
                    finally:
                        tmp.unlink(missing_ok=True)
                print(json.dumps(proof, sort_keys=True))
    elif command == "init":
        task, harness, cwd, sessions, backend, target = args
        require(harness in HARNESSES)
        with Lock(state, task):
            gen = (state / (task + ".busy-gen")).read_text().strip()
            require(bool(gen) and all(c.isalnum() or c in "._-" for c in gen))
            save(state / (task + ".busy-session"), {
                "version": 1, "gen": gen, "harness": harness,
                "cwd": str(Path(cwd).resolve()), "sessions": str(Path(sessions).resolve()),
                "backend": backend, "target": target,
                "prior_logs": [str(path) for path in Path(sessions).resolve().glob("*/*/*/rollout-*.jsonl")],
            })
    elif command == "activate":
        task, = args
        with Lock(state, task):
            data = load(state, task, recovery=True)
            require(data["gen"] == (state / (task + ".busy-gen")).read_text().strip())
            save(state / (task + ".busy-session"), data)
    elif command == "read":
        read(state, *args)
    else:
        raise Unknown()


if __name__ == "__main__":
    try:
        main()
    except (Unknown, OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError) as error:
        print("transcript refused: " + refusal(error), file=sys.stderr)
        if len(sys.argv) > 4 and sys.argv[1] == "read":
            print("unknown " + sys.argv[4] + "-transcript")
        else:
            if sys.argv[1].startswith("recover-"):
                detail = str(error) if isinstance(error, Unknown) and str(error) else "missing, unreadable or contradictory identity evidence"
                print("error: recovery refused: " + detail, file=sys.stderr)
            else:
                print("error: transcript lifecycle evidence unavailable", file=sys.stderr)
            sys.exit(1)
