#!/usr/bin/env python3
"""Aggregate-only, read-only secondmate scoreboard, refreshed at most hourly.

Usage: fm-secondmate-scoreboard.py --config INPUT.json --output SCOREBOARD.json
       [--page cockpit-2.html] [--now EPOCH]
Run on the existing cockpit refresh timer (COCKPIT_SCOREBOARD_CONFIG).
Output/page must be outside every configured source directory.
Config keys: transcripts (explicit Claude JSONL paths), inbox (directory),
pending_replies (directory), task_id, read_only_home (Miko home),
goal_status (list of status paths),
board_results (optional procevent-inbox directory), repo (owner/name).
All paths must be absolute. GitHub is read through gh-axi, with pagination.
No commands, bodies, correlation tokens or source paths are published.
Missing sources produce unknown values and coverage warnings, never zeroes.
Action classification and board capture file-mtime timestamps are approximate.
Only completed Claude turns are supported; other harnesses remain unknown.
"""
import argparse
import datetime as dt
import fcntl
import html
import json
import math
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.parse import urlencode

DAY = 86400
LABELS = {
    'busy_percent': ('Secondmate busy (%)', '63', '<35'),
    'turns_per_hour': ('Turns per hour', '15.4', '<8'),
    'no_action_percent': ('Turns without action (%)', '25', '<5'),
    'compactions': ('Compactions / 24h', '18', '<6'),
    'inbox_pickup_seconds': ('Inbox pickup (s)', '113 / 631', 'p90 <120'),
    'reply_seconds': ('Request reply (s)', '211 / 919', 'p90 <300'),
    'board_reply_seconds': ('Board answer to reply (s)', '433 / 1118', 'median <120, p90 <300'),
    'reminders': ('Automatic reminders / 24h', '81', '<10'),
    'false_missed': ('Missed alarms answered within 15 min', '4 of 5', '0'),
    'merge_goal_seconds': ('Merge to goal record (s)', '2580', 'median <300'),
    'pr_merge_seconds': ('PR open to merged (s)', '3060 / 9900', 'median <1800'),
}


def epoch(value):
    try:
        return float(value)
    except (ValueError, TypeError):
        try:
            return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
        except (ValueError, TypeError, AttributeError):
            return None


def stats(values):
    values = sorted(values)
    n = len(values)
    return {'n': n, 'median': ((values[(n-1)//2] + values[n//2])/2 if n else None),
            'p90': values[math.ceil(n*.9)-1] if n else None}


def atomic(path, text):
    fd, name = tempfile.mkstemp(prefix='.scoreboard-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            out.write(text)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def calculate(cfg, now):
    start = now - DAY
    warnings = set()

    def lines(path):
        try:
            with open(path) as source:
                yield from source
        except OSError:
            warnings.add('source-unavailable')

    def inside(t):
        return t is not None and start <= t <= now

    turns, compacts, calls, seen = [], set(), [], set()
    tool_commands, inbox_reads = {}, []
    loaded = 0
    for path in cfg['transcripts']:
        if Path(path).is_file():
            loaded += 1
        for line in lines(path):
            try:
                row = json.loads(line)
            except ValueError:
                warnings.add('malformed-transcript-row')
                continue
            stamp = epoch(row.get('timestamp'))
            if stamp is None:
                continue
            # Resumed transcripts can contain identical ancestors.
            key = (row.get('uuid') or row.get('id') or line)
            if key in seen:
                continue
            seen.add(key)
            if row.get('subtype') == 'turn_duration':
                duration = row.get('durationMs')
                if isinstance(duration, (float, int)) and duration >= 0:
                    turns.append((stamp-duration/1000, stamp))
            if row.get('subtype') == 'compact_boundary' and inside(stamp):
                compacts.add(key)
            content = row.get('message', {}).get('content', [])
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get('type') == 'tool_result':
                    command = tool_commands.get(block.get('tool_use_id'), '')
                    if 'fm-wake-drain' in command or cfg['inbox'] in command:
                        result = block.get('content', '')
                        if isinstance(result, list):
                            result = ' '.join(b.get('text', '') for b in result if isinstance(b, dict))
                        if isinstance(result, str):
                            inbox_reads.extend((stamp, name) for name in set(re.findall(r'\b\d+\.msg\b', result[:4000])))
                if block.get('type') == 'tool_use':
                    inp = block.get('input', {})
                    # Inspect only command/path fields, never tool results or credentials.
                    command = inp.get('command', '')
                    tool = block.get('name', '').lower()
                    paths = ' '.join(str(inp.get(k, '')) for k in ('file_path', 'path'))
                    calls.append((stamp, tool, command, paths))
                    tool_commands[block.get('id')] = command
    intervals = sorted((max(a, start), min(b, now)) for a, b in turns if b >= start and a <= now)
    busy, end = 0, start
    for a, b in intervals:
        busy += max(0, b-max(a, end))
        end = max(end, b)
    completed = [(a, b) for a, b in turns if inside(b)]
    action = re.compile(r'fm-(?:pr-merge|merge|spawn|dispatch|send|goal|captain-hold|teardown|report|pr-check|backlog)|gh(?:-axi)?\s|lavish|git\s+(?:commit|push)|\b(?:mv|cp|mkdir|rm)\s|(?<![<])>(?![>&])')
    nothing = sum(not any(a <= t <= b and (action.search(cmd) or tool in ('write', 'edit', 'write_file', 'edit_file'))
                          for t, tool, cmd, _ in calls) for a, b in completed)
    if not completed:
        warnings.add('no-completed-claude-turns')
    metrics = {k: None for k in LABELS}
    if completed:
        metrics.update(busy_percent=round(100*busy/DAY, 2), turns_per_hour=round(len(completed)/24, 3),
                       no_action_percent=round(100*nothing/len(completed), 2))
    if loaded:
        metrics['compactions'] = len(compacts)
    pickup, reminders, messages, board_capture = [], 0, 0, {}
    inbox = Path(cfg['inbox'])
    if inbox.is_dir():
        for path in sorted(list(inbox.glob('*.msg')) + list((inbox/'handled').glob('*.msg'))):
            # Header plus bounded body only; acknowledgement is the first tool read,
            # not mtime of handled/ (which may be copied or never moved).
            with path.open() as source:
                prefix = source.read(1500)
            header, _, body = prefix.partition('\n--\n')
            match = re.search(r'^at=(.+)$', header, re.M)
            sent = epoch(match[1]) if match else None
            if not inside(sent):
                continue
            messages += 1
            body = body[:400]
            reminders += bool(re.search(r'no reply yet|pending.reply.*remind|automatic.*remind|nog geen.*antwoord', body, re.I))
            reads = [t for t, _, cmd, paths in calls if sent <= t <= now and
                     (str(path) in cmd or str(path) in paths or
                      re.search(r'(?<!\d)'+re.escape(path.name)+r'(?!\d)', cmd))]
            reads.extend(t for t, name in inbox_reads if name == path.name and sent <= t <= now)
            if reads:
                pickup.append(min(reads)-sent)
            corr = re.search(r'corr=([a-fA-F0-9]{16})', body)
            board = re.search(r'board round (\d+) \(session ([\w-]+)', body)
            if corr and board and cfg.get('board_results'):
                result = Path(cfg['board_results'])/(board[2]+'.'+board[1]+'.result')
                if result.is_file():
                    board_capture[corr[1].lower()] = result.stat().st_mtime
        metrics['reminders'] = reminders
        metrics['inbox_pickup_seconds'] = stats(pickup)
    else:
        warnings.add('inbox-unavailable')
    replies, board_replies, false, alarms, requests = [], [], 0, 0, 0
    pending = Path(cfg['pending_replies'])
    if pending.is_dir():
        for path in pending.iterdir():
            if not path.is_file() or path.name.startswith('.'):
                continue
            # Read only public numeric/schema fields, not request_summary.
            fields = {}
            for line in lines(path):
                key, _, value = line.rstrip('\n').partition('=')
                if key in ('task_id', 'delivered_epoch', 'resolved_epoch', 'resolved_via', 'escalated_epoch', 'corr_id'):
                    fields[key] = value
            if fields.get('task_id') != cfg['task_id']:
                continue
            delivered = epoch(fields.get('delivered_epoch'))
            replied = epoch(fields.get('resolved_epoch'))
            escalated = epoch(fields.get('escalated_epoch'))
            valid = fields.get('resolved_via') in ('status', 'document', 'helper') and replied is not None and replied <= now
            if inside(delivered):
                requests += 1
                if valid and replied >= delivered:
                    replies.append(replied-delivered)
                    capture = board_capture.get(fields.get('corr_id'))
                    if inside(capture) and capture <= replied:
                        board_replies.append(replied-capture)
            if inside(escalated) and delivered is not None:
                alarms += 1
                false += bool(valid and 0 <= replied-escalated <= 900)
        metrics.update(reply_seconds=stats(replies), board_reply_seconds=stats(board_replies),
                       false_missed={'answered_within_900s': false, 'alarms': alarms})
    else:
        warnings.add('reply-records-unavailable')
    merged = {}
    try:
        since = dt.datetime.fromtimestamp(start, dt.timezone.utc).isoformat()
        query = urlencode({'q': 'repo:'+cfg['repo']+' is:pr is:merged merged:>='+since, 'per_page': 100})
        result = subprocess.run(['gh-axi', 'api', '/search/issues?'+query, '--paginate', '--full',
                                 '--jq', '(["count", .total_count] | @tsv), (.items[] | [.number, .created_at, .pull_request.merged_at] | @tsv)'],
                                capture_output=True, text=True, timeout=120, check=True)
        for row in result.stdout.splitlines():
            fields = row.split('\t')
            if fields[0] == 'count':
                if int(fields[1]) > 1000:
                    raise ValueError('search result cap')
                continue
            number, created, merge = fields
            at, opened = epoch(merge), epoch(created)
            if inside(at) and opened is not None and opened <= at:
                merged[int(number)] = (opened, at)
        metrics['pr_merge_seconds'] = stats([b-a for a, b in merged.values()])
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, KeyError):
        warnings.add('github-unavailable')
    marks = {}
    for path in cfg['goal_status']:
        for line in lines(path):
            if not line.startswith('goal ') or not re.search(r'\[(?:state=done|stage=merged)\]', line):
                continue
            match = re.search(r'\[at=(\d+)\]', line)
            at = epoch(match[1]) if match else None
            if not inside(at):
                continue
            for number in re.findall(re.escape('https://github.com/'+cfg['repo']+'/pull/')+r'(\d+)', line):
                number = int(number)
                if number in merged and at >= merged[number][1]:
                    marks[number] = min(at, marks.get(number, at))
    if metrics['pr_merge_seconds'] is not None and cfg['goal_status']:
        metrics['merge_goal_seconds'] = stats([at-merged[n][1] for n, at in marks.items()])
    return {'schema': 'fm-secondmate-scoreboard.v1', 'generated_epoch': now,
            'window_start_epoch': start, 'window_seconds': DAY, 'metrics': metrics,
            'coverage': {'completed_turns': len(completed), 'transcripts_loaded': loaded,
                         'inbox_messages': messages, 'requests': requests, 'linked_goal_prs': len(marks)},
            'warnings': sorted(warnings),
            'limits': ['Completed Claude turns only; partial/missing history can undercount busy time.',
                       'Action keywords and tool-read acknowledgement are approximate; unread messages are censored.',
                       'Latency cells show median / p90 and sample count; unanswered requests are excluded.',
                       'Board capture uses durable result mtime; unmatched rounds are excluded.',
                       'False missed means answered within 15 minutes after escalation, not a causal verdict.',
                       'Goal lag includes only marks explicitly linking this repository PR URL.']}


def render(data):
    def cell(value):
        if value is None:
            return 'unknown'
        if isinstance(value, dict):
            if 'n' in value:
                return ('unknown (n=0)' if not value['n'] else
                        f"{value['median']:.1f} / {value['p90']:.1f} (n={value['n']})")
            return f"{value['answered_within_900s']} of {value['alarms']}"
        return str(value)
    rows = ''.join('<tr>'+''.join('<td>'+html.escape(c)+'</td>' for c in
                   (label, before, cell(data['metrics'][key]), target))+'</tr>'
                   for key, (label, before, target) in LABELS.items())
    stamp = dt.datetime.fromtimestamp(data['generated_epoch'], dt.timezone.utc).isoformat()
    return ('<section id="secondmate-scoreboard"><h2>Secondmate scoreboard</h2><p>Rolling 24h · '+stamp+
            '</p><table><tr><th>Measure</th><th>Audit baseline</th><th>Now (median / p90)</th><th>Target</th></tr>'+rows+
            '</table><p>'+html.escape('; '.join(data['warnings']) or 'Sources read successfully')+'</p><details><summary>Coverage and limits</summary><p>'+
            html.escape(json.dumps(data['coverage']))+'</p><ul>'+''.join('<li>'+html.escape(s)+'</li>' for s in data['limits'])+
            '</ul></details></section>')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--config', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--page', type=Path)
    parser.add_argument('--now', type=float, default=time.time())
    args = parser.parse_args()
    cfg = json.loads(args.config.read_text())
    sources = cfg['transcripts'] + cfg['goal_status'] + [cfg['inbox'], cfg['pending_replies'], cfg['read_only_home']]
    if cfg.get('board_results'):
        sources.append(cfg['board_results'])
    if not cfg['transcripts'] or not re.fullmatch(r'[\w.-]+/[\w.-]+', cfg['repo']):
        parser.error('explicit transcripts and owner/repo required')
    if any(not Path(p).is_absolute() for p in sources):
        parser.error('source paths must be absolute')
    roots = [Path(p).resolve() if Path(p).is_dir() or p in (cfg['inbox'], cfg['pending_replies'], cfg['read_only_home'], cfg.get('board_results'))
             else Path(p).resolve().parent for p in sources]
    for target in (args.output, args.page):
        if target and any(target.resolve() == root or root in target.resolve().parents for root in roots):
            parser.error('output/page must be outside source directories')
    # Persistent flock: no stale lock cleanup or source-home mutations.
    with open(str(args.output)+'.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = None
        try:
            cached = json.loads(args.output.read_text())
            if 0 <= args.now-cached['generated_epoch'] < 3600:
                data = cached
        except (OSError, ValueError, KeyError, TypeError):
            pass
        if data is None:
            data = calculate(cfg, args.now)
            atomic(args.output, json.dumps(data, indent=2)+'\n')
        if args.page:
            page = args.page.read_text()
            section = render(data)
            if 'id="secondmate-scoreboard"' in page:
                page = re.sub(r'<section id="secondmate-scoreboard">.*?</section>', lambda _: section, page, flags=re.S)
            else:
                page = page.replace('</body>', section+'\n</body>')
            atomic(args.page, page)
        print('secondmate-scoreboard: snapshot '+str(data['generated_epoch']))


if __name__ == '__main__':
    main()
