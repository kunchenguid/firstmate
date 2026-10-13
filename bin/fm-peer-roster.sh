#!/usr/bin/env bash
# fm-peer-roster.sh - deterministic fleet overview from durable sources.
# Usage: FM_HOME=<active-firstmate-home> bin/fm-peer-roster.sh [--json]
#
# One read-only command answers "which agents are running, what is on their
# plate, and what is waiting on the captain" with no model in the loop.
#
# Rows (top-level agents[]):
# bd resolves its board from the current working directory; running from
# this script's directory would silently answer with the nearest enclosing
# checkout's board. FM_BOARD (default /Users/jubin/Git/jubin-marut/beads,
# the shared captain board used by bin/fm-propel.sh) pins the chdir target
# every bd invocation runs under. Exported below so the python heredoc can
# read it.

#   - every hand-launched peer in state/peers/peers.tsv (name<TAB>label rows),
#   - every Firstmate-managed worker with state/<id>.meta (its own local copy),
#   - every secondmate named in data/secondmates.md (scope/home), plus
#   - every live child of that secondmate, discovered by scanning the
#     secondmate home's state/*.meta read-only.
# Per row: kind (peer | worker | secondmate | secondmate-child), live pane
# activity from `herdr agent list` (pane membership IS liveness), current work
# as the bead ids joined from the shared board (bd list --status open --json:
# exact assignee == name, or the legacy `owner=<name>` label form), the latest
# free-form status/peer-log line with its age ([at=<epoch>] tags; missing or
# malformed tags fall back to the file's modification time; status files are
# append-only wake records, so the file never carries an authoritative
# last-write stamp), and one deterministic posture:
#   parked        the latest status/peer-log line starts with `paused:` -
#                 a worker declaring a named external wait
#   blocked       an open keyed blocked/needs-decision entry with no later
#                 resolved key, deterministically
#   working       live pane activity is `working` (any other live activity is
#                 shown as activity= but never masks the postures above)
#   idle-stale    not parked, not blocked, and no report stamp for >60 minutes
#   idle          none of the above
# Posture precedence is parked > blocked > working > idle-stale > idle so a
# declared wait always wins over pane motion and an unresolved decision always
# wins over key noise. Work-evidence and open-keys never come from scraping
# free text: only the tag pair [<key=...][at=...]> counts, and nothing else
# appears in posture.
#
# Beyond the rows, `on_captain` surfaces open beads carrying the `captain`
# label plus every open firstmate captain hold read straight from the backlog
# file (a `(hold-kind: captain)` marker on an unchecked row).
#
# Sources: `boards` tracks bd, `herdr`, and `peers` independently; any read
# failure is explicit in sources/errors, posture fields fall back to
# `unknown`, and the script exits 1 (partial) rather than returning a
# confident empty fleet.
#
# No pane, board, inbox cursor, watcher, worker, or task mutation. Herdr
# reads stay on `pane current`, `tab list`, and `agent list`; bd reads stay
# on `--readonly --sandbox list`; backlog and metadata reads stay under the
# active home and any secondmate homes named in this home's registry.
# Dependency: python3 (already required for the Herdr protocol-16 paths).

set -euo pipefail
FM_HOME=${FM_HOME:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
export FM_HOME
BOARD=${FM_BOARD:-/Users/jubin/Git/jubin-marut/beads}
export BOARD
exec python3 - "$@" <<'PY'
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

STALE_AFTER = 3600  # idle beyond 60 minutes of silence is idle-stale

def usage(code):
    print('usage: fm-peer-roster.sh [--json]', file=sys.stderr if code else sys.stdout)
    sys.exit(code)

as_json = False
for arg in sys.argv[1:]:
    if arg == '--json':
        as_json = True
    elif arg in ('--help', '-h'):
        usage(0)
    else:
        usage(2)

home = Path(os.environ['FM_HOME'])
state = home / 'state'
board = os.environ.get('BOARD', '')
session = os.environ.get('HERDR_SESSION', 'default')
now = int(time.time())

result = dict(sources={'herdr': 'unknown', 'beads': 'unknown', 'peers': 'unknown'},
              agents=[], on_captain=dict(beads=[], holds=[]), errors=[], partial=False)

def run(command, cwd=None):
    try:
        proc = subprocess.run(command, capture_output=True, text=True, check=False, cwd=cwd)
    except OSError as exc:
        raise ValueError(str(exc)) from exc
    if proc.returncode:
        raise ValueError((proc.stderr or proc.stdout).strip() or f'exit {proc.returncode}')
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise ValueError(f'invalid JSON: {exc}') from exc

def source_error(source, message):
    result['errors'].append(f'{source}: {message}')

def herdr(command, expected):
    data = run(['herdr', *command, '--session', session])
    value = data.get('result')
    if not isinstance(value, dict) or not isinstance(value.get(expected), (list if expected.endswith('s') else dict)):
        raise ValueError(f'missing result.{expected}')
    return value[expected]

# --- identities -------------------------------------------------------------
# peers.tsv rows are name<TAB>label, as fm-propel.sh registers them.
peers = []
try:
    for number, line in enumerate((state / 'peers/peers.tsv').read_text().splitlines(), 1):
        if not line or line.startswith('#'):
            continue
        columns = line.split('\t')
        if len(columns) != 2 or not all(columns):
            raise ValueError(f'invalid registry row {number}')
        peers.append(dict(name=columns[0], label=columns[1]))
    names = [row['name'] for row in peers]
    if len(names) != len(set(names)):
        raise ValueError('duplicate peer name')
    result['sources']['peers'] = 'ok'
except OSError:
    pass  # An absent registry simply means no hand-launched peers.
except ValueError as exc:
    # Unreadable rows are deterministic knowledge: peers=unknown + partial.
    peers = []
    source_error('peers', str(exc))

# Worker metadata: state/<task-id>.meta key=value rows. A secondmate launched
# from this home leaves kind=secondmate meta here, which is what supplies the
# mate's own status path and pane, so secondmate rows below reuse the worker
# record instead of inventing a second status-file location.
def meta_fields(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)

def pane_id_of(fields):
    raw = fields.get('window', '')
    # '<session>:w6:p79' -> suffix 'w6:p79'; a bare 'pane' stays as-is.
    return raw.split(':', 1)[1] if ':' in raw else (raw or None)

workers = []
try:
    for meta in sorted(state.glob('*.meta')):
        fields = meta_fields(meta)
        task_id = fields.get('endpoint_task_id') or meta.stem
        workers.append(dict(id=task_id, kind=fields.get('kind') or 'worker',
                            pane_id=pane_id_of(fields), mode=fields.get('mode') or None,
                            worktree=fields.get('worktree') or None,
                            status_path=meta.parent / (task_id + '.status')))
except OSError as exc:
    source_error('peers', f'worker metadata: {exc}')

# Secondmates: "- <name> - <purpose> (home: <path>; scope: ...)" rows. The
# heading and prose are captain-written; the roster extracts name, scope, and
# home without validating the rest.
secondmates = []
try:
    registry = home / 'data/secondmates.md'
    if registry.exists():
        for line in registry.read_text().splitlines():
            stripped = line.strip()
            if not stripped.startswith('- '):
                continue
            name_match = re.match(r'^-\s+([^\s(]+)', stripped)
            home_match = re.search(r'\bhome:\s*([^;)]+?)\s*[;)]', stripped)
            scope_match = re.search(r'\bscope:\s*([^;)]+?)\s*[;)]', stripped)
            if name_match:
                secondmates.append(dict(name=name_match.group(1),
                                        home=home_match.group(1) if home_match else None,
                                        scope=scope_match.group(1) if scope_match else None))
except OSError as exc:
    source_error('peers', f'secondmates registry: {exc}')

# Secondmate children: live rows in each registered secondmate home's own
# state/*.meta, read read-only. A secondmate that cannot be read stays a row
# with no children and an explicit error, never a silent omission.
children = []
for mate in secondmates:
    if not mate['home']:
        source_error('peers', f'secondmate {mate["name"]}: registry row names no home')
        continue
    mate_state = Path(mate['home']) / 'state'
    try:
        if not mate_state.is_dir():
            continue
        for meta in sorted(mate_state.glob('*.meta')):
            fields = meta_fields(meta)
            task_id = fields.get('endpoint_task_id') or meta.stem
            children.append(dict(id=task_id, parent=mate['name'],
                                 pane_id=pane_id_of(fields),
                                 kind='secondmate-child', worktree=fields.get('worktree') or None,
                                 status_path=meta.parent / (task_id + '.status')))
    except OSError as exc:
        source_error('peers', f'secondmate {mate["name"]} state: {exc}')

# --- live Herdr activity ----------------------------------------------------
agents_by_pane = {}
herdr_workspace = None
try:
    current = herdr(['pane', 'current'], 'pane')
    herdr_workspace = current.get('workspace_id')
    if not isinstance(herdr_workspace, str) or not herdr_workspace:
        raise ValueError('current pane has no workspace_id')
    herdr_tabs = {tab['tab_id']: (tab.get('label') or '')
                  for tab in herdr(['tab', 'list', '--workspace', herdr_workspace], 'tabs')
                  if isinstance(tab, dict) and tab.get('workspace_id') == herdr_workspace}
    agents_list = herdr(['agent', 'list'], 'agents')
    for agent in agents_list:
        if not isinstance(agent, dict) or not isinstance(agent.get('tab_id'), str):
            continue
        pane_id = agent.get('pane_id')
        if isinstance(pane_id, str) and pane_id:
            agents_by_pane[pane_id] = agent
    result['sources']['herdr'] = 'ok'
except (ValueError, TypeError, AttributeError) as exc:
    source_error('herdr', str(exc))
    herdr_tabs = {}

# --- per-row durable status: latest line + open keyed decisions -------------
# Status lines follow bin/fm-brief.sh: "<verb> [at=<epoch>] [key=<slug>]: free
# text", append-only. Exactly two punctuation-aware reads happen here:
#   latest_line - the last line starting with a known verb (trimmed, with a
#                 real timestamp whenever its [at=] tag parses)
#   open_keys   - keyed blocked/needs-decision entries without a later
#                 resolved key, regardless of the free text in between
REPORT_LINE = re.compile(r'^(working|paused|blocked|needs-decision|resolved|done|failed|note)(?:\s|\[|:)')

def report_tag(line, name):
    head, sep, _ = line.partition(':')
    if not sep:
        return None
    tags = re.findall(r'\[' + name + r'=([^\]]*)\]', head)
    return tags[0] if len(tags) == 1 and tags[0] else None

def report_stamp(line):
    stamp = report_tag(line, 'at')
    return int(stamp) if stamp is not None and re.fullmatch(r'(?:0|[1-9][0-9]{0,11})', stamp) else None

def report_key(line):
    slug = (report_tag(line, 'key') or '').split(' ', 1)[0]
    return slug if slug and '=' not in slug else None

def read_reports(path):
    """Latest status line and keyed-open decision set. Durable, no free-text scraping."""
    reports = []
    for value in path.read_text(errors='replace').splitlines():
        match = REPORT_LINE.match(value)
        if match:
            reports.append((match.group(1), value))
    latest = reports[-1][1] if reports else None
    opened = []
    for verb, value in reports:
        key = report_key(value)
        if key is None:
            continue
        if verb == 'resolved':
            opened = [item for item in opened if item != key]
        elif verb in ('blocked', 'needs-decision') and key not in opened:
            opened.append(key)
    return latest, opened

def mtime(path):
    try:
        return int(path.stat().st_mtime)
    except OSError:
        return None

def report_info(task_id, log_path):
    """Latest line, its epoch, and the open keyed decisions for one row."""
    latest_line, stamp, opened = None, None, []
    if log_path.is_file():
        try:
            latest_line, opened = read_reports(log_path)
            if latest_line is not None:
                stamp = report_stamp(latest_line)
                if stamp is None:
                    stamp = mtime(log_path)  # Append-only log: file stamp, never fabricated.
        except OSError as exc:
            source_error('peers', f'{task_id} status: {exc}')
    age = (now - stamp) if stamp is not None and now >= stamp else None
    return latest_line, stamp, age, opened

def latest_line_is_parked(line):
    # Brief contract: parked workers announce the wait as `paused [at=...] [key=...]: ...`
    # or a bare `paused:` prefix. `parked` is the legacy synonym a peer log may use.
    return bool(line) and line.startswith(('paused:', 'paused [', 'parked:', 'parked ['))

def posture(activity, report_age, opened, parked):
    if parked:
        return 'parked'
    if opened:
        return 'blocked'
    if activity == 'working':
        return 'working'
    if report_age is None or report_age > STALE_AFTER:
        return 'idle-stale'
    return 'idle'

def row(name, kind, activity, latest_line, stamp, age, opened, beads, beads_state):
    ids = [b['id'] for b in beads]
    return dict(name=name, kind=kind, activity=activity or 'unknown',
                beads=ids, bead_count=len(ids), latest_line=latest_line,
                latest_at=stamp, latest_age_s=age, open_keys=opened,
                posture=posture(activity, age, opened, latest_line_is_parked(latest_line)),
                beads_state=beads_state)

# --- current work: the open shared-board beads ------------------------------
# Join rule: exact assignee match on the agent's registered name, plus the
# legacy `owner=<name>` label form used before bd grew an assignee field. bd
# eagerly rewrites `--actor` to created_by, not owner, so the captain's email
# owner column is not an agent surface and never joins.
# The assignee string uploaded to a bead is whichever of name, tab label, or
# a title-cased label the uploader picked. The roster joins on all of them
# so the answer stays deterministic - no fuzzy casing, no substring fold.
targets = {}
beads_by_name = {}
def add_target(string, name):
    """Register one board-side alias that maps to this row's name.

    Agents are named lowercase keys in the registry; the uploader on a bead
    can use any casing. The join stays deterministic by trying every
    deterministic variant once - the raw string, its lower, title, and
    upper form - never by substring or partial-match folding.
    """
    if not string:
        return
    for variant in {string, string.lower(), string.title(), string.upper()}:
        targets.setdefault(variant, set()).add(name)
    beads_by_name.setdefault(name, [])

for peer in peers:
    add_target(peer['name'], peer['name'])
    add_target(peer['label'], peer['name'])
for worker in workers:
    add_target(worker['id'], worker['id'])
for mate in secondmates:
    add_target(mate['name'], mate['name'])
for child in children:
    add_target(child['id'], child['id'])
captain_beads = []

try:
    board_cwd = board if board else None
    payload = run(['bd', '--readonly', '--sandbox', '--json', 'list', '--status', 'open', '--limit', '0'],
                  cwd=board_cwd)
    issues = payload if isinstance(payload, list) else payload.get('issues')
    if not isinstance(issues, list):
        raise ValueError('bd list did not return an issue array')
    result['sources']['beads'] = 'ok'
except ValueError as exc:
    issues = []
    source_error('beads', str(exc))

for issue in issues:
    if not isinstance(issue, dict) or not issue.get('id'):
        continue
    labels = issue.get('labels') or []
    if 'captain' in labels:
        captain_beads.append(dict(id=issue['id'], title=(issue.get('title') or '')[:120]))
    owner_label = next((label[len('owner='):] for label in labels
                        if isinstance(label, str) and label.startswith('owner=')), None)
    for target in {issue.get('assignee'), owner_label}:
        for name in targets.get(target, ()):
            beads_by_name.setdefault(name, []).append(dict(id=issue['id'],
                                              title=(issue.get('title') or '')[:120],
                                              status=issue.get('status') or 'unknown',
                                              assignee=issue.get('assignee')))

# --- firstmate captain holds: open `(hold-kind: captain)` backlog rows ------
holds = []
backlog = home / 'data/backlog.md'
if backlog.is_file():
    try:
        for line in backlog.read_text(errors='replace').splitlines():
            if not line.startswith('- [ ]') or '(hold-kind: captain)' not in line:
                continue
            title = line.split(' - ', 1)[1].split(' (since', 1)[0].strip()
            origin = line.split('[ ] ', 1)[1].split(' - ', 1)[0].strip()
            holds.append(dict(task=origin, title=title[:160]))
    except OSError as exc:
        source_error('peers', f'backlog: {exc}')

result['on_captain'] = dict(beads=captain_beads, holds=holds)

# --- assemble rows ----------------------------------------------------------
beads_state = result['sources']['beads']
def pane_activity(pane_id):
    if not pane_id or result['sources']['herdr'] != 'ok':
        return None
    agent = agents_by_pane.get(pane_id)
    return agent.get('agent_status') if isinstance(agent, dict) else None

# The secondmate's own durable status lives in its registered home under its
# registered name (this home's secondmates.md is the authoring registry); any
# firstmate-side status points nowhere it wrote. Falling back to this home's
# worker status only when the mate has no home keeps one place authoritative.
for worker in workers:
    mate = next((item for item in secondmates if item['name'] == worker['id']), None)
    if mate:
        mate['worker_ref'] = worker

for peer in peers:
    latest, stamp, age, opened = report_info(peer['name'], state / 'peers' / (peer['name'] + '.log'))
    # Match the peer's registry label against herdr's tab labels (not the
    # terminal title; the harness can rewrite that). The glyph prefix
    # is part of the tab label, so strip it before comparing.
    label_matches = [
        agent for agent in agents_by_pane.values()
        if herdr_tabs.get(agent.get('tab_id'), '').lstrip('◐○◇✓⠇⠴⠼⠿> ').strip().lower() == peer['label'].lower()
    ]
    activity = label_matches[0].get('agent_status') if len(label_matches) == 1 else None
    result['agents'].append(row(peer['name'], 'peer', activity,
                                latest, stamp, age, opened,
                                beads_by_name.get(peer['name'], []), beads_state))

for worker in workers:
    latest, stamp, age, opened = report_info(worker['id'], worker['status_path'])
    result['agents'].append(row(worker['id'], worker['kind'], pane_activity(worker['pane_id']),
                                latest, stamp, age, opened,
                                beads_by_name.get(worker['id'], []), beads_state))

for mate in secondmates:
    worker = mate.get('worker_ref')
    if worker is not None:
        continue  # Already listed above under its registered task id and kind.
    if mate['home']:
        status_path = Path(mate['home']) / 'state' / (mate['name'] + '.status')
    else:
        status_path = state / (mate['name'] + '.status')
    latest, stamp, age, opened = report_info(mate['name'], status_path)
    result['agents'].append(row(mate['name'], 'secondmate', pane_activity(None),
                                latest, stamp, age, opened,
                                beads_by_name.get(mate['name'], []), beads_state))

for child in children:
    latest, stamp, age, opened = report_info(child['id'], child['status_path'])
    result['agents'].append(row(child['id'], 'secondmate-child', pane_activity(child['pane_id']),
                                latest, stamp, age, opened,
                                beads_by_name.get(child['id'], []), beads_state))

result['partial'] = bool(result['errors'])

# --- output -----------------------------------------------------------------
if as_json:
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
else:
    print(f"herdr {result['sources']['herdr']} | beads {result['sources']['beads']} | peers {result['sources']['peers']}"
          + (' | PARTIAL: ' + ' && '.join(result['errors']) if result['errors'] else ''))
    for agent in result['agents']:
        stamp = (datetime.datetime.fromtimestamp(agent['latest_at'], datetime.timezone.utc).strftime('%Y-%m-%dT%H:%MZ')
                 if agent['latest_at'] is not None else '-')
        line = ' '.join((agent['latest_line'] or '').split())[:100]
        print(f"{agent['name']} ({agent['kind']}): {agent['posture']}"
              f" activity={agent['activity']}"
              f" beads={len(agent['beads'])} ({','.join(agent['beads']) or '-'})"
              f" latest={stamp} {line}"
              + (f" open={','.join(agent['open_keys'])}" if agent['open_keys'] else ''))
    on = result['on_captain']
    print(f"On captain: beads={len(on['beads'])} holds={len(on['holds'])}")
    for bead in on['beads']:
        print(f"  bead {bead['id']}: {bead['title']}")
    for hold in on['holds']:
        print(f"  hold {hold['task']}: {hold['title']}")
sys.exit(1 if result['partial'] else 0)
PY
