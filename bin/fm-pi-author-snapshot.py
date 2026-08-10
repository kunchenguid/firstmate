#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys


MAX_FILES = 20_000
MAX_TOTAL_BYTES = 64 * 1024 * 1024
MAX_FILE_BYTES = 16 * 1024 * 1024
SLOT_RE = re.compile(r"openai-codex(?:-[1-9][0-9]*)?")


class SnapshotError(RuntimeError):
    pass


def copy_file(source: Path, destination: Path, expected: os.stat_result) -> int:
    if expected.st_size > MAX_FILE_BYTES:
        raise SnapshotError(f"source file exceeds the per-file bound: {source}")
    source_descriptor = os.open(source, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    destination_descriptor = -1
    try:
        actual = os.fstat(source_descriptor)
        if not stat.S_ISREG(actual.st_mode) or (
            actual.st_dev,
            actual.st_ino,
            actual.st_size,
        ) != (expected.st_dev, expected.st_ino, expected.st_size):
            raise SnapshotError(f"source file changed during snapshot: {source}")
        mode = 0o700 if actual.st_mode & 0o111 else 0o600
        destination_descriptor = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            mode,
        )
        copied = 0
        while True:
            chunk = os.read(source_descriptor, min(1024 * 1024, MAX_FILE_BYTES + 1 - copied))
            if not chunk:
                break
            copied += len(chunk)
            if copied > MAX_FILE_BYTES:
                raise SnapshotError(f"source file exceeds the per-file bound: {source}")
            written = 0
            while written < len(chunk):
                written += os.write(destination_descriptor, chunk[written:])
        final = os.fstat(source_descriptor)
        if (final.st_dev, final.st_ino, final.st_size) != (
            actual.st_dev,
            actual.st_ino,
            actual.st_size,
        ):
            raise SnapshotError(f"source file changed during snapshot: {source}")
        os.fsync(destination_descriptor)
        return copied
    finally:
        os.close(source_descriptor)
        if destination_descriptor >= 0:
            os.close(destination_descriptor)


def copy_tree(source: Path, destination: Path) -> None:
    counters = {"files": 0, "bytes": 0}

    def visit(source_directory: Path, destination_directory: Path, depth: int) -> None:
        metadata = source_directory.lstat()
        if not stat.S_ISDIR(metadata.st_mode) or source_directory.is_symlink():
            raise SnapshotError(f"source directory is unsafe: {source_directory}")
        destination_directory.mkdir(mode=0o700)
        for entry in sorted(os.scandir(source_directory), key=lambda item: item.name):
            if depth == 0 and (
                entry.name == "sessions"
                or ".bak" in entry.name
                or entry.name.endswith("~")
            ):
                continue
            entry_metadata = entry.stat(follow_symlinks=False)
            source_path = Path(entry.path)
            destination_path = destination_directory / entry.name
            if stat.S_ISDIR(entry_metadata.st_mode):
                visit(source_path, destination_path, depth + 1)
            elif stat.S_ISREG(entry_metadata.st_mode):
                counters["files"] += 1
                if counters["files"] > MAX_FILES:
                    raise SnapshotError("Pi source exceeds the file-count bound")
                counters["bytes"] += copy_file(
                    source_path, destination_path, entry_metadata
                )
                if counters["bytes"] > MAX_TOTAL_BYTES:
                    raise SnapshotError("Pi source exceeds the total-size bound")
            else:
                raise SnapshotError(f"Pi source contains an unsafe entry: {source_path}")

    visit(source, destination, 0)
    (destination / "sessions").mkdir(mode=0o700)


def account_identity(model: str, snapshot: Path) -> str:
    slot, separator, _ = model.partition("/")
    if separator == "" or SLOT_RE.fullmatch(slot) is None:
        raise SnapshotError("model does not name a routed Pi OpenAI provider slot")
    auth_path = snapshot / "auth.json"
    metadata = auth_path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or auth_path.is_symlink():
        raise SnapshotError("Pi snapshot has no safe auth.json")
    with auth_path.open("rb") as stream:
        raw = stream.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise SnapshotError("Pi snapshot auth.json exceeds the identity bound")
    value = json.loads(raw)
    credential = value.get(slot) if isinstance(value, dict) else None
    identity = credential.get("accountId") if isinstance(credential, dict) else None
    if not (
        isinstance(credential, dict)
        and credential.get("type") == "oauth"
        and isinstance(identity, str)
        and identity.strip()
        and not any(character in identity for character in "\0\r\n")
    ):
        raise SnapshotError("Pi snapshot has no readable OAuth account identity")
    return identity.strip()


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: fm-pi-author-snapshot.py MODEL SOURCE DESTINATION", file=sys.stderr)
        return 2
    model, source_value, destination_value = sys.argv[1:]
    source = Path(source_value)
    destination = Path(destination_value)
    if not source.is_absolute() or not destination.is_absolute():
        print("Pi snapshot paths must be absolute", file=sys.stderr)
        return 1
    if destination.exists() or destination.is_symlink():
        print(f"Pi snapshot destination already exists: {destination}", file=sys.stderr)
        return 1
    try:
        copy_tree(source, destination)
        identity = account_identity(model, destination)
    except (OSError, ValueError, UnicodeError, json.JSONDecodeError, SnapshotError) as exc:
        shutil.rmtree(destination, ignore_errors=True)
        print(f"Pi author snapshot failed: {exc}", file=sys.stderr)
        return 1
    print(identity)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
