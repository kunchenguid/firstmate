#!/usr/bin/env python3
"""Refresh drive state on existing #doelen / #doel-<id> cockpit cards."""

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
ATTRIBUTE = re.compile(r' data-fm-goal-drive="(?:on|off)"(?=>)')
STYLE = '''<style>
[data-fm-goal-drive="off"] { filter: grayscale(1); }
.fm-goal-drive { display:flex; flex-wrap:wrap; align-items:center; gap:4px 8px; margin:2px 0 4px; }
.fm-goal-drive button { font:inherit; color:inherit; background:#202633; border:1px solid #546074;
                        border-radius:6px; padding:4px 8px; cursor:pointer; }
.fm-goal-drive-state { color:#7fe0a5; font-weight:bold; }
.fm-goal-drive .st { background:none; border:0; padding:0; }
.fm-goal-drive .st:empty { display:none; }
</style>'''


class GoalAnchors(HTMLParser):
    """Collect insertion points without reserializing the host's HTML."""

    def __init__(self, page):
        super().__init__(convert_charrefs=False)
        self.offsets = [0] + [m.end() for m in re.finditer('\n', page)]
        self.heading = None
        self.in_heading = False
        self.cards = {}
        self.feed(page)
        self.close()

    def absolute_offset(self):
        line, col = self.getpos()
        return self.offsets[line - 1] + col

    def handle_starttag(self, tag, attrs):
        element_id = dict(attrs).get('id') or ''
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


def render(page, home, allow=None):
    base = ATTRIBUTE.sub('', GENERATED.sub('', page))
    anchors = GoalAnchors(base)
    if anchors.heading is None:
        raise ValueError('missing cockpit goal heading <h2 id="doelen">')
    goals = goals_from(home)
    if allow:
        goals = [g for g in goals if g['id'] in allow]
    driven = sum(g['driven'] for g in goals)
    patches = [(anchors.heading, generated(STYLE + '<p class="small mute" id="doel-drive-kpi">'
                f'{driven} van {len(goals)} doelen actief gedreven</p>'))]
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
    parser.add_argument('--goal-id', action='append', help='limit switches and KPI to this goal ID (repeatable)')
    parser.add_argument('--page', type=Path, required=True, help='already generated cockpit HTML; updated atomically')
    parser.add_argument('--output', type=Path, help='write a preview instead of changing --page')
    args = parser.parse_args()
    target = args.output or args.page
    try:
        page = args.page.read_text(encoding='utf-8')
        updated = render(page, args.goal_home, args.goal_id)
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
