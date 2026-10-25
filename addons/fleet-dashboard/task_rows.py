"""Shared tasks-axi tabular reader for the dashboard and ticket publisher."""
import json
import re

def toon_fields(s):
    out, i = [], 0
    while i <= len(s):
        if s.startswith('"', i):
            j = i + 1
            while j < len(s) and s[j] != '"': j += 2 if s[j] == '\\' else 1
            out.append(json.loads(s[i:j + 1])); i = j + 2
        else:
            j = s.find(',', i); j = len(s) if j < 0 else j
            out.append(s[i:j]); i = j + 1
    return out
def toon_rows(text, name='tasks'):
    """Rows of the named tabular TOON block, [] when it says there are none, else None."""
    lines = text.splitlines()
    for i, l in enumerate(lines):
        m = re.match(rf'^{name}\[(\d+)\]\{{([^}}]*)\}}:$', l)
        if m:
            cols = m.group(2).split(',')
            body = lines[i + 1:i + 1 + int(m.group(1))]
            if len(body) < int(m.group(1)): return None
            return [dict(zip(cols, toon_fields(r.strip()))) for r in body]
        if re.match(rf'^{name}: 0 ', l): return []
    return None

TAGS = re.compile(r'^(?:\[[\w-]+\]\s*)+')
def plain(title):  # a lane or ticket name without its leading [tags], Main message refs or a trailing PR number
    t = re.sub(r'\s*\(Main\d+[^)]*\)|^\s*Main\d+:?\s*|\s+PR \d+$', '', TAGS.sub('', title)).strip()
    t = re.sub(r'\bMain\d+\b', 'Main', t)  # mid-sentence ("approved by Main42") the ref reads as Main
    return title if not t else t if t == title else t[0].upper() + t[1:]  # a name cut at its front starts a sentence
