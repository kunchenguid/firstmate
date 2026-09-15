#!/usr/bin/env python3
"""Prepare an idempotent fm-inbox note; called only by fm-inbox.sh note --key.

Usage: fm_inbox_key.py <inbox-directory> <key> (UTF-8 body on stdin).
The key is 1-160 ASCII alphanumeric/dot/dash/underscore characters.
The immutable receipt under .keys/ binds key to body and stable note id.
A per-key flock serializes publication; pending OR handled notes reconcile a
lost return. Receipts and handled notes must be retained together, including in
backups. A receipt can precede publication, so recovery republishes only when
neither location exists. The caller may reannounce the same note after a crash;
that is a repeated wake, never another note or a completion signal.
"""

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time


def atomic_write(path, content):
    fd, name = tempfile.mkstemp(prefix=".staging-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def prepare(inbox, key, body):
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,160}", key) or not body.strip():
        raise ValueError("invalid key or empty body")
    inbox = Path(inbox)
    keys = inbox / ".keys"
    keys.mkdir(parents=True, exist_ok=True, mode=0o700)
    digest = hashlib.sha256(key.encode()).hexdigest()
    note_id = "key-" + digest
    with (keys / (digest + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        receipt = keys / (digest + ".json")
        data = {"key": key, "id": note_id, "body": body}
        if receipt.exists():
            if json.loads(receipt.read_text()) != data:
                raise ValueError("idempotency key reused with different body")
        else:
            atomic_write(receipt, json.dumps(data, ensure_ascii=False))
        if not (inbox / (note_id + ".note")).exists() and not (
                inbox / "handled" / (note_id + ".note")).exists():
            record = (f"id={note_id}\nat={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}"
                      f"\nsource=text\nexternal_key={key}\n--\n{body}\n")
            atomic_write(inbox / (note_id + ".note"), record)
    return note_id


if __name__ == "__main__":
    os.umask(0o077)
    try:
        print(prepare(sys.argv[1], sys.argv[2], sys.stdin.read()))
    except (OSError, ValueError, IndexError):
        sys.exit("fm-inbox: keyed note refused; inspect private receipt and filesystem")
