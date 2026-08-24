#!/usr/bin/env python3
"""fm-hplan-guard-analyze.py - the content analyzer behind fm-hplan-guard.sh.

Sourced as a program by bin/fm-hplan-guard.sh; not part of the public surface.
See the shell script's header for the guardian's contract. This file owns the
content-side mechanics:

  * It walks the given scopes looking for WORLD-READABLE regular files whose
    CONTENT carries the HPlan inventory signature. The signature hangs on what
    the data is, never on what the file is called:
      - structured tier: a SQLite database containing table `belegung` with a
        filled `uebungsleiter` column and at least --min-rows populated rows.
      - byte tier: when the database cannot be opened as SQLite, co-presence of
        the schema tokens `uebungsleiter` and `belegung` in the raw bytes plus
        at least --byte-min bytes (covers live WAL images and orphaned ones).
      - dump tier: plain SQL text carrying both tokens plus at least one INSERT
        into `belegung`, again above the byte floor.
  * It reads files only to recognize them. Nothing it sees is ever written
    anywhere; its entire output is paths, modes, sizes, tiers, and counts.
  * It changes nothing it scans: databases are opened with URI flag
    immutable=1, which takes no locks and writes no journal, and every other
    access is plain reading.
  * Every failure is ordinary: an unreadable file, a vanished path, or a
    malformed database is counted and the walk continues. A torn time budget
    marks the scope incomplete instead of raising anything.

Usage:
  fm-hplan-guard-analyze.py --budget-secs N --min-rows N --byte-min N \
      --scan-max N SCOPE [SCOPE...]

Prints exactly one JSON object on stdout.
"""

import argparse
import json
import os
import re
import sqlite3
import sys
import time
import urllib.parse

SQLITE_MAGIC = b"SQLite format 3\x00"
MARKER_COLUMN = b"uebungsleiter"
MARKER_TABLE = b"belegung"
# Directories whose contents this detector skips, each a stated limit rather
# than an oversight: git objects are zlib-compressed (the plaintext signature
# cannot appear in them - a committed leak is a different incident family,
# caught at review, not by content scanning); dependency, bytecode, build, and
# cache trees are third-party material no one copies the inventory into.
PRUNE_NAMES = {
    ".git", "node_modules", "__pycache__", ".venv", "venv",
    ".tox", ".cache", ".mypy_cache", ".pytest_cache",
    "target", "dist", "build", ".next", ".turbo",
}
# Files below this cannot carry the inventory: the schema alone spans several
# SQLite pages, and the reporting thresholds sit far higher.
ENUM_MIN_BYTES = 8192
HEAD_BYTES = 512


class Coverage:
    def __init__(self, scope):
        self.scope = scope
        self.status = "ok"
        self.scanned = 0
        self.unreadable = 0
        self.errors = 0

    def as_dict(self):
        return {
            "scope": self.scope,
            "status": self.status,
            "scanned": self.scanned,
            "unreadable": self.unreadable,
            "errors": self.errors,
        }


def out_of_time(deadline):
    return time.monotonic() >= deadline


def human_findings(findings):
    """Merge per-path results so every reported path appears once."""
    merged = {}
    for finding in findings:
        merged.setdefault(finding["path"], finding)
    return list(merged.values())


def companion_siblings(path):
    """World-readable -wal/-shm siblings of a flagged database."""
    out = []
    for suffix in ("-wal", "-shm"):
        sib = path + suffix
        try:
            st = os.stat(sib)
        except OSError:
            continue
        if not os.path.isfile(sib) or os.path.islink(sib):
            continue
        if not st.st_mode & 0o0004:
            continue
        out.append({"path": sib, "mode": format(st.st_mode & 0o777, "o"),
                    "size": st.st_size})
    return out


def scan_bytes_for_markers(path, limit):
    """True when both schema tokens appear in the first <limit> raw bytes."""
    seen_column = False
    seen_table = False
    tail = b""
    try:
        with open(path, "rb") as handle:
            read_total = 0
            while read_total < limit:
                chunk = handle.read(min(1024 * 1024, limit - read_total))
                if not chunk:
                    break
                read_total += len(chunk)
                window = tail + chunk
                if not seen_column and MARKER_COLUMN in window:
                    seen_column = True
                if not seen_table and MARKER_TABLE in window:
                    seen_table = True
                # Tokens can straddle chunk borders; keep the last
                # (token-length - 1) bytes as overlap context.
                tail = window[-(max(len(MARKER_COLUMN), len(MARKER_TABLE)) - 1):]
                if seen_column and seen_table:
                    return True
    except OSError:
        return False
    return False


def analyze_sqlite(path, size, args):
    """Structured confirmation first, honest byte fallback second."""
    count = None
    abspath = os.path.abspath(path)
    uri = "file:" + urllib.parse.quote(abspath) + "?immutable=1"
    try:
        con = sqlite3.connect(uri, uri=True, timeout=0.25)
        try:
            row = con.execute(
                "SELECT name FROM sqlite_master"
                " WHERE type='table' AND lower(name)=?",
                ("belegung",),
            ).fetchone()
            if row is not None:
                table = row[0]
                qtable = '"' + table.replace('"', '""') + '"'
                columns = con.execute(f"PRAGMA table_info({qtable})").fetchall()
                column = next(
                    (c[1] for c in columns if str(c[1]).lower() == "uebungsleiter"),
                    None,
                )
                if column is not None:
                    qcolumn = '"' + str(column).replace('"', '""') + '"'
                    count = con.execute(
                        f"SELECT count(*) FROM {qtable}"
                        f" WHERE {qcolumn} IS NOT NULL AND trim({qcolumn})<>''"
                    ).fetchone()[0]
        finally:
            con.close()
    except (sqlite3.Error, ValueError, OverflowError):
        count = None
    if count is not None and count >= args.min_rows:
        return {"tier": "sqlite-struktur", "detail": f"zeilen={count}"}
    if size >= args.byte_min and scan_bytes_for_markers(path, args.scan_max):
        return {"tier": "byte-signatur", "detail": "marker"}
    return None


def is_text_shaped(head):
    """No NUL and almost no control bytes: prose, code, JSON, SQL text."""
    if b"\x00" in head:
        return False
    control = sum(1 for byte in head if byte < 0x09 or 0x0e <= byte <= 0x1f)
    return control <= 2


def looks_like_sql_dump(head):
    """Text-shaped head carrying SQL shape. Natural-language text that merely
    mentions the marker words never enters the dump tier here - the tier's
    verdict additionally demands an INSERT targeting belegung."""
    return is_text_shaped(head) and (
        b"create table" in head.lower() or b"insert into" in head.lower()
    )


# Containers whose contents are compressed: the plaintext signature cannot
# appear in them, so reading them is wasted budget. An archived copy is out of
# scope by design and stays a stated limit of this guardian.
COMPRESSED_SUFFIXES = (
    ".gz", ".xz", ".bz2", ".zst", ".zip", ".7z", ".lz4",
    ".tar", ".tgz", ".tbz2", ".txz",
)


def is_compressed_container(path):
    lowered = path.lower()
    return lowered.endswith(COMPRESSED_SUFFIXES)


# Compiled binaries and media containers: their payloads are compressed or
# structured formats where the plaintext signature cannot meaningfully appear.
# Skipping them before opening keeps heavy sweeps cheap; this is a stated
# limit, like the compressed-container one above.
MEDIA_SUFFIXES = (
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".ico", ".bmp",
    ".mp3", ".mp4", ".mkv", ".webm", ".wav", ".ogg", ".flac", ".mov",
    ".pdf", ".woff", ".woff2", ".ttf", ".otf", ".eot",
    ".so", ".o", ".a", ".dll", ".dylib", ".exe",
    ".class", ".jar", ".wasm", ".bin", ".iso", ".img", ".dmg",
    ".deb", ".rpm", ".appimage", ".snap",
)


def is_skippable_binary(path):
    return path.lower().endswith(MEDIA_SUFFIXES)


INSERT_INTO_BELEGUNG_RE = re.compile(
    rb"insert\s+(?:or\s+\w+\s+)?into\s+\"?belegung\"?"
)


def analyze_dump(path, size, args):
    if size < args.byte_min:
        return None
    try:
        with open(path, "rb") as handle:
            blob = handle.read(args.scan_max)
    except OSError:
        return None
    lowered = blob.lower()
    if MARKER_COLUMN not in lowered or MARKER_TABLE not in lowered:
        return None
    # The INSERT is what separates an actual data copy from prose or docs that
    # merely mention the schema: without it, this is not reported.
    if not INSERT_INTO_BELEGUNG_RE.search(lowered):
        return None
    return {"tier": "dump-signatur", "detail": "marker+einfuegung"}


def walk_scope(scope, deadline, args, findings):
    cover = Coverage(scope)
    if not os.path.isdir(scope) or os.path.islink(scope):
        cover.status = "leer"
        return cover
    for root, dirs, files in os.walk(scope, followlinks=False):
        dirs[:] = [d for d in dirs if d not in PRUNE_NAMES]
        for name in files:
            if out_of_time(deadline):
                cover.status = "unvollstaendig"
                return cover
            path = os.path.join(root, name)
            try:
                if os.path.islink(path):
                    continue
                st = os.stat(path)
            except OSError:
                cover.errors += 1
                continue
            if not os.path.isfile(path):
                continue
            if not st.st_mode & 0o0004:
                continue
            if st.st_size < ENUM_MIN_BYTES:
                continue
            if is_skippable_binary(path):
                continue
            cover.scanned += 1
            try:
                with open(path, "rb") as handle:
                    head = handle.read(HEAD_BYTES)
            except OSError:
                cover.unreadable += 1
                continue
            if len(head) < 16:
                continue
            verdict = None
            if head[:16] == SQLITE_MAGIC:
                verdict = analyze_sqlite(path, st.st_size, args)
                if verdict is not None:
                    verdict["companions"] = companion_siblings(path)
            elif looks_like_sql_dump(head):
                verdict = analyze_dump(path, st.st_size, args)
            elif (st.st_size >= args.byte_min
                    and not is_text_shaped(head)
                    and not is_compressed_container(path)):
                # Raw binary carrier: a live or orphaned WAL page image, or any
                # other NUL-bearing blob whose bytes carry the schema tokens.
                # Natural-language text never reaches this tier - German prose
                # mentioning both words stays unreported by design.
                if scan_bytes_for_markers(path, args.scan_max):
                    verdict = {"tier": "byte-signatur", "detail": "marker"}
            if verdict is None:
                continue
            findings.append({
                "path": path,
                "mode": format(st.st_mode & 0o777, "o"),
                "size": st.st_size,
                "tier": verdict["tier"],
                "detail": verdict.get("detail", ""),
                "companions": verdict.get("companions", []),
            })
        if out_of_time(deadline):
            cover.status = "unvollstaendig"
            return cover
    return cover


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--budget-secs", type=float, required=True)
    parser.add_argument("--min-rows", type=int, required=True)
    parser.add_argument("--byte-min", type=int, required=True)
    parser.add_argument("--scan-max", type=int, required=True)
    parser.add_argument("scopes", nargs="+")
    args = parser.parse_args()

    deadline = time.monotonic() + max(0.0, args.budget_secs)
    findings = []
    coverage = []
    scopes_seen = set()
    for scope in args.scopes:
        if scope in scopes_seen:
            continue
        scopes_seen.add(scope)
        if out_of_time(deadline):
            cover = Coverage(scope)
            cover.status = "unvollstaendig"
            coverage.append(cover.as_dict())
            continue
        cover = walk_scope(scope, deadline, args, findings)
        coverage.append(cover.as_dict())

    sys.stdout.write(json.dumps({
        "findings": human_findings(findings),
        "coverage": coverage,
    }))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
