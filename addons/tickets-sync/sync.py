#!/usr/bin/env python3
"""Read-only tasks-axi backfill and incremental publication via sign-off-axi ticket.

--check reads without writing and prints one line per ticket whose board state
disagrees with its PR and backlog item, plus every board ticket no home's work
accounts for; the watcher check whose stdout wakes Main runs it.
"""
import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess as sp
import sys
import time
import shutil
import tomllib
import xml.etree.ElementTree as xml

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fleet-dashboard'))
from task_rows import toon_rows
from lane import progress as lane_progress
from hierarchy import UPKEEP, INTERNAL, parents as request_parents, title as request_title

def run(args, env=None, cwd=None, missing=False):
    r = sp.run(args, env=env, cwd=cwd, text=True, capture_output=True, timeout=60)
    if r.returncode and not (missing and '\ncode: NOT_FOUND\n' in '\n' + r.stdout + r.stderr + '\n'):
        raise RuntimeError(f'{args[0]}: {r.stderr.strip() or r.stdout.strip()}')
    return '{}' if r.returncode else r.stdout

def rows(args, env, cwd=None):
    text = run(args + ['--limit', '100000', '--fields', 'held,hold_kind,closed,created,priority,body,links'], env, cwd)
    result = toon_rows(text)
    if result is None or re.search(r'count: \d+ of (?!0\b)\d+ total', text) and len(result) >= 100000:
        raise RuntimeError('tasks-axi returned an unreadable or capped task list')
    return result

ICONS = Path(__file__).resolve().parents[1] / 'fleet-dashboard/fm-dashboard/icons'
ALIAS = {'firstmate-fork': 'firstmate', 'main': 'firstmate', 'muxr': 'pockit'}  # the dashboard's own project-to-image names

def icon_problem(image):
    if image.suffix == '.svg':
        try: root = xml.parse(image).getroot()
        except xml.ParseError as error: return f'not valid XML ({error})'
        return None if root.tag in ('svg', '{http://www.w3.org/2000/svg}svg') else 'not an svg root'
    try: r = sp.run(['identify', '-format', '%m %w %h', str(image) + '[0]'], text=True, capture_output=True, timeout=60)
    except FileNotFoundError: return 'ImageMagick identify is not installed'
    kind, _, size = r.stdout.partition(' ')
    return None if r.returncode == 0 and kind in ('PNG', 'JPEG', 'WEBP') and all(int(n) > 0 for n in size.split()) else 'not a readable ' + image.suffix[1:] + ' image'

def register_icon(board, project, registry):
    """Registers the dashboard's local image for a project; returns a skip reason or None."""
    found = sorted(ICONS.glob(ALIAS.get(project.lower(), project.lower()) + '.*'))
    if not found: return 'no local image'
    image = found[0]
    problem = icon_problem(image)
    if problem: return problem
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    if registry.get(project.lower()) == digest: return None
    target = board.parent / 'icons' / (project.lower() + image.suffix)
    target.parent.mkdir(exist_ok=True)
    shutil.copyfile(image, target)
    try: run(['sign-off-axi', 'project', str(board), '--name', project, '--icon', 'icons/' + target.name])
    except RuntimeError as error: return str(error)[:120]
    registry[project.lower()] = digest
    return None

def ticket_id(home, item):
    return "fm-" + hashlib.sha256(f"{home}/{item}".encode()).hexdigest()[:32]

def sync():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit', action='store_true')
    parser.add_argument('--check', action='store_true', help='print board tickets that disagree with their work; write nothing')
    parser.add_argument('--reconcile', action='store_true', help='read every home without the watcher time budget')
    parser.add_argument('--close', metavar='HOME/ITEM', help='record an authorized cancellation or supersession on the board only')
    parser.add_argument('--reason', choices=['superseded', 'cancelled'])
    options = parser.parse_args()
    if bool(options.close) != bool(options.reason): parser.error('--close and --reason are required together')
    started = time.monotonic()
    budget = float(os.environ.get('FM_TICKETS_SYNC_BUDGET_SECS', '20'))
    home = Path(os.environ['FM_HOME']).resolve()
    board = Path((home / 'config/fleet-board').read_text().strip())
    if not board.is_absolute(): board = home / board
    if options.audit: print(run(['sign-off-axi', 'ticket', str(board), '--json'])); return
    state = home / 'state/tickets-sync'
    state.mkdir(parents=True, exist_ok=True)
    def note(message):
        # Mid-pass progress is not Main-actionable; check stdout is a wake.
        with (state / 'progress.log').open('a') as log: log.write(message + '\n')
    with (state / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        (state / '.tasks.toml').write_text('[markdown]\narchive="unused-archive.md"\n')
        ledger_file = state / ('published-' + hashlib.sha256(str(board).encode()).hexdigest()[:12] + '.json')
        ledger = json.loads(ledger_file.read_text()) if ledger_file.exists() else {}
        pr_file = state / 'prs.json'
        prs = json.loads(pr_file.read_text()) if pr_file.exists() else {}
        closures_file = state / 'closures.json'
        closures = json.loads(closures_file.read_text()) if closures_file.exists() else {}
        homes = {'main': home}
        registry = home / 'data/secondmates.md'
        for line in registry.read_text().splitlines() if registry.exists() else []:
            m = re.match(r'- (\S+) - .*\(home: ([^;]+);', line)
            if m: homes[m[1]] = Path(m[2])
            elif re.match(r'- \S+ - .*\(host:', line): raise RuntimeError('remote home requires a tasks-axi reader: ' + line.split(' - ')[1])
        parked_file = home / 'config/parked-homes'
        parked = {l.split('#')[0].strip() for l in parked_file.read_text().splitlines()} if parked_file.exists() else set()
        cutoff = (dt.date.today() - dt.timedelta(days=7)).isoformat()
        cursor = state / 'cursor.json'
        resume = json.loads(cursor.read_text()) if cursor.exists() and not options.reconcile else {}
        ordered = list(homes.items())
        if resume.get('home') in homes: ordered = ordered[list(homes).index(resume['home']):]
        existing = {t['id']: t for t in json.loads(run(['sign-off-axi', 'ticket', str(board), '--json']))['tickets']}
        changed = 0
        registry = {p['name'].lower(): p.get('icon', {}).get('sha256') for p in json.loads(run(['sign-off-axi', 'project', str(board), '--json'])).get('projects', [])}
        skip_file = state / 'icons-skipped.json'
        skipped = json.loads(skip_file.read_text()) if skip_file.exists() else {}
        tried = set()
        def save(path, value):
            temp = path.with_suffix('.tmp'); temp.write_text(json.dumps(value)); temp.replace(path)
        seen = set()
        def publish(tid, desired):
            nonlocal changed
            seen.add(tid)
            if options.check:
                # A leaf's state is the one its PR and backlog item derive; a grouping row's is its own.
                if 'stage' in desired and (existing.get(tid, {}).get('state') or '') != desired['state']:
                    board_state = existing.get(tid, {}).get('state') or 'no state'
                    print(f"tickets-check: {desired['title'][:70]} ticket says {board_state}, its PR and backlog item say {desired['state'] or 'no state'}")
                return
            digest = hashlib.sha256(json.dumps(desired, sort_keys=True).encode()).hexdigest()
            old = existing.get(tid, {})
            # Board wins over ledger: a prior digest can drift after a partial write.
            matched = all((old.get('prs', []) == ([v] if v else []) if k == 'pr' else old.get('last_event_at', '') == v if k == 'last-event-at' else old.get(k, '') == (v == 'yes' if k in ('hold', 'asked') else v)) for k, v in desired.items())
            if matched:
                if ledger.get(tid) != digest: ledger[tid] = digest; save(ledger_file, ledger)
                return
            args = ['sign-off-axi', 'ticket', str(board), '--id', tid]
            for key, value in desired.items(): args += ['--' + key, str(value)]
            run(args); changed += 1
            updated = dict(old)
            for key, value in desired.items():
                if key == 'pr': updated['prs'] = [value] if value else []
                elif key == 'last-event-at': updated['last_event_at'] = int(value)
                elif key in ('hold', 'asked'): updated[key] = value == 'yes'
                else: updated[key] = value
            existing[tid] = updated
            ledger[tid] = digest; save(ledger_file, ledger)
        if options.close:
            name, sep, item = options.close.partition('/')
            if name not in homes or not sep or not item: raise RuntimeError('--close requires a registered HOME/ITEM')

        upkeep_id = ticket_id('fleet', ':upkeep')
        publish(upkeep_id, dict(title=UPKEEP, progress=0, project='', parent='', hold='no', asked='no', state='queued'))
        for tid, old in existing.items():
            if tid.startswith('fm-') and old['title'].startswith(('Needs a parent', 'Upkeep ·', 'Earlier task grouping')):
                publish(tid, dict(title='Earlier task grouping', progress=0, project='', parent=upkeep_id, hold='no', asked='no', state='done'))
            elif tid.startswith('fm-') and tid != upkeep_id and (old.get('project', '').lower() in INTERNAL or not old.get('asked') and not old.get('parent')):
                publish(tid, dict(project='' if old.get('project', '').lower() in INTERNAL else old.get('project', ''), parent=old.get('parent') or ('' if old.get('asked') else upkeep_id)))
        for name, source in ordered:
            env = {k: v for k, v in os.environ.items() if k not in ('FM_DATA_OVERRIDE', 'FM_ROOT_OVERRIDE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND')}
            env['FM_HOME'] = str(source)
            reader = ['bash', str(home / 'bin/fm-tasks-axi.sh')]
            tasks = rows(reader + ['list'], env) + rows(reader + ['list', '--state', 'done'], env)
            address = run(['bash', '-c', '. "$1/fm-tasks-axi-lib.sh"; . "$1/fm-backlog-transition-lib.sh"; fm_backlog_tasks_axi_addressing "$FM_HOME/data" || exit; printf "%s\\n%s\\n" "$FM_BACKLOG_AXI_ROOT" "$FM_BACKLOG_AXI_FILE"', 'tickets-sync', str(home / 'bin')], env).splitlines()
            root, file = address
            if not file: raise RuntimeError(f'{name}: archive backfill requires markdown addressing')
            settings = {}
            for config in (Path.home() / '.tasks-axi/config.toml', Path(root) / '.tasks.toml'):
                if config.exists(): settings.update(tomllib.loads(config.read_text()).get('markdown', {}))
            archive = Path(root) / settings.get('archive', str(Path(file).parent / 'done-archive.md'))
            archive_copy = state / f'{name}-archive.md'
            if archive.exists():
                archive_copy.write_text(re.sub(r'^## Archived[^\n]*$', '## Done', archive.read_text(), flags=re.M))
            archived = rows(['tasks-axi', 'list', '--state', 'done', '--backend', 'markdown', '--file', str(archive_copy)], env, state) if archive.exists() else []
            backlog_ids = {r['id'] for r in tasks}
            tasks = {r['id']: r for r in archived + tasks}
            full_file = state / f'{name}-full.json'
            full_cache = json.loads(full_file.read_text()) if full_file.exists() else {}
            for item, r in tasks.items():
                if '\n... (truncated, ' not in r['title'] + r.get('body', ''): continue
                path = Path(root) / file if item in backlog_ids else archive
                stamp = str(path.stat().st_mtime_ns)
                cached = full_cache.setdefault(str(path), {})
                if cached.get('stamp') != stamp: cached.clear(); cached.update(stamp=stamp, rows={})
                if item not in cached['rows']:
                    if not options.reconcile and time.monotonic() - started > budget:
                        save(full_file, full_cache); save(cursor, dict(home=name))
                        note('tickets-sync: reading full request context; continuing next check')
                        return
                    full = run(reader + ['show', item, '--full'], env) if item in backlog_ids else run(['tasks-axi', 'show', item, '--full', '--file', str(archive_copy)], env, state)
                    cached['rows'][item] = {k: json.loads(v) if v.startswith('"') else v for k, v in re.findall(r'^  (title|body): (.*)$', full, re.M)}
                r.update(cached['rows'][item])
            save(full_file, full_cache)
            if options.close and name == options.close.partition('/')[0]:
                if options.close.partition('/')[2] not in tasks: raise RuntimeError('--close item not found: ' + options.close)
                closures[options.close] = options.reason
                save(closures_file, closures)
            ids = list(tasks)
            projects = {}
            for r in tasks.values():
                repo = r.get('repo') if r.get('repo') not in ('-', 'none', '') else name
                if repo not in projects:
                    clone = source / 'projects' / repo
                    origin = run(['git', '-C', str(clone), 'remote', 'get-url', 'origin']).strip() if (clone / '.git').exists() else repo
                    projects[repo] = origin.rstrip('/').split('/')[-1].removesuffix('.git')
                r['_project'] = '' if projects[repo].lower() in INTERNAL else projects[repo]
            ancestry, asks = request_parents(tasks)
            parents = set(ancestry.values())
            if resume.get('home') == name and resume.get('task') in tasks: ids = ids[ids.index(resume['task']):]
            required = set(resume.get('required', [])) if resume.get('home') == name else set()
            for item in ids:
                r = tasks[item]
                if not options.reconcile and time.monotonic() - started > budget:
                    save(cursor, dict(home=name, task=item, required=list(required)))
                    note(f'tickets-sync: backfill continuing on next watcher check; {changed} changed')
                    return
                tid = ticket_id(name, r['id'])
                if r['state'] == 'done' and r.get('closed', '-') < cutoff and tid not in ledger and tid not in existing and item not in required: continue
                body = r.get('body', '')
                def field(key):
                    m = re.search(r'^\s*' + key + r':\s*(.+)$', body, re.M | re.I)
                    return m[1].strip() if m else ''
                held = name in parked or r.get('held') == 'yes' or r.get('hold_kind') == 'parked'
                progress, done, pr, stage, event = lane_progress(source, item, r, prs, run)
                save(pr_file, prs)
                done = done or f'{name}/{item}' in closures or existing.get(tid, {}).get('state') == 'done'
                if done: progress, stage = 100, 'done'
                parent = ancestry[item]
                root_ask = item in asks
                title = request_title(r, root_ask)
                if len(title) > 160: title = title[:159].rstrip() + '…'
                project = r['_project']
                if project and project not in tried and not options.check:  # --check writes no board project
                    tried.add(project); reason = register_icon(board, project, registry)
                    if reason != skipped.get(project):
                        skipped.pop(project, None) if reason is None else skipped.__setitem__(project, reason)
                        save(skip_file, skipped)
                        # Skips stay in icons-skipped.json only: check stdout is a Main wake.
                        if reason is None: print(f'tickets-sync: {project} icon registered')
                if parent in tasks and ticket_id(name, parent) not in ledger:
                    required.add(parent); ids.append(parent)
                parent_id = ticket_id(name, parent) if parent in tasks else '' if root_ask else upkeep_id
                desired = dict(title=title, progress=0 if item in parents else progress, state='' if item in parents else 'done' if done else 'on hold' if held else 'queued' if progress == 0 else 'in progress', pr=pr, release=(field('release') or 'later')[:40], parent=parent_id, priority=f"P{r['priority']}" if str(r.get('priority')) in ('0', '1', '2', '3') else '', project=project, hold='yes' if held and not done else 'no', asked='yes' if root_ask else 'no')
                if item not in parents:
                    desired['stage'] = stage
                    if event is not None: desired['last-event-at'] = event
                publish(tid, desired)
        if options.check:
            for tid, old in existing.items():
                if tid.startswith('fm-') and tid not in seen and (old.get('state') or '') != 'done':
                    print(f"tickets-check: {str(old.get('title'))[:70]} ticket says {old.get('state') or 'no state'}, but no home's work accounts for it")
            return
        save(cursor, {})
        if changed: print(f'tickets-sync: {len(homes)} homes read; {changed} tickets changed')

if __name__ == '__main__':
    try: sync()
    except (OSError, ValueError, KeyError, RuntimeError, sp.TimeoutExpired) as error:
        print(f'tickets-sync: {error}', file=sys.stderr)
        sys.exit(1)
