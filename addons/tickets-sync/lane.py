"""Lane/PR evidence for ticket leaves; backlog prose references are not completion evidence."""
import re
import time

PR = re.compile(r'https://github\.com/([\w.-]+/[\w.-]+)/pull/([1-9]\d*)\b')


def evidence(source, item, row):
    state = source / 'state'
    meta = state / (item + '.meta')
    status = state / (item + '.status')
    props = dict(line.split('=', 1) for line in meta.read_text().splitlines() if '=' in line) if meta.exists() else {}
    lines = status.read_text().splitlines() if status.exists() else []
    stage, terminal, link = ('queued' if row['state'] == 'queued' else 'building'), False, ''
    for line in lines:
        verb = re.match(r'^(?:\d+\s+)?([a-z-]+)\b', line)
        verb = verb[1] if verb else ''
        key = re.search(r'\[key=nm-.*?-(review|intent|rebase|test|lint|document|push|pr|ci)(?:-fix\d+)?\]', line)
        if key or verb in ('review', 'ci'): stage = 'review'
        if verb in ('merge', 'merging'): stage = 'merging'
        if verb == 'reopened' or verb == 'working' and stage == 'queued': stage = 'building'
        if verb == 'done':
            stage = 'merging'
            match = PR.search(line)
            if match: link = match[0]
        if verb in ('superseded', 'cancelled', 'canceled'): terminal = True
        if verb in ('working', 'reopened'): terminal = False
    body = row.get('body', '')
    explicit = re.search(r'^\s*(?:status|resolution):\s*(superseded|cancelled|canceled)\b', body, re.M | re.I)
    own = re.search(r'^\s*pr:\s*(' + PR.pattern + ')', body, re.M | re.I)
    # Title/links are task delivery links; arbitrary URLs inside notes may be prerequisites.
    match = PR.search(row.get('links', '') + '\n' + row['title'])
    link = props.get('pr') or (own[1] if own else '') or (match[0] if match else '') or link
    return stage, terminal or bool(explicit), link


def progress(source, item, row, cache, run):
    stage, terminal, link = evidence(source, item, row)
    done = row['state'] == 'done' or terminal
    match = PR.fullmatch(link)
    if match and not done:
        old = cache.get(link, {})
        if not old.get('merged') and time.time() - old.get('at', 0) >= 300:
            result = run(['gh-axi', 'api', f'repos/{match[1]}/pulls/{match[2]}', '--jq', '{merged,state,draft}'])
            values = dict(re.findall(r'^(merged|state|draft): (\S+)$', result, re.M))
            if set(values) != {'merged', 'state', 'draft'}:
                raise RuntimeError('unreadable GitHub PR state for ' + link + ': ' + result)
            old = dict(merged=values['merged'] == 'true', state=values['state'], draft=values['draft'] == 'true', at=time.time())
            cache[link] = old
        done = old['merged']
        if not done and old['state'] == 'open' and not old['draft'] and stage != 'merging': stage = 'review'
    return (100 if done else {'queued': 0, 'building': 30, 'review': 65, 'merging': 90}[stage]), done, link
