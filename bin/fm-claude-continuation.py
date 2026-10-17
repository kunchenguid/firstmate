#!/usr/bin/env python3
"""Native-record proof and process binding for fm-session-lock-lib.sh; Linux only.

Internal interface: <state> <owner-pid> <model-pid> <recorded-id> <current-id>
proves the direct background handoff and writes state/.lock-continuation on first
success; <state> <owner-pid> <model-pid> proves the retained continuation binding
still names those live processes. Exit 0 on proof; every uncertainty exits 1
silently. The shell library owns the ownership contract and the ancestry trust
gate.
"""

import datetime
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def read_regular(path, *, tail=False):
    """Open every component without following symlinks, then bound the read."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("noncanonical path")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = child
        child = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    finally:
        os.close(fd)
    with os.fdopen(child, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ValueError("untrusted file")
        limit = 262144
        offset = max(0, info.st_size - limit) if tail else 0
        if not tail and info.st_size > limit:
            raise ValueError("oversized record")
        stream.seek(offset)
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError("record changed during read")
        if offset:
            data = data.partition(b"\n")[2]
        return data.decode("utf-8")


def process(pid):
    proc = Path("/proc") / str(pid)
    fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    if fields[0] in {"Z", "X"}:
        raise ValueError("dead process")
    env = unique_object(row.split("=", 1) for row in (proc / "environ").read_bytes().decode().split("\0") if "=" in row)
    cwd = os.readlink(proc / "cwd")
    home = env.get("FM_HOME") or cwd
    config = env.get("CLAUDE_CONFIG_DIR") or str(Path(env["HOME"]) / ".claude")
    if not home.startswith("/") or not config.startswith("/"):
        raise ValueError("relative process binding")
    if os.path.realpath(config) != os.path.normpath(config):
        raise ValueError("symlinked native config")
    return fields[19], cwd, os.path.realpath(home), os.path.realpath(config)


def native_record(config, pid, sid, kind, birth, cwd, domain):
    record = json.loads(read_regular(Path(config) / "sessions" / f"{pid}.json"), object_pairs_hook=unique_object)
    if not isinstance(record, dict):
        raise ValueError("nonobject registry")
    if (type(record.get("pid")) is not int or record["pid"] != pid
            or record.get("sessionId") != sid or record.get("kind") != kind
            or record.get("procStart") != birth or record.get("pidDomain") != domain
            or record.get("cwd") != cwd or record.get("spare") is True
            or type(record.get("startedAt")) not in {int, float}
            or not math.isfinite(record["startedAt"]) or record["startedAt"] <= 0):
        raise ValueError("stale or different native identity")
    # Native status/name/heartbeat fields may change while a hook proves identity.
    # Revalidation compares only the facts that actually authorize the handoff.
    keys = ("pid", "sessionId", "kind", "procStart", "pidDomain", "cwd",
            "startedAt", "parkedJobId", "jobId")
    return {key: record.get(key) for key in keys}


def markers(path):
    rows = [json.loads(line, object_pairs_hook=unique_object) for line in read_regular(path, tail=True).splitlines() if line.strip()]
    if any(not isinstance(row, dict) for row in rows):
        raise ValueError("nonobject transcript")
    links = [row for row in rows if row.get("type") == "continued-in"]
    if len(links) > 1:
        raise ValueError("ambiguous continuation")
    if links:
        index = rows.index(links[0])
        if any(row.get("type") in {"user", "assistant"} for row in rows[index + 1:]):
            raise ValueError("source conversation resumed")
    return links


def prove(state, owner, model, recorded, current):
    uuid = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
    if owner == model or recorded == current or not re.fullmatch(uuid, recorded) or not re.fullmatch(uuid, current):
        return False
    before_owner, before_model = process(owner), process(model)
    owner_birth, owner_cwd, owner_home, config = before_owner
    model_birth, model_cwd, model_home, model_config = before_model
    if (owner_home != model_home or config != model_config or owner_cwd != model_cwd
            or os.path.realpath(state) != str(Path(owner_home) / "state")):
        return False
    if (read_regular(Path(state) / ".lock") != f"{owner}\n"
            or read_regular(Path(state) / ".lock-session") != f"{recorded}\n"):
        return False
    binding_path = Path(state) / ".lock-continuation"
    identity = [owner, model, list(before_owner), list(before_model)]
    binding = None
    try:
        saved = json.loads(read_regular(binding_path), object_pairs_hook=unique_object)
        if saved["identity"] == identity:
            binding = saved
    except (OSError, ValueError, KeyError, TypeError):
        pass
    source_id = binding["source"]["sessionId"] if binding else recorded
    target_id = binding["target"]["sessionId"] if binding else current
    if not re.fullmatch(uuid, source_id) or not re.fullmatch(uuid, target_id):
        return False
    domain = f"linux:{Path('/etc/machine-id').read_text().strip()}:{os.readlink('/proc/self/ns/pid')}"
    source = native_record(config, owner, source_id, "interactive", owner_birth, owner_cwd, domain)
    target = native_record(config, model, current, "bg", model_birth, model_cwd, domain)
    if binding and (source != binding["source"] or dict(target, sessionId=target_id) != binding["target"]):
        return False
    if source.get("parkedJobId") != target_id[:8] or target.get("jobId") != target_id[:8]:
        return False
    candidates = list((Path(config) / "projects").glob(f"*/{source_id}.jsonl"))
    if len(candidates) != 1:
        return False
    links = markers(candidates[0])
    if len(links) != 1:
        return False
    link = links[0]
    if link.get("sessionId") != source_id or link.get("continuedInSessionId") != target_id:
        return False
    if not isinstance(link.get("timestamp"), str):
        return False
    timestamp = datetime.datetime.fromisoformat(link["timestamp"].replace("Z", "+00:00"))
    if (timestamp.tzinfo is None or timestamp.timestamp() * 1000 < source["startedAt"]
            or timestamp > datetime.datetime.now(datetime.timezone.utc)):
        return False
    # A moved successor is not an active direct handoff, including a cycle.
    for sid in {target_id, current}:
        successor = candidates[0].with_name(f"{sid}.jsonl")
        if os.path.lexists(successor) and markers(successor):
            return False
    valid = (before_owner == process(owner) and before_model == process(model)
            and source == native_record(config, owner, source_id, "interactive", owner_birth, owner_cwd, domain)
            and target == native_record(config, model, current, "bg", model_birth, model_cwd, domain)
            and read_regular(Path(state) / ".lock") == f"{owner}\n"
            and read_regular(Path(state) / ".lock-session") == f"{recorded}\n")
    if not valid:
        return False
    if not binding:
        fd, temporary = tempfile.mkstemp(prefix=".lock-continuation.", dir=state)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(dict(identity=identity, source=source, target=target), stream)
            os.replace(temporary, binding_path)
        finally:
            if os.path.lexists(temporary):
                os.unlink(temporary)
    return True


def bound(state, owner, model):
    if owner == model:
        return False
    if read_regular(Path(state) / ".lock") != f"{owner}\n":
        return False
    saved = json.loads(read_regular(Path(state) / ".lock-continuation"), object_pairs_hook=unique_object)
    return saved["identity"] == [owner, model, list(process(owner)), list(process(model))]


if __name__ == "__main__":
    try:
        if len(sys.argv) == 4:
            result = bound(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
        else:
            state, owner, model, recorded, current = sys.argv[1:]
            result = prove(state, int(owner), int(model), recorded, current)
    except (OSError, ValueError, KeyError, TypeError, IndexError, UnicodeError):
        result = False
    sys.exit(0 if result else 1)
