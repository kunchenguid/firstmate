#!/usr/bin/env bash
# fm-peer-roster.sh - observe hand-launched Herdr agents without owning them.
# Usage: FM_HOME=<active-firstmate-home> bin/fm-peer-roster.sh [--json]
# Reads the current Herdr pane's workspace, the active home's
# state/peers/peers.tsv and peer logs, and bd's CURRENT configured store as
# resolved from the caller's working directory or Beads environment. Run from
# a directory where `bd where` finds the intended board (or set BEADS_DIR).
# Registry rows are name<TAB>label; a state/peers/<name>.log report line
# starts with needs-decision|blocked|resolved|done|note and may carry
# [key=<slug>] and [at=<epoch>] tags before its colon.
# No pane, board, inbox cursor, watcher, or task mutation. Herdr calls only
# pane current, tab list, and agent list; bd calls only --readonly --sandbox
# where/list. A failed read is explicit in sources/errors; exit 1 on partial.
# JSON: {workspace, sources, peers, unregistered_tabs, managed_tabs,
#        unassigned_beads, other_assigned_beads, errors, partial}; board on success.
# Peers resolve by exact registry tab label after stripping Herdr's one-glyph
# status prefix; Beads join only on exact assignee == peer name. Herdr reads
# target the HERDR_SESSION (default) session, the same one worker metadata is
# filtered by. Dependency status uses blocking edges and the complete board
# snapshot; unknown or tombstone references are not treated as clear. Log
# timestamps are historical reports, never substituted for current Herdr agent
# activity or Beads state; any blocked/needs-decision report key in the log
# with no later resolved line for the same key keeps work_evidence blocked
# regardless of freshness, and every such key is listed in report.open_keys.
set -euo pipefail
FM_HOME=${FM_HOME:-$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
export FM_HOME
exec python3 - "$@" <<'PY'
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def usage():
    print('usage: fm-peer-roster.sh [--json]', file=sys.stderr)
    sys.exit(2)


as_json = False
STALE_AFTER = 4 * 3600
for arg in sys.argv[1:]:
    if arg == '--json':
        as_json = True
    elif arg in ('--help', '-h'):
        print('usage: fm-peer-roster.sh [--json]')
        sys.exit(0)
    else:
        usage()

home = Path(os.environ['FM_HOME'])
state = home / 'state'
session = os.environ.get('HERDR_SESSION', 'default')
result = dict(workspace=None, sources={'herdr': 'unknown', 'beads': 'unknown', 'peers': 'unknown'},
              peers=[], unregistered_tabs=[], managed_tabs=[], unassigned_beads=[],
              other_assigned_beads=[], errors=[], partial=False)
now = int(time.time())


def run(command):
    try:
        proc = subprocess.run(command, capture_output=True, text=True, check=False)
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
    result['sources'][source] = 'unknown'


def herdr(command, expected):
    data = run(['herdr', *command, '--session', session])
    value = data.get('result')
    if not isinstance(value, dict) or not isinstance(value.get(expected), (list if expected.endswith('s') else dict)):
        raise ValueError(f'missing result.{expected}')
    return value[expected]


def bare(label):
    head, sep, rest = (label or '').partition(' ')
    return rest if sep and len(head) == 1 and not head.isalnum() else (label or '')


registry = []
try:
    for number, line in enumerate((state / 'peers/peers.tsv').read_text().splitlines(), 1):
        if not line or line.startswith('#'):
            continue
        columns = line.split('\t')
        if len(columns) != 2 or not all(columns):
            raise ValueError(f'invalid registry row {number}')
        registry.append(dict(name=columns[0], label=columns[1], resolution='unavailable',
                             activity='unknown', report={'freshness': 'missing'}, beads=[]))
    names = [row['name'] for row in registry]
    if len(names) != len(set(names)):
        raise ValueError('duplicate peer name')
    result['sources']['peers'] = 'ok'
except (OSError, ValueError) as exc:
    registry = []  # An incomplete registry cannot establish peer ownership.
    source_error('peers', str(exc))
result['peers'] = registry

REPORT_LINE = re.compile(r'^(needs-decision|blocked|resolved|done|note)(?:\s|\[)')


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


def open_requests(reports):
    opened = []
    for verb, line in reports:
        key = report_key(line)
        if key is None:
            continue
        if verb == 'resolved':
            opened = [item for item in opened if item != key]
        elif verb in ('blocked', 'needs-decision') and key not in opened:
            opened.append(key)
    return opened


for peer in registry:
    log = state / 'peers' / (peer['name'] + '.log')
    try:
        reports = [(match.group(1), value) for value in log.read_text(errors='replace').splitlines()
                   for match in [REPORT_LINE.match(value)] if match]
        if reports:
            line = reports[-1][1]
            stamp = report_stamp(line)
            if stamp is None:
                peer['report'] = {'freshness': 'unknown', 'line': line}
            else:
                freshness = 'fresh' if 0 <= now - stamp <= STALE_AFTER else 'stale'
                peer['report'] = {'at': stamp, 'freshness': freshness, 'line': line}
            peer['report']['open_keys'] = open_requests(reports)
    except FileNotFoundError:
        pass
    except OSError as exc:
        peer['report'] = {'freshness': 'unknown', 'error': str(exc)}
        source_error('peers', f'{peer["name"]} log: {exc}')

try:
    current = herdr(['pane', 'current'], 'pane')
    workspace = current.get('workspace_id')
    if not isinstance(workspace, str) or not workspace:
        raise ValueError('current pane has no workspace_id')
    result['workspace'] = workspace
    tabs = herdr(['tab', 'list', '--workspace', workspace], 'tabs')
    agents = herdr(['agent', 'list'], 'agents')
    if not all(isinstance(item, dict) and isinstance(item.get('tab_id'), str) for item in tabs + agents):
        raise ValueError('invalid tab or agent entries')
    tabs = [tab for tab in tabs if tab.get('workspace_id') == workspace]
    agents = [agent for agent in agents if agent.get('workspace_id') == workspace]
    result['sources']['herdr'] = 'ok'
except (ValueError, TypeError, AttributeError) as exc:
    tabs = []
    agents = []
    source_error('herdr', str(exc))

# Existing Firstmate workers need both recorded tab and pane identity, not a
# suggestive title or an old tab id reused by another agent.
managed = {}
try:
    for meta in state.glob('*.meta'):
        fields = dict(line.split('=', 1) for line in meta.read_text().splitlines() if '=' in line)
        if fields.get('backend') == 'herdr' and fields.get('herdr_session', 'default') == session:
            tab_id = fields.get('herdr_tab_id')
            pane_id = fields.get('window', '').split(':', 1)[-1]
            if tab_id and pane_id:
                managed.setdefault(tab_id, []).append((pane_id, fields.get('endpoint_task_id') or meta.stem))
except OSError as exc:
    source_error('peers', f'worker metadata: {exc}')

for tab in tabs:
    tab_id = tab['tab_id']
    occupants = [agent for agent in agents if agent['tab_id'] == tab_id]
    if not occupants:
        continue  # This tab has no Herdr-observed agent.
    owners = [(agent, name) for agent in occupants
              for pane_id, name in managed.get(tab_id, []) if pane_id == agent.get('pane_id')]
    if owners:
        result['managed_tabs'].append(dict(tab_id=tab_id, label=bare(tab.get('label')),
                                           workers=[name for _, name in owners],
                                           pane_ids=[agent['pane_id'] for agent, _ in owners],
                                           activity=owners[0][0].get('agent_status', 'unknown')
                                           if len(owners) == 1 else 'ambiguous'))
        owned_panes = {agent['pane_id'] for agent, _ in owners}
        occupants = [agent for agent in occupants if agent.get('pane_id') not in owned_panes]
        if not occupants:
            continue
    row = dict(tab_id=tab_id, label=bare(tab.get('label')),
               activity=occupants[0].get('agent_status', 'unknown') if len(occupants) == 1 else 'ambiguous',
               pane_ids=[agent.get('pane_id') for agent in occupants])
    if result['sources']['peers'] != 'ok':
        row['resolution'] = 'unknown'
        result['unregistered_tabs'].append(row)
        continue
    matches = [peer for peer in registry if peer['label'] == row['label']]
    # One registry identity must resolve to exactly one agent tab and pane.
    same_label = [t for t in tabs if bare(t.get('label')) == row['label']
                  and any(a['tab_id'] == t['tab_id'] for a in agents)]
    if len(matches) == 1 and len(occupants) == 1 and len(same_label) == 1 and not owners:
        peer = matches[0]
        peer.update(resolution='matched', tab_id=tab_id, activity=row['activity'], pane_ids=row['pane_ids'])
    elif matches:
        for peer in matches:
            peer['resolution'] = 'ambiguous'
        row['resolution'] = 'ambiguous'
        result['unregistered_tabs'].append(row)
    else:
        row['resolution'] = 'unmapped'
        result['unregistered_tabs'].append(row)
if result['sources']['herdr'] != 'ok' or result['sources']['peers'] != 'ok':
    for peer in registry:
        peer['resolution'] = 'unknown'

# The Beads store belongs to bd's own active configuration in the caller's
# context. Never infer it from a repository or this home's backlog adapter.
try:
    location = run(['bd', '--readonly', '--sandbox', 'where', '--json'])
    if not isinstance(location, dict) or not location.get('path'):
        raise ValueError('bd where returned no board path')
    issues = run(['bd', '--readonly', '--sandbox', 'list', '--all', '--include-gates',
                  '--include-infra', '--limit', '0', '--json'])
    if not isinstance(issues, list) or not all(isinstance(issue, dict) and issue.get('id') for issue in issues):
        raise ValueError('bd list returned invalid issues')
    result['sources']['beads'] = 'ok'
    result['board'] = location['path']
except ValueError as exc:
    issues = []
    source_error('beads', str(exc))

by_id = {issue['id']: issue for issue in issues}
for issue in issues:
    if issue.get('status') in ('closed', 'tombstone'):
        continue
    dependencies = []
    for edge in issue.get('dependencies') or []:
        kind = edge.get('type')
        if kind in ('tracks', 'related', 'relates-to', 'parent-child', 'discovered-from',
                    'caused-by', 'validates', 'supersedes'):
            continue
        target = by_id.get(edge.get('depends_on_id'))
        status = target.get('status', 'unknown') if target else 'unknown'
        dependencies.append(dict(id=edge.get('depends_on_id'), type=kind,
                                 status='unknown' if status == 'tombstone' else status))
    unresolved = [edge for edge in dependencies if edge['status'] != 'closed']
    count = issue.get('dependency_count')
    dep_state = ('unknown' if not isinstance(count, int) or count > len(dependencies)
                 or any(edge['status'] == 'unknown' or edge['type'] not in ('blocks', 'waits-for')
                        for edge in unresolved)
                 else 'blocked' if unresolved else 'clear')
    item = dict(id=issue['id'], title=issue.get('title', ''), status=issue.get('status', 'unknown'),
                assignee=issue.get('assignee') or None, labels=issue.get('labels') or [],
                dependencies=dependencies, dependency_state=dep_state)
    if item['status'] == 'blocked' and dep_state == 'clear':
        item['dependency_state'] = 'unknown'  # Stored blocked status has independent cause.
    if not item['assignee']:
        result['unassigned_beads'].append(item)
    else:
        owner = next((peer for peer in registry if item['assignee'] == peer['name']), None)
        if owner:
            owner['beads'].append(item)
        else:
            item['resolution'] = 'unmapped' if result['sources']['peers'] == 'ok' else 'unknown'
            result['other_assigned_beads'].append(item)

for peer in registry:
    peer['beads_state'] = result['sources']['beads']
    if result['sources']['beads'] != 'ok' or result['sources']['herdr'] != 'ok' or peer['resolution'] != 'matched':
        peer['work_evidence'] = 'unknown'
    elif peer['report'].get('open_keys') or any(
            b['dependency_state'] == 'blocked' or b['status'] == 'blocked' for b in peer['beads']):
        peer['work_evidence'] = 'blocked'
    elif not peer['beads'] or peer['report']['freshness'] != 'fresh' or any(
            b['dependency_state'] == 'unknown' or b['status'] == 'deferred' for b in peer['beads']):
        peer['work_evidence'] = 'unknown'
    else:
        peer['work_evidence'] = 'tracked'  # Not a claim that the agent is available.
result['partial'] = bool(result['errors'])
if as_json:
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
else:
    print(f'Workspace {result["workspace"] or "unknown"} | Herdr {result["sources"]["herdr"]} | '
          f'Beads {result["sources"]["beads"]} | peers {result["sources"]["peers"]}')
    for peer in registry:
        report = peer['report']
        timestamp = datetime.datetime.fromtimestamp(report['at'], datetime.timezone.utc).strftime('%Y-%m-%dT%H:%MZ') if 'at' in report else '-'
        report_text = ' '.join(report.get('line', '').split())[:120]
        ids = ', '.join(f'{b["id"]}({b["status"]},deps:{b["dependency_state"]}' +
                        (':' + ','.join(d['id'] + '=' + d['status'] for d in b['dependencies'] if d['status'] != 'closed')
                         if b['dependencies'] else '') + ')' for b in peer['beads']) or '-'
        open_keys = f' open={",".join(report["open_keys"])}' if report.get('open_keys') else ''
        print(f'{peer["name"]}: {peer["resolution"]} activity={peer["activity"]} work={peer["work_evidence"]}{open_keys} '
              f'report={report["freshness"]}@{timestamp} {report_text} '
              f'beads={ids if result["sources"]["beads"] == "ok" else "unknown"}')
    for tab in result['managed_tabs']:
        print(f'managed {tab["tab_id"]} {tab["label"]}: activity={tab["activity"]} worker={",".join(tab["workers"])}')
    for tab in result['unregistered_tabs']:
        print(f'{tab["resolution"]} {tab["tab_id"]} {tab["label"]}: activity={tab["activity"]}')
    for key, label in (('unassigned_beads', 'unassigned'), ('other_assigned_beads', 'other assignees')):
        if result['sources']['beads'] != 'ok':
            print(f'{label}: unknown')
            continue
        items = result[key]
        print(f'{label}: {len(items)}')
        for item in items[:8]:
            print(f'  {item["id"]} [{",".join(item["labels"]) or "no-label"}] '
                  f'assignee={item["assignee"] or "-"} {item["status"]} deps={item["dependency_state"]}')
        if len(items) > 8:
            print(f'  ... {len(items) - 8} more (--json for all)')
    for error in result['errors']:
        print(f'unknown: {error}')
sys.exit(1 if result['partial'] else 0)
PY
