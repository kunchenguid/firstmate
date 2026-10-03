#!/usr/bin/env python3
"""Replace one task's canonical Intent with MAIN-supplied processed requirements.

This purpose-specific owner writes no task state, progress mirror, lifecycle
record, authority ledger, provenance receipt, or scheduling record.
The task brief is the sole intent record.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

MAX_BYTES = 262144


class Refusal(Exception):
    pass


def require(ok, reason):
    if not ok:
        raise Refusal(reason)


def atom(value):
    return isinstance(value, str) and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,159}", value))


def text(value, maximum=8192):
    return isinstance(value, str) and bool(value) and len(value) <= maximum and "\0" not in value


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def regular(path):
    st = path.lstat()
    require(stat.S_ISREG(st.st_mode) and st.st_nlink == 1, "unsafe file: " + str(path))
    require(st.st_uid == os.getuid() and st.st_size <= MAX_BYTES, "unsafe owner or size: " + str(path))
    return path.read_bytes()


class Intent:
    def __init__(self, task):
        require(atom(task), "invalid task id")
        require(os.environ.get("FM_SUPERVISION_ACTOR", "main") == "main",
                "intent updates belong to MAIN")
        require(bool(os.environ.get("FM_HOME")), "FM_HOME must be explicit")
        self.id = task
        self.home = Path(os.environ["FM_HOME"]).resolve(strict=True)
        self.data = Path(os.environ.get("FM_DATA_OVERRIDE", self.home / "data")).resolve(strict=True)
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE", self.home / "state")).resolve(strict=True)
        self.directory = self.data / task
        require(self.directory.is_dir() and not self.directory.is_symlink(),
                "missing or unsafe task data directory")

    def native_owner(self):
        pid = regular(self.state / ".lock").decode().strip()
        require(pid.isdigit() and int(pid) > 1, "missing native owner")
        parent = os.getpid()
        for _ in range(32):
            if str(parent) == pid:
                break
            result = subprocess.run(["ps", "-o", "ppid=", "-p", str(parent)],
                                    capture_output=True, text=True, check=False)
            require(result.returncode == 0 and result.stdout.strip().isdigit(),
                    "cannot verify native input owner")
            parent = int(result.stdout.strip())
            require(parent > 1, "input caller is outside owning session")
        require(str(parent) == pid, "input owner ancestry exceeded")

    @staticmethod
    def intent_body(raw, requirement):
        body = raw.decode()
        heading = "## Captain's intent\n"
        require(body.count(heading) == 1, "brief needs one canonical Captain intent subsection")
        start = body.index(heading) + len(heading)
        end = re.search(r"^#{1,2} ", body[start:], flags=re.M)
        position = start + end.start() if end else len(body)
        suffix = body[position:].lstrip("\n")
        result = body[:start] + requirement.rstrip("\n") + "\n"
        if suffix:
            result += "\n" + suffix
        encoded = result.encode()
        require(len(encoded) <= MAX_BYTES, "updated brief too large")
        return encoded

    def update(self, requirement):
        self.native_owner()
        require(text(requirement), "intent update requires processed requirement text of at most 8192 characters")
        require(requirement.strip(), "intent update requires non-whitespace processed requirement text")
        require(not re.search(r"^#{1,2}(?:[ \t]+|$)", requirement, flags=re.M),
                "intent update requirement must keep structure inside the Intent subsection; "
                "use Markdown heading level 3 or deeper")
        brief = self.directory / "brief.md"
        raw = regular(brief)
        updated = self.intent_body(raw, requirement)
        if updated == raw:
            return {"task_id": self.id, "mode": "replace", "brief_sha256": digest(raw)}
        fd, name = tempfile.mkstemp(prefix=".brief.", dir=self.directory)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(updated)
                stream.flush()
                os.fsync(stream.fileno())
            require(regular(brief) == raw, "brief changed during intent update")
            os.replace(name, brief)
            directory_fd = os.open(self.directory, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            if os.path.exists(name):
                os.unlink(name)
        return {"task_id": self.id, "mode": "replace", "brief_sha256": digest(updated)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("update-brief",))
    parser.add_argument("task")
    parser.add_argument("--requirement", required=True)
    args = parser.parse_args()
    result = Intent(args.task).update(args.requirement)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (Refusal, OSError, UnicodeError, ValueError, TypeError, KeyError,
            subprocess.TimeoutExpired) as error:
        print("REFUSED: " + str(error), file=sys.stderr)
        sys.exit(6)
