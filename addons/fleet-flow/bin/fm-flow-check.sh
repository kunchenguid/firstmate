#!/usr/bin/env python3
# Home flow check (flow playbook R1-R3). Read-only, local files only (runs inside the
# watcher's 30 s check window, so no GitHub call).
# Usage: fm-flow-check.sh <home>              lines for the lead, at most 5, only new or age-doubled ones
#        fm-flow-check.sh <home> --can-start  exit 0 when the lead may start a lane, 1 otherwise (prints why)
#        fm-flow-check.sh <home> --target     P50/P85 lane hours from lanes landed in 14 days
#        fm-flow-check.sh <home> --summary    one TSV row for Main's pulse:
#                                             home open working ready donewait oldest_wait_h min_since_working counted dry parked stalled
#        fm-flow-check.sh <home> --resume     task ids of lane-cap parked lanes to restart on their branch, one per free slot, oldest first
# Line order: land, over-cap, wait, red, split, budget, key, pull. Format: <task> <actor> <age> <next action>.
# Captain-held = a captain-hold key in the status file, or an open backlog line with hold-kind captain (data/backlog.md);
# captain-held lanes raise no wait or red line.
# Lane = live state/<task>.meta with kind=ship|scout. Lane age starts at the birth of data/<task>/.
# A lane in a long external wait (see FREE_AFTER) keeps its record but stops counting toward the cap:
# counted = open lanes that count; dry = 1 when ready = 0 and working < cap.
# Parked lane = last status verb `parked`. It leaves the open count, the cap and every wait line.
#   parked [key=lane-cap] ...        parked for the lane cap: it counts as ready work in its home's queue, keeps its branch,
#                                    and --resume names it for the next free slot, oldest first; no steer is needed.
#   parked ... (resume-on: <when>)   any other park names its resume condition: a date (YYYY-MM-DD), a PR URL or `captain`.
#                                    A park without one is STALLED: the pulse counts it and a stalled line names it.
# FM_MAIN_HOME names the main home (default ~/firstmate), where lane-caps, the status rollup and bin/ live.
import os, re, sys, glob, json, time, subprocess, statistics as st

CAP = 4
MAIN = os.environ.get('FM_MAIN_HOME') or os.path.expanduser('~/firstmate')
NAMES = {'1': 'takeone', '3': 'crewhouse', '4': 'writeboost', '8': 'muxr', '9': 'desklink', '10': 'byokit'}
AT = re.compile(r'\[at=(\d+)\]')
VERB = re.compile(r'^(?:\d{9,11}\s+)?([a-z][a-z-]*)')
HOLD_KIND = re.compile(r'\(hold-kind:\s*captain\)')
RESUME_ON = re.compile(r'\(resume-on:\s*(?:\d{4}-\d{2}-\d{2}|https?://\S+/pull/\d+|captain)\s*\)')
HOLD_UNTIL = re.compile(r'\(hold-until:\s*(\d{4}-\d{2}-\d{2})\)')

home = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else sys.exit('usage: fm-flow-check.sh <home> [--can-start|--target|--summary]')
mode = sys.argv[2] if len(sys.argv) > 2 else ''
S, D = f'{home}/state', f'{home}/data'
# Slot nicknames for --summary/--target rows; override one slot with FM_SLOT_<n>_NAME.
_slot = os.path.basename(os.path.dirname(home))
name = os.environ.get(f'FM_SLOT_{_slot}_NAME') or NAMES.get(_slot, _slot)
# Per-home cap override: config/lane-caps lines '<home> <cap>'.
CAP = next((int(l.split()[1]) for l in open(f'{MAIN}/config/lane-caps') if l.split()[:1] == [name]), CAP) if os.path.exists(f'{MAIN}/config/lane-caps') else CAP
NOW = int(time.time())

def birth(p):
    try:
        out = subprocess.run(['stat', '-c', '%W', p], capture_output=True, text=True, timeout=2).stdout.strip()
        return int(out) if out and out != '0' else int(os.stat(p).st_mtime)
    except Exception:
        return 0

def lines(p):
    try:
        return open(p, errors='replace').read().splitlines()
    except OSError:
        return []

def stamp(line, fallback):
    a = AT.search(line)
    if a: return int(a.group(1))
    m = re.match(r'^(\d{9,11})\s', line)
    return int(m.group(1)) if m else fallback

def open_keys(ls, fallback):
    op = {}
    for l in ls:
        v = VERB.match(l); v = v.group(1) if v else ''
        k = re.search(r'\[key=([^\]]+)\]', l); k = k.group(1) if k else 'default'
        if v in ('done', 'failed'): op = {}
        elif v in ('needs-decision', 'blocked'): op.setdefault(k, stamp(l, fallback))
        elif v in ('resolved', 'captain-held'): op.pop(k, None)
    return op

def backlog_held(t):
    # fm-captain-hold.sh hold writes "(hold-kind: captain)" on the open backlog line; the hold is inactive on and
    # after its "(hold-until: DATE)" date. Local file only.
    today = time.strftime('%Y-%m-%d', time.gmtime(NOW))
    for l in lines(f'{D}/backlog.md'):
        if l.startswith(f'- [ ] {t} '):
            u = HOLD_UNTIL.search(l)
            return bool(HOLD_KIND.search(l)) and not (u and u.group(1) <= today)
    return False

def h(sec): return f'{sec / 3600:.1f}h'

def landed14():
    out = []
    for l in lines(f'{MAIN}/state/{name}.status'):
        x = re.match(r'done \[key=merged-([^\]]+)\] \[at=(\d+)\]', l)
        if not x or re.search(r'dependabot|renovate', x.group(1)): continue
        at, b = int(x.group(2)), birth(f'{D}/{x.group(1)}')
        if at >= NOW - 14 * 86400 and 0 < b < at: out.append((at - b) / 3600)
    return sorted(out)

def target():
    x = landed14()
    if len(x) < 5: return None, None, len(x)
    return st.median(x), x[int(.85 * len(x))], len(x)

if mode == '--target':
    p50, p85, n = target()
    print(f'{name} landed lanes 14d n={n} ' + (f'P50={p50:.1f}h P85={p85:.1f}h' if p50 is not None else 'too few for P50/P85; red line uses 24h'))
    sys.exit(0)

# Lanes
lanes = []
for m in glob.glob(f'{S}/*.meta'):
    meta = dict(l.split('=', 1) for l in lines(m) if '=' in l)
    if meta.get('kind') not in ('ship', 'scout'): continue
    t = os.path.basename(m)[:-5]; sp = f'{S}/{t}.status'
    ls = [l for l in lines(sp) if l.strip()]
    mt = int(os.stat(sp).st_mtime) if os.path.exists(sp) else int(os.stat(m).st_mtime)
    last = ls[-1] if ls else 'working'
    v = VERB.match(last); v = v.group(1) if v else 'working'
    keys = open_keys(ls, mt)
    lanes.append(dict(t=t, meta=meta, verb=v, since=stamp(last, mt), keys=keys,
                      last=last, at=stamp(last, None) if ls else None, age=NOW - (birth(f'{D}/{t}') or mt),
                      captain=any(k.startswith('captain-hold') for k in keys) or backlog_held(t)))
parked = [L for L in lanes if L['verb'] == 'parked']
lanes = [L for L in lanes if L['verb'] != 'parked']
for L in parked:
    L['cap'] = bool(re.search(r'\[key=lane-cap\]', L['last']))
    L['stalled'] = not L['cap'] and not RESUME_ON.search(L['last'])
open_n = len(lanes)
# A lane whose last event is a paused, blocked or failed wait stamped more than 4 h ago, and still that wait in
# bin/fm-crew-state.sh (so validating and own busy work stay working), stops counting toward the cap; a ready item
# takes its slot. An unstamped wait or an unreadable state keeps counting.
FREE_AFTER = 4 * 3600

def crew_state(t):
    try:
        return subprocess.Popen([f'{MAIN}/bin/fm-crew-state.sh', t], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                text=True, errors='replace', env={**os.environ, 'FM_HOME': home, 'FM_CREW_STATE_NO_FORGE': '1'})
    except OSError:
        return None

# A paused lane is probed at any age: its own no-mistakes run can execute under a paused stamp (the brief's own-run wait),
# and crew-state reads that run-step as working. Blocked and failed lanes are probed only past FREE_AFTER, to free slots.
probes = {L['t']: crew_state(L['t']) for L in lanes if not L['captain'] and (L['verb'] == 'paused' or
          (L['verb'] in ('blocked', 'failed') and L['at'] and NOW - L['at'] > FREE_AFTER))}
deadline = time.time() + 15
for L in lanes:
    p, out = probes.get(L['t']), ''
    if p:
        try: out = p.communicate(timeout=max(0.1, deadline - time.time()))[0]
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    L['free'] = bool(re.match(r'state: (paused|blocked|failed) ', out)) and bool(L['at']) and NOW - L['at'] > FREE_AFTER
    L['busy'] = L['verb'] in ('working', 'resolved') or (L['verb'] == 'paused' and bool(re.match(r'state: working ', out)))
count_n = open_n - sum(L['free'] for L in lanes)
# Busy lanes count toward the cap: working, resolved, and a paused lane whose run crew-state reads as working.
# Waiting, parked and captain-held lanes do not. HARD bounds the open lanes that count, so waits under FREE_AFTER cannot pile up.
active_n = sum(L['busy'] and not L['captain'] for L in lanes)
HARD = CAP + 2

def ready_ids():
    # Raises on a failed query: a failed read must never look like a proven zero.
    r = subprocess.run([f'{MAIN}/bin/fm-tasks-axi.sh', 'ready'], capture_output=True, text=True, timeout=8,
                       env={**os.environ, 'FM_HOME': home})
    if r.returncode: raise RuntimeError(f'ready query exit {r.returncode}: ' + (r.stderr.strip().splitlines() or [''])[-1])
    return re.findall(r'^\s{2}([\w.-]+),queued', r.stdout, re.M)

land = [L for L in lanes if L['verb'] == 'done' and NOW - L['since'] >= 900]
if mode == '--summary':
    # Exact counts: working = active_n (held lanes excluded, same rule as --can-start); done = every done lane,
    # not only those past the 15-minute landing grace that --can-start and the action lines use.
    working = active_n
    try: ready_n = len(ready_ids()) + sum(L['cap'] for L in parked)
    except Exception as e: sys.exit(f'{name}: {e}')
    waits = [NOW - L['since'] for L in lanes if L['verb'] not in ('working', 'resolved', 'done', 'failed')]
    lw = max([L['since'] for L in lanes if L['verb'] in ('working', 'resolved')] or [0])
    print('\t'.join(map(str, [name, open_n, working, ready_n, sum(L['verb'] == 'done' for L in lanes),
                              f'{max(waits) / 3600:.1f}' if waits else '0', (NOW - lw) // 60 if lw else -1,
                              count_n, int(ready_n == 0 and active_n < CAP), len(parked), sum(L['stalled'] for L in parked)])))
    sys.exit(0)

waiting = sorted((L for L in parked if L['cap']), key=lambda L: L['since'])
if mode == '--resume':
    for L in waiting[:max(0, CAP - active_n)]: print(L['t'])
    sys.exit(0)

if mode == '--can-start':
    why = []
    if waiting and active_n < CAP: why.append(f'{waiting[0]["t"]} is parked for the lane cap and takes the free slot: resume it first')
    if active_n >= CAP: why.append(f'{active_n} working lanes, cap {CAP}: finish one first')
    if count_n >= HARD: why.append(f'{count_n} open lanes, hard cap {HARD}: land or close a waiting lane first')
    # A done lane blocks starts only after 60 min unmerged; open >= cap+2 still blocks.
    why += [f'{L["t"]} is done {h(NOW - L["since"])} ago: land and clean it up first' for L in land if not L['captain'] and NOW - L['since'] >= 3600]
    for w in why: print(w)
    sys.exit(1 if why else 0)

out = []  # (key, age_seconds, text)
for L in land:
    if not L['captain']:
        out.append((f'land {L["t"]}', NOW - L['since'], f'{L["t"]} lead {h(NOW - L["since"])} land it: merge if green (bin/fm-pr-merge.sh), then bin/fm-teardown.sh'))
if count_n > HARD:
    out.append((f'over-cap', count_n, f'home lead {count_n}/{HARD} over hard cap: start nothing; land nearest-to-merge, stop the oldest with a learned note'))
for L in lanes:
    clock = 1800 if L['verb'] == 'needs-decision' else 7200
    # failed = stopped on purpose, kept for an unlanded-work refusal; no one waits on it, the red age rule still surfaces it
    if L['verb'] not in ('working', 'resolved', 'done', 'failed') and NOW - L['since'] >= clock and not L['captain']:
        out.append((f'wait {L["t"]}', NOW - L['since'], f'{L["t"]} lead {h(NOW - L["since"])} {L["verb"]} past its clock: decide, restart, route or stop it'))
p50, p85, _ = target()
red = min(p85 * 3600, 86400) if p85 else 86400
for L in lanes:
    if L['age'] > red and not L['captain']:
        out.append((f'red {L["t"]}', L['age'], f'{L["t"]} lead {h(L["age"])} red (limit {h(red)}): land, cut scope, change method or stop'))
for L in parked:
    if L['stalled']:
        out.append((f'stalled {L["t"]}', NOW - L['since'], f'{L["t"]} parked {h(NOW - L["since"])} STALLED, no resume condition: add (resume-on: DATE, PR URL or captain) or resume or stop it'))
cache_p = f'{S}/.flow.cache'
try: cache = json.load(open(cache_p))
except Exception: cache = {}
for L in lanes:
    wt = L['meta'].get('worktree', '')
    if not os.path.isdir(wt): continue
    try:
        head = subprocess.run(['git', '-C', wt, 'rev-parse', 'HEAD'], capture_output=True, text=True, timeout=3).stdout.strip()
        k = 'a:' + head  # added lines only, same rule as fm-checks-lint.sh; deletions are not penalised
        if k not in cache:
            base = subprocess.run(['git', '-C', wt, 'merge-base', 'HEAD', 'origin/HEAD'], capture_output=True, text=True, timeout=3).stdout.strip()
            stat = subprocess.run(['git', '-C', wt, 'diff', '--shortstat', base, head], capture_output=True, text=True, timeout=3).stdout if base else ''
            cache[k] = sum(int(n) for n in re.findall(r'(\d+) insertion', stat))
        if cache[k] >= 1000:
            out.append((f'split {L["t"]}', cache[k], f'{L["t"]} worker {cache[k]} added lines: split before review (limit 1000)'))
    except Exception:
        pass
try:
    json.dump(dict(list(cache.items())[-200:]), open(cache_p, 'w'))
except OSError:
    pass
for L in lanes:
    n = sum(1 for l in lines(f'{D}/{L["t"]}/brief.md') if l.startswith('attempt:'))
    if n >= 3:
        out.append((f'budget {L["t"]}', n, f'{L["t"]} lead {n} attempts: budget spent; really different method with a new budget, or stop'))
live = {L['t'] for L in lanes}
for sp in glob.glob(f'{S}/*.status'):
    t = os.path.basename(sp)[:-7]
    if t in live or os.path.exists(f'{S}/{t}.meta'): continue
    for k, at in open_keys(lines(sp), int(os.stat(sp).st_mtime)).items():
        if k.startswith('captain-hold') or k.startswith('pending-reply'): continue
        out.append((f'key {t} {k}', NOW - at, f'{t} lead {h(NOW - at)} key {k} has no live lane: write resolved [key={k}] or re-raise it'))
# Floor nudge moved into Firstmate's watcher (config/lane-target, afd00e42); no pull line here.

# Nudge-fatigue guard: print a line only when new or its age doubled.
last_p = f'{S}/.flow.last'
try: last = json.load(open(last_p))
except Exception: last = {}
new, shown = {}, 0
for key, age, text in out:
    prev = last.get(key)
    if key == 'pull':  # floor: repeat every 30 min while slots are free and ready work waits
        if shown < 5 and (prev is None or NOW - prev >= 1800):
            print(f'flow: {text}'); shown += 1; new[key] = NOW
        elif prev is not None:
            new[key] = prev
        continue
    if shown < 5 and (prev is None or age >= 2 * max(prev, 1)):
        print(f'flow: {text}'); shown += 1; new[key] = age
    elif prev is not None:
        new[key] = prev
try:
    json.dump(new, open(last_p, 'w'))
except OSError:
    pass
