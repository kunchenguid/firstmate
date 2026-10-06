#!/usr/bin/env bash
# fm-dashboard.sh - build the read-only fleet dashboard page for this home.
#
# Builds ONE self-contained HTML page (inline CSS and SVG, no script, no network
# reference) that answers the common fleet questions at a glance: what is
# running, what finished but has not landed, what merged, whether lead alerts
# are automatic, how skill use and quality track their targets, and what waits
# on the captain. Below that it shows one card per home, seven-day trends, and
# the full task lists in collapsible sections.
#
# Sources, all read-only and all optional:
#   bin/fm-bearings-snapshot.sh --json --all-in-flight --all-decisions
#       --all-queued --all-landed   in flight, decisions, queued, landed
#   data/metrics/prs.tsv            merged PRs (merged, first_pass, escaped, hours_to_merge)
#   data/metrics/daily.tsv          per day and home counters (steers, stall_alarms, ...)
#   data/metrics/skills.tsv         per day, home and skill read counts
#   data/metrics/rings.tsv          leads the watcher woke itself
#   data/fleet-pulse.tsv            per home flow rows (open, ready, donewait, oldestwait_h)
#   config/metrics-targets.tsv      metric, op (>= or <=), target
#   config/lane-target              open-lane target per home (default 4)
#   data/defects.md                 "- " defect lines under "## <date>" headings
#   data/secondmates.md             registered homes (every one gets a card)
#   data/projects.md                this home's projects, and each registered
#                                   home's own data/projects.md
# TSV files are read by header name. A source that is absent or malformed hides
# its section behind a one-line note; it never fails the build. The snapshot's
# own parent-side ledger cache refresh is the only state it may touch besides
# the page.
#
# Usage:
#   fm-dashboard.sh [build]
#   fm-dashboard.sh serve [--bind ADDR] [--port N]
# build (the default) writes $FM_HOME/state/dashboard/index.html and prints its
# path. serve runs a small read-only web server (python3 stdlib, IPv4) that
# answers GET or HEAD for / and /index.html only; every other path is 404. It
# answers at once with the last built page, marked "updated N s ago", and starts
# one background rebuild when that page is older than 60 seconds; only the very
# first load, with no page yet, waits for a build. It prints
# `serving http://ADDR:PORT/` once listening. ADDR defaults to 127.0.0.1 and
# PORT to 8787; port 0 picks a free port. There is no authentication: reach is
# whatever the bind address exposes. Nothing here schedules a refresh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
out_dir="$FM_HOME/state/dashboard"
page="$out_dir/index.html"

usage() { echo "usage: fm-dashboard.sh [build] | serve [--bind ADDR] [--port N]" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "fm-dashboard: python3 is required" >&2; exit 1; }

cmd=${1:-build}
[ $# -gt 0 ] && shift
case "$cmd" in
  build) [ $# -eq 0 ] || usage ;;
  serve)
    bind=127.0.0.1 port=8787
    while [ $# -gt 0 ]; do
      case "$1" in
        --bind) [ $# -ge 2 ] || usage; bind=$2; shift 2 ;;
        --port) [ $# -ge 2 ] || usage; port=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    case "$port" in ''|*[!0-9]*) usage ;; esac
    exec python3 - "$0" "$FM_HOME" "$page" "$bind" "$port" <<'PY'
import http.server, os, subprocess, sys, threading, time
SCRIPT, HOME, PAGE, BIND, PORT = sys.argv[1:6]
MAX_AGE = 60
building = threading.Lock()
last_error = b''

def build():  # call holding `building`; the build replaces the page in one rename
    global last_error
    try:
        r = subprocess.run(['bash', SCRIPT, 'build'], env=dict(os.environ, FM_HOME=HOME),
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        last_error = r.stderr if r.returncode else b''
    finally:
        building.release()

def age():
    try: return time.time() - os.path.getmtime(PAGE)
    except OSError: return None

class Handler(http.server.BaseHTTPRequestHandler):
    timeout = 10  # an idle preconnect must not hold the one-at-a-time server

    def send(self, code, body, ctype):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; img-src data:")
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(body)

    def do_GET(self):
        if self.path.split('?', 1)[0] not in ('/', '/index.html'):
            return self.send(404, b'not found\n', 'text/plain; charset=utf-8')
        a = age()
        if a is None:  # the first load ever waits for the first page
            with building: pass  # a build already under way finishes first
            if age() is None:
                building.acquire(); build()
            a = age()
            if a is None:
                return self.send(500, b'dashboard build failed: ' + last_error, 'text/plain; charset=utf-8')
        elif a >= MAX_AGE and building.acquire(blocking=False):
            threading.Thread(target=build, daemon=True).start()
        note = f' · updated {int(a)} s ago' + (' · refreshing' if building.locked() else '')
        if last_error: note += ' · last refresh failed, showing the last good page'
        with open(PAGE, 'rb') as f:
            body = f.read().replace(b'<!--age-->', note.encode(), 1)
        self.send(200, body, 'text/html; charset=utf-8')
    do_HEAD = do_GET

# ponytail: one request at a time; rebuilds run on a side thread, one at a time.
srv = http.server.HTTPServer((BIND, int(PORT)), Handler)
print(f'serving http://{BIND}:{srv.server_address[1]}/', flush=True)
try: srv.serve_forever()
except KeyboardInterrupt: pass
PY
    ;;
  -h|--help) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac

mkdir -p "$out_dir" || { echo "fm-dashboard: cannot create $out_dir" >&2; exit 1; }
# Per-run scratch names, so a manual build and a served rebuild never share files.
snap="$out_dir/.snapshot.$$.json"
snap_err="$out_dir/.snapshot.$$.err"
trap 'rm -f "$snap" "$snap_err" "$page.$$.tmp"' EXIT
# Raise the per-home bounds; a second mate's cached summary can still apply its own.
FM_HOME="$FM_HOME" FM_SNAPSHOT_SECONDMATE_QUEUED=500 FM_SNAPSHOT_SECONDMATE_DECISIONS=500 \
  "$SCRIPT_DIR/fm-bearings-snapshot.sh" --json --all-in-flight --all-decisions \
  --all-queued --all-landed > "$snap" 2> "$snap_err" \
  || { rc=$?; : > "$snap"; printf 'fleet snapshot exited %s: %s\n' "$rc" "$(tail -n 1 "$snap_err")" >> "$snap_err"; }

python3 - "$FM_HOME" "$snap" "$snap_err" "$page.$$.tmp" <<'PY' || { echo "fm-dashboard: page build failed" >&2; exit 1; }
import html, json, math, os, re, sys
from datetime import date, datetime, timedelta

HOME, SNAP, SNAP_ERR, OUT = sys.argv[1:5]
NOW = datetime.now().astimezone()
TODAY = NOW.date()
YDAY = TODAY - timedelta(days=1)
WEEK = [TODAY - timedelta(days=i) for i in range(6, -1, -1)]
notes = []  # (section, one-line reason) for every hidden or partial section

def esc(v): return html.escape(str(v), quote=True)
def num(v):
    try: v = float(v)
    except (TypeError, ValueError): return None
    return v if math.isfinite(v) else None
def count(v):  # a pulse count; producers write -1 or ? when they could not measure
    v = num(v)
    return v if v is not None and v >= 0 else None
def fmt(v, digits=1):
    if v is None: return '–'
    return str(int(v)) if float(v).is_integer() else f'{v:.{digits}f}'
def local_day(ts):
    try: return datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone().date()
    except (AttributeError, ValueError): return None
def iso_day(s):
    try: return date.fromisoformat(s)
    except (TypeError, ValueError): return None

def tsv(rel, need, extra=()):
    """Rows of a TSV as dicts keyed by header name, or None with a note."""
    p = os.path.join(HOME, rel)
    if not os.path.isfile(p):
        notes.append((rel, 'not found')); return None
    try: lines = open(p, encoding='utf-8', errors='replace').read().splitlines()
    except OSError as e:
        notes.append((rel, f'unreadable: {e.strerror}')); return None
    head = lines[0].lstrip('# ').split('\t') if lines else []  # a config header may be a comment line
    missing = [c for c in need if c not in head]
    if missing:
        notes.append((rel, 'malformed: missing column ' + ', '.join(missing))); return None
    cols = head + list(extra[len(head):]) if extra[:len(head)] == tuple(head) else head
    rows = [dict(zip(cols, l.split('\t'))) for l in lines[1:] if l.strip() and not l.startswith('#')]
    good = [r for r in rows if all(r.get(c) for c in need)]
    if len(good) < len(rows): notes.append((rel, f'{len(rows) - len(good)} short row(s) skipped'))
    return good

# --- sources -------------------------------------------------------------
snap = None
try:
    snap = json.load(open(SNAP))
    if not isinstance(snap, dict) or snap.get('schema') != 'fm-bearings.v1': raise ValueError('unexpected schema')
except (OSError, ValueError) as e:
    err = ''
    try: err = open(SNAP_ERR, errors='replace').read().strip().splitlines()[-1]
    except (OSError, IndexError): pass
    notes.append(('fleet snapshot', err or str(e) or 'no output')); snap = None

prs = tsv('data/metrics/prs.tsv', ('home', 'merged', 'first_pass'))
daily = tsv('data/metrics/daily.tsv', ('day', 'home'))
skills = tsv('data/metrics/skills.tsv', ('day', 'home', 'skill', 'reads'))
rings = tsv('data/metrics/rings.tsv', ('day', 'home'))
# Older pulse files keep their first 6-column header while rows carry the later columns.
PULSE = ('time', 'home', 'merged2h', 'working', 'paused', 'blocked', 'open', 'ready', 'donewait',
         'oldestwait_h', 'min_since_working', 'leadkeys2h', 'rulewords')
pulse = tsv('data/fleet-pulse.tsv', ('time', 'home'), PULSE)
targets = tsv('config/metrics-targets.tsv', ('metric', 'op', 'target'))
lane_target = 4
try: lane_target = int(open(os.path.join(HOME, 'config/lane-target')).read().split()[0])
except (OSError, ValueError, IndexError): pass

def project_names(path):  # "- <name> [mode] - ..." lines, or None when absent
    try: return [m.group(1) for m in re.finditer(r'^- (\S+) \[', open(path, encoding='utf-8', errors='replace').read(), re.M)]
    except OSError: return None
projects = {'main': project_names(os.path.join(HOME, 'data/projects.md'))}
if projects['main'] is None: notes.append(('data/projects.md', 'not found'))
registered = set()
try:
    for l in open(os.path.join(HOME, 'data/secondmates.md'), encoding='utf-8', errors='replace'):
        m = re.match(r'- (\S+) - ', l)
        if not m: continue
        registered.add(m.group(1))
        # The routing fields close the line; greedy .* lands on the last "(home:".
        f = re.match(r'.*\(home: ([^;]*);.*; projects: ([^;)]*)', l)
        own = project_names(os.path.join(f.group(1).strip(), 'data/projects.md')) if f else None
        projects[m.group(1)] = own if own is not None else [x.strip() for x in f.group(2).split(',') if x.strip()] if f else []
except OSError: pass  # no registered homes

defects = None
dp = os.path.join(HOME, 'data/defects.md')
if os.path.isfile(dp):
    defects, cur = [], None
    for l in open(dp, encoding='utf-8', errors='replace'):
        h = re.match(r'## (\d{4}-\d\d-\d\d)', l)
        if l.startswith('## '): cur = h.group(1) if h else None
        elif l.startswith('- ') and cur:
            st = re.search(r'\b(OPEN|FIXED|RETRO)\b[^A-Za-z]*$', l.strip())
            defects.append(dict(day=cur, text=l[2:].strip(), status=st.group(1) if st else ''))
else:
    notes.append(('data/defects.md', 'not found'))

# --- derived numbers -----------------------------------------------------
def dsum(col, day, home=None):
    if daily is None: return None
    return sum(int(num(r.get(col)) or 0) for r in daily if iso_day(r['day']) == day and (home is None or r['home'] == home))

merged_on = {}
for p in prs or []:
    d = local_day(p['merged'])
    if d: merged_on.setdefault(d, []).append(p)
def merged(day, home=None):
    if prs is None: return None
    return len([p for p in merged_on.get(day, []) if home is None or p['home'] == home])
def first_pass_pct(days):
    ps = [p for d in days for p in merged_on.get(d, [])]
    return 100 * sum(p['first_pass'] == '1' for p in ps) // len(ps) if ps else None  # floored, as the retro report does

latest = {}  # home -> latest measured pulse row
for r in pulse or []:
    if count(r.get('donewait')) is not None or count(r.get('open')) is not None:
        latest[r['home']] = r
pulse_at = min((r['time'] for r in latest.values()), default=None)  # the oldest home row in the totals
def pulse_sum(col):
    vals = [count(r.get(col)) for r in latest.values()]
    vals = [v for v in vals if v is not None]
    return sum(vals) if vals else None
def pulse_day(col, day):  # each home's last row of that day, summed
    rows = {}
    for r in pulse or []:
        if r['time'][:10] == day.isoformat() and count(r.get(col)) is not None: rows[r['home']] = count(r[col])
    return sum(rows.values()) if rows else None

in_flight = (snap or {}).get('in_flight') or []
decisions = (snap or {}).get('decisions_open') or []
merge_asks = ((snap or {}).get('contributions') or {}).get('captain') or []
gates = (snap or {}).get('gates') or []
landed = (snap or {}).get('landed') or []
leads = {s.get('id'): s for s in (snap or {}).get('secondmates') or []}
measured = {p['home'] for p in prs or []} | {r['home'] for r in daily or []}
measured.discard('main')  # main carries only fleet-wide counters (captain messages, defects)
def home_of_task(tid): return tid.split('/', 1)[0] if '/' in tid else 'main'
def owner_home(o): return 'main' if o in ('(main)', None, '') else o

# Quality window: today and yesterday, matching the retro's default report.
QWIN = [YDAY, TODAY]
def window_metrics(home=None):
    ps = [p for d in QWIN for p in merged_on.get(d, []) if home is None or p['home'] == home]
    n = len(ps)
    def dw(col): return sum(dsum(col, d, home) or 0 for d in QWIN) if daily is not None else None
    hrs = sorted(v for v in (num(p.get('hours_to_merge')) for p in ps) if v is not None)
    per = lambda v: round(v / n, 2) if n and v is not None else None
    steers, dec, blk = dw('steers'), dw('decisions'), dw('blocks')
    return {
        'first_pass': (100 * sum(p['first_pass'] == '1' for p in ps) // n if n else None) if prs is not None else None,
        'escaped': sum((num(p.get('escaped')) or 0) > 0 for p in ps) if prs is not None else None,
        'p90_hours': hrs[int(0.9 * (len(hrs) - 1))] if hrs else None,
        'corrections_per_merge': per(dw('s_correct')),
        'interventions_per_merge': per(None if steers is None else steers + (dec or 0) + (blk or 0)),
        'captain_per_merge': per(dw('captain_msgs')),
        'stall_alarms': dw('stall_alarms'),
    }, n
QLABEL = {'first_pass': ('First-pass merges', '%'), 'escaped': ('Bugs that escaped', ''),
          'p90_hours': ('Slowest merges (p90)', ' h'), 'corrections_per_merge': ('Corrections per merge', ''),
          'interventions_per_merge': ('Main nudges per merge', ''), 'captain_per_merge': ('Captain messages per merge', ''),
          'stall_alarms': ('Lead stalls that reached Main', '')}
def misses(v, op, t): return v is not None and (v < t if op == '>=' else v > t)

# --- html pieces ---------------------------------------------------------
def tile(label, value, sub, tone=''):
    return (f'<div class="tile {tone}"><div class="tl">{esc(label)}</div>'
            f'<div class="tv">{value}</div><div class="ts">{sub}</div></div>')
def note(section, reason): return f'<p class="note">{esc(section)}: {esc(reason)}. This part is hidden.</p>'
def chip(text, tone=''): return f'<span class="chip {tone}">{esc(text)}</span>'
def link(text, url):
    return f'<a href="{esc(url)}" rel="noreferrer">{esc(text)}</a>' if re.match(r'https?://', url or '') else esc(text)

def bars(values, tone=''):
    vals = [v for v in values if v is not None]
    top = max(vals) if vals and max(vals) > 0 else 1
    w, gap, h = 16, 4, 40
    parts = []
    for i, (d, v) in enumerate(zip(WEEK, values)):
        x = i * (w + gap)
        if v is None:
            parts.append(f'<rect x="{x}" y="{h-2}" width="{w}" height="2" class="b0"><title>{d:%a %d %b}: no data</title></rect>')
            continue
        bh = max(2, round(h * v / top))
        cls = 'bt' if d == TODAY else 'b'
        parts.append(f'<rect x="{x}" y="{h-bh}" width="{w}" height="{bh}" rx="2" class="{cls}"><title>{d:%a %d %b}: {fmt(v)}</title></rect>')
    return f'<svg viewBox="0 0 {7*w+6*gap} {h}" class="spark {tone}" role="img" aria-label="last 7 days">{"".join(parts)}</svg>'

def trend(label, values, kind='count', week=None):
    """kind: count (footer sums the week), level (footer shows the peak), pct (footer shows `week`)."""
    v = values[-1]
    vals = [x for x in values if x is not None]
    if not vals: total = 'no data'
    elif kind == 'count': total = f'7 days {fmt(sum(vals))}'
    elif kind == 'level': total = f'peak {fmt(max(vals))}'
    else: total = f'7 days {fmt(week)}%'
    unit = '%' if kind == 'pct' else ''
    return (f'<div class="trend"><div class="trh"><span>{esc(label)}</span><b>{fmt(v)}{unit if v is not None else ""}</b></div>'
            f'{bars(values)}<div class="trf"><span>{WEEK[0]:%a}</span><span>{total}</span><span>today</span></div></div>')

def details(title, count, body, open_=False):
    return (f'<details{" open" if open_ else ""}><summary><span>{esc(title)}</span><span class="cnt">{count}</span></summary>'
            f'<div class="list">{body or "<p class=empty>Nothing here.</p>"}</div></details>')
def row(main, meta='', right=''):
    return f'<div class="row"><div class="rm">{main}</div><div class="rx">{meta}</div><div class="rr">{right}</div></div>'

STATE_WORDS = {'working': ('Working', 'ok'), 'paused': ('Waiting', 'warn'), 'blocked': ('Blocked', 'bad'),
               'needs-decision': ('Needs a decision', 'bad'), 'done': ('Finished', 'ok'), 'failed': ('Failed', 'bad'),
               'unknown': ('Status unclear', 'warn')}
LEAD_WORDS = {'captain_decision': ('Waiting on you', 'warn'), 'externally_held': ('Waiting on someone else', 'warn'),
              'unknown': ('Records need tidy-up', 'bad'), 'working': ('Working', 'ok'), 'idle': ('Idle', ''),
              'stale': ('Not responding', 'bad'), 'dead': ('Stopped', 'bad')}

# --- page ----------------------------------------------------------------
S = []  # sections

# 1. At a glance
t = []
if snap is not None:
    lanes_open = pulse_sum('open')
    sub = 'work items actively working'
    if lanes_open is not None:  # the snapshot lists second mate lanes only while they work; the pulse counts every open lane
        lanes_open += len([i for i in in_flight if home_of_task(i.get('id', '')) == 'main'])
        sub = f'actively working, of {fmt(lanes_open)} open lanes'
    t.append(tile('Running now', len(in_flight), sub))
if latest:
    nl = pulse_sum('donewait')
    t.append(tile('Finished, not landed', fmt(nl), f'waiting to merge · as of {esc(pulse_at[11:16])}', 'warn' if nl else ''))
if prs is not None:
    t.append(tile('Merged today', merged(TODAY), f'yesterday {merged(YDAY)} · measured homes'))
if latest:
    t.append(tile('Queued and ready', fmt(pulse_sum('ready')), 'can start when a lane frees'))
if snap is not None:
    wait = len(decisions) + len(merge_asks)
    t.append(tile('Waiting on you', wait, f'{len(merge_asks)} merge approval{"s" if len(merge_asks) != 1 else ""}, {len(decisions)} decision{"s" if len(decisions) != 1 else ""}', 'warn' if wait else 'ok'))
S.append(f'<section><h2>At a glance</h2><div class="tiles">{"".join(t)}</div></section>')

# 2. Questions: alerts, skills, quality, firstmate changes
cards = []
if daily is not None:
    def rung(day):  # the ring log is appended every pass; the daily roll-up only every 2 h
        if rings is None: return dsum('self_rings', day)
        return len([r for r in rings if iso_day(r['day']) == day])
    st_t, sr_t, rl_t = dsum('stall_alarms', TODAY), rung(TODAY), dsum('relaunches', TODAY)
    st_y, sr_y, rl_y = dsum('stall_alarms', YDAY), rung(YDAY), dsum('relaunches', YDAY)
    if st_t and not sr_t:
        verdict, tone = f'Not automatic yet: {st_t} lead stall{"s" if st_t != 1 else ""} reached Main and the watcher woke no lead itself.', 'bad'
    elif st_t:
        verdict, tone = f'Partly automatic: the watcher woke {sr_t} lead{"s" if sr_t != 1 else ""} itself, but {st_t} stall{"s" if st_t != 1 else ""} still reached Main.', 'warn'
    else:
        verdict, tone = 'Working: no lead stall reached Main today.', 'ok'
    woke = ''
    if rings is not None:
        names = {}
        for r in rings:
            if iso_day(r['day']) == TODAY: names[r['home']] = names.get(r['home'], 0) + 1
        woke = '<p class="small">Woken today: ' + (esc(', '.join(f'{h} ×{n}' if n > 1 else h for h, n in sorted(names.items()))) or 'none') + '</p>'
    else:
        woke = '<p class="small muted">Per-lead wake record not found yet.</p>'
    def stat(label, a, b, tone_=''):
        return f'<div class="stat {tone_}"><b>{fmt(a)}</b><span>{esc(label)}</span><i>yesterday {fmt(b)}</i></div>'
    cards.append(f'''<div class="card"><h3>Are the alerts working?</h3><p class="verdict {tone}">{esc(verdict)}</p>
<div class="stats">{stat("stalls reached Main", st_t, st_y, "bad" if st_t and not sr_t else ("warn" if st_t else ""))}{stat("leads woken automatically", sr_t, sr_y)}{stat("stopped leads restarted", rl_t, rl_y)}{stat("Main messages to leads", dsum("steers", TODAY), dsum("steers", YDAY))}</div>{woke}</div>''')
else:
    cards.append(f'<div class="card"><h3>Are the alerts working?</h3>{note("data/metrics/daily.tsv", "not available")}</div>')

if skills is not None or daily is not None:
    sk_t, sk_y = dsum('skill_reads', TODAY), dsum('skill_reads', YDAY)
    top = {}
    for r in skills or []:
        if iso_day(r['day']) == TODAY: top[r['skill']] = top.get(r['skill'], 0) + int(num(r['reads']) or 0)
    top = sorted(top.items(), key=lambda kv: (-kv[1], kv[0]))[:6]
    peak = top[0][1] if top else 1
    rows_ = ''.join(f'<div class="hbar"><span>{esc(k)}</span><i style="--w:{max(4, round(100*v/peak))}%"></i><b>{v}</b></div>' for k, v in top)
    delta = '' if sk_t is None or sk_y is None else (f'{"up" if sk_t >= sk_y else "down"} from {sk_y} yesterday')
    cards.append(f'''<div class="card"><h3>Are skills being used?</h3><div class="big"><b>{fmt(sk_t)}</b><span>skill reads today · {esc(delta)}</span></div>
{rows_ or '<p class="small muted">No skill reads recorded today.</p>'}{'' if skills is not None else note('data/metrics/skills.tsv', 'not available')}</div>''')

if targets is not None and (prs is not None or daily is not None):
    vals, n = window_metrics()
    per_home = {h: window_metrics(h)[0] for h in sorted(measured)}
    rows_ = []
    for tr in targets:
        m, op, tv = tr['metric'], tr['op'], num(tr['target'])
        if m not in QLABEL or tv is None or op not in ('>=', '<='): continue
        label, unit = QLABEL[m]; v = vals.get(m)
        homes_missed = [f'{h} {fmt(hv[m], 2)}{unit}' for h, hv in per_home.items()
                        if tr.get('owner') == 'each home' and misses(hv.get(m), op, tv)]
        tone_ = 'bad' if misses(v, op, tv) or homes_missed else ('ok' if v is not None else '')
        rows_.append(f'<div class="q {tone_}"><span>{esc(label)}</span><b>{fmt(v, 2)}{unit if v is not None else ""}</b>'
                     f'<i>target {"at least" if op == ">=" else "at most"} {fmt(tv)}{unit}'
                     f'{" · missed in " + esc(", ".join(homes_missed)) if homes_missed else ""}</i></div>')
    cards.append(f'''<div class="card"><h3>Is quality on target?</h3><p class="small muted">Today and yesterday, {n} merge{"s" if n != 1 else ""}, whole fleet. Red means the fleet or a home missed the target.</p>
<div class="qs">{"".join(rows_) or '<p class="small muted">No known metrics in the targets file.</p>'}</div></div>''')
elif targets is None:
    cards.append(f'<div class="card"><h3>Is quality on target?</h3>{note("config/metrics-targets.tsv", "not available")}</div>')

if snap is not None:
    fm_now = [i for i in in_flight if home_of_task(i.get('id', '')) == 'main']
    fm_landed = [l for l in landed if owner_home(l.get('owner')) == 'main']
    words = [count(r.get('rulewords')) for r in (pulse or []) if count(r.get('rulewords')) is not None]
    rw = ''
    if len(words) >= 2:
        d = words[-1] - words[0]
        rw = f'<p class="small">Written rules: {fmt(words[-1])} words ({"+" if d > 0 else ""}{fmt(d)} since the first pulse).</p>'
    items = ''.join(f'<li>{esc(i.get("name") or i.get("id"))}</li>' for i in fm_now[:5])
    cards.append(f'''<div class="card"><h3>How are Firstmate changes going?</h3><div class="stats">
<div class="stat"><b>{len(fm_now)}</b><span>in progress in Main</span></div><div class="stat"><b>{len(fm_landed)}</b><span>landed recently</span></div></div>
{f'<ul class="mini">{items}</ul>' if items else ''}{rw}</div>''')
S.append(f'<section><h2>Your questions</h2><div class="cards">{"".join(cards)}</div></section>')

# 3. Homes
homes = set(latest) | {r['home'] for r in daily or [] if iso_day(r['day']) in (TODAY, YDAY) and r['home'] != 'main'}
homes |= {home_of_task(i.get('id', '')) for i in in_flight} | {h for h in leads if h} | registered | {'main'}
hc = []
for h in sorted(homes, key=lambda x: (x != 'main', x)):
    r = latest.get(h, {})
    o, rd, dw = (count(r.get(k)) for k in ('open', 'ready', 'donewait'))
    ow = num(r.get('oldestwait_h'))  # -1 means nothing is waiting
    lead = leads.get(h)
    lw = LEAD_WORDS.get((lead or {}).get('state'), (str((lead or {}).get('state', '')).replace('_', ' ').capitalize(), ''))
    lanes = ''
    if o is not None:
        slots = max(lane_target, int(o))
        lanes = '<div class="lanes" aria-label="open lanes">' + ''.join(
            f'<i class="{"on" if k < o else ""}{" over" if k >= lane_target else ""}"></i>' for k in range(slots)) + '</div>'
    flag = ''
    if o is not None and o > lane_target: flag = chip('over lane target', 'warn')
    elif o is not None and o < lane_target and (rd or 0) > 0: flag = chip('free lanes with ready work', 'warn')
    stalls = dsum('stall_alarms', TODAY, h) if h in measured else None
    fp = window_metrics(h)[0]['first_pass'] if h in measured and prs is not None else None
    fp_t = next(((tr['op'], num(tr['target'])) for tr in targets or [] if tr['metric'] == 'first_pass'), None)
    mine = len([i for i in in_flight if home_of_task(i.get('id', '')) == h])
    asks = len([d for d in decisions if owner_home(d.get('owner')) == h]) + len([m for m in merge_asks if owner_home(m.get('owner')) == h])
    def kv(k, v, tone_=''): return f'<div class="kv {tone_}"><span>{esc(k)}</span><b>{v}</b></div>'
    body = ''.join([
        kv('Open lanes', f'{fmt(o)} <small>/ {lane_target}</small>') if o is not None else '',
        kv('Working now', mine) if snap is not None else '',
        kv('Ready to start', fmt(rd)) if rd is not None else '',
        kv('Finished, not landed', fmt(dw), 'warn' if dw else '') if dw is not None else '',
        kv('Oldest wait', f'{fmt(ow)} h' if ow is not None and ow >= 0 else 'none', 'warn' if (ow or 0) >= 2 else '') if ow is not None else '',
        kv('Merged today', merged(TODAY, h)) if prs is not None and h in measured else '',
        kv('First-pass merges, 2 days', f'{fp}%', 'bad' if fp_t and misses(fp, *fp_t) else '') if fp is not None else '',
        kv('Stalls reached Main', stalls, 'bad' if stalls else '') if stalls is not None else '',
        kv('Waiting on you', asks, 'warn' if asks else '') if snap is not None else '',
    ])
    pj = projects.get(h)
    pj = f'<p class="small muted">Projects: {esc(", ".join(pj))}</p>' if pj else ''
    old = f'<p class="small muted">Lane numbers as of {esc(r["time"][11:16])}</p>' if r and r['time'] != max(x['time'] for x in latest.values()) else ''
    hc.append(f'<div class="home"><div class="hh"><h3>{esc("Main" if h == "main" else h)}</h3>{chip(*lw) if lead else ""}</div>{lanes}{flag}<div class="kvs">{body}</div>{pj}{old}</div>')
if hc:
    S.append(f'<section><h2>Homes</h2><p class="small muted">Lane boxes show open lanes against the target of {lane_target}.</p><div class="homes">{"".join(hc)}</div></section>')

# 4. Trends
tr = []
if prs is not None:
    tr.append(trend('Merged', [merged(d) for d in WEEK]))
    tr.append(trend('First-pass merges', [first_pass_pct([d]) for d in WEEK], 'pct', first_pass_pct(WEEK)))
if pulse is not None:
    tr.append(trend('Finished, not landed', [pulse_day('donewait', d) for d in WEEK], 'level'))
    tr.append(trend('Open lanes', [pulse_day('open', d) for d in WEEK], 'level'))
if daily is not None:
    tr.append(trend('Stalls reached Main', [dsum('stall_alarms', d) for d in WEEK]))
    tr.append(trend('Leads woken automatically', [dsum('self_rings', d) for d in WEEK]))
    tr.append(trend('Skill reads', [dsum('skill_reads', d) for d in WEEK]))
    tr.append(trend('Main messages to leads', [dsum('steers', d) for d in WEEK]))
    tr.append(trend('Defects logged', [dsum('defects', d) for d in WEEK]))
if tr:
    S.append(f'<section><h2>Last 7 days</h2><div class="trends">{"".join(tr)}</div></section>')

# 5. Lists
L = []
if snap is not None:
    rs = []
    for i in sorted(in_flight, key=lambda i: i.get('id', '')):
        sw, stone = STATE_WORDS.get(i.get('state'), (str(i.get('state') or 'unknown').capitalize(), ''))
        doing = i.get('doing') or ''
        extra = chip('Checks running', 'ok') if doing.startswith('validating') else ''
        why = f'<div class="why">{esc(doing)}</div>' if doing and i.get('state') in ('paused', 'blocked', 'needs-decision', 'failed') else ''
        h = home_of_task(i.get('id', ''))
        rs.append(row(f'{esc(i.get("name") or i.get("id"))}{why}', esc('Main' if h == 'main' else h), chip(sw, stone) + extra))
    rs.insert(0, '<p class="empty">Second mate work shows here while it is working; paused or blocked lanes count only in the open lanes on each home card.</p>')
    L.append(details('Working now', len(in_flight), ''.join(rs)))
    rs = [row(link(m.get('task') or m.get('url'), m.get('url')), esc(owner_home(m.get('owner'))), chip('Merge approval', 'warn')) for m in merge_asks]
    rs += [row(esc(d.get('summary') or d.get('id')), esc('Main' if owner_home(d.get('owner')) == 'main' else d.get('owner')), chip('Decision', 'warn')) for d in decisions]
    # The snapshot carries no ask time; record order lists the oldest first.
    more = f'<details class="more"><summary>show all {len(rs)}</summary>{"".join(rs[5:])}</details>' if len(rs) > 5 else ''
    L.append(details('Waiting on you', len(rs), ''.join(rs[:5]) + more))
    rs = []
    real = lambda v: v not in (None, '', '-')
    for g in gates:
        if str(g.get('id', '')).startswith('('):  # a synthetic row about the records themselves, not queued work
            notes.append(('Main records', g.get('title') or g.get('id'))); continue
        why = f'<div class="why">{esc(g["reason"])}</div>' if real(g.get('reason')) else ''
        state = chip(f'after {g["blocked_by"]}') if real(g.get('blocked_by')) else (chip('Waiting', 'warn') if why else chip('Ready', 'ok'))
        rs.append(row(esc(g.get('title') or g.get('id')) + why,
                      esc(owner_home(g.get('owner'))) + (f' · filed {esc(g["filed"])}' if real(g.get('filed')) else ''), state))
    cap = '<p class="empty">Second mate homes may send only their first queued items, so this list can be short. The Queued and ready tile counts all ready work.</p>'
    L.append(details('Queued', len(rs), cap + ''.join(rs)))
    rs = [row(link(l.get('what') or l.get('id'), l.get('artifact')), esc('Main' if owner_home(l.get('owner')) == 'main' else l.get('owner')), '') for l in landed]
    L.append(details('Recently landed', len(landed), ''.join(rs)))
else:
    L.append(note('fleet snapshot', next((r for s, r in notes if s == 'fleet snapshot'), 'not available')))
if defects is not None:
    open_n = sum(d['status'] == 'OPEN' for d in defects)
    rs = [row(esc(d['text']), esc(d['day']), chip(d['status'].capitalize(), 'bad' if d['status'] == 'OPEN' else 'ok') if d['status'] else '')
          for d in reversed(defects[-15:])]
    L.append(details(f'Defects log · {open_n} open of {len(defects)}', '15 newest' if len(defects) > 15 else len(defects), ''.join(rs)))
S.append(f'<section><h2>All work</h2>{"".join(L)}</section>')

missing = ''.join(f'<li><code>{esc(s)}</code>: {esc(r)}</li>' for s, r in notes)
if missing: S.append(f'<section class="foot"><h2>Missing data</h2><ul class="mini">{missing}</ul><p class="small muted">Each missing source only hides its own part.</p></section>')

CSS = '''
:root{--bg:#f6f5f1;--card:#ffffff;--ink:#1d1d1b;--soft:#5f5e58;--faint:#8c8a82;--line:#e4e2da;--ok:#2f7d4f;--ok-bg:#e6f2ea;--warn:#9a5b00;--warn-bg:#fbf0dc;--bad:#b3261e;--bad-bg:#fbe5e3;--bar:#c9c6bb;--bar-now:#1d1d1b;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:#141413;--card:#1d1d1b;--ink:#ecebe6;--soft:#b2b0a7;--faint:#86847c;--line:#2f2e2b;--ok:#7fcf9c;--ok-bg:#1d3326;--warn:#f0b65a;--warn-bg:#3a2c12;--bad:#ff8a80;--bad-bg:#3d1c1a;--bar:#4a4944;--bar-now:#ecebe6}}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,Roboto,"Helvetica Neue",sans-serif;font-feature-settings:"tnum" 1}
main{max-width:1120px;margin:0 auto;padding:28px 20px 56px}
header{display:flex;flex-wrap:wrap;align-items:baseline;justify-content:space-between;gap:4px 16px;margin-bottom:22px}
h1{font-size:26px;letter-spacing:-.02em;margin:0}h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--soft);margin:34px 0 12px;font-weight:600}
h3{font-size:16px;margin:0 0 10px;letter-spacing:-.01em}section:first-of-type h2{margin-top:0}
.muted{color:var(--faint)}.small{font-size:13px;margin:8px 0 0}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:16px 18px;min-width:0}
.tl{font-size:13px;color:var(--soft)}.tv{font-size:44px;font-weight:650;letter-spacing:-.03em;line-height:1.1;margin:4px 0}.ts{font-size:13px;color:var(--faint)}
.tile.warn .tv{color:var(--warn)}.tile.bad .tv{color:var(--bad)}.tile.ok .tv{color:var(--ok)}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,400px),1fr));gap:12px}
.card,.home{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:18px;min-width:0}
.verdict{margin:0 0 12px;padding:8px 12px;border-radius:10px;font-size:14px;font-weight:550}
.verdict.ok{background:var(--ok-bg);color:var(--ok)}.verdict.warn{background:var(--warn-bg);color:var(--warn)}.verdict.bad{background:var(--bad-bg);color:var(--bad)}
.stats{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
.stat{display:flex;flex-direction:column;min-width:0}.stat b{font-size:28px;font-weight:650;letter-spacing:-.02em;line-height:1.15}
.stat span{font-size:13px;color:var(--soft)}.stat i{font-style:normal;font-size:12px;color:var(--faint)}
.stat.bad b{color:var(--bad)}.stat.warn b{color:var(--warn)}
.big{display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;margin-bottom:10px}.big b{font-size:36px;font-weight:650;letter-spacing:-.03em}.big span{font-size:13px;color:var(--soft)}
.hbar{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(0,1fr) 2.2em;align-items:center;gap:8px;font-size:13px;margin:5px 0}
.hbar span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.hbar i{display:block;height:8px;border-radius:4px;background:var(--bar);width:var(--w)}.hbar b{text-align:right;font-weight:600}
.qs{display:grid;gap:6px;margin-top:10px}
.q{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:0 10px;padding:7px 10px;border-radius:10px;background:var(--bg)}
.q span{font-size:14px}.q b{font-size:16px;text-align:right}.q i{grid-column:1/-1;font-style:normal;font-size:12px;color:var(--faint)}
.q.bad{background:var(--bad-bg)}.q.bad b,.q.bad span{color:var(--bad)}.q.ok b{color:var(--ok)}
.mini{margin:10px 0 0;padding-left:18px;font-size:13px;color:var(--soft)}.mini li{margin:2px 0;overflow-wrap:anywhere}
.homes{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,240px),1fr));gap:12px}
.hh{display:flex;justify-content:space-between;align-items:center;gap:8px;margin-bottom:8px}.hh h3{margin:0;text-transform:capitalize}
.lanes{display:flex;gap:4px;margin:2px 0 8px}.lanes i{width:22px;height:10px;border-radius:3px;border:1px solid var(--bar)}
.lanes i.on{background:var(--ink);border-color:var(--ink)}.lanes i.on.over{background:var(--warn);border-color:var(--warn)}
.kvs{display:grid;gap:2px;margin-top:6px}.kv{display:flex;justify-content:space-between;gap:10px;font-size:14px;padding:3px 0;border-bottom:1px solid var(--line)}
.kv:last-child{border-bottom:0}.kv span{color:var(--soft)}.kv b{font-weight:600}.kv small{color:var(--faint);font-weight:400}
.kv.warn b{color:var(--warn)}.kv.bad b{color:var(--bad)}
.chip{display:inline-block;font-size:12px;font-weight:550;padding:2px 9px;border-radius:999px;background:var(--bg);color:var(--soft);white-space:nowrap;margin:2px 0 2px 4px}
.chip.ok{background:var(--ok-bg);color:var(--ok)}.chip.warn{background:var(--warn-bg);color:var(--warn)}.chip.bad{background:var(--bad-bg);color:var(--bad)}
.home>.chip{margin:0 0 6px}
.trends{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,200px),1fr));gap:12px}
.trend{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:14px 16px;min-width:0}
.trh{display:flex;justify-content:space-between;align-items:baseline;gap:8px;font-size:13px;color:var(--soft)}.trh b{font-size:22px;color:var(--ink);font-weight:650}
.spark{display:block;width:100%;height:44px;margin:8px 0 4px}.spark .b{fill:var(--bar)}.spark .bt{fill:var(--bar-now)}.spark .b0{fill:var(--line)}
.trf{display:flex;justify-content:space-between;font-size:11px;color:var(--faint)}
details{background:var(--card);border:1px solid var(--line);border-radius:14px;margin-bottom:10px;overflow:hidden}
summary{cursor:pointer;list-style:none;display:flex;justify-content:space-between;align-items:center;gap:10px;padding:14px 18px;font-weight:600}
summary::-webkit-details-marker{display:none}summary::before{content:"›";display:inline-block;margin-right:10px;color:var(--faint);transition:transform .15s}
details[open] summary::before{transform:rotate(90deg)}summary span:first-child{flex:1}
.more{border:0;border-radius:0;margin:0;background:none}.more summary{font-weight:500;color:var(--faint);padding:10px 18px}
.cnt{font-size:13px;font-weight:600;color:var(--soft);background:var(--bg);border-radius:999px;padding:1px 10px}
.list{border-top:1px solid var(--line)}
.row{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,9em) auto;gap:4px 14px;align-items:center;padding:10px 18px;border-bottom:1px solid var(--line);font-size:14px}
.row:last-child{border-bottom:0}.rm{min-width:0;overflow-wrap:anywhere}.rx{color:var(--faint);font-size:13px;overflow-wrap:anywhere;text-transform:capitalize}.rr{text-align:right}
.why{font-size:12px;color:var(--faint);margin-top:2px}
a{color:inherit;text-decoration-color:var(--bar);text-underline-offset:3px}a:hover{text-decoration-color:currentColor}
.note{font-size:13px;color:var(--faint);margin:6px 0 0}.empty{padding:12px 18px;margin:0;color:var(--faint);font-size:14px}
code{font:12px ui-monospace,SFMono-Regular,Menlo,monospace}
@media (max-width:620px){main{padding:18px 14px 40px}.tv{font-size:36px}.tiles{grid-template-columns:repeat(2,minmax(0,1fr))}.tile:last-child:nth-child(odd){grid-column:1/-1}
.row{grid-template-columns:minmax(0,1fr);padding:10px 14px}.rr{text-align:left}.rr .chip{margin:2px 4px 2px 0}.rr:empty{display:none}}
'''
stamp = NOW.strftime('%a %d %b %Y, %H:%M')
doc = f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fleet dashboard</title><style>{CSS}</style></head><body><main>
<header><h1>Fleet dashboard</h1><span class="muted small">Built {esc(stamp)}<!--age--></span></header>
{"".join(S)}</main></body></html>
'''
with open(OUT, 'w', encoding='utf-8') as f: f.write(doc)
PY
mv "$page.$$.tmp" "$page" || { echo "fm-dashboard: cannot write $page" >&2; exit 1; }
printf '%s\n' "$page"
