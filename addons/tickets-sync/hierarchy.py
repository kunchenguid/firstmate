"""Recorded requests and conservative same-project brief matching for unparented work."""
import re
from task_rows import plain

UPKEEP = 'Not from your asks (fleet upkeep)'
INTERNAL = {'main', 'firstmate', 'firstmate-fork', 'herdr', 'herdr-runtime'}


def field(row, key):
    match = re.search(r'^\s*' + key + r':\s*(.+)$', row.get('body', ''), re.M | re.I)
    return match[1].strip() if match else ''


def title(row, request=False):
    text = plain(row['title'])
    if request:
        quote = re.search(r'(?:type:\s*captain-ask:|captain\b)[^"“\n]{0,80}["“]([^"”\n]{10,})["”]', row.get('body', ''), re.I)
        if quote: text = quote[1]
    text = re.sub(r'https?://\S+', '', text).strip()
    return re.sub(r'^(?:(?:/?\d+|Main\d+|P[0-3]|Parent|Epic)\b[\s:/-]*)+', '', text, flags=re.I).strip()


def parents(tasks):
    """Confirmed ancestry first; infer only a unique request sharing a specific phrase."""
    result = {i: (None if field(r, 'parent') == 'upkeep' else field(r, 'parent')) for i, r in tasks.items()}
    asks = {i: r for i, r in tasks.items() if '[captain-ask]' in r['title'] and not field(r, 'parent')}
    def words(r):
        text = title(r, True) + '\n' + r.get('body', '')
        text = re.sub(r'https?://\S+|\bMain\d+\b|^\s*(?:parent|release|type):.*$', '', text, flags=re.M)
        return re.findall(r'[a-z][a-z0-9-]{2,}', text.lower())
    common = set('the and for with from this that work task tests owner captain umer should have has will'.split())
    phrases = {i: {' '.join(ws[n:n+3]) for n in range(len(ws)-2) if sum(w not in common for w in ws[n:n+3]) >= 2} for i, r in asks.items() if (ws := words(r))}
    for i, row in tasks.items():
        if result[i] in tasks and result[i] != i or i in asks or result[i] is None: continue
        ws = words(row)
        own = {' '.join(ws[n:n+3]) for n in range(len(ws)-2)}
        matches = [a for a, r in asks.items() if a != i and r.get('_project') == row.get('_project') and r.get('_project') not in ('', '-', None) and own & phrases.get(a, set())]
        result[i] = matches[0] if len(matches) == 1 else None
    # Bad historical parent cycles must not turn requested work into an invisible loop.
    for i in result:
        seen, current = {i}, result[i]
        while current in tasks:
            if current in seen: result[i] = None; break
            seen.add(current); current = result[current]
    return result, set(asks)
