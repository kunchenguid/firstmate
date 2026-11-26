#!/usr/bin/env python3
"""Re-verify every goal item against reality and build the captain's list, with no AI call.

Rules and step order: .agents/skills/cockpit-refresh/SKILL.md. This help owns the mechanics.

Modes (read-only on the firstmate homes and on the forge):
  sync (default)      cockpit-sync.py --goal-home HOME --out truth.json [--page LIVE.html]
  verify a built page cockpit-sync.py --verify-page BUILT.html --out truth.json
  mark a page failed  cockpit-sync.py --banner-only "reason" --page LIVE.html

Scope (each flag has an environment fallback; lists in the environment are comma separated):
  --goal-home DIR      COCKPIT_GOAL_HOME  home that owns the goal records (required for sync)
  --goal-id ID         COCKPIT_GOAL_IDS   only these goals (repeatable; default every goal)
  --exclude-goal RE    COCKPIT_GOAL_EXCLUDE  drop goals whose id matches this regular expression
  --home DIR           COCKPIT_HOMES      extra home read for tasks, holds and decisions (repeatable);
                                          the goal home and its registered local secondmate homes are always read
  --scope NAME         COCKPIT_SCOPE      select goals and captain entries for these projects or secondmates
                                          (repeatable; default everything). A goal matches if any item names
                                          a scoped project, or has no project and is owned by a scoped
                                          secondmate (or one registered for the project). Verify all items
                                          of matched goals. --goal-id explicitly selects goals instead;
                                          --exclude-goal always applies. Linked decisions stay in scope.
  --out FILE           COCKPIT_TRUTH      the truth JSON
Page options:
  --page FILE          sync: remove the failure banner on success, add it on failure
  --section ID         id of the page's decisions section (repeatable; default captain-door, beslissingen)
  --ignore-question RE data-lavish-question values that are page controls, not captain questions

Exit codes: 0 ok, 1 verify found a stale page, 2 a source could not be read (truth file untouched).
Mismatches between goal marks and reality are findings, not failures: sync still exits 0 and lists them.

truth JSON (schema fm-cockpit-truth.v1; no timestamps, so an unchanged world writes nothing):
  goals[]      {id, title, driven, items[]}
    items[]    {id, title, owner, class, task, mark, status, task_state, last_line, flags[],
                pr: null | {url, state: merged|open|closed|unknown, draft, checks: passing|failing|pending|conflict|none}}
               status: done|running|startable|waiting|open-captain|dropped
  mismatches[] {key, kind, text}
               a needs-decision status key reaches section1 only through a captain hold or an open captain
               goal item; any other open key is listed here for firstmate to hold or resolve
  section1     {must[], can[], later[]}
    entry      {key, aliases[], title, about, question, options[{value,label,detail}], recommendation,
                blocks[], sources[]}
  out_of_scope number of holds and decisions left out by --scope or goal selection

Page contract checked by --verify-page:
  - every must and can entry appears in the section as data-lavish-question="<key or alias>" or
    data-cockpit-captain="<key or alias> ..."
  - every such value in the section belongs to an entry that is still open, and no entry appears twice
  - the goal cards, drive KPI, aggregate and per-goal rings match the scoped truth
  - every item, including dropped, has a status in its goal list, WBS box and Kanban card
  - span or SVG text slots with class fm-goal-item-status and data-fm-goal-item="GOAL/ITEM"
    show the verified status and label. WBS slots belong in a g[data-id] or .fm-goal-box
    under #wbs-blok or #wbs; Kanban slots belong in a .kb-card under #kanban. A Kanban card
    linked to a keyed WBS box by data-wbs uses that box's goal item key.
  - no failure banner is left on the page

Test seams: gh and az come from PATH; COCKPIT_CREW_STATE_BIN replaces bin/fm-crew-state.sh.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
import datetime
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


# The shell entry point uses Python isolated mode, which omits the script directory.
sys.path.append(str(Path(__file__).resolve().parent))
from goal_drive import TRUTH_SCHEMA, verify_goal_views


ROOT = Path(__file__).resolve().parents[2]
SCHEMA = TRUTH_SCHEMA
LIVE = {'working', 'parked', 'paused', 'blocked', 'unknown'}
CLOSED = {'done', 'dropped'}
BANNER = re.compile(r'<!-- fm-cockpit-sync -->.*?<!-- /fm-cockpit-sync -->', re.S)
PR_URL = (r'https://(?:github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/\d+'
          r'|dev\.azure\.com/[^/\s]+/[^/\s]+/_git/[^/\s]+/pullrequest/\d+)')
GITHUB_PR = re.compile(r'https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/(\d+)$')
ADO_PR = re.compile(r'https://dev\.azure\.com/([A-Za-z0-9._%-]+)/[^/\s]+/_git/[^/\s]+/pullrequest/(\d+)$')


class SyncError(Exception):
    """A source could not be read; nothing may be published from this pass."""


def home_env(home):
    env = {k: v for k, v in os.environ.items()
           if k not in ('FM_TASK_ID', 'FM_ROOT_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE')}
    env.update(FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / 'state'),
               FM_DATA_OVERRIDE=str(home / 'data'), FM_CREW_STATE_NO_FORGE='1')
    return env


def run(cmd, what, env=None, timeout=120):
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise SyncError(f'{what}: {exc}') from exc
    if result.returncode != 0:
        raise SyncError(f'{what} failed ({result.returncode}): {(result.stderr or result.stdout).strip()[:300]}')
    return result.stdout


def plain(text, limit=300):
    text = re.sub(r'[\w.+-]+@[\w-]+\.[\w.]+', '[e-mail]', text or '')
    text = re.sub(r'/home/\S+/([^/\s]+)', r'\1', text)
    text = ' '.join(text.split())
    return text if len(text) <= limit else text[:limit - 4].rsplit(' ', 1)[0] + ' ...'


# ---------- homes ----------
def secondmates(goal_home):
    """[(id, home, [projects])] from the goal home's registry, parsed by its owning library."""
    registry = goal_home / 'data' / 'secondmates.md'
    if not registry.is_file():
        return []
    script = ('. "$1"; while IFS= read -r l || [ -n "$l" ]; do case "$l" in "- "*) ;; *) continue ;; esac; '
              'secondmate_registry_parse_line "$l" || continue; [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] || continue; '
              'printf "%s\\t%s\\t%s\\n" "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME" '
              '"$SECONDMATE_REGISTRY_PROJECTS"; done < "$2"')
    out = run(['bash', '-c', script, '_', str(ROOT / 'bin' / 'fm-secondmate-registry-lib.sh'), str(registry)],
              'secondmate registry')
    rows = []
    for line in out.splitlines():
        sm, home, projects = line.split('\t')
        rows.append((sm, Path(home.strip()), [p.strip() for p in projects.split(',') if p.strip()]))
    return rows


def read_meta(path):
    meta = {}
    for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
        key, sep, value = line.partition('=')
        if sep:
            meta[key] = value
    return meta


def status_lines(home, task):
    try:
        text = (home / 'state' / f'{task}.status').read_text(encoding='utf-8', errors='replace')
    except FileNotFoundError:
        return []
    return [line for line in text.splitlines() if line.strip()]


def find_task(homes, task, owner):
    """The home that holds the task: the item owner's home first, then any home with meta, then any log."""
    ordered = sorted(homes, key=lambda h: h[0] != owner)
    for name, home in ordered:
        if (home / 'state' / f'{task}.meta').is_file():
            return name, home, read_meta(home / 'state' / f'{task}.meta')
    for name, home in ordered:
        if (home / 'state' / f'{task}.status').is_file():
            return name, home, None
    return None, None, None


def crew_state(home, task):
    binary = os.environ.get('COCKPIT_CREW_STATE_BIN') or str(ROOT / 'bin' / 'fm-crew-state.sh')
    out = run(['bash', binary, task], f'crew state of {task}', env=home_env(home))
    match = re.match(r'state: (\w+) ', out.strip())
    if not match:
        raise SyncError(f'crew state of {task}: unreadable answer {out.strip()[:120]!r}')
    return match.group(1)


# ---------- forge ----------
def rollup(state):
    return {'SUCCESS': 'passing', 'FAILURE': 'failing', 'ERROR': 'failing',
            'PENDING': 'pending', 'EXPECTED': 'pending'}.get(state, 'none')


def unknown_pr(url):
    return {'url': url, 'state': 'unknown', 'draft': False, 'checks': 'none'}


def github_prs(urls):
    result = {}
    for start in range(0, len(urls), 40):
        chunk = urls[start:start + 40]
        parts = []
        for n, url in enumerate(chunk):
            owner, repo, number = GITHUB_PR.match(url).groups()
            parts.append(f'p{n}: repository(owner:"{owner}",name:"{repo}"){{pullRequest(number:{number})'
                         '{state isDraft mergeable commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}')
        try:
            done = subprocess.run(['gh', 'api', 'graphql', '-f', 'query=query{' + ' '.join(parts) + '}'],
                                  capture_output=True, text=True, timeout=90)
            answer = json.loads(done.stdout)
            data = answer['data']
            assert isinstance(data, dict)
        except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, AssertionError) as exc:
            raise SyncError(f'GitHub pull request read failed: {exc!r}'[:300]) from exc
        hard = [e for e in answer.get('errors', []) if e.get('type') != 'NOT_FOUND']
        if hard:
            raise SyncError('GitHub pull request read failed: ' + str(hard[0].get('message'))[:200])
        for n, url in enumerate(chunk):
            pr = (data.get(f'p{n}') or {}).get('pullRequest')
            if not pr:
                result[url] = unknown_pr(url)
                continue
            commit = ((pr.get('commits') or {}).get('nodes') or [{}])[0].get('commit') or {}
            checks = rollup((commit.get('statusCheckRollup') or {}).get('state'))
            if pr['state'] == 'OPEN' and pr.get('mergeable') == 'CONFLICTING':
                checks = 'conflict'
            result[url] = {'url': url, 'state': pr['state'].lower(), 'draft': bool(pr.get('isDraft')),
                           'checks': checks}
    return result


def ado_pr(url):
    org, number = ADO_PR.match(url).groups()
    az = shutil.which('az') or str(Path.home() / '.local' / 'bin' / 'az')
    base = ['--id', number, '--organization', f'https://dev.azure.com/{org}', '-o', 'json']
    try:
        pr = json.loads(run([az, 'repos', 'pr', 'show', *base], f'Azure DevOps pull request {number}'))
    except SyncError as exc:
        if 'does not exist' in str(exc) or 'TF401180' in str(exc):
            return unknown_pr(url)
        raise
    except ValueError as exc:
        raise SyncError(f'Azure DevOps pull request {number}: unreadable answer') from exc
    state = {'completed': 'merged', 'active': 'open', 'abandoned': 'closed'}.get(pr.get('status'), 'unknown')
    checks = 'none'
    if state == 'open':
        policies = json.loads(run([az, 'repos', 'pr', 'policy', 'list', *base],
                                  f'Azure DevOps policies of pull request {number}'))
        found = {p.get('status') for p in policies if (p.get('configuration') or {}).get('isBlocking')}
        if pr.get('mergeStatus') == 'conflicts':
            checks = 'conflict'
        elif found & {'rejected', 'broken'}:
            checks = 'failing'
        elif found & {'running', 'queued'}:
            checks = 'pending'
        elif found:
            checks = 'passing'
    return {'url': url, 'state': state, 'draft': bool(pr.get('isDraft')), 'checks': checks}


def read_prs(urls):
    urls = sorted(set(urls))
    result = github_prs([u for u in urls if GITHUB_PR.match(u)])
    ado = [u for u in urls if ADO_PR.match(u)]
    with ThreadPoolExecutor(max_workers=4) as pool:
        result.update(zip(ado, pool.map(ado_pr, ado)))
    for url in urls:
        result.setdefault(url, unknown_pr(url))
    return result


# ---------- goals ----------
def project_names(names):
    return {name.rstrip('/').rsplit('/', 1)[-1].casefold() for name in names if name}


def export_goals(goal_home, ids, exclude, scope, mates):
    out = run(['bash', str(ROOT / 'bin' / 'fm-goal.sh'), 'export'], 'goal export', env=home_env(goal_home))
    try:
        snapshot = json.loads(out)
        assert snapshot['schema'] == 'fm-goal-export.v1'
    except (ValueError, KeyError, AssertionError) as exc:
        raise SyncError('goal export: unsupported answer') from exc
    projects = project_names(scope)
    selectors = {name.casefold() for name in scope}
    for sm, _, names in mates:
        if sm.casefold() in selectors:
            projects |= project_names(names)
    owners = {sm.casefold() for sm, _, names in mates if project_names(names) & projects}
    owners |= (selectors | projects) - {'main', 'captain'}

    def in_scope(item):
        if item.get('project'):
            return bool(project_names([item['project']]) & projects)
        return item['owner'].casefold() in owners

    goals, dropped = [], []
    for goal in snapshot['goals']:
        selected = goal['id'] in ids if ids else not scope or any(map(in_scope, goal['items']))
        wanted = selected and not (exclude and re.search(exclude, goal['id']))
        (goals if wanted else dropped).append(goal)
    return goals, dropped


def item_pr_url(item, meta, lines):
    if item.get('pr'):
        return item['pr']
    if meta and re.fullmatch(PR_URL, meta.get('pr', '')):
        return meta['pr']
    for line in reversed(lines):
        match = line.startswith('done') and re.search(PR_URL, line)
        if match:
            return match.group(0)
    return None


def verify_item(item, task_state, pr, must_wait):
    """(verified status, [(kind, text)]) for one item from its mark, its live task and its pull request."""
    mark, captain = item['state'], item['class'] == 'captain'
    number = pr and pr['url'].rsplit('/', 1)[-1]
    merged, state = bool(pr) and pr['state'] == 'merged', pr and pr['state']
    flags = []
    if state == 'unknown':
        flags.append(('pr-unreadable', f'PR {number} could not be read'))
    if mark == 'dropped':
        if state == 'open':
            flags.append(('dropped-pr-open', f'marked dropped, PR {number} still open'))
        return 'dropped', flags
    if mark == 'done':
        if task_state == 'working':
            flags.append(('done-worker-running', 'marked done, its worker is still working'))
        if state in ('open', 'closed'):
            flags.append(('done-pr-not-merged', f'marked done, PR {number} is {state} and not merged'))
            return 'waiting', flags
        return 'done', flags
    live = task_state in LIVE
    if must_wait:
        status = 'waiting'
    elif item['startable']:
        status = 'startable'
    elif captain and mark == 'open':
        status = 'open-captain'
    elif mark == 'running' and live:
        status = 'running'
    else:
        status = 'waiting'
    if merged and task_state in ('done', 'none'):
        flags.append(('pr-merged-not-marked', f'marked {mark}, PR {number} already merged'))
        return 'done', flags
    if merged and live:
        flags.append(('pr-merged-task-live', f'PR {number} merged, task still {task_state}'))
        return 'waiting' if must_wait else 'running', flags
    if task_state == 'working':
        if mark != 'running':
            flags.append(('worker-running-not-marked', f'marked {mark}, a worker is running'))
        return 'waiting' if must_wait else 'running', flags
    if task_state == 'failed':
        flags.append(('task-failed', f'marked {mark}, its task failed'))
    elif mark == 'running' and not live:
        flags.append(('running-no-live-task', 'marked running, no live task'))
    elif task_state == 'done':
        tail = f'PR {number} is {state}' if pr else 'no PR'
        flags.append(('task-done-not-marked', f'marked {mark}, its task is done ({tail})'))
    return status, flags


def build_goals(goals, homes, deciding_tasks):
    found, wanted = {}, []
    for goal in goals:
        for item in goal['items']:
            name, home, meta = find_task(homes, item['task'], item['owner']) if item.get('task') else (None, None, None)
            lines = status_lines(home, item['task']) if home else []
            url = item_pr_url(item, meta, lines)
            found[goal['id'], item['id']] = (name, home, meta, lines, url)
            if meta is not None:
                wanted.append((home, item['task']))
    wanted = sorted(set(wanted), key=str)
    with ThreadPoolExecutor(max_workers=6) as pool:
        states = dict(zip(wanted, pool.map(lambda pair: crew_state(*pair), wanted)))
    prs = read_prs([v[4] for v in found.values() if v[4]])
    out, mismatches = [], []
    for goal in goals:
        items, held_items = [], set()
        for item in goal['items']:
            name, home, meta, lines, url = found[goal['id'], item['id']]
            task_state = states.get((home, item.get('task')), 'none')
            pr = prs.get(url) if url else None
            must_wait = task_state in {'parked', 'blocked'} or (home, item.get('task')) in deciding_tasks
            if must_wait:
                held_items.add(item['id'])
            status, flags = verify_item(item, task_state, pr, must_wait)
            items.append({'id': item['id'], 'title': item['title'], 'owner': item['owner'], 'class': item['class'],
                          'task': item.get('task'), 'after': item.get('after') or [], 'mark': item['state'],
                          'status': status, 'task_state': task_state,
                          'last_line': plain(lines[-1]) if lines else '', 'pr': pr, 'flags': [f[0] for f in flags]})
            mismatches += [{'key': f'{goal["id"]}/{item["id"]}', 'kind': kind, 'text': text} for kind, text in flags]
        # reality may have closed a dependency the record still shows open
        closed = {i['id'] for i in items if i['status'] in CLOSED}
        for item in items:
            if (goal.get('driven') and item['id'] not in held_items
                    and item['status'] == 'waiting' and item['mark'] == 'open'
                    and item['class'] == 'drive' and item['after'] and set(item['after']) <= closed):
                item['status'] = 'startable'
        out.append({'id': goal['id'], 'title': goal['title'], 'driven': goal.get('driven'), 'items': items})
    return out, mismatches


# ---------- captain's list ----------
def tasks_axi(home, args):
    return run(['bash', str(ROOT / 'bin' / 'fm-tasks-axi.sh'), *args], f'backlog of {home}', env=home_env(home))


def held_rows(home):
    out = tasks_axi(home, ['list', '--state', 'held', '--limit', '1000', '--fields', 'hold_kind,hold_until,blocked_by'])
    lines = out.splitlines()
    for n, line in enumerate(lines):
        header = re.match(r'tasks\[(\d+)\]\{([^}]*)\}:$', line)
        if header:
            count, fields = int(header.group(1)), header.group(2).split(',')
            body = [row.strip() for row in lines[n + 1:n + 1 + count]]
            rows = [dict(zip(fields, values)) for values in csv.reader(body, escapechar='\\', doublequote=False)]
            if len(rows) != count or any(len(r) != len(fields) for r in rows):
                raise SyncError(f'backlog of {home}: held list is unreadable')
            return rows
    if re.search(r'^count: 0\b', out, re.M) or re.search(r'^tasks(\[0\])?:', out, re.M):
        return []
    raise SyncError(f'backlog of {home}: unexpected held list')


def show_task(home, task):
    record = {}
    for line in tasks_axi(home, ['show', task, '--full']).splitlines():
        match = re.match(r'  ([a-z_]+): (.*)$', line)
        if match:
            value = match.group(2)
            if value.startswith('"'):
                try:
                    value = json.loads(value)
                except ValueError:
                    value = value.strip('"')
            record[match.group(1)] = value
    if not record:
        raise SyncError(f'backlog of {home}: task {task} is unreadable')
    return record


def backlog_records(home):
    """{task id: its record text} from the backlog and the done archive."""
    records = {}
    for name in ('done-archive.md', 'backlog.md'):
        path = home / 'data' / name
        if path.is_file():
            for block in re.split(r'^(?=- |## )', path.read_text(encoding='utf-8'), flags=re.M):
                match = re.match(r'- (?:\[.\] )?([A-Za-z0-9._-]+) - ', block)
                if match:
                    records[match.group(1)] = block
    return records


def question_context(body):
    for line in body.splitlines():
        line = line.strip()
        if line.startswith('Captain question context: '):
            try:
                value = json.loads(line.split(': ', 1)[1])
                return value if isinstance(value, dict) else {}
            except ValueError:
                return {}
    return {}


def open_decisions(home):
    script = ('. "$1"; printf "#\\t%s\\n" "${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT}"; '
              'for f in "$2"/*.status; do t=${f##*/}; t=${t%.status}; [ -f "$2/$t.meta" ] || continue; '
              'status_open_decisions "$f" | while IFS= read -r l || [ -n "$l" ]; do printf "%s\\t%s\\n" "$t" "$l"; done; done')
    out = run(['bash', '-c', script, '_', str(ROOT / 'bin' / 'fm-classify-lib.sh'), str(home / 'state')],
              f'open decisions of {home}', env=home_env(home), timeout=300)
    reserved, rows = ('remote-reply-continuity-',), []
    for line in out.splitlines():
        parts = line.split('\t', 3)
        if parts[0] == '#':
            reserved += tuple(parts[1].split())
        elif len(parts) == 4 and parts[2] == 'needs-decision':
            rows.append((parts[0], parts[1], parts[3]))
    return reserved, rows


def entry(key, title, about='', question='', options=(), recommendation=None, source=''):
    return {'key': key, 'aliases': [], 'title': plain(title, 200), 'about': plain(about, 900),
            'question': plain(question, 400),
            'options': [{'value': str(o.get('value', '')), 'label': str(o.get('label', o.get('value', ''))),
                         'detail': plain(str(o.get('detail', '')), 400)} for o in options if isinstance(o, dict)],
            'recommendation': recommendation, 'blocks': [], 'sources': [source]}


def captain_list(goals, dropped, homes, scope, sm_projects, decisions):
    links = {}  # task or item id -> goal items it belongs to
    for goal in goals:
        for item in goal['items']:
            for name in {item['id'], item['task']} - {None}:
                links.setdefault(name, []).append((goal, item))
    foreign = {name for goal in dropped for item in goal['items'] for name in (item['id'], item.get('task')) if name}
    foreign -= set(links)

    def waiting_on_item(goal, item):
        return [i for i in goal['items'] if item['id'] in i['after'] and i['status'] not in CLOSED]

    def in_scope(name, repo, home_name, project_dir=''):
        if name in foreign:
            return False
        names = {repo, home_name, Path(project_dir).name} - {''}
        return not scope or name in links or bool(names & scope) or (name in sm_projects and name in scope)

    buckets, order, skipped, mismatches = {}, [], 0, []

    def add(bucket, new, *aliases):
        keys = [new['key'], *aliases]
        old = next((buckets[k] for k in keys if k in buckets), None)
        if old is None:
            old = {'bucket': bucket, 'entry': new}
            order.append(old)
        else:
            old['bucket'] = min(old['bucket'], bucket, key=('must', 'can', 'later').index)
            have = old['entry']
            for field in ('about', 'question', 'options', 'recommendation'):
                have[field] = have[field] or new[field]
            have['blocks'] += [b for b in new['blocks'] if b not in have['blocks']]
            have['sources'] += [s for s in new['sources'] if s not in have['sources']]
        for key in keys:
            buckets[key] = old
            if key != old['entry']['key'] and key not in old['entry']['aliases']:
                old['entry']['aliases'].append(key)

    today = datetime.date.today().isoformat()
    held, known, rows_by_home = set(), {}, {}
    for name, home in homes:
        known.update(backlog_records(home))
        has_backlog = (home / 'data' / 'backlog.md').is_file() or (home / '.tasks.toml').is_file()
        rows_by_home[name] = held_rows(home) if has_backlog else []
        held |= {r['id'] for r in rows_by_home[name] if r.get('hold_kind') == 'captain'}
    blockers = {}
    for rows in rows_by_home.values():
        for row in rows:
            for other in re.split(r'[,\s]+', row.get('blocked_by', '')):
                blockers.setdefault(other, []).append(row['id'])

    for name, home in homes:
        wanted = []
        for row in rows_by_home[name]:
            if row.get('hold_kind') != 'captain':
                continue
            if in_scope(row['id'], row.get('repo', ''), name):
                wanted.append(row)
            else:
                skipped += 1
        # the list truncates titles and bodies, so each held record is shown in full
        with ThreadPoolExecutor(max_workers=8) as pool:
            records = list(pool.map(lambda row: show_task(home, row['id']), wanted))
        for row, record in zip(wanted, records):
            task = row['id']
            body = record.get('body', '')
            context = question_context(body)
            new = entry(task, context.get('question') or record.get('title', task),
                        context.get('about') or record.get('hold_reason', ''),
                        context.get('question', ''), context.get('options') or [], context.get('recommendation'),
                        f'captain hold {task} ({name})')
            if context.get('purpose'):
                new['about'] = plain(new['about'] + ' Waarom het telt: ' + context['purpose'], 900)
            aliases, blocked = [], False
            for goal, item in links.get(task, []):
                blocked = True
                aliases += [f'{goal["id"]}/{item["id"]}', f'{goal["id"]}.{item["id"]}'] if item['class'] == 'captain' else []
                new['blocks'].append(plain(f'{goal["title"]}: {item["title"]}', 200))
            new['blocks'] += [f'backlog: {other}' for other in blockers.get(task, [])]
            origin = re.search(r'^Captain hold origin: (\S+)', body, re.M)
            working = any((h / 'state' / f'{t}.meta').is_file() for _, h in homes
                          for t in (task, origin and origin.group(1)) if t)
            until = row.get('hold_until', '-')
            deferred = (until not in ('', '-') and until[:10] > today) or row.get('blocked_by') not in ('', '-', 'none', None)
            add('later' if deferred else 'must' if blocked or new['blocks'] or working else 'can', new, *aliases)

    for goal in goals:
        by_id = {i['id']: i for i in goal['items']}
        for item in goal['items']:
            if item['class'] != 'captain' or item['status'] in CLOSED:
                continue
            key = f'{goal["id"]}/{item["id"]}'
            task = item['task']
            if task and task not in held and 'Captain decision:' in known.get(task, ''):
                mismatches.append({'key': key, 'kind': 'answered-not-marked',
                                   'text': f'the captain already answered {task}, the item is not marked done'})
                continue
            title = re.sub(r'^next: ', '', item['title'])
            new = entry(key, title, f'Doel: {goal["title"]}', source=f'goal item {key}')
            new['blocks'] = [plain(f'{goal["title"]}: {i["title"]}', 200) for i in waiting_on_item(goal, item)]
            ready = all(by_id[a]['status'] in CLOSED for a in item['after'] if a in by_id)
            aliases = [f'{goal["id"]}.{item["id"]}'] + [a for a in (task, item['id']) if a in held]
            add('later' if not ready else 'must' if new['blocks'] else 'can', new, *aliases)

    # A needs-decision key never makes its own entry: it counts only through a captain hold or an open
    # captain goal item. Every other open key is a finding for firstmate to hold or resolve.
    captain_items = {}
    for goal in goals:
        for item in goal['items']:
            if item['class'] == 'captain' and item['status'] not in CLOSED:
                for ref in (item['id'], item['task']):
                    if ref:
                        captain_items[ref] = f'{goal["id"]}/{item["id"]}'
    for name, home in homes:
        reserved, rows = decisions[home]
        for task, key, note in rows:
            if key.startswith(reserved):
                continue
            relayed = re.fullmatch(r'captain-hold-(.+)-\d+', key)
            target = relayed.group(1) if relayed else key
            label = f'{task}:{key}' if key == 'default' else key
            source = f'needs-decision {key} ({task})'
            match = next((m for m in (target, captain_items.get(target), captain_items.get(task),
                                      task if task in held else None) if m in buckets), None)
            if match:
                # a relayed captain-hold key only echoes the hold; any other open key means someone is waiting
                row = buckets[match]
                add(row['bucket'] if relayed or row['bucket'] == 'later' else 'must',
                    entry(row['entry']['key'], '', source=source), label)
                continue
            meta = read_meta(home / 'state' / f'{task}.meta')
            sm = task if meta.get('kind') == 'secondmate' else name
            if target in held or not in_scope(task, '', sm, meta.get('project', '')):
                skipped += 1
            elif target in known:
                mismatches.append({'key': label, 'kind': 'stale-decision-key',
                                   'text': f'{task} still lists {key} as open, but {target} is no longer held'})
            else:
                mismatches.append({'key': label, 'kind': 'unrouted-decision-key',
                                   'text': f'{task} has an open question with no captain hold or captain goal item; '
                                           f'hold it or resolve it: {plain(note, 160)}'})

    section = {'must': [], 'can': [], 'later': []}
    for row in order:
        section[row['bucket']].append(row['entry'])
    return section, mismatches, skipped


def build_truth(args):
    goal_home = Path(args.goal_home).resolve()
    if not (goal_home / 'state').is_dir():
        raise SyncError(f'goal home {goal_home} has no state directory')
    mates = secondmates(goal_home)
    homes = [('main', goal_home)] + [(sm, home) for sm, home, _ in mates]
    homes += [(Path(h).resolve().name, Path(h).resolve()) for h in args.home]
    unique = []
    for name, home in homes:
        home = home.resolve()
        if not (home / 'state').is_dir():
            raise SyncError(f'home {home} ({name}) has no state directory')
        if home not in [h for _, h in unique]:
            unique.append((name, home))
    goals, dropped = export_goals(goal_home, set(args.goal_id), args.exclude_goal, args.scope, mates)
    decisions = {home: open_decisions(home) for _, home in unique}
    deciding_tasks = {(home, task) for home, (_, rows) in decisions.items() for task, _, _ in rows}
    verified, mismatches = build_goals(goals, unique, deciding_tasks)
    section, more, skipped = captain_list(verified, dropped, unique, set(args.scope),
                                          {sm: projects for sm, _, projects in mates}, decisions)
    return {'schema': SCHEMA, 'goals': verified, 'mismatches': mismatches + more, 'section1': section,
            'out_of_scope': skipped}


# ---------- pages ----------
def write_atomic(target, text):
    mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else 0o644
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=target.parent, delete=False) as handle:
        pending = Path(handle.name)
        try:
            handle.write(text)
            handle.flush()
            pending.chmod(mode)
            pending.replace(target)
        finally:
            pending.unlink(missing_ok=True)


def set_banner(page, reason):
    """Add (reason) or remove (None) the failure banner; the file is written only when it changes."""
    text = page.read_text(encoding='utf-8')
    updated = BANNER.sub('', text)
    if reason is not None:
        banner = ('<!-- fm-cockpit-sync --><div id="cockpit-sync-banner" role="alert" style="background:#5a1620;'
                  'color:#fff;border:2px solid #ff4d4d;border-radius:8px;padding:10px;margin:8px;font-weight:700">'
                  'Verversen mislukt: de gegevens op deze pagina zijn mogelijk verouderd. '
                  f'<span style="font-weight:400">{html.escape(plain(reason))}</span></div><!-- /fm-cockpit-sync -->')
        body = re.search(r'<body[^>]*>', updated)
        at = body.end() if body else 0
        updated = updated[:at] + banner + updated[at:]
    if updated != text:
        write_atomic(page, updated)


class PageKeys(HTMLParser):
    def __init__(self, page, sections, ignore):
        super().__init__()
        self.sections, self.ignore = sections, ignore
        self.tag, self.depth, self.found = None, 0, False
        self.questions, self.banner = [], False
        self.feed(page)
        self.close()

    def handle_starttag(self, tag, attrs):
        attrs = {k: v or '' for k, v in attrs}
        if attrs.get('id') == 'cockpit-sync-banner':
            self.banner = True
        if self.tag is None and attrs.get('id') in self.sections:
            self.tag, self.depth, self.found = tag, 1, True
        elif tag == self.tag:
            self.depth += 1
        if self.tag is None:
            return
        keys = attrs.get('data-cockpit-captain', '').split()
        question = attrs.get('data-lavish-question', '')
        if question and not any(re.search(p, question, re.I) for p in self.ignore):
            keys.append(question)
        if keys:
            self.questions.append(keys)

    def handle_endtag(self, tag):
        if tag == self.tag:
            self.depth -= 1
            if not self.depth:
                self.tag = None


def verify_page(page, truth, sections, ignore):
    seen = PageKeys(page, sections, ignore)
    problems = []
    if seen.banner:
        problems.append('the failure banner is still on the page')
    if not seen.found:
        problems.append(f'no decisions section with id {" or ".join(sections)}')
    section = truth['section1']
    entries = [(bucket, e) for bucket in ('must', 'can', 'later') for e in section[bucket]]
    owner = {key: n for n, (_, e) in enumerate(entries) for key in [e['key'], *e['aliases']]}
    shown = {}
    for keys in seen.questions:
        hits = {owner[k] for k in keys if k in owner}
        if not hits:
            problems.append(f'answered or unknown question still listed: {" ".join(keys)}')
        for n in hits:
            shown[n] = shown.get(n, 0) + 1
    for n, (bucket, e) in enumerate(entries):
        if bucket != 'later' and n not in shown:
            problems.append(f'missing captain item ({bucket}): {e["key"]} - {e["title"]}')
        if shown.get(n, 0) > 1:
            problems.append(f'question listed more than once: {e["key"]}')
    problems.extend(verify_goal_views(page, truth['goals']))
    return list(dict.fromkeys(problems))


def env_list(name):
    return [v.strip() for v in os.environ.get(name, '').split(',') if v.strip()]


def main(argv=None):
    parser = argparse.ArgumentParser(prog='cockpit-sync.py', description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--goal-home', default=os.environ.get('COCKPIT_GOAL_HOME'))
    parser.add_argument('--goal-id', action='append')
    parser.add_argument('--exclude-goal', default=os.environ.get('COCKPIT_GOAL_EXCLUDE'))
    parser.add_argument('--home', action='append')
    parser.add_argument('--scope', action='append')
    parser.add_argument('--out', default=os.environ.get('COCKPIT_TRUTH'))
    parser.add_argument('--page', type=Path)
    parser.add_argument('--verify-page', type=Path)
    parser.add_argument('--banner-only', metavar='REASON')
    parser.add_argument('--section', action='append')
    parser.add_argument('--ignore-question', action='append')
    args = parser.parse_args(argv)
    args.goal_id = args.goal_id or env_list('COCKPIT_GOAL_IDS')
    args.home = args.home or env_list('COCKPIT_HOMES')
    args.scope = args.scope or env_list('COCKPIT_SCOPE')
    try:
        if args.banner_only is not None:
            if not args.page:
                parser.error('--banner-only needs --page')
            set_banner(args.page, args.banner_only)
            return 0
        if not args.out:
            parser.error('--out (or COCKPIT_TRUTH) is required')
        out = Path(args.out)
        if args.verify_page:
            truth = json.loads(out.read_text(encoding='utf-8'))
            if truth.get('schema') != SCHEMA:
                raise SyncError(f'{out} is not a {SCHEMA} file')
            problems = verify_page(args.verify_page.read_text(encoding='utf-8'), truth,
                                   args.section or ['captain-door', 'beslissingen'],
                                   [r'^goal\.drive\.', r'^(ververs|refresh)', *(args.ignore_question or [])])
            for problem in problems:
                print('STALE: ' + problem)
            print(f'cockpit verify: {len(problems)} problem(s)')
            return 1 if problems else 0
        if not args.goal_home:
            parser.error('--goal-home (or COCKPIT_GOAL_HOME) is required')
        truth = build_truth(args)
        text = json.dumps(truth, ensure_ascii=False, indent=1) + '\n'
        changed = not out.is_file() or out.read_text(encoding='utf-8') != text
        if changed:
            write_atomic(out, text)
        if args.page and args.page.is_file():
            set_banner(args.page, None)
        for mismatch in truth['mismatches']:
            print(f'MISMATCH {mismatch["kind"]} {mismatch["key"]}: {mismatch["text"]}')
        section = truth['section1']
        print(f'cockpit sync: {sum(len(g["items"]) for g in truth["goals"])} items in {len(truth["goals"])} goals, '
              f'{len(truth["mismatches"])} mismatch(es), captain: {len(section["must"])} must, {len(section["can"])} can, '
              f'{len(section["later"])} later; truth {"changed" if changed else "unchanged"}')
        return 0
    except Exception as exc:  # any unreadable source must be visible, never a silently stale page
        reason = str(exc) if isinstance(exc, SyncError) else f'{type(exc).__name__}: {exc}'
        print(f'cockpit sync FAILED: {reason}', file=sys.stderr)
        if args.page and args.page.is_file():
            set_banner(args.page, reason)
        return 2


if __name__ == '__main__':
    sys.exit(main())
