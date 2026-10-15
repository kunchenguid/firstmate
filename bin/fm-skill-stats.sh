#!/usr/bin/env bash
# fm-skill-stats.sh - per-skill fleet statistics for the dashboard's Skills view.
# Usage: FM_HOME=<home> fm-skill-stats.sh --json [--now <unix-seconds>]
#
# Read-only: it writes nothing and never touches an endpoint. It reads
# data/metrics/skills.tsv, one row per (day, home, skill) with the reads a private
# collector recorded; the file may be absent, and the reader then reports no rows
# rather than failing. It also enumerates each local home's skill directories so it
# can name skills that were never read.
#
# Output fm-skill-stats.v1 (null means unknown):
#   at, now, windows [7, 30]
#   skills[w]     read counts per skill for the window, most-read first, each with
#                 the number of homes it was read in
#   by_home[w]    per-home read counts, most-read first
#   zero_read_w7, zero_read_w30  known skills with no reads in that window, only for
#                 windows the coverage spans and while no remote home is registered
#   coverage      whether skills.tsv was present, its row/day/skill/home counts
#   limitations   human-readable coverage notices (the dashboard shows the count)
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 - "$SCRIPT_DIR" "${FM_HOME:-$SCRIPT_DIR/..}" "$@" <<'PY'
import json, sys
from datetime import datetime, timezone

sys.path.insert(0, sys.argv[1])
from fm_stats_lib import parse_args, read_tsv, walk_homes

ROOT, NOW = parse_args(sys.argv[2:], 'fm-skill-stats.sh')
WINDOWS = (7, 30)
DAY = 86400
TODAY = datetime.fromtimestamp(NOW, timezone.utc).strftime('%Y-%m-%d')

def cutoff(window):
    return datetime.fromtimestamp(NOW - DAY * (window - 1), timezone.utc).strftime('%Y-%m-%d')

# --- homes ---------------------------------------------------------------
homes = walk_homes(ROOT)

# Known skill names from each local home's skill directories; used only to name
# skills that were never read. A missing directory is simply skipped.
known = set()
for name, home in homes.items():
    if home is None:
        continue
    for rel in ('skills', '.agents/skills'):
        base = home / rel
        try:
            entries = list(base.iterdir())
        except OSError:
            continue
        for child in entries:
            if child.is_dir() and (child / 'SKILL.md').is_file():
                known.add(child.name)

# --- source --------------------------------------------------------------
rows = read_tsv(ROOT / 'data/metrics/skills.tsv') or []
records = []
for row in rows:
    day = (row.get('day') or '').strip()
    skill = (row.get('skill') or '').strip()
    if not day or not skill:
        continue
    try:
        reads = int(row.get('reads') or 0)
    except ValueError:
        continue
    records.append((day, (row.get('home') or '').strip(), skill, reads))

def window_totals(window):
    lo = cutoff(window)
    per_skill, per_home, homes_of = {}, {}, {}
    for day, home, skill, reads in records:
        if day < lo or day > TODAY:
            continue
        per_skill[skill] = per_skill.get(skill, 0) + reads
        home_map = per_home.setdefault(home, {})
        home_map[skill] = home_map.get(skill, 0) + reads
        if reads > 0:
            homes_of.setdefault(skill, set()).add(home)
    return per_skill, per_home, homes_of

per = {w: window_totals(w) for w in WINDOWS}

def skill_entries():
    entries = []
    for skill in set(per[7][0]) | set(per[30][0]):
        e = {'skill': skill}
        for w in WINDOWS:
            totals, _, homes_of = per[w]
            e[f'w{w}'] = {'reads': totals.get(skill, 0), 'homes': len(homes_of.get(skill, ()))}
        entries.append(e)
    entries.sort(key=lambda e: (-e['w7']['reads'], -e['w30']['reads'], e['skill']))
    return entries

def home_entries():
    out = {}
    names = set(per[7][1]) | set(per[30][1])
    for home in sorted(names):
        items = []
        for skill in set(per[7][1].get(home, {})) | set(per[30][1].get(home, {})):
            items.append({'skill': skill,
                          'w7': {'reads': per[7][1].get(home, {}).get(skill, 0)},
                          'w30': {'reads': per[30][1].get(home, {}).get(skill, 0)}})
        items.sort(key=lambda e: (-e['w7']['reads'], -e['w30']['reads'], e['skill']))
        out[home] = items
    return out

remote_registered = any(home is None for home in homes.values())
def zero_read(window):
    lo = cutoff(window)
    if remote_registered or not days or days[0] > lo or days[-1] < lo:
        return []
    return sorted(s for s in known if per[window][0].get(s, 0) == 0)

skills, by_home = skill_entries(), home_entries()
days = sorted({r[0] for r in records})
limitations = []
if not rows:
    limitations.append('No skill-read record found; skill usage stays unknown.')
for name, home in homes.items():
    if home is None:
        limitations.append(f'{name} is a registered remote home; its skill reads are not readable locally.')

print(json.dumps({
    'schema': 'fm-skill-stats.v1',
    'at': NOW,
    'now': NOW,
    'windows': list(WINDOWS),
    'skills': skills,
    'by_home': by_home,
    'zero_read_w7': zero_read(7),
    'zero_read_w30': zero_read(30),
    'coverage': dict(rows=len(records), days=len(days), skills=len(skills),
                     homes=len(set(r[1] for r in records)),
                     first_day=(days[0] if days else None), last_day=(days[-1] if days else None)),
    'limitations': limitations,
}, sort_keys=True, allow_nan=False))
PY
