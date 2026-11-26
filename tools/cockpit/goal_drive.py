#!/usr/bin/env python3
"""Refresh goal KPIs, drive switches and opted-in WBS/kanban status labels."""

import argparse
import hashlib
import html
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile


GOAL_BIN = Path(__file__).resolve().parents[2] / 'bin' / 'fm-goal.sh'
GENERATED = re.compile(r'<!-- fm-goal-drive -->.*?<!-- /fm-goal-drive -->', re.S)
STATUSES = {
    'done': ('Klaar', '#63d6ad'),
    'running': ('Bezig', '#66b5ff'),
    'startable': ('Kan starten', '#ffc35c'),
    'waiting': ('Wacht', '#a3afc2'),
    'open-captain': ('Aan jou', '#d8a8ff'),
    'dropped': ('Vervallen', '#858892'),
}
ATTRIBUTE = re.compile(r' data-fm-goal-drive="(?:on|off)"(?=>)|'
                       r' data-fm-goal-status="(?:' + '|'.join(STATUSES) + r')"(?=>)')
STYLE = '''<style>
[data-fm-goal-drive="off"] { filter: grayscale(1); }
.fm-goal-drive { display:flex; flex-wrap:wrap; align-items:center; gap:4px 8px; margin:2px 0 4px; }
.fm-goal-drive button { font:inherit; color:inherit; background:#202633; border:1px solid #546074;
                        border-radius:6px; padding:4px 8px; cursor:pointer; }
.fm-goal-drive-state { color:#7fe0a5; font-weight:bold; }
.fm-goal-drive .st { background:none; border:0; padding:0; }
.fm-goal-drive .st:empty { display:none; }
.fm-goal-items { color-scheme:dark; color:#f2f4f8; background:#141821; border:1px solid #465369;
                 border-radius:8px; padding:12px; margin:6px 0 10px; }
.fm-goal-items-body { display:flex; align-items:center; flex-wrap:wrap; gap:12px 16px; }
.fm-goal-ring { flex:none; border-radius:50%; inline-size:6rem; block-size:6rem;
                background:#3b4659; background-image:var(--fm-goal-ring, none);
                display:grid; place-items:center; }
.fm-goal-ring > span { border-radius:50%; inline-size:4.65rem; block-size:4.65rem;
                       background:#141821; display:grid; place-content:center; text-align:center;
                       font-size:.75rem; line-height:1.2; }
.fm-goal-ring strong { font-size:1.2rem; }
.fm-goal-items ul { flex:1 1 8rem; min-inline-size:0; max-inline-size:14rem;
                    list-style:none; padding:0; margin:0; font-size:.875rem; }
.fm-goal-items li { display:grid; grid-template-columns:.65rem minmax(0,1fr) auto;
                    align-items:center; gap:.55rem; margin:0; overflow-wrap:anywhere; }
.fm-goal-items li::before { content:""; inline-size:.65rem; block-size:.65rem;
                            border-radius:50%; background:var(--fm-goal-color); }
span.fm-goal-item-status[data-fm-goal-status] { display:inline-block; color:#f2f4f8; background:#141821;
    border:1px solid var(--fm-goal-color); border-inline-start-width:4px; border-radius:4px;
    padding:0 4px; font-size:.75rem; font-weight:700; }
text.fm-goal-item-status[data-fm-goal-status] { fill:var(--fm-goal-color); font-weight:700; }
''' + '\n'.join(f'[data-fm-goal-status="{state}"] {{ --fm-goal-color:{color}; }}'
                for state, (_, color) in STATUSES.items()) + '</style>'


class GoalAnchors(HTMLParser):
    """Collect insertion points without reserializing the host's HTML."""

    def __init__(self, page):
        super().__init__(convert_charrefs=False)
        self.offsets = [0] + [m.end() for m in re.finditer('\n', page)]
        self.heading = None
        self.in_heading = False
        self.cards = {}
        self.items = []
        self.feed(page)
        self.close()

    def absolute_offset(self):
        line, col = self.getpos()
        return self.offsets[line - 1] + col

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        element_id = attrs.get('id') or ''
        item = attrs.get('data-fm-goal-item')
        start_tag = self.get_starttag_text()
        if (tag in ('span', 'text') and item and not start_tag.endswith('/>')
                and 'fm-goal-item-status' in (attrs.get('class') or '').split()):
            self.items.append((item, self.absolute_offset() + len(start_tag)))
        if tag == 'h2' and element_id == 'doelen':
            self.in_heading = True
        if tag in ('article', 'div', 'section') and element_id.startswith('doel-'):
            self.cards[element_id[5:]] = self.absolute_offset() + len(self.get_starttag_text())

    def handle_endtag(self, tag):
        if tag == 'h2' and self.in_heading:
            self.heading = self.absolute_offset() + len('</h2>')
            self.in_heading = False


def goals_from(home):
    result = subprocess.run(
        ['bash', str(GOAL_BIN), 'export'], check=True, text=True, stdout=subprocess.PIPE,
        env={**os.environ, 'FM_HOME': str(home), 'FM_STATE_OVERRIDE': str(home / 'state'),
             'FM_DATA_OVERRIDE': str(home / 'data')},
    )
    snapshot = json.loads(result.stdout)
    if snapshot['schema'] != 'fm-goal-export.v1':
        raise ValueError('unsupported goal export schema')
    return snapshot['goals']


def generated(fragment):
    return '<!-- fm-goal-drive -->' + fragment + '<!-- /fm-goal-drive -->'


def item_status(item):
    # The export already applies dependencies, pause and orphaned-running checks.
    if item['startable']:
        return 'startable'
    state = item['state']
    if state == 'open' and item['class'] == 'captain':
        return 'open-captain'
    if state in ('open', 'blocked'):
        return 'waiting'
    if state not in STATUSES:
        raise ValueError(f'unsupported goal item state: {state}')
    return state


def items_kpi(statuses):
    total = len(statuses)
    counts = dict.fromkeys(STATUSES, 0)
    for state in statuses:
        counts[state] += 1
    legend, stops = [], []
    seen = 0
    for state, (label, color) in STATUSES.items():
        count = counts[state]
        legend.append(f'<li data-fm-goal-status="{state}"><span>{label}</span> <b>{count}</b></li>')
        if count:
            stops.append(f'{color} {seen / total:.8%} {(seen + count) / total:.8%}')
            seen += count
    ring = f' style="--fm-goal-ring:conic-gradient({", ".join(stops)})"' if stops else ''
    return ('<div class="fm-goal-items" id="doel-item-kpi">'
            '<div class="fm-goal-items-body">'
            f'<div class="fm-goal-ring"{ring}><span><strong>{total}</strong> taken</span></div>'
            f'<ul role="list" aria-label="Status van doeltaken">{"".join(legend)}</ul></div></div>')


def render(page, goals, allow=None):
    base = ATTRIBUTE.sub('', GENERATED.sub('', page))
    anchors = GoalAnchors(base)
    if anchors.heading is None:
        raise ValueError('missing cockpit goal heading <h2 id="doelen">')
    if allow:
        goals = [g for g in goals if g['id'] in allow]
    driven = sum(g['driven'] for g in goals)
    statuses = {f"{g['id']}/{item['id']}": item_status(item) for g in goals for item in g['items']}
    patches = [(anchors.heading, generated(STYLE + '<p class="small mute" id="doel-drive-kpi">'
                f'{driven} van {len(goals)} doelen actief gedreven</p>' + items_kpi(list(statuses.values()))))]
    for item, end in anchors.items:
        if item in statuses:
            state = statuses[item]
            patches.append((end - 1, f' data-fm-goal-status="{state}"'))
            patches.append((end, generated(STATUSES[state][0])))
    for g in goals:
        goal_id = g['id']
        if goal_id not in anchors.cards:
            raise ValueError(f'missing cockpit card #doel-{goal_id}; rebuild the Doelen section first')
        end = anchors.cards[goal_id]
        on = g['driven']
        label = html.escape('Firstmate stuurt: ' + g['title'], quote=True)
        answer = html.escape(f'{"pause" if on else "resume"} {goal_id}', quote=True)
        key = 'goal.drive.' + hashlib.sha256(goal_id.encode('ascii')).hexdigest()
        patches.append((end - 1, f' data-fm-goal-drive="{"on" if on else "off"}"'))
        patches.append((end, generated(f'''<form class="fm-goal-drive small" data-lavish-question="{key}" onsubmit="return mikoSend(event,'{key}')">
<span class="fm-goal-drive-state">{'wordt gedreven' if on else 'uit'}</span>
<input type="hidden" name="a" value="{answer}">
<button type="submit" role="switch" aria-checked="{'true' if on else 'false'}" aria-label="{label}">{'Zet uit' if on else 'Zet aan'}</button>
<span class="st mute small" role="status"></span></form>''')))
    for offset, fragment in sorted(patches, reverse=True):
        base = base[:offset] + fragment + base[offset:]
    return base


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--goal-home', type=Path, required=True, help='home that owns the goal records')
    parser.add_argument('--goal-id', action='append', help='limit goal controls and status rendering to this goal ID (repeatable)')
    parser.add_argument('--page', type=Path, required=True, help='already generated cockpit HTML; updated atomically')
    parser.add_argument('--output', type=Path, help='write a preview instead of changing --page')
    args = parser.parse_args()
    target = args.output or args.page
    try:
        page = args.page.read_text(encoding='utf-8')
        updated = render(page, goals_from(args.goal_home), args.goal_id)
        if target == args.page and updated == page:
            return
        with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=target.parent, delete=False) as f:
            pending = Path(f.name)
            try:
                f.write(updated)
                f.flush()
                pending.chmod(stat.S_IMODE(args.page.stat().st_mode))
                pending.replace(target)
            finally:
                pending.unlink(missing_ok=True)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f'goal-drive: {exc}\n')


if __name__ == '__main__':
    main()
