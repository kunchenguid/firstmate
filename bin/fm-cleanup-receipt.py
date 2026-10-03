#!/usr/bin/env python3
"""Exact cleanup-operation receipt owner.

This store is not task progress or semantic acceptance.  It binds only the
cleanup transaction to one home, task, executor generation, retained-copy
identity, phase readback, and final cleanup facts.  Historical v1 receipts may
carry goal_revision; it is preserved but never consulted for new operations.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

MAX_BYTES = 1024 * 1024


class Refusal(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def regular(path, allow_missing=False):
    try:
        st = path.lstat()
    except FileNotFoundError:
        if allow_missing:
            return None
        raise Refusal(f"missing cleanup evidence: {path}")
    require(path.is_file() and not path.is_symlink() and st.st_nlink == 1, f"unsafe cleanup evidence: {path}")
    raw = path.read_bytes()
    require(len(raw) <= MAX_BYTES, f"cleanup evidence too large: {path}")
    return raw


def load(path):
    raw = regular(path)
    try:
        return json.loads(raw)
    except (TypeError, ValueError) as error:
        raise Refusal(f"invalid cleanup receipt: {error}") from error


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


class Receipt:
    def __init__(self, task, generation):
        require(task and all(c.isalnum() or c in "._-" for c in task) and len(task) <= 160,
                "invalid task id")
        require(generation, "cleanup generation is required")
        self.task = task
        self.generation = generation
        self.home = Path(os.environ["FM_HOME"]).resolve(strict=True)
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE", self.home / "state")).resolve(strict=True)
        self.path = self.state / f"{task}.cleanup.json"

    def read(self):
        value = load(self.path)
        require(value.get("schema") == "fm-task-cleanup.v1" and value.get("task_id") == self.task and
                value.get("spawn_gen") == self.generation and isinstance(value.get("phases"), dict),
                "cleanup receipt identity conflict")
        return value

    def initial(self):
        return {"schema": "fm-task-cleanup.v1", "task_id": self.task,
                "spawn_gen": self.generation, "phases": {}}

    def current_or_initial(self):
        if self.path.exists() or self.path.is_symlink():
            return self.read()
        return self.initial()

    def write(self, value):
        raw = (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
        require(len(raw) <= MAX_BYTES, "cleanup receipt too large")
        fd, temporary = tempfile.mkstemp(prefix=f".{self.task}.cleanup.", dir=self.state)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    @staticmethod
    def identity(raw):
        path = Path(raw)
        require(path.is_absolute() and path.is_dir() and not path.is_symlink(),
                "copy/project needs an existing absolute directory")
        canonical = path.resolve(strict=True)
        st = canonical.stat()
        result = {"path": str(canonical), "device": st.st_dev, "inode": st.st_ino}
        git = subprocess.run(["git", "-C", str(canonical), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                             capture_output=True, text=True, check=False, timeout=10)
        if git.returncode == 0:
            common = Path(git.stdout.strip()).resolve(strict=True)
            common_st = common.stat()
            result["git"] = {"path": str(common), "device": common_st.st_dev, "inode": common_st.st_ino}
        return result

    def copy_inspect(self):
        meta = self.state / f"{self.task}.meta"
        fields = {}
        for line in regular(meta).decode().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                require(key not in fields, f"duplicate metadata field: {key}")
                fields[key] = value
        require(fields.get("spawn_gen") == self.generation, "copy execution generation conflict")
        return {"home": str(self.home), "task": self.task, "spawn_gen": self.generation,
                "copy": self.identity(fields.get("worktree", "")),
                "project": self.identity(fields.get("project", ""))}

    def copy_bind(self):
        binding = self.copy_inspect()
        receipt = self.current_or_initial()
        require(not receipt.get("copy_binding") or receipt["copy_binding"] == binding, "copy binding changed")
        if receipt.get("copy_binding") != binding:
            receipt["copy_binding"] = binding
            self.write(receipt)
        return binding

    def copy_read(self):
        receipt = self.read()
        binding = receipt.get("copy_binding")
        require(isinstance(binding, dict) and binding.get("home") == str(self.home) and
                binding.get("task") == self.task and binding.get("spawn_gen") == self.generation,
                "missing exact retained copy binding; recover original owner evidence, never recreate metadata")
        phase = receipt["phases"].get("directory_return", {})
        require(isinstance(phase, dict), "invalid retained copy phase")
        if phase.get("state") == "confirmed":
            return {"binding": binding, "phase": phase, "absent": False}
        for kind in ("project", "copy"):
            identity = binding.get(kind, {})
            path = Path(identity.get("path", ""))
            require(path.is_absolute(), "invalid copy binding path")
            if kind == "copy" and not path.exists() and not path.is_symlink():
                return {"binding": binding, "phase": phase, "absent": True}
            require(path.is_dir() and not path.is_symlink() and str(path.resolve()) == identity.get("path"),
                    "copy/project path changed")
            st = path.stat()
            require(st.st_dev == identity.get("device") and st.st_ino == identity.get("inode"),
                    "copy/project identity changed")
            git_identity = identity.get("git")
            if git_identity:
                git = subprocess.run(["git", "-C", str(path), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                     capture_output=True, text=True, check=False, timeout=10)
                require(git.returncode == 0, "copy Git owner unreadable")
                common = Path(git.stdout.strip()).resolve(strict=True)
                common_st = common.stat()
                require(str(common) == git_identity.get("path") and common_st.st_dev == git_identity.get("device") and
                        common_st.st_ino == git_identity.get("inode"), "copy Git owner changed")
        return {"binding": binding, "phase": phase, "absent": False}

    def binding(self):
        receipt = self.read()
        journal = self.state / f"{self.task}.herdr-presentation"
        value = digest(regular(journal))
        require(receipt.get("journal_sha256") in (None, value), "cleanup launch binding changed")
        return value

    def completion_record(self, facts):
        receipt = self.current_or_initial()
        current = receipt.get("completion")
        candidate = {"spawn_gen": self.generation, "facts": facts}
        require(current in (None, candidate), "cleanup completion receipt conflict")
        if current is None:
            receipt["completion"] = candidate
            self.write(receipt)
        return candidate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("operation", choices=("read", "create", "copy-inspect", "copy-bind", "copy-read", "binding", "completion-record", "completion-read"))
    parser.add_argument("task")
    parser.add_argument("--generation", required=True)
    parser.add_argument("--facts")
    args = parser.parse_args()
    owner = Receipt(args.task, args.generation)
    if args.operation == "read":
        result = owner.read()
    elif args.operation == "create":
        result = owner.current_or_initial()
        if not owner.path.exists(): owner.write(result)
    elif args.operation == "copy-inspect": result = owner.copy_inspect()
    elif args.operation == "copy-bind": result = owner.copy_bind()
    elif args.operation == "copy-read": result = owner.copy_read()
    elif args.operation == "binding":
        print(owner.binding())
        return
    elif args.operation == "completion-record":
        require(args.facts, "completion facts are required")
        result = owner.completion_record(json.loads(args.facts))
    else:
        result = owner.read().get("completion")
        require(isinstance(result, dict) and result.get("spawn_gen") == args.generation,
                "cleanup has no generation-bound completion receipt")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (Refusal, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"REFUSED: {error}", file=os.sys.stderr)
        raise SystemExit(1)
