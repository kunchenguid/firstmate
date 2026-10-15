#!/usr/bin/env bash
# fm-dashboard.sh - build and serve the read-only fleet dashboard for this home.
#
# The dashboard is the app in bin/fm-dashboard/ (vendored Preact, htm, Inter and, for the Ship tab
# only, three.js; no network reference; light and dark): Board, a kanban of Building, Review,
# Test, PR + CI and To merge with tabs for Queued, Landed today and All and rows by home on
# request, whose cards carry the lane's model, age, pull request and, when it waits, why in plain
# words; filters by home, model and state; a card's detail with its stages and activity; Overview
# (five key figures, where Stuck, Lanes open and Ready also show their change since yesterday and
# a day's trend; the lifecycle, every open lane by stage split into moving, waiting and stuck, then
# landings; lanes by state; 14-day landed and closed charts; queue reasons; quota runway; each home's
# lanes by stage against its plan); Needs you
# (the ask list); Ship (ship/: the selected home's ship at night with each lane a worker at its
# stage's deck station, dressed by model, and a sheet with fleet-wide key numbers and stuck or
# parked work); Insights (the shipped fm-flow.sh reader's lifecycle, waits, queue, retained merge
# outcomes and optional read-only capacity observations, plus the Models and Skills sections
# from bin/fm-model-stats.sh and bin/fm-skill-stats.sh, defined in docs/fleet-ledger.md); a command palette and keys (?).
# In Ship, tap a worker or its tag to open its card's detail; a station or its plate opens
# a worker in that stage, prioritizing stuck work and then recorded age, oldest first (empty stations do nothing).
# Stuck and parked sheet rows also open their cards, by click or focused Enter/Space.
# Select a home tab or swipe left/right on the sea for the next/previous home, without wrapping.
# Home changes sail the outgoing ship ahead and bring the selected ship in from astern;
# scene tags and picking pause during the transition, while the panels remain interactive.
# Existing workers walk to their new deck stations when a refresh changes their stage.
# Landed-today cards appear as a capped crate stack at the bow; an increased count on the home
# in view lowers new crates on a rope, or lowers the top crate again when the stack is full.
# Selecting another home places its existing crates immediately, without a landing animation.
# Ship needs WebGL2; otherwise a static illustration replaces the scene while its panels stay live.
# The system's reduced-motion preference stops continuous scene animation and tag pulsing
# and immediately settles home transitions, worker walks and crate drops, restoring tags and picking.
# At viewport widths of 760-1279 CSS pixels the header figures use their own row.
# At 760-1023 CSS pixels the sidebar becomes a compact rail with four-character home
# labels (or the whole name if shorter); home buttons retain the full accessible name and tooltip.
# Below 760 CSS pixels the board is a mobile kanban that shows one status column at a time,
# with a sticky switcher that jumps to any column, and a dock.
# Each build writes the app's one data file, state/dashboard/board.json: homes with their
# lane plans, one card per open lane, ready backlog item and pull request landed today,
# and parked home ids. Its flow key is the fm-flow.v1 Insights observation, or flow_error when
# that reader is unavailable or unreadable; its models and skills keys hold the fm-model-stats.v1
# and fm-skill-stats.v1 observations, or the matching *_error; a recursive scrub removes raw
# reason, source, gate_source and errors keys before the write.
# Cards carry the current stage inferred from status lines (which can move backwards), wait,
# metadata model or ledger dispatch model, and up to 40 recent
# activity lines. Recorded merges replace matching live cards using the canonical request
# URL; supported requests are GitHub PRs, GitLab merge requests and Gerrit changes.
# The payload includes the ask list (the only source of "needs you": a lane's own decision
# is its home's, Main's or its lead's), 14 local days of landed counts and cycle p50
# (dispatch to merge across recorded merges, shown only with at least five samples).
# Dispatch history is local-only; each merge uses its latest preceding dispatch.
# Quota and history samples remain on Overview, not in board.json.
# A lane the captain holds is parked on the board, remains open, and counts as
# waiting on other in metric lane-state totals, not as stuck or waiting on a decision.
# Each build also atomically replaces data.json (every metric with its status and source;
# GET/HEAD /data.json serves it as application/json) and writes three self-contained HTML
# pages (inline CSS and SVG, no script, no network reference), phone first:
#   index    the legacy Overview page; still built last as the build-completion and freshness
#            marker, but the app serves its own native Overview in its place and never links here.
#            (Its content: Main's ask list, attention chips, six tiles and trends, lane waits,
#            14-day in/out chart, homes, quota runway, devices and machine.)
#   backlog  queued, ready and held work per home, held-for-captain items, every lane, agents
#   measure  every number's one definition (what it counts, source, window and cutoff, how
#            often it is read), records that disagree, sources not read
# Method owns the metric definitions shared with data.json's coverage and source metadata.
# Backlog lists default to action grouping, with a by-home variant.
# Board and Overview leave parked homes out of totals; Insights labels its all-registered-home scope.
# Sources are local records, existing caches and read-only probes; no GitHub collection runs during builds.
# Insights invokes fm-flow.sh --json --capacity at the build cutoff (180 s overall deadline).
# FM_MAC_HOST opts into that reader's bounded read-only Mac SSH probe; unset means unknown.
# The reader's live capacity timestamps remain separate from the durable-record cutoff.
# Remote lane/backlog records are unavailable, not read from same-named local paths.
# Insights also invokes fm-model-stats.sh and fm-skill-stats.sh (read-only, 10 s timeout each,
# outside the flow reader's 180 s deadline); their script headers name their sources.
#   data/captain-asks.tsv           Waiting on you: Main's fleet-wide headerless
#                                   id<TAB>since-epoch<TAB>text<TAB>url; each row with an id and
#                                   text is an ask (a bad time or duplicate id shows as a record
#                                   needing correction); blank rows and rows without an id or text
#                                   are skipped, with a note; absent/empty means zero
#   <home>/state/home-summary.json  local lead state; summaries older than 15 minutes are silent
#                                   (bin/fm-home-summary-refresh.sh); Main's fresh endpoint view
#                                   and Herdr inventory inform local liveness; remote leads use the existing route-keyed FM_SNAPSHOT_CACHE_DIR cache
#   data/secondmates.md             registered homes: "- <name> - ... (home: <dir>; ...)"
#   config/parked-homes             home ids the captain parked, one per line (# comments)
#   <home>/state/*.meta + *.status  lanes: every ship/scout record, in one state by its last
#                                   status verb and [at=] time (building, validating or waiting on
#                                   CI, waiting on a decision, blocked, waiting on something
#                                   else, finished not landed); a secondmate record is a lead.
#                                   Without a captain hold, blocked/failed stay blocked even when
#                                   their text names CI; only paused validation/no-mistakes/CI/checks/
#                                   pipeline waits are validating (tests/fm-dashboard.test.sh ci-stuck)
#   config/lane-caps                "<home> <cap>" lane plan per home (Main is "main" or the name
#                                   of its home's parent folder); config/lane-target is the default (4)
#   bin/fm-tasks-axi.sh list        each home's backlog (FM_HOME=<home>): queued = ready + held +
#                                   waiting on another item; held for the captain = hold-kind captain
#   herdr agent list                agents busy now (agent_status working), the state the muxr
#                                   app reads; role by pane id against the records: lead, worker,
#                                   Main (the folder holding this home's data), else other
#   state/<lead>.status, state/fleet-ledger.jsonl   Landed: each pull request the fleet
#                                   recorded as merged, once (bin/fm-merge-outcome-lib.sh writes a
#                                   lead's merges to Main's channel for it, Main's own to its ledger)
#   resolved markdown backlog + configured archive    Out: closed per local day; missing backlog or unsupported backend is unknown, absent archive is empty
#   ~/.cache/quota-axi/quotas.json  schema-3 quota cache, read-only; no collector runs during builds
# Machine and devices, each probe read-only with a 5 s timeout:
#   adb devices -l                  connected phones and emulators (nothing else is asked of adb);
#                                   adb from PATH, else platform-tools under $ANDROID_HOME,
#                                   $ANDROID_SDK_ROOT, ~/Android/Sdk or ~/Library/Android/sdk
#   pgrep -a '^qemu-system'         running emulators (-avd, -port; VmRSS from <proc>/<pid>/status)
#   pgrep -cf 'appname=gradle[w]'   Gradle builds, counted as config/fm-mem-gate.sh counts them
#   systemctl --user show fm-heavy.slice   MemoryCurrent, MemoryHigh, MemoryMax
#   <proc>/meminfo, <proc>/pressure/memory   MemAvailable; "some avg10", the memory gate's own
#                                   pressure, the one pressure number on every page
#   <locks>/fm-phone-<name>.lock + <proc>/locks   who holds a device now (flock by inode);
#   <locks>/fm-device-lock.log      the holder's pid, time and cwd, mapped to its home by
#                                   each home's state/*.meta worktree=, tasktmp= or task id;
#                                   an emulator matches a held lock its process ancestry took
#   <proc> is FM_DASHBOARD_PROC (default /proc), <locks> FM_DEVICE_LOCK_DIR (default /tmp);
#   FM_EMU_MAX, FM_GRADLE_MAX, FM_MEM_MIN_GB (defaults 2, 2, 12) mirror the memory gate's caps
# All day comparisons use the host timezone. A build writes only under state/dashboard:
# HTML, data.json, board.json, filed.json (observed open-item filing days, kept 15 days), and
# history.tsv (lane, stuck and ready counts sampled every 10 minutes, kept 8 days).
# .cache.lock serializes cache updates across builds.
#
# Usage:
#   fm-dashboard.sh [build]
#   fm-dashboard.sh serve [--bind ADDR] [--port N]
# build (the default) writes $FM_HOME/state/dashboard/ and prints the index page path.
# serve runs a small read-only web server (python3 stdlib, IPv4) that answers GET or
# HEAD for / and /index.html (the JavaScript app), its files under bin/fm-dashboard/,
# /board.json, /overview (the same app shell; the app opens its own native Overview in
# place of the old page), /backlog, /measure and /data.json; every other path is 404.
# Overview and Board are one app and one navigation; the old generated Overview page is no
# longer reachable through the app. The app's
# files and both JSON files carry an ETag, answer 304 while unchanged and are gzipped
# for a client that accepts it (the font is not); the app's CSP allows its own origin
# only. The app keeps its view, tabs, filters and open card in the URL hash and its theme
# in localStorage; ? opens its shortcut list. It polls board.json every 10 seconds,
# retains the last good data on refresh failure, and marks data older than 15 minutes stale.
# Both JSON endpoints return 503 after a failed rebuild rather than reporting a healthy
# refresh. On the generated Backlog page, ?group=home or ?group=action selects grouping
# and is remembered in a cookie. It answers at once with the last built pages, marked "updated N s ago",
# retaining source timestamps from the build, and keeps them fresh itself: a side
# thread starts each rebuild early enough, by the last build's length,
# for the new pages to land as the old ones turn 60 seconds old, and the pages reload
# themselves every 60 seconds; only the first generated-page or JSON load waits for a
# build, while the app shell is served immediately. Requests are
# answered on their own threads, so an idle connection never holds another one up.
# It prints `serving http://ADDR:PORT/` once listening. ADDR defaults to
# 127.0.0.1 and PORT to 8787; port 0 picks a free port. There is no authentication:
# reach is whatever the bind address exposes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
out_dir="$FM_HOME/state/dashboard"
page="$out_dir/index.html"
MAX_AGE=60

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
    exec python3 - "$0" "$FM_HOME" "$out_dir" "$bind" "$port" "$MAX_AGE" "$SCRIPT_DIR/fm-dashboard" <<'PY'
import gzip, http.server, os, re, subprocess, sys, threading, time, urllib.parse
SCRIPT, HOME, DIR, BIND, PORT, MAX_AGE, APP = sys.argv[1:8]
MAX_AGE = int(MAX_AGE)
PAGE = os.path.join(DIR, 'index.html')
ROUTES = {'/backlog': 'backlog', '/measure': 'measure', '/data.json': 'data', '/board.json': 'board'}
# The app's own files: one optional folder level, no hidden names, no other types.
STATIC = re.compile(r'/((?:[\w-]+/)?[\w-][\w.-]*\.(js|css|svg|woff2))')
TYPES = {'js': 'text/javascript; charset=utf-8', 'css': 'text/css; charset=utf-8', 'svg': 'image/svg+xml', 'woff2': 'font/woff2',
         'html': 'text/html; charset=utf-8', 'json': 'application/json'}
PAGE_CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src data:"
APP_CSP = "default-src 'self'; base-uri 'none'; form-action 'none'; object-src 'none'; frame-ancestors 'none'"
building = threading.Lock()
last_error = b''
last_took = 5.0

def build():  # call holding `building`; the build replaces each page in one rename
    global last_error, last_took
    start = time.time()
    try:
        r = subprocess.run(['bash', SCRIPT, 'build'], env=dict(os.environ, FM_HOME=HOME),
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        last_error = (r.stderr or b'build exited unsuccessfully') if r.returncode else b''
        last_took = time.time() - start
    finally:
        building.release()

def age():
    try: return time.time() - os.path.getmtime(PAGE)
    except OSError: return None
def ago(s):
    s = max(0, int(s))
    return f'{s}\u00a0s' if s < 120 else f'{s // 60}\u00a0min' if s < 7200 else f'{s // 3600}\u00a0h'

class Handler(http.server.BaseHTTPRequestHandler):
    timeout = 10  # an idle preconnect is closed after 10 s

    def send(self, code, body, ctype, cookie=None, csp=PAGE_CSP, etag=None, gz=False):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        if gz: self.send_header('Content-Encoding', 'gzip')
        if etag: self.send_header('Vary', 'Accept-Encoding')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-cache' if etag else 'no-store')
        if etag: self.send_header('ETag', etag)
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', csp)
        if cookie: self.send_header('Set-Cookie', f'fm_group={cookie}; Path=/; Max-Age=31536000; SameSite=Lax')
        self.end_headers()
        if self.command != 'HEAD': self.wfile.write(body)

    def file(self, path, ext, csp=PAGE_CSP):  # answered by version: 304 when the client already has it; text gzipped when asked
        gz = ext != 'woff2' and 'gzip' in (self.headers.get('Accept-Encoding') or '')
        try:
            with open(path, 'rb') as fh:
                st = os.fstat(fh.fileno())
                tag = f'"{st.st_mtime_ns:x}-{st.st_size:x}{"-gz" if gz else ""}"'
                hit = self.headers.get('If-None-Match') == tag
                body = b'' if hit else gzip.compress(fh.read(), 6) if gz else fh.read()
        except OSError: return self.send(404, b'not built yet\n', 'text/plain; charset=utf-8')
        self.send(304 if hit else 200, body, TYPES[ext], csp=csp, etag=tag, gz=gz and not hit)

    def do_GET(self):
        path, _, query = self.path.partition('?')
        if path in ('/', '/index.html', '/overview'): return self.file(os.path.join(APP, 'index.html'), 'html', APP_CSP)
        m = STATIC.fullmatch(path)
        if m and os.path.isfile(os.path.join(APP, m.group(1))): return self.file(os.path.join(APP, m.group(1)), m.group(2), APP_CSP)
        name = ROUTES.get(path)
        if name is None:
            return self.send(404, b'not found\n', 'text/plain; charset=utf-8')
        asked = urllib.parse.parse_qs(query).get('group', [''])[0]
        asked = asked if asked in ('home', 'action') else None
        jar = dict(c.strip().split('=', 1) for c in (self.headers.get('Cookie') or '').split(';') if '=' in c)
        group = asked or jar.get('fm_group')
        a = age()
        if a is None:  # the first load ever waits for the first pages
            building.acquire()  # a build already under way finishes first
            if age() is None: build()
            else: building.release()
            a = age()
            if a is None:
                return self.send(500, b'dashboard build failed: ' + last_error, 'text/plain; charset=utf-8')
        if name in ('data', 'board'):
            if last_error: return self.send(503, b'dashboard refresh failed\n', 'text/plain; charset=utf-8')
            return self.file(os.path.join(DIR, f'{name}.json'), 'json')
        tone = 'bad' if last_error or a >= 3 * MAX_AGE else 'warn' if a >= 1.5 * MAX_AGE else 'ok'
        note = (f'<span class="age {tone}">updated {ago(a)} ago' + (' · refreshing' if building.locked() else '')
                + (' · last refresh failed, showing the last good page' if last_error else '') + '</span>')
        f = os.path.join(DIR, f'{name}.home.html' if group == 'home' and name == 'backlog' else f'{name}.html')
        if not os.path.isfile(f): f = os.path.join(DIR, f'{name}.html')
        try:
            with open(f, 'rb') as fh: body = fh.read().replace(b'<!--age-->', note.encode(), 1)
        except OSError:
            return self.send(404, b'not built yet\n', 'text/plain; charset=utf-8')
        self.send(200, body, 'text/html; charset=utf-8', asked)
    do_HEAD = do_GET

# Each request on its own thread; rebuilds run on a side thread, one at a time.
def refresh():  # rebuild on age, not on requests, so an idle phone never opens a minutes-old page
    while True:
        a = age()  # start early by the last build's length, so the new page lands as this one turns MAX_AGE
        if (a is None or a + last_took >= MAX_AGE) and building.acquire(blocking=False):
            build()
            if last_error: time.sleep(MAX_AGE)  # a failing build retries once a minute
        time.sleep(1)  # one stat a second; a page is replaced within a second of turning MAX_AGE

threading.Thread(target=refresh, daemon=True).start()
srv = http.server.ThreadingHTTPServer((BIND, int(PORT)), Handler)
print(f'serving http://{BIND}:{srv.server_address[1]}/', flush=True)
try: srv.serve_forever()
except KeyboardInterrupt: pass
PY
    ;;
  -h|--help) sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  *) usage ;;
esac

mkdir -p "$out_dir" || { echo "fm-dashboard: cannot create $out_dir" >&2; exit 1; }
# Per-run scratch names, so a manual build and a served rebuild never share files.
tmp="$out_dir/.build.$$"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp" || { echo "fm-dashboard: cannot create $tmp" >&2; exit 1; }

python3 - "$FM_HOME" "$out_dir" "$tmp" "$SCRIPT_DIR" "$MAX_AGE" <<'PY' || { echo "fm-dashboard: page build failed" >&2; exit 1; }
import fcntl, hashlib, html, json, math, os, re, shutil, subprocess, sys, time
BUILD_STARTED = time.monotonic()
from urllib.parse import urlsplit
from datetime import date, datetime, timedelta

HOME, STATE_DIR, OUT, BIN, MAX_AGE = sys.argv[1:6]
MAX_AGE = int(MAX_AGE)
NOW = datetime.now().astimezone()
NOW_TS = NOW.timestamp()
TODAY = NOW.date()
notes = []  # (source, one-line reason) for every source that could not be read

def esc(v): return html.escape(str(v), quote=True)
def iso_day(s):
    try: return date.fromisoformat(s)
    except (TypeError, ValueError): return None
def dur(s):
    s = max(0, int(s))
    if s < 60: return 'under a minute'
    if s < 3600: return f'{s // 60}\u00a0min'
    if s < 86400: return f'{s // 3600}\u00a0h' + (f' {s % 3600 // 60}\u00a0min' if s < 36000 and s % 3600 >= 60 else '')
    return f'{s // 86400}\u00a0d'
def days_old(d): return 'today' if d == TODAY else f'{(TODAY - d).days}\u00a0d'
def plural(n, word, many=None): return f'{n} {word if n == 1 else many or word + "s"}'
def hname(h): return 'Main' if h == 'main' else h

def adb_path():  # a server started outside a login shell often lacks the SDK on PATH
    sdks = [os.environ.get('ANDROID_HOME'), os.environ.get('ANDROID_SDK_ROOT'), '~/Android/Sdk', '~/Library/Android/sdk']
    return shutil.which('adb') or next((p for d in sdks if d and os.access(p := os.path.join(os.path.expanduser(d), 'platform-tools', 'adb'), os.X_OK)), 'adb')

def probe(cmd, ok=(0,), timeout=5, env=None, cwd=None):
    """(stdout, None) from a read-only command, or (None, reason)."""
    try: r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd)
    except FileNotFoundError: return None, f'{cmd[0]} not found'
    except subprocess.TimeoutExpired: return None, f'{os.path.basename(cmd[0])} gave no answer in {timeout} s'
    except OSError as e: return None, f'{cmd[0]}: {e.strerror}'
    if r.returncode not in ok: return None, (r.stderr.strip().splitlines() or [f'{cmd[0]} exit {r.returncode}'])[-1]
    return r.stdout, None

# --- homes ---------------------------------------------------------------
home_dir = {'main': HOME}
remote_hosts = {}
try:
    for l in open(os.path.join(HOME, 'data/secondmates.md'), encoding='utf-8', errors='replace'):
        m = re.match(r'- (\S+) - ', l)
        f = re.match(r'.*\((?:host:[^;]*;\s*root:[^;]*;\s*)?home: ([^;]*);', l)
        if m and f:
            home_dir[m.group(1)] = f.group(1).strip()
            host = re.search(r'\(host:\s*([^;]+);\s*root:', l)
            if host: remote_hosts[m.group(1)] = host.group(1).strip()
except OSError: pass  # no registered homes
parked = set()
try:
    for l in open(os.path.join(HOME, 'config/parked-homes'), encoding='utf-8', errors='replace'):
        if l.split('#', 1)[0].strip(): parked.add(l.split('#', 1)[0].strip())
except OSError: pass  # no parked homes
ACTIVE = sorted(set(home_dir) - parked, key=lambda h: (h != 'main', h))
PARKED = sorted(set(home_dir) & parked)

lane_default = 4
try: lane_default = int(open(os.path.join(HOME, 'config/lane-target')).read().split()[0])
except (OSError, ValueError, IndexError): pass
caps = {}
try:
    for l in open(os.path.join(HOME, 'config/lane-caps'), encoding='utf-8', errors='replace'):
        f = l.split('#', 1)[0].split()
        if len(f) == 2 and f[1].isdigit(): caps[f[0]] = int(f[1])
except OSError: pass
MAIN_ALIAS = os.path.basename(os.path.dirname(os.path.realpath(HOME)))
def plan(h): return caps.get(h, caps.get(MAIN_ALIAS, lane_default) if h == 'main' else lane_default)
PLAN = sum(plan(h) for h in ACTIVE)

# --- lead state: the summary each home publishes about itself ----------
SUMMARY_MAX_AGE = 900  # a home republishes at least every 5 minutes
def summary(h):
    if h in remote_hosts:
        key = hashlib.sha256(f'{h}\n{remote_hosts[h]}\n{home_dir[h]}\n'.encode()).hexdigest()
        p = os.path.join(os.environ.get('FM_SNAPSHOT_CACHE_DIR', os.path.join(HOME, 'state/secondmate-summary-cache')), key + '.json')
    else: p = os.path.join(home_dir[h], 'state/home-summary.json')
    try:
        if os.path.getsize(p) > 262144: raise ValueError('summary larger than 256 KB')
        s = json.load(open(p, encoding='utf-8'))
        if not isinstance(s, dict) or s.get('schema') != 'fm-secondmate-home-summary.v1': raise ValueError('unexpected summary schema')
        if (str(s.get('home')) != home_dir[h] if h in remote_hosts else os.path.realpath(str(s.get('home'))) != os.path.realpath(home_dir[h])): raise ValueError('summary names another home')
        if h in remote_hosts and s.get('hold_classifier_schema') != 'fm-captain-hold-buckets.v1': raise ValueError('unexpected summary classifier')
        if not isinstance(s.get('generated_epoch'), int): raise ValueError('summary has no time')
        return s
    except OSError as e: notes.append(('home summary', f'{h}: {e.strerror}'))
    except ValueError as e: notes.append(('home summary', f'{h}: {str(e)[:80]}'))
    return None
sums = {h: summary(h) for h in ACTIVE}
summaries_read_at = time.time()
leads = {h: sums[h] for h in ACTIVE if h != 'main'}
main_summary = sums.get('main') or {}
endpoints = {e.get('id'): e.get('endpoint') or {} for e in main_summary.get('endpoints') or []} if 0 <= NOW_TS - main_summary.get('generated_epoch', 0) <= SUMMARY_MAX_AGE else {}
down = set()
LEAD_WORDS = {'captain_decision': ('Holding a decision', 'warn'), 'externally_held': ('Waiting on someone else', 'warn'),
              'unknown': ('Records need tidy-up', 'bad'), 'active_child_work': ('Working', 'ok'), 'no_active_work': ('Idle', '')}
def lead_word(h):
    if h not in leads: return ('', '')
    if leads[h] is None: return ('State unknown', 'bad')
    age = NOW_TS - leads[h]['generated_epoch']
    if age < 0: return ('State unknown', 'bad')
    if age > SUMMARY_MAX_AGE: return (f'Silent {dur(age)}', 'bad')
    if h not in remote_hosts:
        pane = next((m.get('herdr_pane_id') for task, m in metas.get('main', []) if task == h and m.get('kind') == 'secondmate'), None)
        current = agents is not None and pane and any(a.get('pane_id') == pane for a in agents)
        endpoint = endpoints.get(h, {})
        if not current:
            if endpoint.get('exists') is False or endpoint.get('agent_alive') == 'dead': return ('Not running', 'bad')
            if endpoint.get('exists') is not True or endpoint.get('agent_alive') != 'alive': return ('Runtime unknown', 'bad')
    if leads[h].get('valid') is False: return ('State unknown', 'bad')
    s = leads[h].get('state')
    return LEAD_WORDS.get(s, (str(s or '').replace('_', ' ').capitalize(), ''))

# --- Waiting on you: Main's ask list ------------------------------------
asks, asks_known, ask_ids = [], True, set()
try:
    for n, line in enumerate(open(os.path.join(HOME, 'data/captain-asks.tsv'), encoding='utf-8', errors='replace'), 1):
        fields = line.rstrip('\r\n').split('\t')
        if not line.strip(): continue
        if len(fields) < 3 or not fields[0].strip() or not fields[2].strip():  # no id or no text: not an ask
            notes.append(('data/captain-asks.tsv', f'row {n} skipped: no id or text')); continue
        valid = len(fields) == 4 and fields[0].strip() and fields[2].strip() and re.fullmatch(r'[0-9]{1,10}', fields[1]) and fields[0] not in ask_ids
        if valid: ask_ids.add(fields[0])
        epoch = int(fields[1]) if valid else None
        age = None if epoch is None or epoch > int(NOW_TS) else int(NOW_TS) - epoch
        asks.append((fields, age))
        if age is None: notes.append(('data/captain-asks.tsv', f'malformed row {n}'))
except FileNotFoundError: pass
except OSError as e:
    asks_known = False
    notes.append(('data/captain-asks.tsv', f'unreadable: {e.strerror}'))

asks_read_at = time.time()

# --- lanes: every ship/scout record, one state each ---------------------
VALIDATING = re.compile(r'validat|no-mistakes|\bCI\b|\bchecks?\b|pipeline', re.I)
STATES = {'blocked': 'Blocked, needs help', 'decision': 'Waiting on a decision', 'finished': 'Finished, not landed',
          'building': 'Building', 'validating': 'Validating or waiting on CI', 'waiting': 'Waiting on something else'}
ACT = [('Blocked or waiting on a decision', ('blocked', 'decision'), 'wb'), ('Finished, not landed', ('finished',), 'l2'),
       ('Producing', ('building', 'validating'), ''), ('Waiting on something else', ('waiting',), 'ol')]
metas, lanes, lane_err = {}, [], set()
for h, d in sorted(home_dir.items()):
    if h in remote_hosts:
        lane_err.add(h); notes.append(('lane records', f'{h}: remote records not cached')); continue
    sd = os.path.join(d, 'state')
    try: files = sorted(f for f in os.listdir(sd) if f.endswith('.meta'))
    except OSError as e:
        lane_err.add(h); notes.append(('lane records', f'{h}: {e.strerror}')); continue
    for f in files:
        try:
            with open(os.path.join(sd, f), errors='replace') as fh:
                meta_mt = os.fstat(fh.fileno()).st_mtime
                meta = dict(l.rstrip('\n').split('=', 1) for l in fh if '=' in l)
        except FileNotFoundError: continue
        except OSError as e:
            lane_err.add(h); notes.append(('lane records', f'{h}: {e.strerror}')); continue
        metas.setdefault(h, []).append((f[:-5], meta))
        if meta.get('kind') not in ('ship', 'scout'): continue
        try:
            with open(os.path.join(sd, f[:-5] + '.status'), errors='replace') as fh:
                mt = os.fstat(fh.fileno()).st_mtime
                ls = [l.strip() for l in fh if l.strip()]
        except FileNotFoundError:
            if not os.path.exists(os.path.join(sd, f)): continue
            ls, mt = [], meta_mt
        except OSError as e:
            lane_err.add(h); notes.append(('lane records', f'{h}: {e.strerror}')); continue
        keys, verb, at, text, pr = set(), 'working', None, '', ''
        for l in ls:
            v = re.match(r'^(?:\d{9,11}\s+)?([a-z][a-z-]*)', l)
            verb = v.group(1) if v else 'unknown'
            a = re.search(r'\[at=(\d+)\]', l)
            at = int(a.group(1)) if a else at
            k = re.search(r'\[key=([^\]]+)\]', l)
            key = k.group(1) if k else 'default'
            if verb in ('done', 'failed'): keys.clear()
            elif verb in ('blocked', 'needs-decision'): keys.add(key)
            elif verb in ('resolved', 'captain-held'): keys.discard(key)
            text = l.split(':', 1)[1].strip() if ':' in l else ''
            pr = (re.findall(r'https://github\.com/[\w.-]+/[\w.-]+/pull/\d+', l) or [pr])[-1]
        if any(k.startswith('captain-hold') for k in keys): state = 'waiting'
        elif verb in ('working', 'resolved'): state = 'building'
        elif verb == 'needs-decision': state = 'decision'
        elif verb == 'done': state = 'finished'
        elif verb == 'paused' and VALIDATING.search(text): state = 'validating'
        elif verb in ('blocked', 'failed'): state = 'blocked'
        else: state = 'waiting'
        lanes.append(dict(home=h, task=f[:-5], state=state, since=at or mt, text=text, pr=pr, meta=meta,
                          held=any(k.startswith('captain-hold') for k in keys)))
live = [l for l in lanes if l['home'] not in parked]
def split(ls): return {s: sum(l['state'] == s for l in ls) for s in STATES}
SPLIT = split(live)
OPEN = len(live)
by_home = {h: [l for l in live if l['home'] == h] for h in ACTIVE}
LANES_KNOWN = not lane_err & set(ACTIVE)
lanes_read_at = time.time()
def lane_value(n, h=None): return 'unknown' if h in lane_err else n if h is not None or LANES_KNOWN else f'at least {n}'

# --- backlog per home: tasks-axi ----------------------------------------
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
def prose(t):
    def resource(m):
        token = m.group().rstrip('.,;:)`')
        suffix = m.group()[len(token):]
        path = urlsplit(token).path if '://' in token else token.split('?', 1)[0].split('#', 1)[0]
        pr = re.search(r'/pull/(\d+)$', path)
        return (f'PR {pr.group(1)}' if pr else os.path.basename(path.rstrip('/')) or 'link') + suffix
    text = re.sub(r'\[(?:key|at)=[^\]]*\]', '', str(t or ''))
    text = re.sub(r'(?<![\w/])(?:https?://|~?/|(?:[\w.-]+/)+)\S+', resource, text)
    return re.sub(r'\bPR PR (\d+)', r'PR \1', text)  # "PR <link>" reads as one "PR 8"
def clean(t):
    t = prose(t)
    return t.split('\n', 1)[0].rstrip() + '…' if '\n' in t else t
backlog, backlog_sources = {}, {}
for h, d in sorted(home_dir.items()):
    if h in remote_hosts:
        backlog[h] = None; notes.append(('backlog', f'{h}: remote records not cached')); continue
    address, err = probe(['bash', '-c', '. "$1/fm-tasks-axi-lib.sh"; . "$1/fm-backlog-transition-lib.sh"; fm_backlog_tasks_axi_addressing "${FM_DATA_OVERRIDE:-$FM_HOME/data}" || exit 1; printf "%s\\n%s\\n" "$FM_BACKLOG_AXI_ROOT" "$FM_BACKLOG_AXI_FILE"', 'dashboard', BIN], env=dict(os.environ, FM_HOME=d))
    fields = address.splitlines() if address is not None else []
    if len(fields) != 2:
        backlog[h] = None; notes.append(('backlog', f'{h}: {err or "unsupported backlog source"}')); continue
    backlog_sources[h] = fields
    out, err = probe(['bash', os.path.join(BIN, 'fm-tasks-axi.sh'), 'list', '--limit', '10000',
                      '--fields', 'held,hold_kind,hold_reason,blocked,created,closed'],
                     timeout=20, env=dict(os.environ, FM_HOME=d))
    rows = toon_rows(out) if out is not None else None
    if rows is None:
        backlog[h] = None; notes.append(('backlog', f'{h}: {err or "no task table in its output"}')); continue
    for r in rows:
        r['title'] = clean(r.get('title'))
        r['day'] = iso_day(r.get('created'))
        r['class'] = ('held' if r.get('held') == 'yes' else 'waiting' if r.get('blocked') == 'yes' else 'ready') if r.get('state') == 'queued' else None
    backlog[h] = rows
def bl(h, cls=None, state=None):
    return [r for r in backlog.get(h) or [] if (cls is None or r['class'] == cls) and (state is None or r.get('state') == state)]
bl_known = all(backlog.get(h) is not None for h in ACTIVE)
backlog_read_at = time.time()
QUEUE = {c: sum(len(bl(h, c)) for h in ACTIVE) for c in ('ready', 'held', 'waiting')} if bl_known else None
held_cap = sorted(((h, r) for h in ACTIVE for r in backlog.get(h) or []
                   if r.get('hold_kind') == 'captain' and r.get('state') != 'done'), key=lambda x: (x[1]['day'] or TODAY, x[0]))
held_all = sorted(held_cap + [(h, r) for h in ACTIVE for r in bl(h, 'held') if r.get('hold_kind') != 'captain'],
                  key=lambda x: (x[1]['day'] or TODAY, x[0]))
titles = {(h, r['id']): r['title'] for h in home_dir for r in backlog.get(h) or []}
could = {h: min(max(0, plan(h) - len(by_home[h])), len(bl(h, 'ready'))) if h not in lane_err else 0 for h in ACTIVE}

# --- flow over local days: landed, closed, filed ------------------------
def load_json(p):
    try:
        v = json.load(open(p))
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError): return {}
def save_json(p, v):
    try:
        with open(p + f'.tmp.{os.getpid()}', 'w') as f: json.dump(v, f)
        os.replace(p + f'.tmp.{os.getpid()}', p)
    except OSError: pass  # no cache only means the next build reads again
def midnight(d): return datetime.combine(d, datetime.min.time()).astimezone().timestamp()
def when(ts):  # 14:05 today, Thu 08:05 this week, else 07 Oct 14:05
    t = datetime.fromtimestamp(ts).astimezone()
    if t.date() == TODAY: return t.strftime('%H:%M')
    return t.strftime('%a %H:%M') if abs((t.date() - TODAY).days) < 6 else t.strftime('%d %b %H:%M')
DAYS = [TODAY - timedelta(days=i) for i in range(13, -1, -1)]  # 14 local days, today last

# Landed: each pull request the fleet recorded as merged, once, by the home that merged it.
PR_URL = re.compile(r'https://(?:github\.com/[\w.-]+/[\w.-]+/pull|[\w.-]+/[\w./-]+/-/merge_requests|[\w.-]+/c/[\w./-]+/\+)/[1-9]\d*')
MERGED = re.compile(r'^done \[key=merged-([^\]]+)\] \[at=(\d+)\]: merged \1 (' + PR_URL.pattern + r')(?=\s|$)')
merges = {}  # PR URL -> (epoch, home, task)
def merged(url, at, h, task):
    if url not in merges or at < merges[url][0]: merges[url] = (at, h, task)
for h in leads:
    try:
        with open(os.path.join(HOME, 'state', f'{h}.status'), encoding='utf-8', errors='replace') as fh:
            for l in fh:
                m = MERGED.match(l)
                if m: merged(m.group(3), int(m.group(2)), h, m.group(1))
    except FileNotFoundError: pass
    except OSError as e: notes.append(('merge records', f'{h}: {e.strerror}'))
try:
    with open(os.path.join(HOME, 'state/fleet-ledger.jsonl'), encoding='utf-8', errors='replace') as fh:
        for n, l in enumerate(fh):
            if n and '"task.merged"' not in l: continue
            try: e = json.loads(l)
            except ValueError: continue
            if not isinstance(e, dict) or not isinstance(e.get('ts'), int): continue
            if e.get('event') == 'task.merged' and PR_URL.fullmatch(str(e.get('pr'))): merged(e['pr'], e['ts'], 'main', str(e.get('task')))
except OSError as e: notes.append(('merge records', f"Main: {e.strerror}, so Main's own merges are not counted"))
def landed_on(d, h=None):
    lo, hi = midnight(d), midnight(d + timedelta(days=1))
    return sum(lo <= at < hi and h in (None, hh) for at, hh, _ in merges.values())
LANDED = [landed_on(d) for d in DAYS]
merges_read_at = time.time()

# Closed: backlog items marked done, by the local day they closed (the backlog and its archive).
CLOSED = re.compile(r'^- \[x\] (\S+) (?:- )?(.*?)(?= blocked-by:| \((?:repo|kind|priority|merged|reported|done|closed)\b|$)')
CDATE = re.compile(r'\((?:merged|reported|done|closed) (\d{4}-\d\d-\d\d)\)')
closed, done_title = {}, {}  # home -> {day: n}; (home, id) -> title
for h in ACTIVE:
    seen, c = set(), {}
    try:
        if h not in backlog_sources or not backlog_sources[h][1]: raise ValueError('unsupported backlog source')
        root, source = backlog_sources[h]
        import tomllib
        config = next((p for p in (os.path.join(root, '.tasks.toml'), os.path.expanduser('~/.tasks-axi/config.toml')) if os.path.lexists(p)), None)
        settings = tomllib.load(open(config, 'rb')) if config else {}
        archive = (settings.get('markdown') or {}).get('archive', os.path.join(os.path.dirname(source), 'done-archive.md'))
        if not isinstance(archive, str) or not archive: raise ValueError('archive unavailable')
        for f in (source, os.path.join(root, archive)):
            try: fh = open(f, encoding='utf-8', errors='replace')
            except FileNotFoundError:
                if f == source: raise
                continue  # tasks-axi writes the archive with its first archived item: none yet
            with fh:
                for l in fh:
                    m, ds = CLOSED.match(l), CDATE.findall(l)
                    d = iso_day(ds[-1]) if m and ds else None
                    if d is None or (m.group(1), d) in seen: continue
                    seen.add((m.group(1), d)); c[d] = c.get(d, 0) + 1
                    done_title.setdefault((h, m.group(1)), clean(m.group(2).strip()))
        closed[h] = c
    except (OSError, ValueError, ImportError) as e: closed[h] = None; notes.append(('closed items', f'{h}: {e.strerror if isinstance(e, OSError) else str(e)}'))
CLOSED_KNOWN = all(closed[h] is not None for h in ACTIVE)
closed_read_at = time.time()
def closed_on(d, h=None): return sum((closed[x] or {}).get(d, 0) for x in ([h] if h else ACTIVE))
CLOSED_N = [closed_on(d) for d in DAYS]

# Filed: a closed item loses its filing day, so a log keeps each open item's day once seen.
FILED = os.path.join(STATE_DIR, 'filed.json')
with open(os.path.join(STATE_DIR, '.cache.lock'), 'a') as cache_lock:
    fcntl.flock(cache_lock, fcntl.LOCK_EX)
    flog = load_json(FILED)
    items = flog.get('items') if isinstance(flog.get('items'), dict) else {}
    gap = not bl_known or not all(isinstance(flog.get(k), (int, float)) for k in ('since', 'last')) or NOW_TS - flog['last'] > 3600
    filed_since = NOW_TS if gap else flog['since']  # a gap in the log restarts what it can vouch for
    for h in ACTIVE:
        for r in backlog.get(h) or []:
            if r['day'] and r.get('state') != 'done': items.setdefault(f'{h}\t{r["id"]}', r['day'].isoformat())
    items = {k: v for k, v in items.items() if isinstance(v, str) and v >= (DAYS[0] - timedelta(days=1)).isoformat()}
    save_json(FILED, dict(since=filed_since if bl_known else None, last=NOW_TS if bl_known else None, items=items))
    FILED_N = [len({k.split('\t', 1)[1] for k, v in items.items() if '\t' in k and v == d.isoformat() and k.split('\t', 1)[0] in ACTIVE}) for d in DAYS]

    # Trends: the tiles' numbers now, sampled every 10 minutes and kept 8 days (-1 is unknown).
    HIST = os.path.join(STATE_DIR, 'history.tsv')
    STUCK = SPLIT['blocked'] + SPLIT['decision']
    hist = []
    try:
        for l in open(HIST):
            f = l.split()
            if len(f) == 4 and all(re.fullmatch(r'-?\d+', x) for x in f): hist.append([int(x) for x in f])
    except OSError: pass
    if not hist or NOW_TS - hist[-1][0] >= 600:
        hist = [r for r in hist if NOW_TS - r[0] < 8 * 86400] + [[int(NOW_TS), OPEN if LANES_KNOWN else -1, STUCK if LANES_KNOWN else -1, QUEUE['ready'] if QUEUE else -1]]
        try:
            with open(HIST + f'.tmp.{os.getpid()}', 'w') as f: f.write(''.join('\t'.join(map(str, r)) + '\n' for r in hist))
            os.replace(HIST + f'.tmp.{os.getpid()}', HIST)
        except OSError: pass  # the trend only misses this sample
def day_ago(col):
    r = min((r for r in hist if abs(r[0] - (NOW_TS - 86400)) <= 1800 and r[col] >= 0), key=lambda r: abs(r[0] - (NOW_TS - 86400)), default=None)
    return r[col] if r else None

# --- quota -------------------------------------------------------------
def num(v): return v if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) else None
def parse_ts(ts):
    try: return datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone()
    except (AttributeError, ValueError): return None
def quota():
    try:
        data = json.load(open(os.path.expanduser('~/.cache/quota-axi/quotas.json'), encoding='utf-8'))
        if not isinstance(data, dict) or data.get('schemaVersion') != 3: raise ValueError('unsupported quota-axi cache schema')
        at = parse_ts(data.get('generatedAt'))
        if at is None: raise ValueError('quota cache has no valid time')
        if not isinstance(data.get('providers'), list): raise ValueError('no providers')
        return data, at.timestamp()
    except (OSError, ValueError) as e:
        notes.append(('quota-axi', str(e) or 'unreadable')); return None, None
qdata, q_at = quota()
accounts = []
for p in (qdata or {}).get('providers') or []:
    if not isinstance(p, dict): continue
    st = p.get('state') if isinstance(p.get('state'), dict) else {}
    at = parse_ts(st.get('refreshedAt')) or datetime.fromtimestamp(q_at).astimezone()
    wins = []
    for w in p['windows'] if isinstance(p.get('windows'), list) else []:
        if not isinstance(w, dict): continue
        used, span, reset = num(w.get('percentUsed')), num(w.get('windowSeconds')), parse_ts(w.get('resetsAt'))
        elapsed = span - (reset - at).total_seconds() if span and reset else None
        valid = used is not None and 0 <= used <= 100 and span is not None and span > 0 and elapsed is not None and 0 < elapsed < span
        try: out = at + timedelta(seconds=(100 - used) * elapsed / used) if valid and used else None
        except OverflowError: out, valid = None, False
        status = 'unknown' if not valid else 'exhausted_now' if used == 100 else 'projected_exhaustion' if out and out < reset else 'through_reset'
        wins.append(dict(id=w.get('id'), label=str(w.get('label') or w.get('id')), used=used,
                         pace=100 * elapsed / span if valid else None, reset=reset, runout=out, status=status))
    limit = min((w for w in wins if w['status'] in ('exhausted_now', 'projected_exhaustion')), key=lambda w: (w['status'] != 'exhausted_now', w['runout']), default=None)
    problem = str(st.get('status') or 'state unknown').replace('_', ' ') if st.get('status') not in ('fresh', 'stale') else None
    if not wins or any(w['status'] == 'unknown' for w in wins): problem = problem or 'runway unknown'
    accounts.append(dict(name=clean(p.get('label') or str(p.get('provider')).title()), status=limit['status'] if limit else 'unknown' if problem else 'through_reset',
                         runout=limit['runout'] if limit else None, limit=limit, windows=wins, read_at=at.timestamp(),
                         problem=problem, empty=not problem and limit is not None and limit['status'] == 'exhausted_now'))
def runs_out(a): return a['status'] == 'projected_exhaustion' and not a['problem']
running_out = sorted((a for a in accounts if runs_out(a)), key=lambda a: a['runout'])
quota_times = sorted({a['read_at'] for a in accounts})
quota_stamp = f'as of {esc(when(quota_times[0]))}' + (f' through {esc(when(quota_times[-1]))} across accounts' if len(quota_times) > 1 else '') if quota_times else 'not read'

# --- agents: the Herdr state the muxr app reads -------------------------
agents = None
out, err = probe(['herdr', 'agent', 'list'])
try:
    if out is None: raise ValueError(err)
    agents = json.loads(out)['result']['agents']
    if not isinstance(agents, list): raise ValueError('no agent list')
except (ValueError, KeyError, TypeError) as e:
    agents = None; notes.append(('herdr agent list', str(e) or 'unreadable'))
agents_read_at = time.time()
pane_role = {}
for h, ms in metas.items():
    for task, m in ms:
        if m.get('herdr_pane_id'):
            pane_role[m['herdr_pane_id']] = ('lead', task, task) if m.get('kind') == 'secondmate' else ('worker', h, task)
ROLES = [('lead', 'leads'), ('main', 'Main'), ('worker', 'workers'), ('other', 'other')]
agent_rows = []  # (role, home, name, status)
for a in agents or []:
    role = pane_role.get(a.get('pane_id'))
    if role: r, h, n = role
    elif os.path.realpath(os.path.join(a.get('cwd') or '/', 'data')) == os.path.realpath(os.path.join(HOME, 'data')): r, h, n = 'main', 'main', 'Main'  # the folder holding this home's records
    else: r, h, n = 'other', None, a.get('name') or os.path.basename((a.get('cwd') or '').rstrip('/')) or 'unnamed'
    if h in parked: continue
    agent_rows.append((r, h, n, a.get('agent_status') or 'unknown'))
busy = [a for a in agent_rows if a[3] == 'working']
BUSY = {r: sum(a[0] == r for a in busy) for r, _ in ROLES}

# --- machine and devices: read-only probes, each with a short timeout ------
# A probe that fails says "unknown" and why; it never guesses a value or a zero.
PROC = os.environ.get('FM_DASHBOARD_PROC', '/proc')
LOCK_DIR = os.environ.get('FM_DEVICE_LOCK_DIR', '/tmp')
def env_int(name, default):
    try: return int(os.environ.get(name, default))
    except ValueError: return default
EMU_MAX, GRADLE_MAX, MEM_MIN_GB = env_int('FM_EMU_MAX', 2), env_int('FM_GRADLE_MAX', 2), env_int('FM_MEM_MIN_GB', 12)

def read(rel):
    try: return open(os.path.join(PROC, rel), errors='replace').read(), None
    except OSError as e: return None, f'{PROC}/{rel}: {e.strerror}'
def gb(kib): return kib / 1048576

def machine():
    m = {}
    t, err = read('meminfo')
    kv = dict(re.findall(r'^(\w+):\s+(\d+)', t or '', re.M))
    m['free'] = (gb(int(kv['MemAvailable'])), gb(int(kv['MemTotal']))) if 'MemAvailable' in kv and 'MemTotal' in kv else None
    m['free_why'] = err or 'no MemAvailable in meminfo'
    t, err = read('pressure/memory')
    p = re.search(r'^some avg10=([0-9.]+)', t or '', re.M)
    m['pressure'], m['pressure_why'] = (float(p.group(1)) if p else None), err or 'no "some avg10" line'
    m['swap'] = gb(int(kv['SwapTotal']) - int(kv['SwapFree'])) if 'SwapTotal' in kv and 'SwapFree' in kv else None
    # Use the independent sampler's history (bin/fm-host-memory-sampler.sh), not the dashboard's refresh cadence.
    try:
        rows = [l.split('\t') for l in open(os.path.join(HOME, 'state/host-memory.tsv'), errors='replace')]
        m['peak'] = max((float(r[3]) for r in rows if len(r) >= 5 and r[3].strip() and float(r[0]) >= NOW_TS - 3600), default=None)
        m['peak_why'] = 'no sample in the last hour'
    except (OSError, ValueError) as e:
        m['peak'], m['peak_why'] = None, getattr(e, 'strerror', None) or str(e)
    out, err = probe(['systemctl', '--user', 'show', 'fm-heavy.slice', '-p', 'MemoryCurrent', '-p', 'MemoryHigh', '-p', 'MemoryMax'])
    kv = dict(l.split('=', 1) for l in (out or '').splitlines() if '=' in l)
    def size(v): return int(v) / 2**30 if (v or '').isdigit() else None
    m['heavy'] = (size(kv.get('MemoryCurrent')), size(kv.get('MemoryHigh')), size(kv.get('MemoryMax')))
    m['heavy_why'] = err or f"MemoryCurrent is {kv.get('MemoryCurrent', 'missing')}"
    out, err = probe(['pgrep', '-cf', 'appname=gradle[w]'], ok=(0, 1))  # the memory gate's own count
    m['gradle'], m['gradle_why'] = (int(out.split()[0]) if out and out.split()[0].isdigit() else None), err or 'no count'
    return m

def emulators():
    """[{pid, avd, port, rss}] from the running qemu processes, or (None, reason)."""
    out, err = probe(['pgrep', '-a', '^qemu-system'], ok=(0, 1))
    if out is None: return None, err
    emus = []
    for l in out.splitlines():
        pid, _, args = l.partition(' ')
        a = args.split()
        opt = lambda k: a[a.index(k) + 1] if k in a[:-1] else None
        st, _ = read(f'{pid}/status')
        rss = re.search(r'^VmRSS:\s+(\d+)', st or '', re.M)
        emus.append(dict(pid=pid, avd=opt('-avd') or '?', port=opt('-port'), rss=gb(int(rss.group(1))) if rss else None))
    return emus, None

def lock_holders():
    """{lock name: {held, pid, cwd, at, last, verb}} from the device locks, /proc/locks and the lock log."""
    t, err = read('locks')
    held = set(re.findall(r'^\d+:\s+FLOCK\s+\S+\s+\S+\s+\d+\s+(\S+)', t or '', re.M))
    locks = {}
    try: names = sorted(f for f in os.listdir(LOCK_DIR) if f.startswith('fm-phone-') and f.endswith('.lock'))
    except OSError: names = []
    for f in names:
        try: s = os.stat(os.path.join(LOCK_DIR, f))
        except OSError: continue
        key = f'{os.major(s.st_dev):02x}:{os.minor(s.st_dev):02x}:{s.st_ino}'
        locks[f[9:-5]] = dict(held=None if t is None else key in held)
    try:
        for l in open(os.path.join(LOCK_DIR, 'fm-device-lock.log'), errors='replace'):
            f = l.split()
            if len(f) < 3: continue
            at = datetime.fromisoformat(f[0].replace('Z', '+00:00')) if re.match(r'\d{4}-\d\d-\d\dT', f[0]) else None
            d = locks.setdefault(f[1], dict(held=None if t is None else False))
            d.update(last=at, verb=f[2])
            if f[2] == 'acquired':
                kv = dict(x.split('=', 1) for x in f[3:] if '=' in x)
                d.update(pid=kv.get('pid'), at=at, cwd=l.split(' cwd=', 1)[1].strip() if ' cwd=' in l else None)
    except OSError: pass
    return locks, err

def worktree_homes():  # every task's worktree and id, and each home itself, mapped to its home
    m = {}
    for h, d in home_dir.items():
        if h in remote_hosts: continue
        m[os.path.realpath(d)] = h
        try:
            for f in os.listdir(os.path.join(d, 'state')):
                if not f.endswith('.meta'): continue
                m[f[:-5]] = h  # a worker's own scratch dir is often named after its task id
                for l in open(os.path.join(d, 'state', f), errors='replace'):
                    k, _, v = l.strip().partition('=')
                    if k in ('worktree', 'tasktmp') and v: m[os.path.realpath(v)] = h
        except OSError: pass
    return m
def who(cwd, homes_by_path):
    if not cwd: return 'an unknown worker'
    p = os.path.realpath(cwd)
    while p not in homes_by_path and os.path.dirname(p) != p: p = os.path.dirname(p)
    h = homes_by_path.get(p)
    base = os.path.basename(cwd.rstrip('/'))
    h = h or homes_by_path.get(base) or homes_by_path.get(base.removeprefix('fm-'))
    return ('Main' if h == 'main' else h) if h else base
def ago(at):
    if at is None: return ''
    s = max(0, int(NOW.timestamp() - at.timestamp()))
    return 'under a minute' if s < 60 else f'{s // 60} min' if s < 3600 else f'{s // 3600} h {s % 3600 // 60} min' if s < 86400 else f'{s // 86400} d'
def ancestors(pid):
    seen = []
    for _ in range(40):
        t, _ = read(f'{pid}/stat')
        m = re.match(r'\d+ \(.*\) \S (\d+)', t or '', re.S)
        if not m or m.group(1) in ('0', '1'): break
        pid = m.group(1); seen.append(pid)
    return seen

def devices():
    """(rows, summary) for every adb device, every running emulator and every held device lock."""
    out, adb_err = probe([adb_path(), 'devices', '-l'])
    emus, emu_err = emulators()
    locks, lock_err = lock_holders()
    homes_by_path = worktree_homes()
    held_by_pid = {d['pid']: n for n, d in locks.items() if d.get('held') and d.get('pid')}
    rows, seen_locks = [], set()
    def holder(names, pids=()):
        """(text, tone) for the first held lock among names, else via a held lock an ancestor process took."""
        for n in names:
            d = locks.get(n)
            if d and d.get('held'):
                seen_locks.add(n); w = who(d.get("cwd"), homes_by_path); return f'In use by {w} · {ago(d.get("at"))}', 'warn', w
        for p in pids:
            if p in held_by_pid:
                d = locks[held_by_pid[p]]; seen_locks.add(held_by_pid[p]); w = who(d.get("cwd"), homes_by_path)
                return f'In use by {w} · {ago(d.get("at"))}', 'warn', w
        if lock_err: return f'unknown: {lock_err}', '', None  # no lock state, so free is a guess
        d = next((locks[n] for n in names if n in locks), None)
        if d and d.get('at'):
            return f'Free · last used by {who(d.get("cwd"), homes_by_path)} {ago(d.get("last"))} ago', 'ok', None
        return 'Free', 'ok', None
    emu_by_port = {e['port']: e for e in emus or [] if e['port']}
    serials = []
    connected = 0
    for l in (out or '').splitlines()[1:]:
        f = l.split()
        if len(f) < 2: continue
        serials.append(f[0])
        if f[1] == 'device': connected += 1
        kv = dict(x.split(':', 1) for x in f[2:] if ':' in x)
        e = emu_by_port.pop(f[0][9:], None) if f[0].startswith('emulator-') else None
        if e:
            name, sub = f'Emulator {e["avd"]}', f'{f[0]}' + (f' · {e["rss"]:.1f} GB in use' if e['rss'] is not None else '')
            text, tone, w = holder([f[0], e['avd']], ancestors(e['pid']))
        else:
            name, sub = (kv.get('model') or 'Device').replace('_', ' '), f'{f[0]}' + (' · USB' if 'usb' in kv else '')
            name = ('Emulator ' if f[0].startswith('emulator-') else 'Phone ') + name
            text, tone, w = holder([f[0]])
        if f[1] != 'device': text, tone = f'{f[1].capitalize()} · {text}', 'bad'
        rows.append((name, sub, text, tone, w))
    for e in emu_by_port.values() if emus is not None else []:  # running, but adb does not list it
        text, tone, w = holder([f'emulator-{e["port"]}', e['avd']], ancestors(e['pid']))
        rows.append((f'Emulator {e["avd"]}', 'not listed by adb' + (f' · {e["rss"]:.1f} GB in use' if e['rss'] is not None else ''), text, tone, w))
    for n, d in sorted(locks.items()):  # a held lock no device above accounts for
        if d.get('held') and n not in seen_locks and n not in serials:
            w = who(d.get("cwd"), homes_by_path)
            rows.append((f'Lock {n}', 'no matching device', f'Held by {w} · {ago(d.get("at"))}', 'warn', w))
    problems = [f'adb: {adb_err}'] if out is None else []
    if emus is None: problems.append(f'emulators: {emu_err}')
    if lock_err: problems.append(f'device locks: {lock_err}')
    return rows, connected if out is not None else None, len(emus) if emus is not None else None, problems

mach = machine()
dev_rows, dev_count, emu_count, dev_problems = devices()
machine_read_at = time.time()
for a in accounts:
    if a['problem']: notes.append(('quota-axi account', f'{a["name"]}: {a["problem"]}'))
if qdata is not None and not accounts: notes.append(('quota-axi', 'no account runway readings'))
for key, label in (('free', 'free memory'), ('pressure', 'memory pressure'), ('gradle', 'Gradle builds')):
    if mach[key] is None: notes.append(('machine ' + label, mach[key + '_why']))
for label, value in zip(('heavy jobs', 'heavy high limit', 'heavy max limit'), mach['heavy']):
    if value is None: notes.append(('machine ' + label, mach['heavy_why']))
notes.extend(('devices', p) for p in dev_problems)
for h, s in leads.items():
    reason = ('summary unavailable' if s is None else
              'summary time is in the future' if s['generated_epoch'] > NOW_TS else
              'summary stale' if NOW_TS - s['generated_epoch'] > SUMMARY_MAX_AGE else
              'child state unavailable' if s.get('valid') is False else
              'runtime evidence unavailable' if lead_word(h)[0] == 'Runtime unknown' else
              'child state unknown' if s.get('state') == 'unknown' or s.get('state') not in LEAD_WORDS else None)
    if reason: notes.append(('lead state', f'{h}: {reason}'))
def device_group(r, group):
    if not r[4] and 'unknown:' in r[2]: return 'Unknown'
    return (r[4] or 'No holder') if group == 'home' else 'Problem' if r[3] == 'bad' else 'In use' if r[4] else 'Free'
device_groups = {g: {k: sum(device_group(r, g) == k for r in dev_rows)
                    for k in sorted({device_group(r, g) for r in dev_rows})} for g in ('action', 'home')}

# --- html pieces ---------------------------------------------------------
BUILT = NOW.strftime('%H:%M')
def link(text, url, cls='inl'):
    return f'<a class="{cls}" href="{esc(url)}" rel="noreferrer">{esc(text)}</a>' if re.match(r'https?://', url or '') else esc(text)
def sh(label, more=None):  # a section's small label: what it counts, its window and the time its source was read
    a = f'<a href="{esc(more[0])}">{esc(more[1])} →</a>' if more else ''
    return f'<div class="sh"><p class="label">{esc(label)}</p>{a}</div>'
def dot(tone=''): return f'<span class="dot {tone}"></span>'
def unknown(why): return f'<span class="unkv">unknown: {esc(why)}</span>'
def why_of(source): return next((r for s, r in notes if s == source or s.startswith(source)), 'not read')

def item(tone, t, h='', w='', tm=None, href=None):
    t = f'<a href="{esc(href)}">{t}</a>' if href else t
    return (f'<div class="item{" feed" if tm is not None else ""}">' + (f'<span class="tm">{esc(tm)}</span>' if tm is not None else dot(tone))
            + f'<span class="t">{t}</span><span class="h">{h}</span>' + (f'<span class="w">{w}</span>' if w else '') + '</div>')

def switch(group):
    segs = ''.join(f'<a href="?group={k}"{" aria-current=true" if k == group else ""}>{n}</a>' for k, n in (('action', 'What to do'), ('home', 'Home')))
    return f'<div class="gsw"><span>Group lists by</span><nav class="seg" aria-label="Group every list on this page">{segs}</nav></div>'
def glist(groups, total_label, total=None):
    """groups: (name, count, rows html, sub, swatch class or None, open). Group counts sum to the total line."""
    out = ''
    for name, n, rows, sub, sw, op in groups:
        s = f'<i class="sw2 {sw}"></i>' if sw is not None else ''
        out += (f'<details class="g"{" open" if op else ""}><summary><span class="cv"></span><span class="gn">{s}{esc(name)}</span>'
                + (f'<span class="gs">{sub}</span>' if sub else '') + f'<span class="gc">{n}</span></summary><div class="gb">{rows}</div></details>')
    counts = [g[1] for g in groups if isinstance(g[1], int)]
    total = sum(counts) if total is None else total
    eq = f'{" + ".join(map(str, counts))} = ' if len(counts) > 1 else ''
    return f'<div class="gl">{out}<div class="gtot"><span class="k">{esc(total_label)}</span><span class="sum">{eq}<b>{total}</b></span></div></div>'
def grow(n, w='', c=None):
    if c is None: return f'<div class="gr st"><span class="n">{n}</span><span class="w">{w}</span></div>'  # a named row: what, then where and why
    return f'<div class="gr"><span class="n">{n}</span><span class="w">{w}</span><span class="c">{c}</span></div>'
def split_txt(sp, states): return ' · '.join(f'{lane_value(sp[s])} {s if s != "decision" else "on a decision"}' for s in states if sp.get(s))
PARKED_LINE = (f'<p class="note">{esc(" and ".join(PARKED))} {"is" if len(PARKED) == 1 else "are"} parked by the captain and left out of every total.</p>'
               if PARKED else '')

# --- lanes: the strip (graft from B) and the grouped list ----------------
FREE = max(0, PLAN - OPEN) if LANES_KNOWN else None
def lane_strip(): return stack(lane_parts(SPLIT), OPEN + (FREE or 0), 'sb big') + lane_legend(SPLIT, FREE)
def lanes_list(group, names=False, strip=True):
    """Every open lane in exactly one group; with names, each lane is a row, else one row per home with its count."""
    def lane_row(l):
        t = esc(titles.get((l['home'], l['task'])) or l['task'])
        what = STATES[l['state']] if group == 'home' else hname(l['home'])
        pr = f' · {link("pull request", l["pr"])}' if l['pr'] else ''
        why = f' · {esc(prose(l["text"])[:140])}' if l['state'] in ('blocked', 'decision', 'waiting', 'validating') and l['text'] else ''
        return grow(t, f'{esc(what)} · {dur(NOW_TS - l["since"])}{pr}{why}')
    groups = []
    if group == 'home':
        for h in sorted(ACTIVE, key=lambda h: (-sum(l['state'] in ('blocked', 'decision') for l in by_home[h]), -len(by_home[h]), h)):
            ls, sp = by_home[h], split(by_home[h])
            need = sp['blocked'] + sp['decision']
            rows = (''.join(lane_row(l) for l in sorted(ls, key=lambda l: (list(STATES).index(l['state']), l['since']))) if names else
                    ''.join(grow(f'<i class="sw2 {sw}"></i>{esc(STATES[s])}', '', sp[s]) for _, states, sw in ACT for s in states if sp[s]))
            groups.append((hname(h), lane_value(len(ls), h), rows, esc(split_txt(sp, list(STATES))) if not need or names else esc(split_txt(sp, ('blocked', 'decision'))), None, bool(need) or names and bool(ls)))
    else:
        for name, states, sw in ACT:
            ls = [l for l in live if l['state'] in states]
            if names: rows = ''.join(lane_row(l) for l in sorted(ls, key=lambda l: l['since']))
            else:
                per = sorted(((h, [l for l in ls if l['home'] == h]) for h in ACTIVE), key=lambda x: (-len(x[1]), x[0]))
                rows = ''.join(grow(esc(hname(h)), esc(split_txt(split(hl), states)) if len(states) > 1 else '', len(hl)) for h, hl in per if hl)
            groups.append((name, lane_value(len(ls)), rows, esc(split_txt(SPLIT, states)) if len(states) > 1 else '', sw, True))
    return (lane_strip() if strip else '') + glist(groups, 'Open lanes', lane_value(OPEN))

# --- slow spots: each row a state, a number and an age ------------------
spots = []  # dict(tone, chip, what, n, age, href, title)
def where(ls):
    c = {}
    for l in ls: c[l['home']] = c.get(l['home'], 0) + 1
    return ', '.join(f'{hname(h)} {n}' for h, n in sorted(c.items(), key=lambda x: (-x[1], x[0])))
def spot(tone, chip, what, n, age, href, title=''):
    spots.append(dict(tone=tone, chip=chip, what=what, n=n, age=age, href=href, title=f'{n} {what}' + (f' · {title}' if title else '')))
stuck = [l for l in live if l['state'] in ('blocked', 'decision')]
if stuck: spot('bad' if SPLIT['blocked'] else 'warn', 'Stuck', 'stuck', lane_value(len(stuck)), dur(NOW_TS - min(l['since'] for l in stuck)), 'backlog#lanes', where(stuck))
fin = [l for l in live if l['state'] == 'finished']
if fin: spot('warn', 'To land', 'to land', lane_value(len(fin)), dur(NOW_TS - min(l['since'] for l in fin)), 'backlog#lanes', where(fin))
if held_cap:
    c = {}
    for h, _ in held_cap: c[h] = c.get(h, 0) + 1
    oldest = held_cap[0][1]['day']
    spot('warn', 'Held', 'held for triage', f'{"" if bl_known else "≥"}{len(held_cap)}', days_old(oldest) if oldest else 'unknown',
         'backlog?group=home#held', ', '.join(f'{hname(h)} {n}' for h, n in sorted(c.items(), key=lambda x: (-x[1], x[0]))))
if bl_known:
    if sum(could.values()):
        old = min((r['day'] for h in ACTIVE if could[h] for r in bl(h, 'ready') if r['day']), default=None)
        spot('warn', 'Idle', 'idle with ready work', sum(could.values()), days_old(old) if old else 'unknown', 'backlog#targets',
             ', '.join(f'{hname(h)} {len(bl(h, "ready"))} ready, {len(by_home[h])} of {plan(h)} open' for h in ACTIVE if could[h]))
down = {h for h in leads if lead_word(h)[0] == 'Not running'}
if down: spot('bad', 'Down', 'lead down' if len(down) == 1 else 'leads down', len(down), 'now', '#homes', ', '.join(sorted(down)))
tidy = sorted(h for h in leads if h not in down and lead_word(h)[1] == 'bad')
if tidy: spot('warn', 'Check', 'lead to check' if len(tidy) == 1 else 'leads to check', len(tidy), 'now', '#homes', ', '.join(f'{h}: {lead_word(h)[0]}' for h in tidy))

# --- machine and devices -------------------------------------------------
free, psi, (hc_, hh_, hm_) = mach['free'], mach['pressure'], mach['heavy']
def psi_tone(v): return 'bad' if v >= 40 else 'warn' if v >= 20 else 'ok'
gate_wait = (free is not None and free[0] < MEM_MIN_GB) or (psi is not None and psi >= 40)
at_cap = [x for x, full in (('emulators', (emu_count or 0) >= EMU_MAX), ('Gradle builds', (mach['gradle'] or 0) >= GRADLE_MAX)) if full]
for h in ACTIVE:  # fm-spawn.sh and fm-control.sh relaunch record why the host memory guard turned a new agent away
    if h in remote_hosts: continue
    try: at, task, why = open(os.path.join(home_dir[h], 'state/admission-refused'), errors='replace').read().rstrip('\n').split('\t', 2)
    except (OSError, ValueError): continue
    if NOW_TS - float(at) < 900: spot('bad', 'Memory', f'new agents wait ({hname(h)})', task, dur(NOW_TS - float(at)), '#devices', why)
low = free is not None and free[0] < MEM_MIN_GB
if gate_wait: spot('bad', 'Memory', 'free, heavy jobs wait' if low else 'memory pressure, heavy jobs wait', f'{free[0]:.0f} GB' if low else f'{psi:.0f}%', 'now', '#devices', 'the next heavy job queues')
for x, n, cap in (('emulators', emu_count, EMU_MAX), ('Gradle builds', mach['gradle'], GRADLE_MAX)):
    if x in at_cap: spot('warn', 'At cap', f'{x} at cap', f'{n}/{cap}', 'now', '#devices', 'the next one queues')
def meter(label, value, frac, tone, hint=''):
    bar = f'<span class="bar"><i class="{tone}" style="width:{max(2, min(100, round(100 * frac)))}%"></i></span>' if frac is not None else ''
    return f'<div class="mm"><span>{esc(label)}</span><b class="{tone}">{value}</b>{bar}{f"<small>{esc(hint)}</small>" if hint else ""}</div>'
machine_rows = ''.join([
    meter('Free memory', f'{free[0]:.1f} GB <small>of {free[1]:.0f} GB</small>', free[0] / free[1] if free[1] else None,
          'bad' if free[0] < MEM_MIN_GB else 'ok', f'heavy jobs wait below {MEM_MIN_GB} GB')
    if free else meter('Free memory', unknown(mach['free_why']), None, ''),
    meter('Memory pressure', f'{psi:.0f}%', psi / 100, psi_tone(psi), 'share of the last 10 s some job waited on memory; heavy jobs wait at 40% or more')
    if psi is not None else meter('Memory pressure', unknown(mach['pressure_why']), None, ''),
    meter('Pressure peak, last hour', f'{mach["peak"]:.0f}%', mach['peak'] / 100, psi_tone(mach['peak']),
          'highest sustained share (lower of 10 s and 60 s averages) the watcher recorded; config/host-memory sets when new agents wait and when an alert goes out')
    if mach['peak'] is not None else meter('Pressure peak, last hour', unknown(mach['peak_why']), None, ''),
    meter('Swap used', f'{mach["swap"]:.1f} GB', None, 'warn' if mach['swap'] >= 8 else 'ok', 'memory the kernel pushed to disk')
    if mach['swap'] is not None else meter('Swap used', unknown('no SwapTotal in meminfo'), None, ''),
    meter('Heavy jobs', f'{hc_:.1f} GB <small>of {hh_:.0f} GB</small>' if hh_ else f'{hc_:.1f} GB', hc_ / hh_ if hh_ else None,
          'warn' if hh_ and hc_ >= 0.9 * hh_ else 'ok', 'shared group for builds and emulators' + (f'; hard limit {hm_:.0f} GB' if hm_ else ''))
    if hc_ is not None else meter('Heavy jobs', unknown(mach['heavy_why']), None, ''),
    meter('Gradle builds', f'{mach["gradle"]} <small>of {GRADLE_MAX}</small>', mach['gradle'] / GRADLE_MAX if GRADLE_MAX else None,
          'warn' if mach['gradle'] >= GRADLE_MAX else 'ok', 'a new build waits at the cap')
    if mach['gradle'] is not None else meter('Gradle builds', unknown(mach['gradle_why']), None, ''),
    meter('Emulators', f'{emu_count} <small>of {EMU_MAX}</small>', emu_count / EMU_MAX if EMU_MAX else None,
          'warn' if emu_count >= EMU_MAX else 'ok', 'a new emulator waits at the cap')
    if emu_count is not None else meter('Emulators', unknown(next((p for p in dev_problems if p.startswith('emulators')), 'no answer')), None, ''),
])
def devices_list(group):
    key = lambda r: device_group(r, group)
    if group == 'home':
        order = sorted(device_groups[group], key=lambda k: (k == 'No holder', k))
    else:
        order = [k for k in ('Problem', 'In use', 'Free', 'Unknown') if k in device_groups[group]]
    groups = [(k, sum(key(r) == k for r in dev_rows), ''.join(grow(esc(r[0]), esc(f'{r[2]} · {r[1]}')) for r in dev_rows if key(r) == k), '', None, True) for k in order]
    body = glist(groups, 'Devices') if dev_rows else ('<p class="note">No device connected and no emulator running.</p>' if dev_count is not None else '')
    return body + ''.join(f'<p class="note">unknown - {esc(p)}</p>' for p in dev_problems)

# --- homes: one row each, every lane stack on one shared scale -----------
def home_rows():
    top = max([plan(h) for h in ACTIVE] + [len(by_home[h]) for h in ACTIVE] + [1])
    def cell(v): return f'<span class="hn{" z" if not v else ""}">{"–" if v is None else v}</span>'
    rows = ''
    for h in ACTIVE:
        lw, sp, n = lead_word(h), split(by_home[h]), len(by_home[h])
        tone = 'bad' if lw[1] == 'bad' or h in lane_err else 'warn' if lw[1] == 'warn' or sp['blocked'] + sp['decision'] else 'ok' if n else 'idle'
        sub = ((lw[0] + ' · ' if h in remote_hosts else '') + 'Lane records unreadable') if h in lane_err else lw[0] if lw[1] in ('bad', 'warn') else ''
        free = max(0, plan(h) - n) if h not in lane_err else 0
        rows += (f'<div class="hr"><span class="hname">{dot(tone)}<b>{esc(hname(h))}</b>{f"<small>{esc(sub)}</small>" if sub else ""}</span>'
                 f'<span class="hst"><span class="hsc"><span style="width:{100 * (n + free) / top:.1f}%">{stack(lane_parts(sp, h), n + free) if h not in lane_err else ""}</span></span><small>{lane_value(n, h)} of {plan(h)}</small></span>'
                 + cell(len(bl(h, 'ready')) if backlog.get(h) is not None else None) + cell(f'at least {landed_on(TODAY, h)}')
                 + cell(sum((closed[h] or {}).get(d, 0) for d in DAYS[7:]) if closed[h] is not None else None) + '</div>')
    return ('<div class="hrs"><div class="hr hh"><span>Home</span><span>Lanes open of plan</span><span class="hn">Ready</span>'
            '<span class="hn">Landed today</span><span class="hn">Closed 7\u00a0d</span></div>' + rows + '</div>' + PARKED_LINE)

# --- charts: inline CSS bars drawn here, no script ----------------------
def legend(*items):  # (class, text)
    return '<div class="lg">' + ''.join(f'<span><i class="{c}"></i>{t}</span>' for c, t in items) + '</div>'
# Lane states in one order and one colour each, the same everywhere.
LANE_ORDER = [('building', 'building'), ('validating', 'validating or CI'), ('finished', 'finished, not landed'),
              ('waiting', 'waiting on something'), ('decision', 'on a decision'), ('blocked', 'blocked')]
def stack(parts, total, cls='sb'):  # parts: (class, n, title); total sets the scale, the rest is free
    used = sum(n for _, n, _ in parts)
    segs = ''.join(f'<i class="{c}" style="flex:{n}" title="{esc(t)}"></i>' for c, n, t in parts if n)
    free = total - used
    return f'<div class="{cls}">{segs}' + (f'<i class="free" style="flex:{free}" title="{free} free"></i>' if free > 0 else '') + '</div>'
def lane_parts(sp, h=None): return [(f's-{s}', sp[s], f'{lane_value(sp[s], h)} {n}') for s, n in LANE_ORDER]
def lane_legend(sp, free=None):
    return legend(*[(f'k s-{s}', f'{lane_value(sp[s])} {n}') for s, n in LANE_ORDER if sp[s]], *([('k free', f'{free} free of plan {PLAN}')] if free else []))
def card(title, window, body, cls='', more=None, cid=''):
    m = f'<a class="cm" href="{esc(more[0])}">{esc(more[1])} →</a>' if more else ''
    return f'<section class="card {cls}"{f" id={cid}" if cid else ""}><div class="ch"><h3>{title}</h3>{m}</div><p class="cw">{window}</p>{body}</section>'

# --- page shell ----------------------------------------------------------
NAV = [('./', 'app', 'Board'), ('/#/overview', 'overview', 'Overview'), ('backlog', 'backlog', 'Backlog'), ('measure', 'measure', 'Method')]
records = []  # (title, detail): two records that give different answers
for h in sorted(home_dir):
    fl = bl(h, state='in_flight')
    if h in parked and fl: records.append((f'{h} is parked but has {plural(len(fl), "item")} marked in flight', 'Its backlog still lists them in flight.'))
    elif fl and h not in lane_err:
        lt = {l['task'] for l in lanes if l['home'] == h}
        orphan = [r for r in fl if r['id'] not in lt and r.get('kind') in ('ship', 'scout')]
        if orphan: records.append((f'{hname(h)}: {plural(len(orphan), "item")} marked in flight with no live lane',
                                   ', '.join(r['id'] for r in orphan[:6]) + (' and more' if len(orphan) > 6 else '')))
def trust():
    parts = [f'<a class="warn" href="measure#records">{plural(len(records), "record mismatch", "record mismatches")}</a>'] if records else []
    parts += [f'<a class="warn" href="measure#unknown">{plural(len(notes), "source")} unknown</a>'] if notes else []
    return ' · '.join(parts) or 'All sources read'
CSS = ':root{color-scheme:light dark;--bg:#faf5ee;--card:#ffffff;--text:#231b14;--text2:#5a4d41;--text3:#736456;--line:rgba(90,55,20,.11);--line2:rgba(90,55,20,.22);--bar:#4a3f36;--track:rgba(90,55,20,.09);--tick:#231b14;--acc:#c84f00;--in:#007ea6;--vio:#a07cdb;--ok:#1a7a3c;--okbar:#218a45;--warn:#8f5600;--warnbar:#bb7400;--bad:#c72c4c}@media (prefers-color-scheme:dark){:root{--bg:#15110d;--card:#201a15;--text:#f6efe7;--text2:#d4c8ba;--text3:#a89a8a;--line:rgba(255,230,200,.09);--line2:rgba(255,230,200,.18);--bar:#d8ccbf;--track:rgba(255,230,200,.09);--tick:#f5eee6;--acc:#df6c32;--in:#10a8b0;--vio:#9a7de3;--ok:#5fd394;--okbar:#3eab5e;--warn:#f5ae39;--warnbar:#f5ae39;--bad:#f0546e}}*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}body{margin:0;background:var(--bg);color:var(--text);font:16px/1.5 system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;font-variant-numeric:tabular-nums;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}a{color:inherit;text-decoration:none}a:hover{text-decoration:underline;text-decoration-color:var(--line2);text-underline-offset:3px}.shell{max-width:780px;margin:0 auto;padding:0 16px 40px}/* nav */.brand{display:none}.brand b{font-size:16px;font-weight:600;letter-spacing:-.01em}.stamp{display:block;font-size:12px;color:var(--text3);margin-top:2px}.nav{display:flex;gap:16px;align-items:center;border-bottom:1px solid var(--line);overflow-x:auto;scrollbar-width:none}.nav a{font-size:14px;color:var(--text2);padding:12px 0 11px;border-bottom:1.5px solid transparent;margin-bottom:-1px;white-space:nowrap}.nav a:hover{text-decoration:none;color:var(--text)}.nav a[aria-current]{color:var(--text);border-bottom-color:var(--text);font-weight:500}.side-foot{display:none}main{padding-top:14px}/* type: 12 meta, 14 small, 16 body, 20 answers, 28/36 verdicts */.label{font-size:12px;color:var(--text3);margin:0;font-weight:500}.sh{display:flex;justify-content:space-between;align-items:baseline;gap:12px;margin:0 0 4px}.sh a{font-size:12px;color:var(--text2);white-space:nowrap}h1{text-wrap:balance;font-size:28px;line-height:1.15;letter-spacing:-.022em;font-weight:650;margin:0;max-width:24ch}.lede{text-wrap:pretty;font-size:16px;color:var(--text2);margin:8px 0 0;max-width:56ch}.lede a,.inl{color:var(--text);text-decoration:underline;text-decoration-color:var(--line2);text-underline-offset:3px}h2{font-size:20px;line-height:1.3;letter-spacing:-.014em;font-weight:600;margin:0 0 10px;text-wrap:balance}.meta{display:flex;flex-wrap:wrap;align-items:center;gap:4px 14px;margin-bottom:8px;font-size:12px;color:var(--text3)}.state{display:inline-flex;align-items:center;gap:7px;font-size:14px;font-weight:500}.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.mut{color:var(--text3)}.sub{color:var(--text2)}a.warn{text-decoration:underline;text-decoration-color:currentColor;text-underline-offset:3px;text-decoration-thickness:1px}.dot{width:7px;height:7px;border-radius:50%;background:currentColor;flex:none;display:inline-block}.dot.idle{background:none;box-shadow:inset 0 0 0 1.5px var(--text3)}.dot.warn{background:var(--warnbar)}.dot.ok{background:var(--ok)}.sections{display:grid;gap:26px;margin-top:20px}.stack{display:grid;gap:28px;align-content:start;min-width:0}section{min-width:0}.more{display:inline-block;margin-top:10px;font-size:14px;color:var(--text2)}/* key-value rows */.rows{border-top:1px solid var(--line)}.kv{display:grid;grid-template-columns:minmax(0,1fr) 48px 2.6em 6.6em;align-items:center;column-gap:10px;min-height:40px;border-bottom:1px solid var(--line)}.kv .k{color:var(--text2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.kv .v{text-align:right;font-weight:600;white-space:nowrap;letter-spacing:-.01em}.kv .d{font-size:12px;color:var(--text3);white-space:nowrap}.kv .d.warn{color:var(--warn)}.ge{font-weight:400;color:var(--text3);margin-right:1px}.spark{display:block;width:48px;height:18px;color:var(--text3)}.wo,.wonly{display:none}.nw{white-space:nowrap}/* items: what / where / why */.item{display:grid;grid-template-columns:14px minmax(0,1fr) auto;column-gap:8px;padding:8px 0;border-bottom:1px solid var(--line);align-items:baseline}.item .dot{transform:translateY(-1px)}.item .t{font-weight:500}.item .w{grid-column:2/4;font-size:14px;color:var(--text3);margin-top:1px}.item .h{font-size:14px;color:var(--text2);white-space:nowrap}.cline{display:grid;grid-template-columns:14px minmax(0,1fr);column-gap:8px;align-items:baseline;font-size:14px;color:var(--text2);padding:10px 0 0}.cline .dot{transform:translateY(-1px)}/* homes */.home{display:grid;grid-template-columns:minmax(0,1fr) repeat(3,3.4em);grid-template-areas:"n a b c" "s s s s";column-gap:6px;padding:10px 0;border-bottom:1px solid var(--line);align-items:baseline}.home.head{padding:0 0 6px;font-size:12px;color:var(--text3);line-height:1.25;align-items:end}.home .n{grid-area:n;display:flex;align-items:center;gap:9px;font-weight:550}.home .s{grid-area:s;font-size:14px;color:var(--text2);padding-left:16px;margin-top:1px}.home .f{text-align:right}.home .fa{grid-area:a}.home .fb{grid-area:b}.home .fc{grid-area:c}.home.head .s{display:none}.z{color:var(--text3)}/* lane split */.split{display:flex;height:10px;gap:2px;margin:2px 0 12px}.split i{display:block;height:100%;background:var(--bar)}.split i.l2{opacity:.6}.split i.l3{opacity:.35}.split i.wb{background:var(--warnbar)}.lane{display:grid;grid-template-columns:12px minmax(0,1fr) 2.4em;column-gap:8px;padding:8px 0;border-bottom:1px solid var(--line);align-items:baseline}.lane .sw2{width:9px;height:9px;border-radius:2px;background:var(--bar);transform:translateY(0)}.lane .sw2.l2{opacity:.6}.lane .sw2.l3{opacity:.35}.lane .sw2.wb{background:var(--warnbar)}.lane .c{text-align:right;font-weight:600}.lane .w{grid-column:2/4;font-size:14px;color:var(--text3)}.lane.tot{border-bottom:0;border-top:1px solid var(--line2);margin-top:-1px}.lane.tot .k{font-weight:600}.split i.ol,.sw2.ol{background:none;box-shadow:inset 0 0 0 1.5px var(--text3)}/* grouped lists: switch, collapsible groups, visible sum */.gsw{display:flex;align-items:center;gap:10px;margin:18px 0 0;font-size:12px;color:var(--text3)}.seg{display:inline-flex;gap:2px;padding:2px;border:1px solid var(--line2);border-radius:8px}.seg a{padding:4px 11px;border-radius:6px;color:var(--text2);white-space:nowrap;line-height:1.4}.seg a:hover{text-decoration:none;color:var(--text)}.seg a[aria-current]{background:var(--track);color:var(--text);font-weight:600}.gl{border-top:1px solid var(--line)}details.g{border-bottom:1px solid var(--line)}details.g>summary{list-style:none;cursor:pointer;display:grid;grid-template-columns:16px minmax(0,1fr) auto;grid-template-areas:"cv gn gc" ". gs gs";column-gap:8px;align-items:baseline;padding:10px 0}details.g>summary::-webkit-details-marker{display:none}.cv{grid-area:cv;align-self:start;height:24px;display:flex;align-items:center}.cv::before{content:"";width:6px;height:6px;border-right:1.5px solid var(--text3);border-bottom:1.5px solid var(--text3);transform:translate(2px,-2px) rotate(45deg)}details.g:not([open]) .cv::before{transform:translate(0,0) rotate(-45deg)}details.g[open] .gs.cl{display:none}.gn{grid-area:gn;font-weight:600}.gn .sw2{display:inline-block;width:9px;height:9px;border-radius:2px;background:var(--bar);margin-right:9px;vertical-align:0}.gn .sw2.l3{opacity:.35}.gn .sw2.wb{background:var(--warnbar)}.gn .sw2.ol{background:none}.gn .sw2.no{visibility:hidden}.gc{grid-area:gc;font-weight:600;text-align:right}.gs{grid-area:gs;font-size:14px;color:var(--text3)}.gb{padding:0 0 10px 24px;font-size:14px}.gr{display:grid;grid-template-columns:6.5em minmax(0,1fr) 2.4em;column-gap:12px;align-items:baseline;padding:3px 0}.gr .n{color:var(--text)}.gr .w{color:var(--text3)}.gr .c{grid-column:3;text-align:right;color:var(--text2)}.gr.st .n{grid-column:1/3}.gr .sw2{display:inline-block;width:8px;height:8px;border-radius:2px;background:var(--bar);margin-right:9px}.gr .sw2.l3{opacity:.35}.gr .sw2.wb{background:var(--warnbar)}.gr .sw2.ol{background:none}.gr.dv{grid-template-columns:minmax(0,1fr)}.homes.nl .home{grid-template-columns:minmax(0,1fr) repeat(2,3.4em);grid-template-areas:"n b c" "s s s"}.gtot{display:flex;justify-content:space-between;align-items:baseline;gap:12px;padding:10px 0 0;border-top:1px solid var(--line2);margin-top:-1px}.gtot .k{font-weight:600}.gtot .sum{font-size:14px;color:var(--text3);white-space:nowrap}.gtot .sum b{font-size:16px;color:var(--text);font-weight:600;margin-left:3px}.ks{display:block;font-size:12px;color:var(--text3);line-height:1.3}.kv .k.span{grid-column:1/3;padding:4px 0}/* tables */table{width:100%;border-collapse:collapse}th{font-size:12px;font-weight:500;color:var(--text3);text-align:right;padding:0 0 6px 8px;vertical-align:bottom;line-height:1.25}th:first-child,td:first-child{text-align:left;padding-left:0}td{text-align:right;padding:9px 0 9px 8px;border-top:1px solid var(--line)}tbody tr:last-child td{border-bottom:1px solid var(--line)}tfoot td{font-weight:600;border-top:1px solid var(--line2);border-bottom:0}td.l,th.l{text-align:left}td .bf,th.bfc,td.bfc{display:none}.tt td{vertical-align:top}.tt td:first-child{color:var(--text)}.tt td.l{color:var(--text2);font-size:14px}.tt th.l{width:46%}/* totals equation */.eq{display:flex;flex-wrap:wrap;align-items:flex-end;gap:6px 14px;border-top:1px solid var(--line);border-bottom:1px solid var(--line);padding:12px 0}.eq div span{display:block;font-size:12px;color:var(--text3)}.eq div b{display:block;font-size:20px;font-weight:600;letter-spacing:-.015em;line-height:1.3}.eq .op{font-size:20px;color:var(--text3);line-height:1.3}.eq small{font-size:14px;font-weight:400;color:var(--text2)}/* charts */.chart svg{display:block;width:100%;height:120px}.cols{display:grid;text-align:center;font-size:12px;color:var(--text3);border-top:1px solid var(--line2);padding-top:6px}.cols b{display:block;font-size:14px;font-weight:600;color:var(--text)}.cols i{font-style:normal}.legend{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:14px;color:var(--text2);margin:0 0 10px}.sw{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}.sw.f{background:var(--bar)}.sw.o{box-shadow:inset 0 0 0 1.5px var(--text2)}.note{font-size:14px;color:var(--text3);margin:10px 0 0;max-width:62ch}.unk{display:flex;justify-content:space-between;gap:12px;padding:10px 0;border-bottom:1px solid var(--line);color:var(--text2)}.unk b{font-weight:500;color:var(--text3)}/* feed */.feed .item{grid-template-columns:3.4em minmax(0,1fr) auto}.feed.nt .item{grid-template-columns:minmax(0,1fr) auto}.feed.nt .item .w{grid-column:1/3}.feed .tm{font-size:14px;color:var(--text3)}/* quota */.acct{padding:14px 0 16px;border-bottom:1px solid var(--line)}.acct:first-child{border-top:1px solid var(--line)}.acct-h{display:flex;justify-content:space-between;align-items:baseline;gap:4px 12px;flex-wrap:wrap}.acct-h b{font-weight:600}.acct-h .r{font-size:14px;font-weight:500}.acct-meta{font-size:14px;color:var(--text3);margin-top:1px}.win{display:grid;grid-template-columns:minmax(0,1fr) 3.2em;grid-template-areas:"l p" "b b" "x x";column-gap:10px;margin-top:12px}.win .l{grid-area:l;font-size:14px;color:var(--text2)}.win .p{grid-area:p;text-align:right;font-weight:600}.win svg{grid-area:b;display:block;width:100%;height:12px;margin:4px 0 2px;overflow:visible}.win .x{grid-area:x;font-size:12px;color:var(--text3)}.meter .tr{fill:var(--track)}.meter .fi{fill:var(--bar)}.meter .fi.w{fill:var(--warnbar)}.meter .fi.m{fill:var(--text3);opacity:.55}.meter .tk{stroke:var(--tick);stroke-width:1.5}.users{font-size:14px;color:var(--text3);margin-top:12px}.users b{font-weight:500;color:var(--text2)}.two table{margin-top:22px}.grp{font-size:12px;color:var(--text3);font-weight:500;margin:16px 0 4px}.grp:first-of-type{margin-top:0}footer{margin-top:40px;padding-top:14px;border-top:1px solid var(--line);font-size:14px;color:var(--text3);line-height:1.6}footer p{margin:0 0 4px}footer a{color:var(--text2);text-decoration:underline;text-decoration-color:var(--line2);text-underline-offset:3px}@media (min-width:600px){ main{padding-top:24px} h1{font-size:36px} .sections{gap:36px;margin-top:28px} .stack{gap:36px} .kv{grid-template-columns:minmax(0,1fr) 72px 2.8em 13em;column-gap:16px;min-height:44px} .spark{width:72px;height:22px} .wo{display:inline}.wonly{display:block} .item .w{grid-column:2/3} .feed.nt .item .w{grid-column:1/2} .home{grid-template-columns:9em minmax(0,1fr) repeat(3,4.6em);grid-template-areas:"n s a b c";column-gap:12px} .home .s{padding-left:0;margin-top:0} .home.head .s{display:block;visibility:hidden} td .bf{display:block;margin:0 auto} th.bfc,td.bfc{display:table-cell;width:42%} th.bfc{text-align:center} .chart svg{height:140px} details.g>summary{grid-template-columns:16px auto minmax(0,1fr) auto;grid-template-areas:"cv gn gs gc";column-gap:10px} .homes.nl .home{grid-template-columns:9em minmax(0,1fr) repeat(2,4.6em);grid-template-areas:"n s b c"}}@media (max-width:1099px){ .ov>.stack{display:contents} .a-out{order:1}.a-slow{order:2}.a-lanes{order:3}.a-homes{order:4}.a-dev{order:5}}@media (min-width:1100px){ .shell{max-width:1312px;padding:0 48px 64px} main{padding-top:28px} .hero .meta{display:none} .sections{grid-template-columns:repeat(2,minmax(0,1fr));gap:52px 72px;margin-top:44px} .sections .wide{grid-column:1/-1} .stack{gap:52px} .accts{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));column-gap:72px} .acct:nth-child(2){border-top:1px solid var(--line)} .two{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);column-gap:72px;align-items:start} .two table{margin-top:0!important} .kv{grid-template-columns:minmax(0,1fr) 64px 2.8em 10.5em} .home{grid-template-columns:9em minmax(0,30em) repeat(3,minmax(4.6em,1fr))} .homes.nl .home{grid-template-columns:9em minmax(0,30em) repeat(2,minmax(4.6em,1fr))}}/* phase 2: grafts and live-only pieces */.unkv{color:var(--text3);font-weight:400;font-size:14px}.trust{margin-top:0}.trust a{color:var(--text2)}.trust a.warn{color:var(--warn)}.strip{display:flex;height:12px;gap:2px;margin:2px 0 8px}.strip i{flex:1;border-radius:2px;background:var(--bar)}.strip i.st{background:var(--warnbar)}.strip i.fr{background:none;box-shadow:inset 0 0 0 1.5px var(--line2)}.sw.mv{background:var(--bar)}.sw.st{background:var(--warnbar)}.sw.fr{box-shadow:inset 0 0 0 1.5px var(--line2)}.gr .n{min-width:0;overflow:hidden;text-overflow:ellipsis}.gb .gr{grid-template-columns:minmax(0,1fr) auto 2.4em}.gb .gr .w{font-size:13px;text-align:right}@media (max-width:599px){.gb .gr{grid-template-columns:minmax(0,1fr) 2.4em}.gb .gr .w{grid-column:1/-1;grid-row:2;text-align:left}}.iol{border-top:1px solid var(--line)}.iob{display:grid;grid-template-columns:6em minmax(0,1fr);grid-template-areas:"lab bars" ". nums";column-gap:12px;padding:10px 0;border-bottom:1px solid var(--line)}.iob .lab{grid-area:lab;color:var(--text2)}.iob .bars{grid-area:bars;display:grid;gap:4px;align-content:center}.iob .nums{grid-area:nums;font-size:13px;color:var(--text3)}.io{display:block;height:9px;border-radius:2px;min-width:0}.io.out{background:var(--bar)}.io.in{box-shadow:inset 0 0 0 1.5px var(--text2)}.iol+.legend{margin-top:10px}.ro{display:grid;grid-template-columns:auto minmax(0,1fr);column-gap:12px;padding:10px 0;border-bottom:1px solid var(--line);align-items:baseline}.ro>b{font-size:20px;font-weight:600;letter-spacing:-.015em}.ro .rn{font-size:14px;color:var(--text2)}.ro .rn b{color:var(--text)}.ro .bar,.mm .bar{grid-column:1/-1;display:block;height:6px;background:var(--track);border-radius:3px;margin:6px 0 3px;overflow:hidden}.ro .bar i,.mm .bar i{display:block;height:100%;background:var(--bar)}.ro .bar i.w,.mm .bar i.warn{background:var(--warnbar)}.mm .bar i.bad{background:var(--bad)}.ro small,.mm small{grid-column:1/-1;font-size:12px;color:var(--text3)}.mach{margin-top:18px}.mm{display:grid;grid-template-columns:minmax(0,1fr) auto;column-gap:12px;padding:8px 0;border-bottom:1px solid var(--line);align-items:baseline}.mm:first-child{border-top:1px solid var(--line)}.mm>span{color:var(--text2)}.mm>b{font-weight:600}.mm>b small{font-size:12px;font-weight:400;color:var(--text3);grid-column:auto}.xl{display:none}.sm{font-size:13px}@media (min-width:1100px){.xl{display:block}.trust{margin-top:6px}}.gb .gr.st{display:block;padding:5px 0}.gb .gr.st .n{display:block;white-space:normal}.gb .gr.st .w{display:block;text-align:left;grid-column:auto}.kv .ks{white-space:normal}.kv .k.wide{grid-column:1/3}.kv .dw{display:block;white-space:normal;line-height:1.3}.item.feed{grid-template-columns:4.2em minmax(0,1fr) auto}.item.feed .tm{white-space:nowrap}.item.feed .w{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}.item.feed .tm{font-size:14px;color:var(--text3)}/* visual-first: cards, tiles and charts */.c-ok{--c:var(--okbar)}.c-warn{--c:var(--warnbar)}.c-bad{--c:var(--bad)}.c-in{--c:var(--in)}.c-out{--c:var(--acc)}.c-vio{--c:var(--vio)}.c-mut{--c:var(--text3)}.hero.ov h1{display:flex;align-items:center;gap:12px;max-width:none}.hd{width:14px;height:14px;border-radius:50%;background:var(--c);flex:none;box-shadow:0 0 0 5px color-mix(in srgb,var(--c) 22%,transparent)}.tiles{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin-top:18px}.tile{display:flex;flex-direction:column;min-width:0;background:var(--card);border:1px solid var(--line);border-radius:16px;padding:12px 12px 10px;color:inherit;position:relative;overflow:hidden}.tile:hover{text-decoration:none;border-color:var(--line2)}.tile.t-warn{box-shadow:inset 0 3px 0 var(--warnbar)}.tile.t-bad{box-shadow:inset 0 3px 0 var(--bad)}.tl{font-size:12px;font-weight:600;color:var(--text2);letter-spacing:.01em}.tv{display:flex;align-items:baseline;flex-wrap:wrap;gap:4px 8px;font-size:30px;font-weight:700;letter-spacing:-.03em;line-height:1.15;margin:2px 0 4px}.tv small{font-size:14px;font-weight:500;color:var(--text3);letter-spacing:0}.tv .unkv{font-size:13px;letter-spacing:0}.okv{color:var(--ok)}.dl{font-size:12px;font-weight:600;letter-spacing:0;padding:1px 7px;border-radius:999px;background:var(--track);color:var(--text2);white-space:nowrap}.dl.up{color:var(--ok);background:color-mix(in srgb,var(--ok) 14%,transparent)}.dl.down{color:var(--warn);background:color-mix(in srgb,var(--warnbar) 16%,transparent)}.ta{font-size:11px;line-height:1.35;color:var(--text3);margin-top:auto;padding-top:6px}.tc{flex-basis:100%;font-size:12px;font-weight:500;letter-spacing:0;color:var(--text3)}.mini b{font-weight:600;color:var(--text)}.tsp.ok .ln{stroke:var(--okbar)}.tsp.ok .ar{fill:var(--okbar)}.tsp.warn .ln{stroke:var(--warnbar)}.tsp.warn .ar{fill:var(--warnbar)}.tsp.bad .ln{stroke:var(--bad)}.tsp.bad .ar{fill:var(--bad)}.gauge+.mini,.tv:has(.gauge)+.mini{margin-top:6px}.mini+.tsp{margin-top:6px}.tsp{display:block;width:100%;height:34px}.tsp .ln{fill:none;stroke-width:2;stroke-linejoin:round}.tsp .ar{stroke:none;opacity:.16}.tsp.out .ln{stroke:var(--acc)}.tsp.out .ar{fill:var(--acc)}.tsp.in .ln{stroke:var(--in)}.tsp.in .ar{fill:var(--in)}.hit{fill:transparent}.donut{width:84px;height:84px;display:block;margin:2px 0}.donut,.gauge{letter-spacing:0}.donut circle{fill:none;stroke-width:4.2;stroke:var(--c)}.donut .tr{stroke:var(--track)}.donut .dc,.gauge .dc{font-size:9px;font-weight:700;fill:var(--text);text-anchor:middle;letter-spacing:-.3px}.donut .ds,.gauge .ds{font-size:4.2px;font-weight:500;letter-spacing:0;fill:var(--text3);text-anchor:middle}.tv:has(.donut),.tv:has(.gauge){margin:0}.gauge{width:110px;height:64px;display:block}.gauge path{fill:none;stroke-width:4.6;stroke-linecap:round;stroke:var(--c)}.gauge .tr{stroke:var(--track)}.gauge .dc{font-size:10px}.mini{display:flex;flex-wrap:wrap;gap:2px 10px;font-size:12px;color:var(--text2)}.mini span{display:inline-flex;align-items:center;gap:5px;white-space:nowrap}.mini i.free{background:none;box-shadow:inset 0 0 0 1.5px var(--line2)}.mini i,.lg i{width:8px;height:8px;border-radius:2px;background:var(--c);display:inline-block;flex:none}.sb{display:flex;gap:2px;height:10px;border-radius:5px;overflow:hidden;margin:4px 0}.sb.big{height:14px;margin:8px 0 6px}.sb i{display:block;min-width:3px;background:var(--c)}.sb i.free,.lg i.free{background:none;box-shadow:inset 0 0 0 1.5px var(--line2)}.s-building{--c:var(--acc)}.s-validating{--c:var(--in)}.s-finished{--c:var(--vio)}.s-waiting{--c:var(--text3)}.s-decision{--c:var(--warnbar)}.s-blocked{--c:var(--bad)}.k.out{--c:var(--acc)}.k.in{--c:var(--in)}.k.y{opacity:.55}.k.p50{--c:var(--acc)}.k.p85{--c:var(--vio)}.k.ok{--c:var(--okbar)}.k.bad{--c:var(--bad)}.k.mut{--c:var(--text3)}.lg{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12px;color:var(--text2);margin:2px 0 8px}.lg span{display:inline-flex;align-items:center;gap:6px;white-space:nowrap}.lg .k.y{opacity:1}.lg .k.y i,.lg i.k.y{opacity:.5}.cards{display:grid;gap:12px;margin-top:12px}.card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px 14px 12px;min-width:0}.ch{display:flex;justify-content:space-between;align-items:baseline;gap:10px}.ch h3{font-size:16px;font-weight:650;letter-spacing:-.01em;margin:0}.cm{font-size:12px;color:var(--text2);white-space:nowrap}.cw{font-size:11px;color:var(--text3);margin:0 0 10px}.cf{display:grid;grid-template-columns:auto minmax(0,1fr);column-gap:6px}.ya{display:flex;flex-direction:column;justify-content:space-between;height:var(--ch);font-size:11px;color:var(--text3);text-align:right;line-height:1;margin-top:-1px}.pl svg{display:block;width:100%;height:var(--ch);overflow:visible}.xa{display:grid;font-size:11px;color:var(--text3);margin-top:4px}.xa span{text-align:center;white-space:nowrap}.gl{stroke:var(--line);stroke-width:1}.ln{fill:none;stroke-width:2.5;stroke-linejoin:round;stroke-linecap:round}.ln.out{stroke:var(--acc)}.ln.in{stroke:var(--in)}.ln.y{stroke-width:1.6;stroke-dasharray:5 4;opacity:.7}.ln.p50{stroke:var(--acc)}.ln.p85{stroke:var(--vio);stroke-dasharray:6 4}.now{stroke:var(--text3);stroke-width:1;stroke-dasharray:2 3}.b.out{fill:var(--acc)}.b.in{fill:var(--in);opacity:.85}.hbs{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:6px 16px}.hb{display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:baseline;color:inherit;padding:4px 0}.hb:hover{text-decoration:none}.hb .hn{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.hb .hv{font-size:14px;font-weight:700}.hb .hv small{font-size:11px;color:var(--text3);font-weight:500}.hb .sb{grid-column:1/-1;height:8px;margin:3px 0 0}.qb{display:grid;grid-template-columns:6.5em minmax(0,1fr) auto;align-items:center;gap:10px;padding:5px 0}.qn{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.qt{position:relative;height:10px;border-radius:5px;background:var(--track)}.qt i{position:absolute;inset:0 auto 0 0;border-radius:5px;background:var(--c)}.qt b{position:absolute;top:-3px;bottom:-3px;width:2px;margin-left:-1px;background:var(--tick);opacity:.55;border-radius:1px}.qr{font-size:12px;white-space:nowrap;text-align:right;min-width:6.5em}.qr.warn{font-weight:600}.sps{display:grid}.sp{display:grid;grid-template-columns:4.8em minmax(0,1fr) 3.4em 4.6em;align-items:center;gap:8px;padding:7px 0;border-top:1px solid var(--line);color:inherit}.sp:hover{text-decoration:none;background:var(--track)}.sp.sph{font-size:11px;color:var(--text3);border-top:0;padding-top:0}.sp.sph span:nth-child(n+3){text-align:right}.chip{font-size:11px;font-weight:700;text-align:center;padding:2px 0;border-radius:999px;color:var(--c);background:color-mix(in srgb,var(--c) 17%,transparent);white-space:nowrap}.sp .spw{font-size:13.5px;line-height:1.3;min-width:0}.sp .sn{font-size:15px;text-align:right}.sp .sa{font-size:12px;color:var(--text3);text-align:right;white-space:nowrap}.okn{color:var(--ok)}.card .gl,.card table{margin-top:4px}@media (min-width:600px){ .tiles{grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}}@media (min-width:900px){ .cards{grid-template-columns:repeat(2,minmax(0,1fr));gap:14px} .cards .wide{grid-column:1/-1}}@media (min-width:1100px){ .tiles{grid-template-columns:repeat(6,minmax(0,1fr))}}.xa.xp{position:relative;display:block;height:1.3em}.xa.xp span{position:absolute;transform:translateX(-50%)}.xa.xp span:first-child{transform:none}.xa.xp span:last-child{transform:translateX(-100%)}.mm .bar i.ok{background:var(--okbar)}@media (min-width:600px){.devm{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);column-gap:28px;align-items:start}.devm .mach{margin-top:0}}.sections section{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px 14px 12px}.sections .stack{gap:12px}.sections{gap:12px}.io.out{background:var(--acc)}.io.in{box-shadow:inset 0 0 0 1.5px var(--in)}.legend .sw.f{background:var(--acc)}.legend .sw.o{box-shadow:inset 0 0 0 1.5px var(--in);background:none}@media (min-width:600px){.sections,.sections .stack{gap:14px}}@media (min-width:1100px){.sections{gap:16px}.sections .stack{gap:16px}}/* v4: top tabs, chips, bars on one scale, homes, definitions */.top{position:sticky;top:0;z-index:5;background:var(--bg);border-bottom:1px solid var(--line)}.topi{max-width:780px;margin:0 auto;padding:0 16px;display:flex;align-items:center;gap:6px 14px;min-height:52px;flex-wrap:wrap}.brand{display:block;font-size:17px;font-weight:750;letter-spacing:-.02em}.top .nav{border:0;gap:2px;flex:1}.top .nav a{padding:7px 11px;margin:0;border:0;border-radius:9px}.top .nav a[aria-current]{background:var(--track);color:var(--text);font-weight:600}.stamp{margin:0}.age{font-size:12px;font-weight:600;padding:4px 10px;border-radius:999px;background:var(--track);white-space:nowrap}.age::before{content:"● "}.age.ok{color:var(--ok)}.age.warn{color:var(--warn)}.age.bad{color:var(--bad)}.chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}.chip2{display:inline-flex;align-items:baseline;gap:6px;padding:6px 13px;border-radius:999px;font-size:14px;background:color-mix(in srgb,var(--c) 16%,var(--card));border:1px solid color-mix(in srgb,var(--c) 30%,transparent);color:var(--text);white-space:nowrap}.chip2:hover{text-decoration:none;background:color-mix(in srgb,var(--c) 26%,var(--card))}.chip2 i{font-style:normal;font-size:11px;color:var(--c)}.chip2 b{font-weight:700}.chip2 small{font-size:12px;color:var(--text2)}.tsp .ln{stroke:var(--text2)}.t-bad .tsp .ln{stroke:var(--bad)}.t-warn .tsp .ln{stroke:var(--warnbar)}.tile .sb.big{margin:8px 0 4px}.tv .dl{align-self:center}.b.out{fill:var(--okbar)}.b.in{fill:var(--text3);opacity:.75}.b.in.fl,.b.out.fl{opacity:.35}.k.out{--c:var(--okbar)}.k.in{--c:var(--text3)}.hbr{border-top:1px solid var(--line)}.hbr>summary,div.hbr{list-style:none;display:grid;grid-template-columns:12.5rem minmax(0,1fr) 7.2em;align-items:center;gap:12px;padding:9px 0}.hbr>summary{cursor:pointer}.hbr>summary::-webkit-details-marker{display:none}.hbl{font-size:14px;display:flex;align-items:center;gap:8px;white-space:nowrap}.hbl .sw2{width:10px;height:10px;border-radius:3px;background:var(--c);flex:none}.hbt{height:12px;border-radius:6px;background:var(--track);overflow:hidden}.hbt i{display:block;height:100%;background:var(--c);border-radius:6px}.hbv{text-align:right;font-size:13px;white-space:nowrap}.hbv b{font-size:16px;font-weight:700}.hbv small{color:var(--text3);font-size:12px;margin-left:2px}.hbv.z b{color:var(--text3);font-weight:500}details.hbr[open]>summary .hbl{font-weight:600}.hbr .gb{padding:0 0 10px 18px}i.s-waiting,.hbl .sw2.s-waiting{background:none;box-shadow:inset 0 0 0 1.5px var(--text3)}.hbr+.gtot{margin-top:0}.hrs{display:grid}.hr{display:grid;grid-template-columns:minmax(0,10.5em) minmax(0,1fr) repeat(3,4.4em);gap:10px;align-items:center;padding:9px 0;border-top:1px solid var(--line)}.hr.hh{font-size:11px;line-height:1.25;color:var(--text3);border-top:0;padding-top:0;align-items:end}.hname{display:flex;align-items:center;flex-wrap:wrap;gap:0 8px;min-width:0}.hname b{font-weight:600}.hname small{flex-basis:100%;padding-left:15px;font-size:12px;color:var(--warn)}.hst{display:grid;grid-template-columns:minmax(0,1fr) 3.6em;gap:8px;align-items:center}.hsc>span{display:block}.hst .sb{margin:0}.hst small{font-size:12px;color:var(--text3);white-space:nowrap}.hn{text-align:right;font-weight:600}.hr.hh .hn{font-weight:500}.qn{white-space:nowrap}.tile .qt{display:block;margin:12px 0 6px}.qt.unk{background:none;outline:1.5px dashed var(--line2);outline-offset:-1.5px}.qr.ok,.qr.mut{color:var(--text3)}.qr.bad{color:var(--bad)}.qr.warn{color:var(--warn)}.defs{display:grid;gap:4px 32px}.def{scroll-margin-top:72px;border-top:1px solid var(--line);padding:12px 0 8px}.def:first-child{border-top:0}.def:target{outline:2px solid var(--acc);outline-offset:4px;border-radius:6px}.def h3{margin:0 0 6px;font-size:16px}.def dl{display:grid;grid-template-columns:4.6em minmax(0,1fr);gap:3px 12px;margin:0;font-size:14px}.def dt{color:var(--text3)}.def dd{margin:0;color:var(--text2)}footer .trust a{color:var(--warn)}@media (max-width:519px){.hbr>summary,div.hbr{grid-template-columns:minmax(0,1fr) auto}.hbt{grid-column:1/-1;grid-row:2}.hr{grid-template-columns:minmax(0,1fr) repeat(3,3.6em)}.hst{grid-column:1/-1;grid-row:2}.hr.hh>span:nth-child(2){display:none}}@media (min-width:900px){.defs{grid-template-columns:repeat(2,minmax(0,1fr))}.def:nth-child(2){border-top:0}}@media (min-width:1100px){.topi{max-width:1312px;padding:0 48px}}'
def page(name, title, body, foot=''):
    nav = ''.join(f'<a href="{u}"{" aria-current=page" if n == name else ""}>{t}</a>' for u, n, t in NAV)
    return f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark"><meta http-equiv="refresh" content="{MAX_AGE}">
<title>{esc(title)}</title><style>{CSS}</style></head>
<body><header class="top"><div class="topi"><b class="brand">Fleet</b><nav class="nav" aria-label="Pages">{nav}</nav><span class="stamp"><!--age--></span></div></header>
<div class="shell"><main>{body}
<footer><p>Built {NOW:%a %d %b}, {BUILT} · <span class="trust">{trust()}</span></p>{foot}{"" if name == "measure" else '<p><a href="measure">How each number is measured</a></p>'}</footer>
</main></div></body></html>
'''
def unknown_foot(*sources):
    hit = [f'{s}: {r}' for s, r in notes if any(s.startswith(x) for x in sources)]
    return f'<p>Unknown now: {esc("; ".join(hit))}.</p>' if hit else ''

# --- overview ------------------------------------------------------------
def ask_rows():
    if not asks_known: return f'<p class="lede">{unknown("the ask list is unreadable")}</p>'
    if not asks: return ''
    rs = []
    for fields, age in asks:
        if age is None: rs.append(item('bad', 'Ask record needs correction', '', ''))
        else: rs.append(item('warn', link(fields[2], fields[3]), esc(dur(age))))
    return f'<div class="rows asks">{"".join(rs)}</div>'
def busy_split():  # leads + Main + workers (+ other), always summing to the busy total
    return ' + '.join(f'{BUSY[r]} Main' if r == 'main' else plural(BUSY[r], r) for r, n in ROLES if BUSY[r] or r != 'other')
GLYPH = {'bad': '✕', 'warn': '▲', 'ok': '●', 'mut': '?'}
def chips():  # the fleet's state at a glance: each spot one chip, linking to where it is listed
    cs = [(s['tone'], s['n'], s['what'], s['age'], s['href'], s['title']) for s in spots]
    if records: cs.append(('mut', len(records), 'record mismatch' if len(records) == 1 else 'record mismatches', '', 'measure#records', ''))
    if notes: cs.append(('mut', len(notes), 'source unknown' if len(notes) == 1 else 'sources unknown', '', 'measure#unknown', '; '.join(f'{s}: {r}' for s, r in notes)))
    if not spots and not notes and not records and asks_known and LANES_KNOWN and bl_known: cs.insert(0, ('ok', '', 'All flowing', '', '#wait', 'nothing stuck, waiting to land or idle'))
    return '<div class="chips">' + ''.join(f'<a class="chip2 c-{t}" href="{esc(h)}" title="{esc(ti)}"><i>{GLYPH[t]}</i><b>{n}</b> {esc(w)}'
                                           + (f' <small>{esc(a)}</small>' if a and a != 'now' else '') + '</a>' for t, n, w, a, h, ti in cs) + '</div>'

def delta(now, then, good_up=True):  # change against a named earlier value: absolute under 20, else percent
    if now is None or then is None: return '<span class="dl">–</span>'
    d = now - then
    txt = f'{d:+d}' if then < 20 else f'{round(100 * d / then):+d}%'
    return f'<span class="dl{"" if not d or good_up is None else " up" if (d > 0) == good_up else " down"}">{txt}</span>'  # up: the good way
def day_cols(vals, exact):  # one column per local day from 0; a day the records cannot vouch for is faded (at least)
    top, w = max(vals + [1]), 1000 / len(vals)
    return ('<svg class="tsp" viewBox="0 0 1000 40" preserveAspectRatio="none" aria-hidden="true">' + ''.join(
        f'<rect class="b out{"" if ok else " fl"}" x="{i * w + w * .14:.0f}" y="{40 - v / top * 38:.1f}" width="{w * .72:.0f}" height="{v / top * 38:.1f}" vector-effect="non-scaling-stroke"/>'
        for i, (v, ok) in enumerate(zip(vals, exact))) + '</svg>')
def trend(col):  # one point per hour over 7 days from the sampled history, broken at gaps
    t0, pts = NOW_TS - 7 * 86400, {}
    for r in hist:
        if r[0] >= t0: pts[int((r[0] - t0) // 3600)] = r[col]
    top, d, prev = max(list(pts.values()) + [1]), '', None
    for k in sorted(pts):
        if pts[k] < 0: prev = None; continue
        d += f'{"L" if prev is not None and k - prev <= 2 else "M"}{k / 168 * 1000:.0f},{38 - pts[k] / top * 36:.1f}'; prev = k
    return f'<svg class="tsp" viewBox="0 0 1000 40" preserveAspectRatio="none" aria-hidden="true"><path class="ln" d="{d}" vector-effect="non-scaling-stroke"/></svg>' if 'L' in d else ''
def tile(mid, label, value, foot, art='', tone='', at=None):  # a tap opens the number's definition
    if mid == 'quota': foot += f' · {quota_stamp if at is None else "as of " + esc(when(at))}'
    return (f'<a class="tile{" t-" + tone if tone else ""}" href="measure#m-{mid}"><span class="tl">{label}</span>'
            f'<span class="tv">{value}</span>{art}<span class="ta">{foot}</span></a>')
def tiles():
    c7, f7 = sum(CLOSED_N[7:]), sum(FILED_N[7:])
    old = dur(NOW_TS - min(l['since'] for l in stuck)) if stuck else ''
    if qdata is None: q = tile('quota', 'Quota runs out', unknown(why_of('quota-axi')), '')
    elif any(a['empty'] for a in accounts):
        a = next(a for a in accounts if a['empty'])
        q = tile('quota', 'Quota runs out', 'used up', esc(a['name']), tone='bad', at=a['read_at'])
    elif running_out:
        a = running_out[0]
        w = tight_window(a)
        bar = (f'<span class="qt"><i class="c-warn" style="width:{max(2, min(100, round(w["used"])))}%"></i>'
               + (f'<b style="left:{w["pace"]:.0f}%"></b>' if w['pace'] is not None else '') + '</span>') if w else ''
        q = tile('quota', 'Quota runs out', f'{dur(a["runout"].timestamp() - NOW_TS)}', f'{esc(a["name"])} before its reset'
                 + (f' · {len(running_out) - 1} more' if len(running_out) > 1 else '')
                 + (' · others unknown' if any(a['problem'] for a in accounts) else ''), bar, 'warn', at=a['read_at'])
    elif not accounts or any(a['problem'] for a in accounts): q = tile('quota', 'Quota runs out', unknown('runway unavailable for some accounts'), '')
    else: q = tile('quota', 'Quota runs out', '<span class="okv">none</span>', f'{sum(a["empty"] for a in accounts)} used up · {len(accounts)} read')
    return '<div class="tiles">' + ''.join([
        tile('landed', 'Landed today', f'at least {LANDED[-1]}', 'recorded merges · 14 d', day_cols(LANDED, [False] * len(DAYS))),
        tile('closed', 'Closed 7 d', f'{c7}{delta(c7, sum(CLOSED_N[:7]))}' if CLOSED_KNOWN else unknown(why_of('closed')),
             f'filed at least {f7} · vs prior 7 d', day_cols(CLOSED_N, [True] * len(DAYS)) if CLOSED_KNOWN else ''),
        tile('lanes', 'Lanes open', f'{lane_value(OPEN)}<small>of {PLAN}</small>{delta(OPEN if LANES_KNOWN else None, day_ago(1), None)}', f'{lane_value(SPLIT["building"])} building · {str(FREE) + " free" if FREE is not None else "free unknown"}', stack(lane_parts(SPLIT), OPEN + (FREE or 0), 'sb big')),
        tile('stuck', 'Stuck', f'{lane_value(STUCK)}{delta(STUCK if LANES_KNOWN else None, day_ago(2), False)}', (f'{lane_value(SPLIT["blocked"])} blocked · oldest {old}' if stuck else 'vs 24 h ago'),
             stack([('s-blocked', SPLIT['blocked'], 'blocked'), ('s-decision', SPLIT['decision'], 'on a decision')], STUCK, 'sb big') + trend(2),
             'bad' if SPLIT['blocked'] else 'warn' if STUCK else ''),
        tile('ready', 'Ready', f'{QUEUE["ready"]}{delta(QUEUE["ready"], day_ago(3), None)}' if QUEUE else unknown(why_of('backlog')),
             f'{QUEUE["held"]} held · {QUEUE["waiting"]} waiting' if QUEUE else '',
             (stack([(cls, sum(v.values()), n) for n, v, cls in QREASONS], sum(QUEUE.values()), 'sb big') if QUEUE else '') + trend(3)),
        q]) + '</div>'

def hbar(label, n, cls, right='', body='', top=1, partial=False):  # one bar on a shared scale; with a body it opens to the items
    head = (f'<span class="hbl"><i class="sw2 {cls}"></i>{label}</span><span class="hbt"><i class="{cls}" style="width:{100 * n / max(top, 1):.1f}%"></i></span>'
            f'<span class="hbv{"" if n else " z"}"><b>{lane_value(n) if partial else n}</b>{f" <small>{right}</small>" if right else ""}</span>')
    return f'<details class="hbr"><summary>{head}</summary><div class="gb">{body}</div></details>' if body else f'<div class="hbr">{head}</div>'
WAIT = [('blocked', 'Blocked'), ('decision', 'On a decision'), ('finished', 'Finished, not landed'),
        ('validating', 'Validating or CI'), ('waiting', 'Waiting on other'), ('building', 'Building')]
def wait_bars():  # every open lane in exactly one state; why it waits, in its own last words
    def row(l):
        t = esc(titles.get((l['home'], l['task'])) or l['task'])
        why = f' · {esc(prose(l["text"])[:140])}' if l['state'] in ('blocked', 'decision', 'waiting', 'validating') and l['text'] else ''
        return grow(t, f'{esc(hname(l["home"]))} · {dur(NOW_TS - l["since"])}' + (f' · {link("PR", l["pr"])}' if l['pr'] else '') + why)
    top = max(SPLIT.values())
    return ''.join(hbar(name, len(ls), f's-{s}', dur(NOW_TS - min(l['since'] for l in ls)) if ls else '',
                        ''.join(row(l) for l in sorted(ls, key=lambda l: l['since'])), top, partial=True)
                   for s, name in WAIT for ls in [[l for l in live if l['state'] == s]])
capt = {h: sum(r.get('hold_kind') == 'captain' for r in bl(h, 'held')) for h in ACTIVE}
QREASONS = [('Ready, a lane is free', could, 'c-warn'), ('Ready, lanes full', {h: len(bl(h, 'ready')) - could[h] if h not in lane_err else 0 for h in ACTIVE}, 's-building'),
            ('Held for the captain', capt, 's-decision'), ('Held, other reason', {h: len(bl(h, 'held')) - capt[h] for h in ACTIVE}, 'c-mut'),
            ('Waiting on another item', {h: len(bl(h, 'waiting')) for h in ACTIVE}, 's-waiting')]
if not LANES_KNOWN: QREASONS.append(('Ready, capacity unknown', {h: len(bl(h, 'ready')) if h in lane_err else 0 for h in ACTIVE}, 'c-mut'))  # why queued work waits; sums to the queue
def held_reasons(rows): return ''.join(grow(esc(r['title']), esc(hname(h) + ': ' + prose(r.get('hold_reason') or 'no reason recorded'))) for h, r in rows)
def queue_bars():
    if QUEUE is None: return f'<p class="lede">{unknown(why_of("backlog"))}</p>' + held_reasons(held_all)
    top = max([sum(v.values()) for _, v, _ in QREASONS] + [len(held_all)])
    return (''.join(hbar(n, sum(v.values()), cls, '', ''.join(grow(esc(hname(h)), '', c) for h, c in sorted(v.items(), key=lambda x: (-x[1], x[0])) if c), top)
                    for n, v, cls in QREASONS)
            + f'<div class="gtot"><span class="k">Queued</span><span class="sum">{" + ".join(str(sum(v.values())) for _, v, _ in QREASONS)} = <b>{sum(QUEUE.values())}</b></span></div>'
            + hbar('Captain calls and queued holds', len(held_all), 's-decision', '', held_reasons(held_all), top))

def nice_top(v):  # a round axis top at or above v
    m = 10 ** math.floor(math.log10(max(v, 1)))
    return next(s * m for s in (1, 2, 2.5, 5, 10) if s * m >= v)
def frame(svg, top, xlabels, h=150):
    """A chart: y labels (top, half, 0) beside a stretched SVG with gridlines, x labels below."""
    ys = ''.join(f'<span>{v:g}</span>' for v in (top, top / 2, 0))
    grid = ''.join(f'<line class="gl" x1="0" x2="1000" y1="{y}" y2="{y}" vector-effect="non-scaling-stroke"/>' for y in (1, 100, 199))
    return (f'<div class="cf" style="--ch:{h}px"><div class="ya">{ys}</div><div class="pl">'
            f'<svg viewBox="0 0 1000 200" preserveAspectRatio="none" role="img">{grid}{svg}</svg>'
            f'<div class="xa" style="grid-template-columns:repeat({len(xlabels)},1fr)">{"".join(f"<span>{x}</span>" for x in xlabels)}</div></div></div>')
def inout_chart():  # filed (in) beside closed (out) per local day
    top, w = nice_top(max(FILED_N + CLOSED_N + [1])), 1000 / len(DAYS)
    svg = ''.join(f'<rect class="b in fl" x="{i * w + w * .1:.1f}" y="{200 - f / top * 198:.1f}" width="{w * .38:.1f}" height="{f / top * 198:.1f}" vector-effect="non-scaling-stroke"/>'
                  + (f'<rect class="b out" x="{i * w + w * .52:.1f}" y="{200 - c / top * 198:.1f}" width="{w * .38:.1f}" height="{c / top * 198:.1f}"/>' if CLOSED_KNOWN else '')
                  for i, (f, c) in enumerate(zip(FILED_N, CLOSED_N)))
    lg = legend(('k in', 'In: filed, always at least'), ('k out', 'Out: closed' if CLOSED_KNOWN else 'Out: unknown'))
    return lg + frame(svg, top, [('today' if d == TODAY else f'{d:%d}') if i % 2 else '' for i, d in enumerate(DAYS)])
def recent():  # the latest merges, newest first
    rows = ''.join(item('', link(done_title.get((h, task)) or titles.get((h, task)) or task, url), esc(hname(h)), tm=when(at))
                   for url, (at, h, task) in sorted(merges.items(), key=lambda x: -x[1][0])[:6])
    return '<p class="note">Recorded merges only; some may be missing.</p>' + (f'<div class="rows">{rows}</div>' if rows else '<p class="note">No merge on record.</p>')

def tight_window(a):  # the limiting window, else the most used one
    return a['limit'] if a['limit'] and a['limit']['used'] is not None else max((w for w in a['windows'] if w['used'] is not None), key=lambda w: w['used'], default=None)
def quota_bars():  # every account read: its tightest window, soonest runout first
    rows = ''
    for a in sorted(accounts, key=lambda a: (not runs_out(a), not a['empty'], a['problem'] is not None, a['runout'] or NOW, a['name'])):
        w = tight_window(a)
        used = w['used'] if w else None
        tone = 'bad' if a['empty'] else 'warn' if runs_out(a) else 'mut' if used is None else 'ok'
        right = ('used up' if a['empty'] else f'out {when(a["runout"].timestamp())}' if runs_out(a) else 'unknown' if a['problem'] else
                 f'resets {when(w["reset"].timestamp())}' if w and w['reset'] else 'lasts')
        right += f' · as of {when(a["read_at"])}'
        tick = f'<b style="left:{w["pace"]:.0f}%"></b>' if w and w['pace'] is not None and not a['empty'] else ''
        rows += (f'<div class="qb"><span class="qn">{esc(a["name"])}</span><span class="qt{" unk" if used is None and not a["empty"] else ""}">'
                 f'<i class="c-{tone}" style="width:{100 if a["empty"] and used is None else 0 if used is None else max(2, min(100, round(used)))}%"></i>{tick}</span>'
                 f'<span class="qr {tone}">{esc(right)}</span></div>')
    return rows or '<p class="note">No account reported a window.</p>'

def index_body(group):
    n_asks = len(asks)
    h1 = 'Nothing needs you.' if asks_known and not asks else f'{plural(n_asks, "thing")} {"needs" if n_asks == 1 else "need"} you.' if asks_known else 'Ask list unknown.'
    tone = 'ok' if asks_known and not asks else 'warn' if asks_known else 'mut'
    return f'''
<div class="hero ov">
<h1><span class="hd c-{tone}"></span>{h1}</h1>
{ask_rows()}
{chips()}
</div>
{tiles()}
<div class="cards">
{card("Where lanes wait", f"{lane_value(OPEN)} open lanes by state · oldest wait · tap for each lane", wait_bars(), cid="wait", more=("backlog#lanes", "Lanes"))}
{card("Why work is queued", "queued items by reason · tap for each home", queue_bars(), more=("backlog", "Backlog"))}
{card("In vs out", "backlog items per local day, 14 days", inout_chart(), "wide")}
{card("Landed recently", "pull requests merged, newest first", recent())}
{card("Quota runway", f"tightest window per account · even-pace mark · {quota_stamp}", quota_bars() if qdata is not None else f'<p class="lede">{unknown(why_of("quota-axi"))}</p>')}
{card("Homes", "lanes now · landed today · closed 7 days", home_rows(), "wide", ("backlog", "Backlog"), "homes")}
<section class="card wide" id="devices"><div class="ch"><h3>Devices and machine</h3></div><p class="cw">now</p><div class="devm"><div>{devices_list(group)}</div><div class="mach">{machine_rows}</div></div></section>
</div>
'''

# --- backlog -------------------------------------------------------------
def backlog_body(group):
    if QUEUE is None:
        eq = f'<p class="lede">{unknown("; ".join(r for s, r in notes if s == "backlog"))}</p>'
        queued = ''
    else:
        total = sum(QUEUE.values())
        eq = (f'<div class="eq"><div><span>Queued</span><b>{total}</b></div><span class="op">=</span><div><span>Ready</span><b>{QUEUE["ready"]}</b></div>'
              f'<span class="op">+</span><div><span>Held</span><b>{QUEUE["held"]}</b></div><span class="op">+</span><div><span>Waiting on another item</span><b>{QUEUE["waiting"]}</b></div></div>'
              f'<p class="note">In flight: {plural(sum(len(bl(h, state="in_flight")) for h in ACTIVE), "item")}, counted apart from the queue. Held for the captain: {len(held_cap)}.</p>')
        CL = (('ready', 'Ready to start'), ('held', 'Held'), ('waiting', 'Waiting on another item'))
        if group == 'home':
            gs = [(hname(h), len([r for r in backlog[h] if r['class']]),
                   ''.join(grow(esc(n), '', len(bl(h, c))) for c, n in CL if bl(h, c)), '', None, False)
                  for h in sorted(ACTIVE, key=lambda h: (-len([r for r in backlog[h] if r['class']]), h)) if any(r['class'] for r in backlog[h])]
        else:
            gs = [(n, QUEUE[c], ''.join(grow(esc(hname(h)), '', len(bl(h, c))) for h in sorted(ACTIVE, key=lambda h: (-len(bl(h, c)), h)) if bl(h, c)), '', None, c == 'ready')
                  for c, n in CL]
        queued = glist(gs, 'Queued', total)
    def held_row(h, r):
        return item('', esc(r['title']), esc(hname(h)), esc(prose(r['hold_reason']) if r.get('hold_reason') not in (None, '-') else 'no reason recorded'),
                    tm=days_old(r['day']) if r['day'] else '?')
    if group == 'home':
        hs = sorted({h for h, _ in held_all}, key=lambda h: (-sum(x == h for x, _ in held_all), h))
        hgroups = [(hname(h), sum(x == h for x, _ in held_all), ''.join(held_row(x, r) for x, r in held_all if x == h), '', None, True) for h in hs]
    else:
        band = lambda r: 'Over 3 days' if r['day'] and (TODAY - r['day']).days > 3 else '1 to 3 days' if r['day'] and (TODAY - r['day']).days >= 1 else 'Today or unknown'
        hgroups = [(b, sum(band(r) == b for _, r in held_all), ''.join(held_row(h, r) for h, r in held_all if band(r) == b), '', None, True)
                   for b in ('Over 3 days', '1 to 3 days', 'Today or unknown') if any(band(r) == b for _, r in held_all)]
    held = (glist(hgroups, 'Unresolved captain calls and queued holds') if held_all else '<p class="note">No unresolved captain call or queued hold in any home record.</p>' if bl_known else '')
    unread = [hname(h) for h in ACTIVE if backlog.get(h) is None]
    held_h2 = (f'{plural(len(held_all), "item")} held' + (f'; oldest {days_old(held_all[0][1]["day"])}' if held_all and held_all[0][1]['day'] else '') + '.'
               if bl_known else f'At least {plural(len(held_all), "item")} held; the backlog of {", ".join(unread)} is unknown.')
    val = [l for l in live if l['state'] == 'validating']
    oldest_val = min(val, key=lambda l: l['since']) if val else None
    ltrows = ''.join(f'<tr><td>{esc(hname(h))}</td><td>{lane_value(len(by_home[h]), h)}</td><td>{plan(h)}</td><td>{len(bl(h, "ready")) if backlog.get(h) is not None else "–"}</td></tr>'
                     for h in ACTIVE)
    raised = ', '.join(f'{hname(h)} {plan(h)}' for h in ACTIVE if plan(h) != lane_default)
    if group == 'home':
        ag = [(hname(h) if h else 'Not matched to a home', sum(1 for a in agent_rows if a[1] == h and a[3] == 'working'),
               ''.join(grow(esc(n), esc(f'{dict(ROLES)[r]} · {s}')) for r, hh, n, s in sorted(agent_rows, key=lambda a: (a[3] != 'working', a[2])) if hh == h), '', None, False)
              for h in sorted({a[1] for a in agent_rows}, key=lambda h: (h is None, h != 'main', h or ''))]
    else:
        ag = [(n.capitalize() if r != 'main' else 'Main', BUSY[r], ''.join(grow(esc(nm), esc(f'{hname(hh) if hh else "no home"} · {s}')) for rr, hh, nm, s in sorted(agent_rows, key=lambda a: (a[3] != 'working', a[2])) if rr == r), '', None, False)
              for r, n in ROLES if any(a[0] == r for a in agent_rows)]
    agents_html = (glist(ag, 'Busy now', sum(BUSY.values())) + f'<p class="note">Busy means working now in Herdr; the groups list all {len(agent_rows)} running agents, busy first.</p>'
                   if agents is not None else f'<p class="lede">{unknown(why_of("herdr"))}</p>')
    return f'''
<div class="hero">
{sh(f"Backlog · read {BUILT} from each home's backlog")}
<h1>{QUEUE["ready"] if QUEUE else "–"} items ready to start; {lane_value(SPLIT["building"])} building among {lane_value(OPEN)} open lanes.</h1>
{switch(group)}
</div>
<div class="sections">
<section class="wide">
{sh(f"Fleet totals · now {BUILT}")}
{eq}
{PARKED_LINE}
</section>
<div class="stack">
<section id="held">
{sh("Captain calls and queued holds · in home records, oldest first")}
<h2>{held_h2}</h2>
{held}
</section>
<section>
{sh(f"Queued work · now {BUILT}")}
<h2>{"Queued work unknown." if QUEUE is None else f"{sum(QUEUE.values())} queued."}</h2>
{queued}
</section>
<section id="agents">
{sh(f"Agents · Herdr, now {BUILT}")}
<h2>{f"{sum(BUSY.values())} busy: {busy_split()}." if agents is not None else "Agents unknown."}</h2>
{agents_html}
</section>
</div>
<div class="stack">
<section id="lanes">
{sh(f"Every lane · now {BUILT} · age since its last status")}
<h2>{lane_value(OPEN)} lanes open; {lane_value(STUCK)} blocked or waiting.</h2>
{lanes_list(group, names=True)}
<p class="note">Oldest validation or CI wait: {f'{"" if LANES_KNOWN else "at least "}{dur(NOW_TS - oldest_val["since"])} ({esc(titles.get((oldest_val["home"], oldest_val["task"])) or oldest_val["task"])}, {esc(hname(oldest_val["home"]))})' if oldest_val else "none running" if LANES_KNOWN else "unknown"}.</p>
</section>
<section id="targets">
{sh("Lane plan · lane settings")}
<h2>Lane settings plan {PLAN} lanes; {lane_value(OPEN)} are open.</h2>
<table><thead><tr><th>Home</th><th>Open</th><th>Plan</th><th>Ready</th></tr></thead><tbody>{ltrows}</tbody>
<tfoot><tr><td>Fleet</td><td>{lane_value(OPEN)}</td><td>{PLAN}</td><td>{QUEUE["ready"] if QUEUE else "–"}</td></tr></tfoot></table>
<p class="note">Plan per home from the lane settings{f" ({esc(raised)})" if raised else ""}; every other home {lane_default}.</p>
</section>
</div>
</div>
'''

# --- method --------------------------------------------------------------
OFF = NOW.strftime('%z')
METRICS = [  # each number's one definition: id, name, what it counts, source, window and cutoff, how often it is read
    ('asks', 'Waiting on you', "each row of Main's ask list, and nothing else", "Main's ask list", 'now', 'every build'),
    ('landed', 'Landed', 'pull requests the fleet recorded as merged, each once, on the day of its first merge record',
     "each lead's merge lines in Main's records; Main's own merges from its fleet ledger",
     f"local days from midnight (UTC{OFF[:3]}:{OFF[3:]}); always at least: recording can be disabled or records unreadable", 'every build'),
    ('closed', 'Closed', 'backlog items marked done, merged or reported, on the day they closed', "each home's backlog and its done archive",
     'the last 7 local days, today so far, against the 7 days before', 'every build'),
    ('filed', 'Filed', 'backlog items on the day they were filed', "each home's open items, plus a log that keeps each filing day after the item closes",
     'local days; always at least: items filed and closed between readings can be missed; matching task IDs and filing dates count once across homes; a failed backlog read breaks coverage', 'every build'),
    ('lanes', 'Lanes open', 'ship and scout lanes, each in one state by its last status line', "each home's lane records",
     'now; unreadable homes are unknown, fleet counts are at least and free capacity is unknown; compared with the sample nearest 24 hours ago', 'every build; sampled every 10 minutes, kept 8 days'),
    ('stuck', 'Stuck', 'lanes blocked or waiting on a decision; age from the oldest one\'s last status', "each home's lane records",
     'now; compared with the sample nearest 24 hours ago', 'every build; sampled every 10 minutes, kept 8 days'),
    ('ready', 'Ready', 'queued items neither held nor waiting on another item', "each home's backlog",
     'now; compared with the sample nearest 24 hours ago', 'every build; sampled every 10 minutes, kept 8 days'),
    ('quota', 'Quota runs out', "even pace per window: elapsed = windowSeconds minus time until resetsAt at the reading; exhaustion = reading time plus (100 − percentUsed) × elapsed / percentUsed. All three fields must be present, with positive elapsed time inside the window; otherwise runway is unknown. Zero use lasts through reset. Each mark is elapsed share of the window; projections are estimates",
     'quota-axi cache ~/.cache/quota-axi/quotas.json, read-only; unavailable runway is unknown', 'as of each provider reading, retained when old', 'every build; ' + quota_stamp),
    ('leads', 'Lead state', 'what each lead home last published about itself; silent after 15 minutes without a new one',
     "each home's own summary, and Main's view of which leads are not running", 'now', 'every build'),
    ('machine', 'Machine and devices', 'free memory, memory pressure, heavy jobs, Gradle builds, emulators and who holds each device', 'this host and adb, read-only',
     'now; memory pressure is the share of the last 10 seconds some job waited on memory, the memory gate\'s own rule', 'every build'),
]
def measure_body():
    defs = ''.join(f'<div class="def" id="m-{i}"><h3>{esc(n)}</h3><dl><dt>Counts</dt><dd>{esc(c)}</dd><dt>Source</dt><dd>{esc(src)}</dd>'
                   f'<dt>Window</dt><dd>{esc(w)}</dd><dt>Read</dt><dd>{r}</dd></dl></div>' for i, n, c, src, w, r in METRICS)
    rrow = ''.join(item('warn', esc(t), '', esc(w)) for t, w in records)
    urow = ''.join(item('warn', esc(s), '', esc(r)) for s, r in notes)
    return f'''
<div class="hero">
{sh(f"Method · built {BUILT}, every {MAX_AGE} s")}
<h1>How each number is measured.</h1>
<p class="note"><a href="data.json">data.json</a> contains the same readings, coverage and lists, with build time and duration.</p>
<p class="lede">One definition per number. A source that cannot be read shows unknown and why, never a guess or a zero. Parked homes are left out{f" ({esc(', '.join(PARKED))})" if PARKED else ""}.</p>
</div>
<div class="sections">
<section class="wide defs">{defs}</section>
<section id="records" class="wide">
{sh("Records that disagree")}
<h2>{f'{plural(len(records), "place")} where two records give different answers.' if records else 'No two records disagree.'}</h2>
<div class="rows">{rrow}</div>
</section>
<section id="unknown" class="wide">
{sh("Sources not read")}
<h2>{f'{plural(len(notes), "source")} could not be read.' if notes else 'Every source was read.'}</h2>
<div class="rows">{urow}</div>
</section>
</div>
'''

# The pages, rendered after every source so each shell shows the full trust line.
notes = [(s, prose(r)) for s, r in notes]
pages = {'index.html': page('index', 'Fleet', index_body('action'), unknown_foot('backlog', 'herdr', 'quota', 'merge', 'closed', 'home summary')),
         'backlog.html': page('backlog', 'Fleet backlog', backlog_body('action'), unknown_foot('backlog', 'herdr', 'lane')),
         'backlog.home.html': page('backlog', 'Fleet backlog', backlog_body('home'), unknown_foot('backlog', 'herdr', 'lane')),
         'measure.html': page('measure', 'Fleet method', measure_body())}
for f, doc in pages.items():
    with open(os.path.join(OUT, f), 'w', encoding='utf-8') as fh: fh.write(doc)

def reading(value, mid, known=True, lower=False, reason=None, read_at=NOW_TS):
    definition = next(x for x in METRICS if x[0] == mid)
    return dict(value=value if known else None, status='unknown' if not known else 'lower_bound' if lower else 'exact',
                reason=prose(reason or why_of(mid)) if not known else None, source=definition[3],
                window=definition[4], cutoff=NOW_TS, read_at=read_at)
def lane_reading(value, h=None):
    return reading(value, 'lanes', known=h not in lane_err, lower=h is None and not LANES_KNOWN,
                   reason='lane records unavailable', read_at=lanes_read_at)
quota_known = bool(accounts) and not any(a['problem'] for a in accounts)
quota_value = dict(used_up=sum(a['empty'] for a in accounts),
                   soonest_runout=running_out[0]['runout'].timestamp() if running_out else None)
metrics = {
    'asks': reading(len(asks), 'asks', asks_known, reason='ask list unreadable', read_at=asks_read_at),
    'landed': reading(LANDED[-1], 'landed', lower=True, read_at=merges_read_at),
    'closed': reading(sum(CLOSED_N[7:]), 'closed', CLOSED_KNOWN, read_at=closed_read_at),
    'filed': reading(sum(FILED_N[7:]), 'filed', lower=True, read_at=backlog_read_at),
    'lanes': lane_reading(OPEN),
    'lane_states': lane_reading(SPLIT),
    'oldest_lane_seconds': lane_reading({s: max((max(0, NOW_TS - l['since']) for l in live if l['state'] == s), default=0) for s in STATES}),
    'lane_plan': reading(PLAN, 'lanes'),
    'free_lanes': reading(FREE, 'lanes', LANES_KNOWN, reason='lane records unavailable', read_at=lanes_read_at),
    'stuck': reading(STUCK, 'stuck', lower=not LANES_KNOWN, read_at=lanes_read_at),
    'ready': reading(QUEUE['ready'] if QUEUE else None, 'ready', bl_known, reason=why_of('backlog'), read_at=backlog_read_at),
    'queue': reading(QUEUE, 'ready', bl_known, reason=why_of('backlog'), read_at=backlog_read_at),
    'held_for_captain': reading(len(held_cap), 'ready', lower=not bl_known, read_at=backlog_read_at),
    'busy_agents': reading(sum(BUSY.values()), 'lanes', agents is not None, reason=why_of('herdr'), read_at=agents_read_at),
    'agent_roles': reading(BUSY, 'lanes', agents is not None, reason=why_of('herdr'), read_at=agents_read_at),
    'running_agents': reading(len(agent_rows), 'lanes', agents is not None, reason=why_of('herdr'), read_at=agents_read_at),
    'quota': reading(quota_value, 'quota', quota_known, reason='runway unavailable for some accounts', read_at=quota_times[0] if quota_times else None),
    'free_memory_gb': reading(free[0] if free else None, 'machine', free is not None, reason=mach['free_why'], read_at=machine_read_at),
    'total_memory_gb': reading(free[1] if free else None, 'machine', free is not None, reason=mach['free_why'], read_at=machine_read_at),
    'memory_pressure': reading(psi, 'machine', psi is not None, reason=mach['pressure_why'], read_at=machine_read_at),
    'gradle_builds': reading(mach['gradle'], 'machine', mach['gradle'] is not None, reason=mach['gradle_why'], read_at=machine_read_at),
    'emulators': reading(emu_count, 'machine', emu_count is not None, reason='emulator inventory unavailable', read_at=machine_read_at),
    'devices': reading(len(dev_rows), 'machine', lower=bool(dev_problems), read_at=machine_read_at),
    'device_groups': reading(device_groups, 'machine', not dev_problems, reason='device availability or inventory unavailable', read_at=machine_read_at),
    'connected_devices': reading(dev_count, 'machine', dev_count is not None, reason='adb inventory unavailable', read_at=machine_read_at),
}
metrics['quota'].update(read_at_latest=quota_times[-1] if quota_times else None, read_at_policy='oldest contributing account reading')
for key, value in zip(('heavy_jobs_gb', 'heavy_high_gb', 'heavy_max_gb'), mach['heavy']):
    metrics[key] = reading(value, 'machine', value is not None, reason=mach['heavy_why'], read_at=machine_read_at)
for key, values in (('landed', LANDED), ('closed', CLOSED_N), ('filed', FILED_N)):
    metrics[key]['daily'] = [dict(day=d.isoformat(), value=v if key != 'closed' or CLOSED_KNOWN else None) for d, v in zip(DAYS, values)]
for key in ('busy_agents', 'agent_roles', 'running_agents'):
    metrics[key].update(source='Herdr agent inventory', window='now')
metrics['lane_plan'].update(source='lane settings', window='configured plan')
metrics['queue'].update(window='now')
metrics['held_for_captain'].update(window='now')
data = dict(build_time=NOW.isoformat(), cutoff=NOW_TS, metrics=metrics,
    lanes=[dict(state=l['state'], home=l['home'], title=titles.get((l['home'], l['task'])) or l['task'],
                age_seconds=max(0, NOW_TS - l['since']), reason=prose(l['text'])) for l in live],
    queue_reasons=[dict(reason=n, by_home={h: count if backlog.get(h) is not None else None for h, count in v.items()}) for n, v, _ in QREASONS],
    homes=[dict(home=h, lead_state=lead_word(h)[0], summary_read_at=summaries_read_at, summary_generated_epoch=(sums[h] or {}).get('generated_epoch'),
                lanes=lane_reading(len(by_home[h]), h), plan=plan(h),
                free_lanes=reading(max(0, plan(h) - len(by_home[h])), 'lanes', h not in lane_err, reason='lane records unavailable', read_at=lanes_read_at),
                ready=reading(len(bl(h, 'ready')), 'ready', backlog.get(h) is not None, reason='backlog unavailable', read_at=backlog_read_at),
                landed=reading(landed_on(TODAY, h), 'landed', lower=True, read_at=merges_read_at),
                closed=reading(sum((closed[h] or {}).get(d, 0) for d in DAYS[7:]), 'closed', closed[h] is not None, reason='completion records unavailable', read_at=closed_read_at)) for h in ACTIVE],
    held_items=[dict(home=h, title=r['title'], reason=prose(r.get('hold_reason')), filed=r['day']) for h, r in held_all],
    recent_merges=[dict(home=h, title=done_title.get((h, task)) or titles.get((h, task)) or task, url=url, at=at)
                   for url, (at, h, task) in sorted(merges.items(), key=lambda x: -x[1][0])[:6]],
    quota_accounts=accounts, devices=[dict(zip(('name', 'where', 'detail', 'tone', 'holder'), r)) for r in dev_rows],
    machine={k: prose(v) if isinstance(v, str) else v for k, v in mach.items()},
    machine_limits=dict(emulators=EMU_MAX, gradle=GRADLE_MAX, min_memory_gb=MEM_MIN_GB, memory_pressure=40),
    agents=[dict(zip(('role', 'home', 'name', 'status'), a)) for a in agent_rows],
    lane_history=[dict(at=r[0], lanes=r[1] if r[1] >= 0 else None, stuck=r[2] if r[2] >= 0 else None,
                       ready=r[3] if r[3] >= 0 else None) for r in hist],
    parked_homes=PARKED, sources_unknown=[dict(source=s, reason=r) for s, r in notes], device_problems=dev_problems)
data['build_duration_seconds'] = time.monotonic() - BUILD_STARTED
with open(os.path.join(OUT, 'data.json'), 'w', encoding='utf-8') as fh:
    json.dump(data, fh, ensure_ascii=False, allow_nan=False, default=lambda v: v.isoformat())

# --- board.json: the one document the web app reads ----------------------
STAGES = [('queued', 'Queued'), ('building', 'Building'), ('review', 'Review'), ('test', 'Test'),
          ('ci', 'PR + CI'), ('merge', 'Waiting to merge'), ('landed', 'Landed today')]
RANK = {s: i for i, (s, _) in enumerate(STAGES)}
STEP = {'intent': 'review', 'rebase': 'review', 'review': 'review', 'test': 'test', 'document': 'test',
        'lint': 'test', 'push': 'ci', 'pr': 'ci', 'ci': 'ci'}
def line_stage(verb, key, text):
    s = re.search(r'^nm-.*?-(' + '|'.join(STEP) + r')(?:-fix\d+)?$', key or '')
    if s: return STEP[s.group(1)]
    pr = PR_URL.search(text)
    if verb == 'done': return 'merge' if pr and '/+/' not in pr.group() else 'review'
    if pr: return 'review' if '/+/' in pr.group() else 'ci'
    if re.search(r'no-mistakes|pipeline', text, re.I): return 'test' if re.search(r'\btest (step|gate)', text, re.I) else 'review'
    return None
def family(model, harness):  # the model family a lane runs on, else its tool
    m = (model or '').lower()
    for pat, fid, name in (('opus', 'opus', 'Opus'), ('sonnet', 'sonnet', 'Sonnet'), ('fable', 'fable', 'Fable'), ('haiku', 'haiku', 'Haiku'),
                           ('-sol', 'sol', 'Sol'), ('muse-spark', 'muse', 'Muse Spark'), ('qwen', 'qwen', 'Qwen'), ('grok', 'grok', 'Grok'),
                           ('gemini', 'gemini', 'Gemini'), ('kimi', 'kimi', 'Kimi'), ('deepseek', 'deepseek', 'DeepSeek'), ('gpt', 'gpt', 'GPT')):
        if pat in m: return fid, name
    return 'tool-' + (harness or 'unknown'), (harness or 'Unknown').capitalize()
disp = {}
for h in ACTIVE:
    if h in remote_hosts: continue
    try:
        with open(os.path.join(home_dir[h], 'state/fleet-ledger.jsonl'), encoding='utf-8', errors='replace') as fh:
            for l in fh:
                if '"task.dispatched"' not in l: continue
                try: e = json.loads(l)
                except ValueError: continue
                if not isinstance(e, dict) or not isinstance(e.get('ts'), int): continue
                if e.get('event') == 'task.dispatched' and isinstance(e.get('task'), str): disp.setdefault((h, e['task']), []).append(e)
    except OSError: pass  # a home without the ledger has no dispatch history
def dispatch(h, task, at=float('inf')):
    return max((e for e in reversed(disp.get((h, task), [])) if e['ts'] <= at), key=lambda e: e['ts'], default={})
VERBS = {'working': 'Working', 'resolved': 'Cleared', 'paused': 'Waiting', 'blocked': 'Blocked', 'needs-decision': 'Needs a decision',
         'done': 'Finished', 'failed': 'Failed', 'captain-held': 'Held by the captain'}
WAIT_OF = {'blocked': 'blocked', 'decision': 'decision', 'waiting': 'waiting'}
WAIT_VERBS = {'blocked': ('blocked', 'failed'), 'decision': ('needs-decision', 'captain-held', 'paused', 'blocked'), 'waiting': ('paused',)}
WAIT_VERBS['parked'] = WAIT_VERBS['decision']
def card(h, task, kind, title, stage, **kw):
    d = {} if stage == 'queued' else dispatch(h, task, kw['since']) if stage == 'landed' else dispatch(h, task)
    fid, fname = family(kw.pop('model', None) or d.get('model'), kw.get('tool') or d.get('harness'))
    return dict(dict(id=f'{h}/{task}', home=h, task=task, kind=kind, title=title, stage=stage, wait=None, wait_since=None, reached={},
                     state=stage, since=None, started=d.get('ts'), pr=None, why='', model=fid if d or kw.get('tool') else None,
                     model_name=fname, tool=d.get('harness'), effort=None, history=[]), **kw)
cards = []
for l in live:
    h, task, meta = l['home'], l['task'], l['meta']
    try: ls = [x.strip() for x in open(os.path.join(home_dir[h], 'state', task + '.status'), errors='replace') if x.strip()]
    except OSError: ls = []
    stage, entered, rows, at, reached, verbs, pr = 'building', None, [], None, {}, [], None
    for x in ls:
        v = re.match(r'^(?:\d{9,11}\s+)?([a-z][a-z-]*)', x)
        verb = v.group(1) if v else ''
        a = re.search(r'\[at=(\d+)\]', x)
        at = int(a.group(1)) if a else at
        k = re.search(r'\[key=([^\]]+)\]', x)
        text = x.split(':', 1)[1].strip() if ':' in x else ''
        pr = PR_URL.search(text) or pr
        s = line_stage(verb, k.group(1) if k else None, text)
        if meta.get('kind') == 'scout' and s and RANK[s] > RANK['review']: s = 'review'
        if s and s != stage: stage, entered = s, at
        if s and at: reached.setdefault(s, at)
        verbs.append((verb, at))
        rows.append(dict(at=at, v=verb, stage=stage, verb=VERBS.get(verb, verb.replace('-', ' ').capitalize() or 'Note'),
                         tone={'blocked': 'bad', 'failed': 'bad', 'needs-decision': 'warn', 'done': 'ok'}.get(verb, ''), text=prose(text)))
    # a captain hold parks the lane on purpose: it is not stuck and asks nothing of anyone
    wait, wait_since = 'parked' if l['held'] else {'blocked': 'blocked', 'failed': 'blocked', 'paused': 'waiting', 'needs-decision': 'decision'}.get(verbs[-1][0] if verbs else '', WAIT_OF.get(l['state'])), None
    for verb, a in reversed(verbs):  # the current wait began with the trailing run of lines that say it
        if verb not in WAIT_VERBS.get(wait, ()): break
        wait_since = a or wait_since
    d = dispatch(h, task)
    pr = PR_URL.fullmatch(meta.get('pr', '')) or pr
    pr = pr.group() if pr else None
    if pr in merges and merges[pr][1:] == (h, task): continue
    started = d.get('ts') or (rows[0]['at'] if rows else None) or l['since']
    cards.append(card(h, task, meta.get('kind'), titles.get((h, task)) or task.replace('-', ' '), stage, model=meta.get('model'), tool=meta.get('harness') or d.get('harness'),
                      wait=wait, wait_since=(wait_since or l['since']) if wait else None, reached=reached, state=l['state'], since=entered or started,
                      started=started, pr=pr, why=prose(l['text'])[:240], effort=meta.get('effort'), history=rows[-40:]))
# a merge line's title ends in its PR number, which the card shows as its own link
def landed_title(h, task): return re.sub(r'\s+PR \d+$', '', done_title.get((h, task)) or titles.get((h, task)) or task.replace('-', ' '))
for url, (at, h, task) in merges.items():
    if at >= midnight(TODAY) and h in ACTIVE:
        cards.append(card(h, task, 'ship', landed_title(h, task), 'landed', id=f'{h}/{task}@{url}', since=at, pr=url))
for h in ACTIVE:
    for r in bl(h, 'ready'):
        if any(c['home'] == h and c['task'] == r['id'] and c['stage'] != 'landed' for c in cards): continue
        cards.append(card(h, r['id'], r.get('kind') or 'ship', r['title'], 'queued', since=midnight(r['day']) if r['day'] else None))
# Cycle time: dispatch to merge, for each merged task whose dispatch is in a ledger.
cycles = sorted(at - d['ts'] for at, h, task in merges.values() if (d := dispatch(h, task, at)))
flow_text = probe(['bash', os.path.join(BIN, 'fm-flow.sh'), '--json', '--now', str(int(NOW_TS)), '--capacity'],
                  timeout=180, env=dict(os.environ, FM_HOME=HOME))[0]
flow, flow_error = None, None if flow_text is not None else 'Flow reader unavailable'
if flow_text is not None:
    try:
        flow = json.loads(flow_text)
        if not isinstance(flow, dict) or flow.get('schema') != 'fm-flow.v1':
            raise ValueError('unsupported flow observation format')
        for row in flow['lanes'] + flow['queue'] + flow['executed_24h'] + flow['executed_7d']:
            h, task = row['home'], row['task']
            row['display_title'] = titles.get((h, task)) or re.sub(r'\s+PR \d+$', '', done_title.get((h, task), '')) or 'Task name not recorded'
            row['display_reason'] = prose(row.get('reason', ''))
            why = row.get('why', '')
            if why.startswith('dependency:'):
                row['display_why'] = 'Waiting for: ' + ', '.join(titles.get((h, t.strip()), 'earlier work (name unavailable)') for t in why[11:].split(','))
            else:
                row['display_why'] = prose(why).replace('recorded active lanes', 'recorded active tasks').replace('lane cap:', 'Count limit:')
            if why:
                row['why'] = why.partition(':')[0] + ':'
            for wait in row.get('open_waits', []):
                wait['display_reason'] = prose(wait.get('reason', ''))
            row['pr'] = next((url for url, (at, mh, mt) in merges.items()
                              if (mh, mt) == (h, task) and at == row.get('times', {}).get('merged')), None)
        flow['limitations'] = len(flow['limitations'])
        cap = flow.get('capacity') or {}
        for job in cap.get('jobs', []):
            if job['owner']:
                job['owner']['display_title'] = titles.get((job['owner']['home'], job['owner']['task'])) or 'Task name not recorded'
        mac = cap.get('mac') or {}
        for key in ('simulators', 'android_pids'):
            if isinstance(mac.get(key), list):
                mac[key] = len(mac[key])
        for folder in cap.get('tmp', {}).get('top_folders') or []:
            folder['display_name'] = os.path.basename(folder.pop('path'))
    except (ValueError, KeyError, TypeError):
        flow, flow_error = None, 'Flow observations unreadable'
def read_stat(kind, script):
    text = probe(['bash', os.path.join(BIN, script), '--json', '--now', str(int(NOW_TS))],
                   timeout=10, env=dict(os.environ, FM_HOME=HOME))[0]
    if text is None:
        return None, f'{kind} statistics reader unavailable'
    try:
        data = json.loads(text)
        if not isinstance(data, dict) or data.get('schema') != f'fm-{kind.lower()}-stats.v1':
            raise ValueError(f'unsupported {kind.lower()} statistics format')
        data['limitations'] = len(data.get('limitations') or [])
    except (ValueError, KeyError, TypeError):
        return None, f'{kind} statistics unreadable'
    return data, None
models, models_error = read_stat('Model', 'fm-model-stats.sh')
skills, skills_error = read_stat('Skill', 'fm-skill-stats.sh')
def scrub(node):
    if isinstance(node, dict):
        for key in ('reason', 'source', 'gate_source', 'errors'):
            node.pop(key, None)
        for value in node.values(): scrub(value)
    elif isinstance(node, list):
        for value in node: scrub(value)
board = dict(
    schema='fm-dashboard-board.v1', generated=int(NOW_TS), stages=[dict(id=s, name=n) for s, n in STAGES],
    homes=[dict(id=h, name=hname(h), plan=plan(h), open=sum(c['home'] == h and c['stage'] not in ('queued', 'landed') for c in cards), ready=len(bl(h, 'ready')) if backlog.get(h) is not None else None,
                known=h not in lane_err) for h in ACTIVE],
    parked=PARKED, cards=cards, flow=flow, flow_error=flow_error,
    models=models, models_error=models_error,
    skills=skills, skills_error=skills_error,
    asks=[dict(id=f[0], text=f[2], url=f[3] if len(f) > 3 else '', age=a) for f, a in asks] if asks_known else None,
    landed=LANDED, cycle_p50=cycles[(len(cycles) - 1) // 2] if len(cycles) >= 5 else None)
scrub(board)
with open(os.path.join(OUT, 'board.json'), 'w', encoding='utf-8') as fh:
    json.dump(board, fh, ensure_ascii=False, allow_nan=False, separators=(',', ':'))
PY
# The index lands last, so its time is the time the whole set was built.
for f in "$tmp"/*.html "$tmp"/*.json; do
  [ "$(basename "$f")" = index.html ] && continue
  mv -f "$f" "$out_dir/" || { echo "fm-dashboard: cannot write $out_dir/$(basename "$f")" >&2; exit 1; }
done
mv -f "$tmp/index.html" "$page" || { echo "fm-dashboard: cannot write $page" >&2; exit 1; }
printf '%s\n' "$page"
