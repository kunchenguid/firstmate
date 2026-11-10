#!/usr/bin/env python3
"""Classify a /tmp snapshot against the producer table and the safety gates.

Reads the one-line-per-entry snapshot the tick already took
(`name<TAB>mtime_epoch`) and prints `class<TAB>name<TAB>age_minutes` for every
entry an acting class owns AND that passes the safety gates. The producer table
is the single source of truth: a name that matches no row is never printed, so
the tick can never act on a class the operator has not enumerated.

The gates run here, not in the shell, because they have to run 800,000 times and
a bash loop over that many names costs a minute. The tick re-verifies the
canonical path of every candidate it is about to move, so this pass is a cheap
prefilter and never the last word.

Gates, in order:
  1. age      - the class's own idle threshold
  2. busy     - the name is held by a live process (one /proc scan, done by the
                caller and passed in as --busy)
  3. protected - the literal name matches a protected glob, or the canonical
                path is one of the protected exact paths or lives under one

Both spellings are checked. A symlink named /tmp/ak47-foo resolves to its target
under realpath, so a canonical-only check would miss it; a literal-only check
would miss /tmp//ak47-foo. Checking both is the only way to be sure the two
sides of the comparison spell the path the same way.

Usage:
  classify.py --producers FILE --snapshot FILE --now EPOCH --busy FILE
              --mktemp-min N --producer-min N --orphan-min N
              --fm-home DIR [--tmp-root DIR]
              [--protected-exact PATH]... [--protected-glob GLOB]...

Writes `skipped_busy=N skipped_protected=M` to stderr.
Exit 0 on success, 2 on a malformed producer table.
"""
import argparse
import fnmatch
import os
import re
import sys

# The two systemic rows are owned by their own class so the tick can report them
# separately from the named producers.
SYSTEMIC = {"py-mkdtemp": "tmp-mktemp", "sh-mktemp": "tmp-mktemp"}


def read_producers(path):
    rows = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("|")
            if len(parts) < 3:
                sys.stderr.write(
                    f"classify.py: {path}:{lineno}: expected id|match|pattern, got {line!r}\n"
                )
                raise SystemExit(2)
            pid, match, pattern = parts[0].strip(), parts[1].strip(), parts[2]
            if match == "prefix":
                rows.append((pid, "prefix", pattern, None))
            elif match == "regex":
                try:
                    rows.append((pid, "regex", pattern, re.compile(pattern)))
                except re.error as exc:
                    sys.stderr.write(
                        f"classify.py: {path}:{lineno}: bad regex {pattern!r}: {exc}\n"
                    )
                    raise SystemExit(2)
            else:
                sys.stderr.write(
                    f"classify.py: {path}:{lineno}: match must be prefix or regex, got {match!r}\n"
                )
                raise SystemExit(2)
    return rows


def under(path, root):
    """True when path is root or lives beneath it, on a path-component boundary."""
    if path == root:
        return True
    return path.startswith(root.rstrip("/") + "/")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--producers", required=True)
    ap.add_argument("--snapshot", required=True)
    ap.add_argument("--now", type=int, required=True)
    ap.add_argument("--busy", required=True)
    ap.add_argument("--mktemp-min", type=int, required=True)
    ap.add_argument("--producer-min", type=int, required=True)
    ap.add_argument("--orphan-min", type=int, required=True)
    ap.add_argument("--fm-home", required=True)
    ap.add_argument("--tmp-root", default="/tmp")
    ap.add_argument("--protected-exact", action="append", default=[])
    ap.add_argument("--protected-glob", action="append", default=[])
    args = ap.parse_args()

    rows = read_producers(args.producers)
    # Longest prefix first so `uvn-lens-` wins over `uvn-`.
    rows.sort(key=lambda r: len(r[2]), reverse=True)

    try:
        with open(args.busy, encoding="utf-8", errors="replace") as fh:
            busy = {line.rstrip("\n") for line in fh if line.strip()}
    except OSError:
        busy = set()

    state = os.path.join(args.fm_home, "state")
    try:
        metas = {n[: -len(".meta")] for n in os.listdir(state) if n.endswith(".meta")}
    except OSError:
        metas = set()

    root = args.tmp_root.rstrip("/")
    exact = [p.rstrip("/") for p in args.protected_exact]
    globs = args.protected_glob

    def protected(name, ftype):
        literal = f"{root}/{name}"
        # Literal spelling first: a symlink's own name is what the operator wrote.
        for g in globs:
            if fnmatch.fnmatchcase(literal, g):
                return True
        for p in exact:
            if under(literal, p):
                return True
        # Then the canonical spelling, so /tmp//ak47-foo and a symlink both land.
        # Only a symlink can differ from its literal spelling here: every entry is
        # a direct child of a real /tmp, so the parent path has no link to follow.
        # The snapshot carries the type, so this costs one realpath per symlink
        # instead of one per entry.
        if ftype != "l":
            return False
        canon = os.path.realpath(literal)
        for g in globs:
            if fnmatch.fnmatchcase(canon, g):
                return True
        for p in exact:
            if under(canon, p):
                return True
        return False

    skipped_busy = skipped_protected = 0
    out = sys.stdout
    with open(args.snapshot, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            name, _, rest = line.rstrip("\n").partition("\t")
            if not name:
                continue
            mtime, _, ftype = rest.partition("\t")
            try:
                age_min = (args.now - int(float(mtime))) // 60
            except ValueError:
                continue

            # orphan-task-scratch: a /tmp/fm-<id> whose task has no metadata at
            # all. A task that still has metadata is firstmate's decision, never
            # the tick's, so it is not printed here.
            if name.startswith("fm-") and age_min > args.orphan_min:
                if name[3:] in metas:
                    continue
                cls = "orphan-task-scratch"
            else:
                cls = None
                for pid, match, pattern, rx in rows:
                    if match == "prefix":
                        if not name.startswith(pattern):
                            continue
                    elif not rx.match(name):
                        continue
                    cls = SYSTEMIC.get(pid, "tmp-producer")
                    limit = args.mktemp_min if cls == "tmp-mktemp" else args.producer_min
                    if age_min <= limit:
                        cls = None
                    break
                if cls is None:
                    continue

            if name in busy:
                skipped_busy += 1
                continue
            if protected(name, ftype or "d"):
                skipped_protected += 1
                continue
            out.write(f"{cls}\t{name}\t{age_min}\n")

    sys.stderr.write(f"skipped_busy={skipped_busy} skipped_protected={skipped_protected}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
