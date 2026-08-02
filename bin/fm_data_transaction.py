#!/usr/bin/env python3
"""Crash-recoverable publication for Firstmate's durable memory files."""

from __future__ import annotations

import json
import os
import signal
import stat
import tempfile
from pathlib import Path
from typing import Callable


JOURNAL_NAME = ".firstmate-data-transaction.json"
ALLOWED_NAMES = frozenset(("captain.md", "learnings.md", "backlog.md"))
MAX_JOURNAL_BYTES = 5_000_000


class TransactionError(Exception):
    def __init__(self, message: str, *, partial: bool = False) -> None:
        super().__init__(message)
        self.partial = partial


def fsync_directory(data: Path) -> None:
    descriptor = os.open(data, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write(path: Path, content: str, prefix: str) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=prefix, dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            descriptor = -1
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def load_journal(data: Path) -> dict[str, object] | None:
    journal = data / JOURNAL_NAME
    try:
        info = journal.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise TransactionError(f"cannot inspect pending data transaction: {exc}") from exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise TransactionError("pending data transaction journal is unsafe")
    if info.st_size > MAX_JOURNAL_BYTES:
        raise TransactionError("pending data transaction journal is oversized")
    try:
        payload = json.loads(journal.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise TransactionError(f"cannot read pending data transaction: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("version") != 1:
        raise TransactionError("pending data transaction journal is invalid")
    before = payload.get("before")
    if not isinstance(before, dict) or not before or not set(before).issubset(ALLOWED_NAMES):
        raise TransactionError("pending data transaction targets are invalid")
    for value in before.values():
        if (
            not isinstance(value, dict)
            or set(value) != {"present", "content"}
            or not isinstance(value["present"], bool)
            or not isinstance(value["content"], str)
        ):
            raise TransactionError("pending data transaction before-image is invalid")
    return payload


def recover_pending_transaction(data: Path) -> bool:
    payload = load_journal(data)
    if payload is None:
        return False
    if os.environ.get("FM_AUTOCOMPACT_TEST_FAIL_RECOVERY_WITH_JOURNAL") == "1":
        raise TransactionError("injected pending data transaction recovery failure")
    before = payload["before"]
    assert isinstance(before, dict)
    try:
        for name, raw_value in before.items():
            value = raw_value
            assert isinstance(name, str) and isinstance(value, dict)
            target = data / name
            if value["present"]:
                atomic_write(
                    target,
                    value["content"],
                    f".firstmate-data-recovery-{name}.",
                )
            else:
                try:
                    target.unlink()
                except FileNotFoundError:
                    pass
        fsync_directory(data)
        (data / JOURNAL_NAME).unlink()
        fsync_directory(data)
    except OSError as exc:
        raise TransactionError(f"cannot recover pending data transaction: {exc}") from exc
    return True


def publish_transaction(
    data: Path,
    snapshots: dict[str, tuple[bool, str]],
    changes: dict[str, str],
    matches: Callable[[Path, bool, str], bool],
) -> None:
    if not changes:
        return
    recover_pending_transaction(data)
    for name in changes:
        present, content = snapshots[name]
        if not matches(data / name, present, content):
            raise TransactionError(f"{name} changed before transactional publication")

    before = {
        name: {"present": snapshots[name][0], "content": snapshots[name][1]}
        for name in changes
    }
    journal_content = json.dumps(
        {"version": 1, "before": before},
        ensure_ascii=False,
        separators=(",", ":"),
    )
    if len(journal_content.encode("utf-8")) > MAX_JOURNAL_BYTES:
        raise TransactionError("data transaction journal exceeds its size limit")

    journal = data / JOURNAL_NAME
    try:
        atomic_write(journal, journal_content, ".firstmate-data-transaction.")
        fsync_directory(data)
        pause_after = os.environ.get("FM_AUTOCOMPACT_TEST_PAUSE_PUBLISH_AFTER")
        fail_after = os.environ.get("FM_AUTOCOMPACT_TEST_FAIL_PUBLISH_AFTER")
        for index, (name, content) in enumerate(changes.items(), start=1):
            if fail_after is not None and index > int(fail_after):
                raise OSError("injected publication failure")
            atomic_write(data / name, content, f".firstmate-data-new-{name}.")
            if pause_after is not None and index >= int(pause_after):
                ready = os.environ.get("FM_AUTOCOMPACT_TEST_PUBLISH_READY")
                if ready:
                    atomic_write(Path(ready), f"{os.getpid()}\n", ".publish-ready.")
                os.kill(os.getpid(), signal.SIGSTOP)
        fsync_directory(data)
        journal.unlink()
        fsync_directory(data)
    except OSError as exc:
        try:
            recover_pending_transaction(data)
        except TransactionError as recovery_exc:
            raise TransactionError(
                f"cannot publish data transaction: {exc}; {recovery_exc}",
                partial=True,
            ) from recovery_exc
        raise TransactionError(
            f"cannot publish data transaction: {exc}", partial=True
        ) from exc
