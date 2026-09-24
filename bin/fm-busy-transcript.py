#!/usr/bin/env python3
"""Task-bound Codex/TraeX rollout reader; called by fm-busy-lib and fm-spawn.

Usage: init STATE ID HARNESS CWD SESSIONS BACKEND TARGET
       activate STATE ID
       read STATE ID HARNESS BACKEND TARGET
       fence-target STATE BACKEND TARGET

Owns <id>.busy-session (v1 JSON). The existing busy-gen and busy-state.lock
serialize init/read/submission fencing with arm/retire. No vendor file is written.
The launch prompt carries FIRSTMATE_BUSY_GENERATION=<gen>. Only a root CLI
session whose FIRST typed UserMessage contains that whole line may bind. Cwd,
session id, verified schema version, metadata generation and endpoint must match.
Binding is sticky: inode replacement, truncation or rewriting any observed prefix
is unknown, never permission to choose a different session. Duplicate candidates
are unknown at discovery; after binding only that exact file is read. No timestamps or rendered output decide state.

Before scripted input, fence-target records the observed start count under the
same lock. An old terminal cannot settle a pending submission: each submission
requires a new task_started. Mid-turn steering coalesced by the vendor can remain
unknown after completion; there is deliberately no timeout-to-idle fallback.
Unreadable/corrupt evidence, unverified versions and logs over 32 MiB fail closed.
This is a pull source, not a busy-state event writer or turn-end notifier.
"""

import hashlib
import json
import os
from pathlib import Path
import sys
import time


VERSIONS = {"codex": "0.156.1", "traex": "0.207.1"}
LIMIT = 32 * 1024 * 1024


class Unknown(Exception):
    pass


class BrokenBinding(Unknown):
    pass


def require(ok):
    if not ok:
        raise Unknown()


def metadata(state, task):
    values = {}
    for line in (state / (task + ".meta")).read_text().splitlines():
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

    def __enter__(self):
        for _ in range(40):
            try:
                self.path.mkdir()
                return self
            except FileExistsError:
                time.sleep(0.05)
        raise Unknown()

    def __exit__(self, *_):
        self.path.rmdir()


def load(state, task):
    data = json.loads((state / (task + ".busy-session")).read_text())
    meta = metadata(state, task)
    require(data["version"] == 1)
    require(data["gen"] == (state / (task + ".busy-gen")).read_text().strip())
    require(data["gen"] == meta.get("busy_gen"))
    require(data["harness"] == meta.get("harness"))
    require(data["cwd"] == str(Path(meta["worktree"]).resolve()))
    require(data["backend"] == meta.get("backend", "tmux"))
    require(data["target"] == meta.get("window"))
    return data


def identity(payload, data):
    return (
        payload.get("source") == "cli"
        and payload.get("thread_source") == "user"
        and payload.get("originator") == data["harness"] + "-tui"
        and payload.get("cli_version") == VERSIONS[data["harness"]]
        and payload.get("id") == payload.get("session_id")
        and isinstance(payload.get("id"), str)
        and bool(payload.get("id"))
        and str(Path(payload.get("cwd", "")).resolve()) == data["cwd"]
    )


def inspect(path, data):
    # Reject unrelated sessions using only their first record. In particular,
    # child transcripts and other tasks never contribute lifecycle evidence.
    with path.open("rb") as stream:
        first = stream.readline(LIMIT + 1)
        try:
            head = json.loads(first)
        except (ValueError, UnicodeError):
            return None
        if head.get("type") != "session_meta" or not identity(head.get("payload", {}), data):
            return None
        stat = os.fstat(stream.fileno())
        require(stat.st_size <= LIMIT)
        stream.seek(0)
        raw = stream.read(LIMIT + 1)
    require(len(raw) <= LIMIT and raw.endswith(b"\n"))
    records = [json.loads(line) for line in raw.splitlines()]
    sid = head["payload"]["id"]
    marker = "FIRSTMATE_BUSY_GENERATION=" + data["gen"]
    first_user = None
    for record in records:
        payload = record.get("payload", {})
        if record.get("type") == "event_msg" and payload.get("type") == "item_completed":
            item = payload.get("item", {})
            if item.get("type") == "UserMessage":
                first_user = payload
                break
    if first_user is None:
        return None
    text = "\n".join(part.get("text", "") for part in first_user["item"].get("content", [])
                     if part.get("type") == "text")
    if marker not in text.splitlines():
        return None
    require(first_user.get("thread_id") == sid)
    turn = None
    seen = set()
    state = "unknown"
    previous = -1
    for record in records:
        ordinal = record.get("ordinal")
        require(type(ordinal) is int and ordinal > previous)
        previous = ordinal
        payload = record.get("payload", {})
        if record.get("type") == "session_meta":
            require(identity(payload, data) and payload["id"] == sid)
        if record.get("type") != "event_msg":
            continue
        event = payload.get("type")
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
    require(first_user.get("turn_id") in seen)
    return {"path": str(path), "sid": sid, "dev": stat.st_dev, "ino": stat.st_ino,
            "size": len(raw), "digest": hashlib.sha256(raw).hexdigest(),
            "raw": raw, "starts": len(seen), "state": state}


def observe(data):
    require(not data.get("broken_binding"))
    old = data.get("bound")
    if old:
        path = Path(old["path"])
        try:
            stat = path.stat()
        except FileNotFoundError as error:
            raise BrokenBinding() from error
        if stat.st_ino != old["ino"] or stat.st_dev != old["dev"] or stat.st_size < old["size"]:
            raise BrokenBinding()
        current = inspect(path, data)
        if not current or any(current[key] != old[key] for key in ("sid", "dev", "ino")):
            raise BrokenBinding()
        if hashlib.sha256(current["raw"][:old["size"]]).hexdigest() != old["digest"]:
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
        require(len(candidates) == 1)
        current = candidates[0]
    data["bound"] = {key: current[key] for key in ("path", "sid", "dev", "ino", "size", "digest")}
    return current


def read(state, task, harness, backend, target):
    with Lock(state, task):
        data = load(state, task)
        require((data["harness"], data["backend"], data["target"]) == (harness, backend, target))
        require(not data.get("unaccounted_input"))
        try:
            current = observe(data)
        except BrokenBinding:
            data["broken_binding"] = True
            save(state / (task + ".busy-session"), data)
            raise
        verdict = current["state"]
        if current["starts"] < data.get("required_starts", 0) and verdict == "idle":
            verdict = "unknown"
        save(state / (task + ".busy-session"), data)
        print(verdict + " " + harness + "-transcript")


def fence(state, backend, target):
    for path in state.glob("*.busy-session"):
        # A damaged unrelated binding must not affect another adapter's input.
        # Its own reader already fails closed, so allowing input cannot produce
        # a false idle verdict from that damaged binding.
        try:
            header = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        if (header.get("backend"), header.get("target")) != (backend, target):
            continue
        task = path.name.removesuffix(".busy-session")
        with Lock(state, task):
            data = load(state, task)
            if not data.get("input_enabled"):
                continue
            try:
                current = observe(data)
            except (Unknown, OSError, ValueError, KeyError, TypeError, AttributeError):
                # No watermark can account for this submission. Persist unknown
                # rather than blessing an old completion if the log reappears.
                data["unaccounted_input"] = True
            else:
                data["required_starts"] = max(data.get("required_starts", 0), current["starts"]) + 1
            save(path, data)


def main():
    command, state_arg, *args = sys.argv[1:]
    state = Path(state_arg)
    if command == "init":
        task, harness, cwd, sessions, backend, target = args
        require(harness in VERSIONS)
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
            data = load(state, task)
            data["input_enabled"] = True
            save(state / (task + ".busy-session"), data)
    elif command == "read":
        read(state, *args)
    elif command == "fence-target":
        fence(state, *args)
    else:
        raise Unknown()


if __name__ == "__main__":
    try:
        main()
    except (Unknown, OSError, ValueError, KeyError, TypeError, AttributeError):
        if len(sys.argv) > 4 and sys.argv[1] == "read":
            print("unknown " + sys.argv[4] + "-transcript")
        else:
            print("error: transcript binding unavailable; input not sent", file=sys.stderr)
            sys.exit(1)
