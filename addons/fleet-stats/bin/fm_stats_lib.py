"""Shared input helpers for the per-model and per-skill statistics readers.

Only bin/fm-model-stats.sh and bin/fm-skill-stats.sh import this: usage and
argument parsing, tab-separated file reading, and enumerating this home plus
every locally registered home from each home's data/secondmates.md. All
aggregation and output stays in the importing reader.
"""
import re
import sys
import time
from pathlib import Path


def parse_args(argv, prog):
    """Parse [home, --json, [--now <unix-seconds>] ...]; return (root, now).

    Exits 2 on misuse, matching the readers' original usage contract.
    """
    if len(argv) < 2 or argv[1] != '--json':
        print(f'usage: {prog} --json [--now <unix-seconds>]', file=sys.stderr)
        raise SystemExit(2)
    now = None
    rest = argv[2:]
    while rest:
        if rest[0] == '--now' and len(rest) >= 2:
            now, rest = rest[1], rest[2:]
        else:
            raise SystemExit(2)
    if now is None:
        now = str(int(time.time()))
    if not re.fullmatch(r'\d+', now):
        print(f'{prog}: --now requires Unix seconds', file=sys.stderr)
        raise SystemExit(2)
    return Path(argv[0]).resolve(), int(now)


def read_tsv(path):
    """Read a tab-separated file; None when absent, [] when empty."""
    try:
        lines = Path(path).read_text(errors='replace').splitlines()
    except OSError:
        return None
    if not lines:
        return []
    cols = lines[0].split('\t')
    rows = []
    for line in lines[1:]:
        if line == '':
            continue
        fields = line.split('\t')
        if len(fields) != len(cols):
            continue
        rows.append(dict(zip(cols, fields)))
    return rows


def walk_homes(root):
    """Map home name to local path; registered remote homes map to None."""
    homes, seen, pending = {}, set(), [('main', root)]
    while pending:
        name, home = pending.pop(0)
        if home in seen:
            continue
        seen.add(home)
        homes[name] = home
        try:
            lines = (home / 'data/secondmates.md').read_text(errors='replace').splitlines()
        except OSError:
            continue
        for line in lines:
            m = re.match(r'^- ([\w.-]+) - .*\((?:host:\s*([^;]+);\s*root:\s*([^;]+);\s*)?home:\s*([^;]+);', line)
            if not m:
                continue
            if m.group(2):
                homes[m.group(1)] = None
                continue
            path = Path(m.group(4).strip())
            if path.is_absolute():
                pending.append((m.group(1), path.resolve()))
    return homes
