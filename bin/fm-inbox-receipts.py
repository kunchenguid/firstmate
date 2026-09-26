#!/usr/bin/env python3
"""Serialized inbox receipt projection, imported once and refreshed on owner writes.

The inbox files remain authoritative; the SQLite projection is disposable.
It mirrors private bodies, so the database and SQLite sidecars must be mode 0600
before SQLite opens them, including when repairing an existing projection.
Interrupted publications are reconciled by note id before the next operation.
Use receipts --rebuild after importing or editing records outside the owner.
Public commands and receipt bounds are owned by fm-inbox.sh.
"""

import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys


def rebuild(db, command, env, inbox):
    raw = subprocess.run(command + ["receipts", "--all-pending", "--all-handled", "--all-replies"],
                         env=env, capture_output=True, text=True, check=True)
    view = json.loads(raw.stdout)
    with db:
        db.execute("DELETE FROM notes")
        db.execute("DELETE FROM replies")
        for kind in ("pending", "handled"):
            db.executemany("INSERT INTO notes VALUES (?, ?, ?)",
                           ((kind, row["id"], json.dumps(row)) for row in view[kind]))
        db.executemany("INSERT INTO replies VALUES (?, ?, ?)",
                       ((row["cursor"], i, json.dumps(row)) for i, row in enumerate(view["replies"])))
        meta = {"home": view["home"], "omitted": view["omitted"],
                "counts": {kind: len(view[kind]) for kind in ("pending", "handled", "replies")}}
        db.execute("INSERT OR REPLACE INTO metadata VALUES (1, ?)", (json.dumps(meta),))
    return meta


def receipt_page(db, meta, args):
    parser = argparse.ArgumentParser(prog="fm-inbox.sh receipts")
    parser.add_argument("--after", default="")
    parser.add_argument("--rebuild", action="store_true")
    for kind in ("pending", "handled", "replies"):
        parser.add_argument("--all-" + kind, action="store_true")
    options = parser.parse_args(args)
    if options.after and (len(options.after) != 12 or not options.after.isascii() or not options.after.isdigit()):
        parser.error("--after must be a 12-digit reply cursor")
    result = {"schema": "fm-inbox-receipts.v1", "home": meta["home"],
              "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
              "omitted": list(meta["omitted"])}
    for kind in ("pending", "handled", "replies"):
        limit = -1 if getattr(options, "all_" + kind) else 20
        if kind == "replies":
            rows = db.execute("SELECT position, payload FROM replies WHERE cursor > ? ORDER BY cursor LIMIT ?",
                              (options.after, limit)).fetchall()
        else:
            rows = db.execute("SELECT id, payload FROM notes WHERE kind = ? ORDER BY id DESC LIMIT ?",
                              (kind, limit)).fetchall()
        result[kind] = [json.loads(payload) for _, payload in rows]
        if kind == "replies":
            omitted = meta["counts"][kind] - rows[-1][0] - 1 if rows else 0
        else:
            omitted = meta["counts"][kind] - len(rows)
        if omitted:
            surface = kind if kind == "replies" else kind + " notes"
            result["omitted"].append({"surface": f"{surface} omitted by bound: {omitted}",
                                      "reveal": "pass --all-" + kind})
    result["reply_cursor"] = result["replies"][-1]["cursor"] if result["replies"] else options.after
    return result


def refresh_note(db, meta, command, env, note_id):
    raw = subprocess.run(command + ["receipts", "--record", note_id],
                         env=env, capture_output=True, text=True, check=True)
    view = json.loads(raw.stdout)
    old = db.execute("SELECT kind FROM notes WHERE id = ?", (note_id,)).fetchone()
    if old:
        meta["counts"][old[0]] -= 1
        db.execute("DELETE FROM notes WHERE id = ?", (note_id,))
    for kind in ("pending", "handled"):
        for row in view[kind]:
            db.execute("INSERT INTO notes VALUES (?, ?, ?)", (kind, note_id, json.dumps(row)))
            meta["counts"][kind] += 1
    for row in view["replies"]:
        old_reply = db.execute("SELECT position FROM replies WHERE cursor = ?", (row["cursor"],)).fetchone()
        position = old_reply[0] if old_reply else meta["counts"]["replies"]
        db.execute("INSERT OR REPLACE INTO replies VALUES (?, ?, ?)",
                   (row["cursor"], position, json.dumps(row)))
        if not old_reply:
            meta["counts"]["replies"] += 1
    db.execute("INSERT OR REPLACE INTO metadata VALUES (1, ?)", (json.dumps(meta),))
    db.execute("DELETE FROM dirty WHERE id = ?", (note_id,))


def main():
    os.umask(0o077)
    state, home = map(Path, sys.argv[1:3])
    args = sys.argv[3:]
    state.mkdir(parents=True, exist_ok=True)
    inbox = state / "inbox"
    env = dict(os.environ, FM_INBOX_RECEIPT_OWNER="1", FM_HOME=str(home))
    command = [str(Path(__file__).with_name("fm-inbox.sh"))]
    with (state / ".inbox-receipts.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        database = state / ".inbox-receipts.sqlite3"
        fd = os.open(database, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            os.fchmod(fd, 0o600)
        finally:
            os.close(fd)
        for suffix in ("-journal", "-wal", "-shm"):
            try:
                Path(str(database) + suffix).chmod(0o600)
            except FileNotFoundError:
                pass
        with sqlite3.connect(database) as db:
            if db.execute("PRAGMA user_version").fetchone()[0] != 2:
                db.executescript("""
                    BEGIN;
                    DROP TABLE IF EXISTS notes;
                    DROP TABLE IF EXISTS replies;
                    DROP TABLE IF EXISTS metadata;
                    CREATE TABLE notes (kind TEXT, id TEXT PRIMARY KEY, payload TEXT);
                    CREATE INDEX notes_by_kind ON notes(kind, id);
                    CREATE TABLE replies (cursor TEXT PRIMARY KEY, position INTEGER, payload TEXT);
                    CREATE TABLE metadata (id INTEGER PRIMARY KEY, payload TEXT);
                    CREATE TABLE IF NOT EXISTS dirty (id TEXT PRIMARY KEY);
                    PRAGMA user_version = 2;
                    COMMIT;
                """)
            row = db.execute("SELECT payload FROM metadata WHERE id = 1").fetchone()
            meta = json.loads(row[0]) if row else None
            if meta is None or (args[0] == "receipts" and "--rebuild" in args[1:]):
                meta = rebuild(db, command, env, inbox)
            for (note_id,) in db.execute("SELECT id FROM dirty").fetchall():
                with db:
                    refresh_note(db, meta, command, env, note_id)
            if args[0] == "publish":
                source, destination, note_id = args[1:]
                with db:
                    db.execute("INSERT OR IGNORE INTO dirty VALUES (?)", (note_id,))
                os.replace(source, destination)
                with db:
                    refresh_note(db, meta, command, env, note_id)
            elif args[0] == "receipts":
                print(json.dumps(receipt_page(db, meta, args[1:]), separators=(",", ":")))
            else:
                raise ValueError("unknown receipt operation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
