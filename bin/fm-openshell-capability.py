#!/usr/bin/env python3
"""Use the task's file-transfer channel from inside its OpenShell workspace."""

import json
import os
import re
import sys
import time
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parent
CHANNEL = ROOT / "channel"
INBOX = CHANNEL / "inbox"
OUTBOX = CHANNEL / "outbox"
RESPONSES = CHANNEL / "responses"
MAX_REQUEST = 8192
MAX_RESPONSE = 2 * 1024 * 1024
NAME_RE = re.compile(r"^[0-9]+\.msg$")


def usage():
    print(
        "usage: fm-task-capability inbox list|read|ack [NNN.msg]\n"
        "       fm-task-capability status append '<one status line>'\n"
        "       fm-task-capability turn-ended\n"
        "       fm-task-capability validation request",
        file=sys.stderr,
    )
    return 2


def read_index():
    path = INBOX / "index.txt"
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("host inbox snapshot is unavailable")
    names = path.read_text(encoding="utf-8").splitlines()
    if any(not NAME_RE.fullmatch(name) for name in names) or names != sorted(names, key=lambda n: (int(n[:-4]), n)):
        raise RuntimeError("host inbox snapshot is malformed")
    return names


def read_message(name):
    if not NAME_RE.fullmatch(name) or name not in read_index():
        raise RuntimeError("message is not in the current task inbox snapshot")
    path = INBOX / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_RESPONSE:
        raise RuntimeError("task inbox message is unsafe or too large")
    return path.read_text(encoding="utf-8")


def request(operation):
    request_id = uuid.uuid4().hex
    payload = json.dumps(operation, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
    if len(payload) > MAX_REQUEST:
        raise RuntimeError("capability request is too large")
    OUTBOX.mkdir(parents=True, exist_ok=True)
    RESPONSES.mkdir(parents=True, exist_ok=True)
    destination = OUTBOX / (request_id + ".json")
    temporary = OUTBOX / (request_id + ".tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(str(temporary), flags, 0o600)
    try:
        os.write(fd, payload)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(str(temporary), str(destination))
    response_path = RESPONSES / (request_id + ".json")
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        if response_path.is_symlink():
            raise RuntimeError("host returned an unsafe capability response")
        if response_path.is_file():
            if response_path.stat().st_size > MAX_RESPONSE:
                raise RuntimeError("host capability response exceeded its size limit")
            result = json.loads(response_path.read_text(encoding="utf-8"))
            destination.unlink(missing_ok=True)
            response_path.unlink(missing_ok=True)
            if not isinstance(result, dict) or result.get("ok") is not True:
                error = result.get("error", "host capability refused the request") if isinstance(result, dict) else "invalid host response"
                raise RuntimeError(error)
            return result.get("text") or ""
        time.sleep(0.25)
    raise RuntimeError("timed out waiting for the host task capability bridge")


def main():
    args = sys.argv[1:]
    try:
        if args == ["inbox", "list"]:
            sys.stdout.write("".join(name + "\n" for name in read_index()))
            return 0
        if len(args) == 3 and args[:2] == ["inbox", "read"]:
            sys.stdout.write(read_message(args[2]))
            return 0
        if len(args) == 3 and args[:2] == ["inbox", "ack"] and NAME_RE.fullmatch(args[2]):
            text = request({"op": "inbox.ack", "name": args[2]})
        elif len(args) == 3 and args[:2] == ["status", "append"]:
            text = request({"op": "status.append", "line": args[2]})
        elif args == ["validation", "request"]:
            text = request({"op": "validation.request"})
        elif args == ["turn-ended"]:
            text = request({"op": "turn-ended"})
        else:
            return usage()
        if text:
            sys.stdout.write(text)
            if not text.endswith("\n"):
                sys.stdout.write("\n")
        return 0
    except (OSError, ValueError, UnicodeError, RuntimeError) as exc:
        print("fm-task-capability: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
