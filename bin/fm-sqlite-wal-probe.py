#!/usr/bin/env python3
"""Probe whether this host can share a SQLite WAL database across processes.

SQLite's WAL mode keeps its index in a shared-memory file (`<db>-shm`) that every
connection maps and locks. A host whose kernel does not implement those shared
mapping and POSIX advisory locking semantics lets a single process open a WAL
database normally, and fails only when a SECOND process opens it while the first
still holds it: SQLite retries WAL-index recovery, gives up, and returns
SQLITE_PROTOCOL (15), surfaced by callers as "locking protocol".

WSL1 is the known host in this class. The failure is kernel-level, not
filesystem-level: it reproduces on every filesystem WSL1 offers.

Usage:
  fm-sqlite-wal-probe.py <dir> [--timeout SECONDS]
      Run the probe in <dir>. Prints one line and exits:
        0  "supported"
        1  "unsupported: <detail>"
        2  "unverified: <reason>"   (no usable sqlite3; nothing was observed)
  fm-sqlite-wal-probe.py --read <db>
      Internal second-process mode; not for direct use.

The probe creates and removes its own scratch database and never opens a
database it was not asked to create.
"""

import os
import sys
import tempfile

DEFAULT_TIMEOUT = 3.0


def _read_mode(db):
    """Second process: open the WAL database the holder is holding."""
    import sqlite3

    try:
        conn = sqlite3.connect(db, timeout=1)
        conn.execute("select count(*) from probe").fetchone()
        conn.close()
    except Exception as exc:  # noqa: BLE001 - any failure to open is the verdict
        sys.stdout.write("%s: %s\n" % (type(exc).__name__, exc))
        return 1
    sys.stdout.write("ok\n")
    return 0


def _probe(directory, timeout):
    try:
        import sqlite3  # noqa: F401
    except Exception as exc:  # noqa: BLE001
        sys.stdout.write("unverified: python3 has no sqlite3 module (%s)\n" % exc)
        return 2

    import sqlite3
    import subprocess

    try:
        work = tempfile.mkdtemp(prefix="fm-walprobe-", dir=directory)
    except OSError as exc:
        sys.stdout.write("unverified: cannot create a scratch directory in %s (%s)\n" % (directory, exc))
        return 2

    db = os.path.join(work, "probe.db")
    holder = None
    try:
        # First process: create a WAL database and keep it open, exactly as a
        # long-running daemon holds its state database.
        holder = sqlite3.connect(db, timeout=1, isolation_level=None)
        mode = holder.execute("pragma journal_mode=wal").fetchone()[0]
        if mode != "wal":
            sys.stdout.write("unverified: this sqlite3 build refused WAL mode (journal_mode=%s)\n" % mode)
            return 2
        holder.execute("create table probe(x)")
        holder.execute("insert into probe values(1)")
        holder.execute("begin")
        holder.execute("select count(*) from probe").fetchone()

        # Second process: a genuinely separate process, which is the only thing
        # that exercises the cross-process WAL-index contract.
        try:
            done = subprocess.run(
                [sys.executable, os.path.abspath(__file__), "--read", db],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
        except subprocess.TimeoutExpired:
            sys.stdout.write(
                "unsupported: a second process could not open the WAL database within %gs\n" % timeout
            )
            return 1

        detail = done.stdout.decode("utf-8", "replace").strip()
        if done.returncode == 0 and detail == "ok":
            sys.stdout.write("supported\n")
            return 0
        sys.stdout.write("unsupported: a second process could not open the WAL database (%s)\n" % detail)
        return 1
    finally:
        if holder is not None:
            try:
                holder.close()
            except Exception:  # noqa: BLE001
                pass
        for suffix in ("", "-wal", "-shm"):
            try:
                os.unlink(db + suffix)
            except OSError:
                pass
        try:
            os.rmdir(work)
        except OSError:
            pass


def main(argv):
    if len(argv) >= 3 and argv[1] == "--read":
        return _read_mode(argv[2])
    if len(argv) < 2 or argv[1].startswith("-"):
        sys.stdout.write("usage: fm-sqlite-wal-probe.py <dir> [--timeout SECONDS]\n")
        return 2
    directory = argv[1]
    timeout = DEFAULT_TIMEOUT
    if len(argv) >= 4 and argv[2] == "--timeout":
        try:
            timeout = float(argv[3])
        except ValueError:
            sys.stdout.write("usage: fm-sqlite-wal-probe.py <dir> [--timeout SECONDS]\n")
            return 2
    return _probe(directory, timeout)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
