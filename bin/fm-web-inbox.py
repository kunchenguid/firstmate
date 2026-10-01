#!/usr/bin/env python3
"""Read and acknowledge the append-only browser mailbox used by local bridges."""
from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
from pathlib import Path


def fail(message: str) -> "NoReturn":
    print(f"fm-web-inbox: {message}", file=sys.stderr)
    raise SystemExit(1)


def state_dir() -> Path:
    home = Path(os.environ.get("FM_HOME", Path(__file__).resolve().parent.parent))
    return Path(os.environ.get("FM_STATE_OVERRIDE", home / "state"))


def safe_file(path: Path, *, create: bool = False) -> Path:
    if path.is_symlink():
        fail(f"refusing symlink: {path.name}")
    if create:
        path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and not stat.S_ISREG(path.lstat().st_mode):
        fail(f"refusing non-regular file: {path.name}")
    return path


def read_state() -> tuple[Path, int, list[tuple[int, bytes, dict | None]]]:
    state = state_dir()
    if state.is_symlink() or not state.is_dir():
        fail("state directory is missing or unsafe")
    inbox = safe_file(state / ".inbox")
    seen_path = safe_file(state / ".inbox.seen")
    if not inbox.exists():
        return state, 0, []
    try:
        fd = os.open(inbox, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                fail("mailbox is not a regular file")
            with os.fdopen(fd, "rb", closefd=False) as stream:
                data = stream.read()
        finally:
            os.close(fd)
    except OSError as exc:
        fail(f"cannot read mailbox: {exc}")
    seen = 0
    if seen_path.exists():
        try:
            fd = os.open(seen_path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                if not stat.S_ISREG(os.fstat(fd).st_mode):
                    fail("mailbox cursor is not a regular file")
                with os.fdopen(fd, "r", encoding="ascii", closefd=False) as stream:
                    raw = stream.read().strip()
            finally:
                os.close(fd)
            seen = int(raw)
            if seen < 0 or seen > len(data):
                fail("mailbox cursor is outside the file")
        except (OSError, UnicodeError, ValueError):
            fail("mailbox cursor is invalid")
    rows = []
    offset = 0
    for raw in data.splitlines(keepends=True):
        offset += len(raw)
        if offset <= seen or not raw.endswith(b"\n"):
            continue
        payload = raw[:-1]
        try:
            item = json.loads(payload)
        except (json.JSONDecodeError, UnicodeDecodeError):
            item = None
        if not isinstance(item, dict):
            item = None
        rows.append((offset, payload, item))
    return state, seen, rows


def valid_message(item: dict | None) -> bool:
    if not item:
        return False
    if not isinstance(item.get("id"), str) or not item["id"]:
        return False
    if not isinstance(item.get("ts"), str) or not isinstance(item.get("text"), str):
        return False
    if item.get("channel") not in ("typed", "voice", "click"):
        return False
    if item["channel"] == "click":
        ref = item.get("ref")
        return isinstance(ref, dict) and isinstance(ref.get("task"), str) and isinstance(ref.get("sha"), str)
    return True


def append_json(path: Path, record: dict) -> None:
    safe_file(path, create=True)
    line = (json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    flags = os.O_RDWR | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        import fcntl
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.lseek(fd, 0, os.SEEK_SET)
        existing = os.read(fd, os.fstat(fd).st_size)
        for old_line in existing.splitlines():
            try:
                old = json.loads(old_line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if isinstance(old, dict) and old.get("id") == record["id"]:
                old_without_ts = {key: value for key, value in old.items() if key != "ts"}
                new_without_ts = {key: value for key, value in record.items() if key != "ts"}
                if old_without_ts != new_without_ts:
                    fail("a different reply already uses this message id")
                return
        if os.write(fd, line) != len(line):
            fail("short mailbox append")
        os.fsync(fd)
    finally:
        os.close(fd)


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("pending", "drain", "ack", "reply"):
        fail("usage: fm-web-inbox.py pending|drain|ack <id> <offset>|reply <id> <kind> <text>")
    command = argv[0]
    state, seen, rows = read_state()
    rows = [row for row in rows if row[0] > seen]
    if command == "pending":
        return 0 if rows else 1
    if command == "drain":
        for offset, raw, item in rows:
            if valid_message(item):
                print(json.dumps({"offset": offset, "message": item}, ensure_ascii=False, separators=(",", ":")))
            else:
                print(json.dumps({"offset": offset, "malformed": raw.decode("utf-8", errors="replace")}, ensure_ascii=False))
        return 0
    if command == "ack":
        if len(argv) != 3 or not rows:
            fail("ack requires the first pending message id and its byte offset")
        offset = int(argv[2])
        current_offset, _, item = rows[0]
        requested_id = (item or {}).get("id")
        malformed = not valid_message(item)
        if offset != current_offset or (argv[1] != requested_id and not (argv[1] == "--malformed" and malformed)):
            fail("ack must name the first pending message and its exact offset")
        cursor = safe_file(state / ".inbox.seen", create=True)
        fd, temp_name = tempfile.mkstemp(prefix=".inbox.seen.", dir=state)
        try:
            with os.fdopen(fd, "w", encoding="ascii") as stream:
                stream.write(f"{offset}\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temp_name, cursor)
        finally:
            if os.path.exists(temp_name):
                os.unlink(temp_name)
        return 0
    if len(argv) < 4 or not rows:
        fail("reply requires a pending message id, kind and text")
    message_id, kind = argv[1:3]
    if argv[3] == "-":
        if len(argv) != 4:
            fail("reply with stdin accepts no additional arguments")
        text = sys.stdin.read()
    else:
        text = " ".join(argv[3:])
    if not valid_message(rows[0][2]) or rows[0][2].get("id") != message_id:
        fail("reply must name the first pending valid message")
    if kind not in ("answer", "proposal", "ready", "decision", "blocked", "fyi") or not text.strip():
        fail("reply kind or text is invalid")
    from datetime import datetime, timezone
    append_json(state / ".outbox", {"id": f"reply-{message_id}", "ts": datetime.now(timezone.utc).isoformat(), "kind": kind, "text": text, "in_reply_to": message_id})
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
