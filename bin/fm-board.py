#!/usr/bin/env python3
# Captain dashboard daemon and CLI, Python 3.14, standard library only.
#
# Config owner: config/board.json (or --config /absolute/file, FM_BOARD_CONFIG).
# Required: homes=[{"id":"Main","path":"/absolute/home"}, ...], lan_host
# (one DNS name or IP, no scheme/port), port (1..65535), secret (>=24 characters),
# repo_tags={"repository-name":"WOK", ...}. Optional: github_boards={} (reserved,
# never queried in phase 1). FM_HOME is the absolute owning home; source homes
# are read-only. Paths are canonicalized; ids are unique path-safe slugs.
# Tags: WOK,CES,MF,CSLS-OG,JVP,WM,FM,Charlier. Unknown repos display as FM.
# Config is private: chmod 600. HTTP is plaintext on the trusted private LAN.
# Bind only lan_host; Host must equal lan_host:port (port optional only at 80).
# Origin, when supplied, must equal http://lan_host:port. No CORS is granted.
#
# Explicit HTTP routes (no filesystem browsing):
# GET / -> dashboard.html; GET /api/state[?project=TAG] -> rev, generated_at,
# homes (last_ok, ingest_error, age_s, stale), tasks, decisions, events,
# connection {transport, github}, counts. GET /healthz -> ok, db_ok,
# ingest_age_s (by home), last_snapshot_ms (by home), sse_clients,
# outbox_backlog, answers_armed, ingest_error (by home).
# GET /events -> SSE event: changed, id: rev, data: {rev,generated_at}; also
# event: heartbeat every 15 s also carries homes (last_ok/error/age/stale), so
# timestamp-only freshness updates require no JSON polling. Initial changed sent.
# Each client has one coalescing notification slot, 20 s socket timeout,
# at most 32 clients. No SQLite transaction is held while streaming.
# POST /answer -> {home,task,key,revision,choice,note?,device?}; /answers ->
# {answers:[same,...]} (1..50), atomic all-or-nothing. Authorization: Bearer <secret> is required
# on EVERY API request; GET / is the bookmark bootstrap; size <=65536 bytes. 403 auth/Host/Origin, 409 stale returns
# current decision, 400 invalid input. Idempotency: identity/revision/choice/
# SHA256(note). Answers are queued for 15 s, then routed and sent, NEVER
# consumed by POST. /answer also accepts {action:"undo",answer_id}; only while
# queued and before its deadline. {action:"correction",answer_id,note} queues
# a correction request for a consumed answer without reopening its decision.
# Legacy choice values: custom (note required), request-options.
#
# SQLite: WAL, busy_timeout=5000, user_version=1 plus schema_version table.
# Every visible committing transaction bumps meta.rev ONCE; bookkeeping-only
# timestamps/fingerprints do not. All readers use per-call connections.
# Private runtime: state/board.sqlite, board-inbox/answers.jsonl and cursor,
# board-refresh, board-daemon.lock, backups/board-<date>-<uuid>.sqlite,
# logs/board*.log. Backup via VACUUM INTO nightly; keep seven. Events retained
# 30 days. stdout/stderr log files rotate at 5 MiB when owned by the daemon.
#
# Ingest: one worker; tick every 5 s coalesces into a dirty event. Explicit
# file fingerprints only (meta/status/backlog/report), per-id reads <=10 s;
# full snapshot only startup/15 min/manual refresh/wake, <=90 s. Last-good
# rows survive failure; vanished tasks become unknown on partial passes and
# tombstoned on a complete pass. Timestamp-only churn does not change rev.
#
# Queue: SQLite is authoritative. Ready answers route in one single-flight
# handler directly, without JSONL on the main path. Only errors export to JSONL.
# POST /internal/reload (Bearer auth, 127.0.0.1 only, same port) immediately
# notifies SSE after decision/live CLI writes. /api/state uses rev as its ETag.
# Outbox: flock serializes exception export and routing across instances.
# Atomic replace publishes one complete jsonl burst; answer_id scans recover
# crash after publication but before exported_at. The non-destructive source
# reads from its acknowledged cursor; handler advances it only after capture.
# Legacy integer cursors are accepted without rebasing; old lines without ids
# remain human-review exceptions and never block new UUID exports.
# Routing uncertainty after a crash is surfaced, never automatically re-sent.
# The board-answers adapter advances the exception cursor after durable capture;
# its unacknowledged exception packet wakes firstmate. Successful routes never
# fire a source. CLI answered records consumption after firstmate handles errors.
# The daemon maintains the registered runner; graceful SIGTERM stops its child
# runner without retiring pending captures. No LLM, browser, or GitHub calls.

import argparse
import contextlib
import csv
import datetime
import fcntl
import hashlib
import hmac
import http.server
import io
import ipaddress
import json
import os
from pathlib import Path
import queue
import re
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import urllib.error
import uuid

ROOT = Path(__file__).resolve().parent.parent
TAGS = ('WOK', 'CES', 'MF', 'CSLS-OG', 'JVP', 'WM', 'FM', 'Charlier')
SLUG = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]{0,119}\Z')


class Invalid(ValueError):
    pass


class Conflict(Invalid):
    def __init__(self, message, current=None):
        super().__init__(message)
        self.current = current


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def text(value, name, limit=2000, empty=False):
    if not isinstance(value, str) or len(value) > limit or (not empty and not value.strip()):
        raise Invalid(f'invalid {name}')
    if any(ord(c) < 32 and c not in '\n\t' for c in value):
        raise Invalid(f'invalid control character in {name}')
    return value


def slug(value, name):
    if not isinstance(value, str) or not SLUG.fullmatch(value):
        raise Invalid(f'invalid {name}')
    return value


def url(value):
    text(value, 'URL', 2048)
    p = urllib.parse.urlsplit(value)
    if p.scheme not in ('http', 'https') or not p.hostname or p.username or any(c.isspace() for c in value):
        raise Invalid('URL must be absolute http or https without credentials')
    return value


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        dfd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


@contextlib.contextmanager
def file_lock(path, blocking=True):
    with open(path, 'a') as f:
        fcntl.flock(f, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        yield


def run(argv, home, timeout=10, input_data=None):
    env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE=str(ROOT))
    # Isolate homes from inherited per-session overrides.
    for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
        env.pop(key, None)
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
        p = subprocess.Popen((['nice', '-n', '10'] if Path(argv[0]).name in ('tasks-axi', 'fm-crew-state.sh', 'fm-fleet-snapshot.sh', 'bash') else []) + [str(a) for a in argv], cwd=home, env=env,
                             stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
                             stdout=out, stderr=err, start_new_session=True)
        try:
            p.communicate(input_data.encode() if input_data is not None else None, timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
            raise Invalid(f'{Path(argv[0]).name}: timeout after {timeout}s') from None
        if p.returncode:
            err.seek(0)
            reason = err.read(500).decode('utf-8', 'replace').strip().replace('\n', ' ')
            raise Invalid(f'{Path(argv[0]).name}: exit {p.returncode}: {reason}')
        out.seek(0)
        result = out.read(8 * 1024 * 1024 + 1)
        if len(result) > 8 * 1024 * 1024:
            raise Invalid(f'{Path(argv[0]).name}: output too large')
        return result.decode('utf-8', 'replace')


class Board:
    def __init__(self, config=None):
        own = os.environ.get('FM_HOME', '')
        if not own or not Path(own).is_absolute() or not Path(own).is_dir():
            raise Invalid('FM_HOME must name an existing absolute directory')
        self.home = Path(own).resolve()
        self.config_path = Path(config or os.environ.get('FM_BOARD_CONFIG', self.home / 'config/board.json')).resolve()
        self.config = json.loads(self.config_path.read_text())
        if not isinstance(self.config, dict):
            raise Invalid('config must be an object')
        c = self.config
        self.secret = text(c.get('secret'), 'secret', 512)
        if len(self.secret) < 24:
            raise Invalid('secret must contain at least 24 characters')
        host = text(c.get('lan_host'), 'lan_host', 253)
        try:
            ipaddress.ip_address(host)
        except ValueError:
            if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?', host):
                raise Invalid('invalid lan_host') from None
        self.host = host.lower()
        self.port = c.get('port')
        if type(self.port) is not int or not 1 <= self.port <= 65535:
            raise Invalid('port must be between 1 and 65535')
        authority = f'[{self.host}]' if ':' in self.host else self.host
        self.authority = f'{authority}:{self.port}'
        self.origins = {f'http://{self.authority}'}
        self.authorities = {self.authority}
        if self.port == 80:
            self.authorities.add(authority)
            self.origins.add(f'http://{authority}')
        self.homes = {}
        if not isinstance(c.get('homes'),list) or any(not isinstance(h,dict) for h in c['homes']):
            raise Invalid('homes must be an array of home objects')
        for h in c['homes']:
            hid = slug(h.get('id'), 'home id')
            path = Path(text(h.get('path'), 'home path', 4096))
            if not path.is_absolute() or not path.is_dir() or hid in self.homes:
                raise Invalid('homes must be unique ids with existing absolute paths')
            self.homes[hid] = path.resolve()
        if not self.homes or len(set(self.homes.values())) != len(self.homes):
            raise Invalid('homes must contain distinct sources')
        self.repo_tags = c.get('repo_tags', {})
        if not isinstance(self.repo_tags, dict) or any(not k or v not in TAGS for k, v in self.repo_tags.items()):
            raise Invalid('repo_tags must map repositories to known project tags')
        self.state = self.home / 'state'
        self.state.mkdir(mode=0o700, exist_ok=True)
        for directory in ('board-inbox', 'backups', 'logs'):
            (self.state / directory).mkdir(mode=0o700, exist_ok=True)
        self.db = self.state / 'board.sqlite'
        self.stop = threading.Event()
        self.dirty = threading.Event()
        self.ingest_lock = threading.Lock()
        self.clients = set()
        self.client_lock = threading.Lock()
        self.runner = None
        self.armed = False
        self.source_id = 'board-answers-' + hashlib.sha256(str(self.home).encode()).hexdigest()[:16]
        self.migrate()

    @contextlib.contextmanager
    def connect(self):
        con = sqlite3.connect(self.db, timeout=5)
        con.row_factory = sqlite3.Row
        con.execute('PRAGMA busy_timeout=5000')
        try:
            yield con
        finally:
            con.close()

    def migrate(self):
        with self.connect() as c:
            version = c.execute('PRAGMA user_version').fetchone()[0]
            if version > 1:
                raise Invalid('database schema is newer than this daemon')
            c.execute('PRAGMA journal_mode=WAL')
            c.executescript('''
                CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);
                INSERT INTO schema_version SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_version);
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                INSERT OR IGNORE INTO meta VALUES('rev','0');
                INSERT OR IGNORE INTO meta VALUES('generated_at','');
                CREATE TABLE IF NOT EXISTS projects(tag TEXT,home_id TEXT,repo TEXT,board_url TEXT,
                    PRIMARY KEY(home_id,repo));
                CREATE TABLE IF NOT EXISTS tasks(home_id TEXT,task_id TEXT,title TEXT,kind TEXT,
                    current_state TEXT,worker TEXT,pr_url TEXT,project TEXT,last_status TEXT,
                    updated_at TEXT,deleted_at TEXT,meta_present INTEGER,
                    PRIMARY KEY(home_id,task_id));
                CREATE TABLE IF NOT EXISTS decisions(home_id TEXT,task_id TEXT,decision_key TEXT,
                    revision INTEGER,question TEXT,options TEXT,recommendation TEXT,why TEXT,
                    source TEXT,state TEXT,asked_at TEXT,closed_at TEXT,project TEXT,
                    origin_id TEXT,registered INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(home_id,task_id,decision_key,revision));
                CREATE TABLE IF NOT EXISTS events(event_id TEXT PRIMARY KEY,home_id TEXT,task_id TEXT,
                    kind TEXT,project TEXT,message TEXT,url TEXT,environment TEXT,verified_at TEXT,
                    evidence TEXT,created_at TEXT);
                CREATE TABLE IF NOT EXISTS answers(answer_id TEXT PRIMARY KEY,home_id TEXT,
                    task_id TEXT,decision_key TEXT,revision INTEGER,choice TEXT,note TEXT,note_hash TEXT,
                    device TEXT,received_at TEXT,ready_at REAL,exported_at TEXT,consumed_at TEXT,
                    error TEXT,cancelled_at TEXT,routing_at TEXT,action TEXT DEFAULT 'answer',
                    UNIQUE(home_id,task_id,decision_key,revision,choice,note_hash));
                CREATE TABLE IF NOT EXISTS board_items(item_id TEXT PRIMARY KEY,project TEXT,
                    payload TEXT,fetched_at TEXT,stale INTEGER);
                CREATE TABLE IF NOT EXISTS ingest_runs(home_id TEXT PRIMARY KEY,last_ok TEXT,
                    last_error TEXT,duration_ms INTEGER,last_snapshot_ms INTEGER);
                CREATE TABLE IF NOT EXISTS fingerprints(home_id TEXT,path TEXT,value TEXT,
                    PRIMARY KEY(home_id,path));
                CREATE TABLE IF NOT EXISTS backlog(home_id TEXT,task_id TEXT,payload TEXT,
                    PRIMARY KEY(home_id,task_id));
                PRAGMA user_version=1;
            ''')
            c.commit()
        os.chmod(self.db, 0o600)

    @contextlib.contextmanager
    def write(self):
        with self.connect() as c:
            c.execute('BEGIN IMMEDIATE')
            visible = [False]
            try:
                yield c, visible
                if visible[0]:
                    c.execute("UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='rev'")
                    c.execute("UPDATE meta SET value=? WHERE key='generated_at'", (stamp(),))
                c.commit()
            except BaseException:
                c.rollback()
                raise

    def hid(self, value):
        if value in self.homes:
            return value
        match = [hid for hid, path in self.homes.items() if str(path) == value]
        if not match:
            raise Invalid('unknown configured home')
        return match[0]

    def latest(self, c, hid, task, key):
        return c.execute('SELECT * FROM decisions WHERE home_id=? AND task_id=? AND decision_key=? ORDER BY revision DESC LIMIT 1', (hid, task, key)).fetchone()

    @staticmethod
    def decision_dict(row):
        if row is None:
            return None
        d = dict(row)
        d['options'] = json.loads(d['options'])
        return d

    def upsert_decision(self, c, changed, hid, task, key, question, options, rec, why,
                        source, project, origin='', registered=False):
        prior = self.latest(c, hid, task, key)
        fields = dict(question=question, options=json.dumps(options), recommendation=rec,
                      why=why, source=source, project=project, origin_id=origin, registered=int(registered))
        if prior and all(prior[k] == v for k, v in fields.items()) and prior['state'] != 'closed':
            return prior['revision']
        rev = prior['revision'] + 1 if prior else 1
        if prior and prior['state'] in ('queued', 'sent'):
            raise Conflict('cannot revise a decision with an outstanding answer', self.decision_dict(prior))
        if prior:
            c.execute('UPDATE decisions SET state=\'closed\',closed_at=? WHERE home_id=? AND task_id=? AND decision_key=? AND revision=?',
                      (stamp(), hid, task, key, prior['revision']))
        c.execute('INSERT INTO decisions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                  (hid, task, key, rev, question, fields['options'], rec, why, source, 'open', stamp(), None, project, origin, int(registered)))
        changed[0] = True
        return rev

    def register(self, args):
        hid = self.hid(args.home)
        slug(args.task, 'task'); slug(args.key, 'key')
        options = []
        for option in args.option:
            match = re.fullmatch(r'([A-Z0-9]):\s*(.+)', option, re.S)
            if not match:
                raise Invalid('option must have the form A: wording')
            label, wording = match.groups()
            text(wording, 'option', 1000)
            if any(o['value'] == label for o in options):
                raise Invalid('duplicate option value')
            options.append({'value': label, 'label': wording})
        if not 1 <= len(options) <= 9 or (args.rec and args.rec not in [o['value'] for o in options]):
            raise Invalid('need 1..9 options and a matching recommendation')
        text(args.title, 'title', 1000); text(args.why, 'why', empty=True)
        with self.write() as (c, changed):
            prior = self.latest(c, hid, args.task, args.key)
            source = prior['source'] if prior else 'firstmate'
            origin = prior['origin_id'] if prior else ''
            rev = self.upsert_decision(c, changed, hid, args.task, args.key, args.title, options,
                                       args.rec, args.why, source, args.project, origin, True)
        self.reload()
        return {'revision': rev}

    def reload(self):
        request = urllib.request.Request(f'http://127.0.0.1:{self.port}/internal/reload',
            data=b'{}',headers={'Authorization':f'Bearer {self.secret}'},method='POST')
        try:
            with urllib.request.urlopen(request,timeout=1) as response:
                response.read()
        except (OSError,urllib.error.URLError):
            pass  # CLI writes remain valid while the daemon is stopped.

    def project(self, repo):
        return self.repo_tags.get(repo, 'FM')

    def manifest(self, home):
        paths = [home / 'data/backlog.md']
        paths += list((home / 'state').glob('*.meta')) + list((home / 'state').glob('*.status'))
        paths += list((home / 'data').glob('*/report.md'))
        result = {}
        for path in paths:
            if path.name.startswith('.') or path.is_symlink():
                continue
            try:
                s = path.stat()
                result[str(path.relative_to(home))] = f'{s.st_mtime_ns}:{s.st_size}:{s.st_ino}'
            except FileNotFoundError:
                pass
        return result

    def backlog_rows(self, home):
        rows = {}
        for state in ('held', 'in_flight'):
            output = run(['tasks-axi', 'list', '--state', state, '--fields',
                          'hold_kind,hold_reason,blocked,blocked_by', '--limit', '10000'], home)
            if not re.search(r'^[A-Za-z_ -]+(?:\[\d+\]|:)', output, re.M):
                raise Invalid('tasks-axi list: invalid response')
            for line in output.splitlines():
                if not line.startswith('  ') or ',' not in line:
                    continue
                values = next(csv.reader(io.StringIO(line.strip())))
                if len(values) < 9:
                    raise Invalid('tasks-axi list: unexpected row shape')
                tid, actual, kind, repo, title, hold_kind, reason, blocked, blockers = values[:9]
                slug(tid, 'backlog task')
                row = dict(id=tid, state=actual, kind=kind, repo=repo, title=title,
                           hold_kind=hold_kind, reason=reason.replace('\\n', ' '),
                           blocked=blocked, blockers=blockers)
                # held listing overlaps canonical state listings.
                rows[tid] = row
        for row in rows.values():
            blockers = [x.strip() for x in re.split(r'[|;\s,]+', row['blockers']) if x.strip() not in ('', '-', 'none', '[]')]
            unresolved = blockers  # tasks-axi blocked_by already contains only active blockers
            row['captain_actionable'] = (row['state'] == 'queued' and row['kind'] == 'captain'
                and row['hold_kind'] == 'captain' and row['reason'] not in ('', '-')
                and not unresolved and row['blocked'].lower() not in ('true', 'yes', '1'))
        return rows

    def task_row(self, hid, task, home, backlog, snapshot=None):
        meta = {}
        for line in (home / f'state/{task}.meta').read_text().splitlines():
            if '=' in line:
                k, v = line.split('=', 1)
                meta[k] = v.strip()
        if meta.get('kind') == 'secondmate':
            return None, []
        status = home / f'state/{task}.status'
        last = ''
        if status.exists():
            with status.open('rb') as f:
                f.seek(max(0, status.stat().st_size - 8192))
                lines = f.read().decode('utf-8', 'replace').splitlines()
                last = next((x for x in reversed(lines) if x.strip()), '')
        if snapshot is None:
            combined = run(['bash','-c',
                'source "$1"; "$2" "$3" || exit; printf "\\n__DECISIONS__\\n"; status_open_decisions "$4"',
                'board',ROOT / 'bin/fm-classify-lib.sh',ROOT / 'bin/fm-crew-state.sh',task,status],home)
            current, folded = combined.split('\n__DECISIONS__\n',1)
            match = re.search(r'^state: ([a-z-]+)',current)
            if not match:
                raise Invalid('fm-crew-state: invalid response')
            current = match.group(1)
        else:
            current = snapshot['current_state']['state']
            folded = run(['bash','-c','source "$1"; status_open_decisions "$2"',
                          'board',ROOT / 'bin/fm-classify-lib.sh',status],home)
        decisions = []
        for line in folded.splitlines():
            key, verb, summary = line.split('\t', 2)
            decisions.append((key, summary))
        b = backlog.get(task, {})
        repo = b.get('repo') or meta.get('project', '')
        return dict(home_id=hid, task_id=task, title=b.get('title') or task, kind=meta.get('kind', 'task'),
                    current_state=current, worker=' '.join(filter(None, [meta.get('harness'), meta.get('model')])),
                    pr_url=meta.get('pr', ''), project=self.project(repo), last_status=last, meta_present=1), decisions

    def update_task(self, c, changed, row):
        old = c.execute('SELECT * FROM tasks WHERE home_id=? AND task_id=?', (row['home_id'], row['task_id'])).fetchone()
        if old and all(old[k] == v for k, v in row.items()) and old['deleted_at'] is None:
            return
        columns = list(row) + ['updated_at', 'deleted_at']
        values = list(row.values()) + [stamp(), None]
        c.execute(f'INSERT OR REPLACE INTO tasks ({",".join(columns)}) VALUES ({",".join("?" for _ in columns)})', values)
        changed[0] = True
        last = row['last_status']
        if last and (not old or old['last_status'] != last):
            kind = 'built' if re.match(r'done(?:\s*\[.*?\])?:', last) else 'status'
            eid = hashlib.sha256(f'{row["home_id"]}|{row["task_id"]}|{last}'.encode()).hexdigest()
            c.execute('INSERT OR IGNORE INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                      (eid, row['home_id'], row['task_id'], kind, row['project'], last, '', '', '', '', stamp()))
            # A prose LIVE token alone cannot establish environment and verification time.
            live = re.fullmatch(r'done: LIVE - (.+) verified on (https?://\S+) \[env=([^\]]+) verified_at=([^\]]+)\]', last)
            if live:
                message, link, environment, verified = live.groups()
                try:
                    url(link)
                    when = datetime.datetime.fromisoformat(verified)
                    if when.tzinfo is None:
                        raise ValueError('timezone missing')
                    c.execute('INSERT OR IGNORE INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?)',
                              (eid + '-live', row['home_id'], row['task_id'], 'live', row['project'], message,
                               link, environment, verified, last, stamp()))
                except ValueError:
                    pass

    def ingest_home(self, hid, reconcile=False):
        started = time.monotonic()
        home = self.homes[hid]
        try:
            fresh = self.manifest(home)
        except OSError as e:
            with self.write() as (c, changed):
                c.execute('INSERT INTO ingest_runs(home_id,last_error) VALUES(?,?) ON CONFLICT(home_id) DO UPDATE SET last_error=excluded.last_error', (hid,str(e)))
                changed[0] = True
            return str(e)
        with self.connect() as c:
            old = dict(c.execute('SELECT path,value FROM fingerprints WHERE home_id=?', (hid,)))
            backlog = {r['task_id']: json.loads(r['payload']) for r in c.execute('SELECT * FROM backlog WHERE home_id=?', (hid,))}
        moved = {p for p in set(old) | set(fresh) if old.get(p) != fresh.get(p)}
        ids = {Path(p).stem for p in moved if p.startswith('state/')}
        ids |= {Path(p).parent.name for p in moved if p.endswith('/report.md')}
        error = None
        snapshots = {}
        snapshot_ms = None
        if reconcile:
            before = time.monotonic()
            try:
                snap = json.loads(run([ROOT / 'bin/fm-fleet-snapshot.sh', '--json'], home, 90))
                snapshots = {x['id']: x for x in snap['tasks']}
                snapshot_ms = int((time.monotonic() - before) * 1000)
            except (Invalid, ValueError, KeyError) as e:
                error = str(e)
        backlog_changed = 'data/backlog.md' in moved or not old or reconcile
        if backlog_changed:
            try:
                new_backlog = self.backlog_rows(home)
                ids |= {tid for tid in set(backlog) | set(new_backlog) if backlog.get(tid) != new_backlog.get(tid)}
                backlog = new_backlog
            except (Invalid, ValueError) as e:
                error = str(e)
        present = {Path(p).stem for p in fresh if p.endswith('.meta')}
        if reconcile:
            ids |= present
        updates = []
        for tid in sorted(ids & present):
            try:
                slug(tid, 'task')
                updates.append((tid, *self.task_row(hid, tid, home, backlog, snapshots.get(tid))))
            except (OSError, Invalid, ValueError, KeyError) as e:
                error = str(e)
        with self.write() as (c, changed):
            for tid, row, decisions in updates:
                if row is None:
                    continue
                self.update_task(c, changed, row)
                open_keys = set()
                for key, summary in decisions:
                    open_keys.add(key)
                    prior = self.latest(c, hid, tid, key)
                    if prior and prior['registered'] and prior['source'] == 'firstmate':
                        c.execute("UPDATE decisions SET source='worker' WHERE home_id=? AND task_id=? AND decision_key=? AND revision=?", (hid,tid,key,prior['revision']))
                        changed[0] = True
                    if prior and (prior['registered'] or prior['state'] in ('queued', 'sent', 'consumed', 'failed')):
                        continue
                    self.upsert_decision(c, changed, hid, tid, key, summary, [], '', '', 'worker', row['project'])
                for prior in c.execute("SELECT * FROM decisions WHERE home_id=? AND task_id=? AND source='worker' AND state='open'", (hid, tid)).fetchall():
                    if prior['decision_key'] not in open_keys:
                        c.execute("UPDATE decisions SET state='closed',closed_at=? WHERE home_id=? AND task_id=? AND decision_key=? AND revision=?",
                                  (stamp(), hid, tid, prior['decision_key'], prior['revision']))
                        changed[0] = True
            for tid, b in backlog.items():
                was_worker = c.execute('SELECT meta_present FROM tasks WHERE home_id=? AND task_id=?', (hid,tid)).fetchone()
                if tid not in present and b['state'] != 'done' and not (was_worker and was_worker['meta_present']):
                    self.update_task(c, changed, dict(home_id=hid, task_id=tid, title=b['title'], kind=b['kind'],
                        current_state='paused' if b['hold_kind'] not in ('', '-') else b['state'], worker='',
                        pr_url='', project=self.project(b['repo']), last_status=b['reason'] if b['reason'] != '-' else '', meta_present=0))
                if b['captain_actionable']:
                    origin, sep, key = tid.rpartition('-decision-')
                    if not sep:
                        origin, key = tid, 'default'
                    prior = self.latest(c, hid, tid, key)
                    if prior and prior['registered']:
                        continue
                    self.upsert_decision(c, changed, hid, tid, key, b['title'] + ': ' + b['reason'], [], '', '',
                                         'hold', self.project(b['repo']), origin, bool(sep))
            if not error:
                for prior in c.execute("SELECT * FROM decisions WHERE home_id=? AND source='hold' AND state='open'", (hid,)).fetchall():
                    if not backlog.get(prior['task_id'], {}).get('captain_actionable'):
                        c.execute("UPDATE decisions SET state='closed',closed_at=? WHERE home_id=? AND task_id=? AND decision_key=? AND revision=?",
                                  (stamp(), hid, prior['task_id'], prior['decision_key'], prior['revision']))
                        changed[0] = True
            for row in c.execute('SELECT * FROM tasks WHERE home_id=? AND deleted_at IS NULL', (hid,)).fetchall():
                vanished = row['task_id'] not in present if row['meta_present'] else row['task_id'] not in backlog or backlog[row['task_id']]['state'] == 'done'
                if vanished:
                    if error:
                        if row['current_state'] != 'unknown':
                            c.execute("UPDATE tasks SET current_state='unknown' WHERE home_id=? AND task_id=?", (hid, row['task_id']))
                            changed[0] = True
                    else:
                        c.execute('UPDATE tasks SET deleted_at=? WHERE home_id=? AND task_id=?', (stamp(), hid, row['task_id']))
                        changed[0] = True
            prior = c.execute('SELECT * FROM ingest_runs WHERE home_id=?', (hid,)).fetchone()
            if (prior['last_error'] if prior else None) != error:
                changed[0] = True
            c.execute('INSERT OR REPLACE INTO ingest_runs VALUES(?,?,?,?,?)',
                      (hid, prior['last_ok'] if error and prior else (None if error else stamp()), error,
                       int((time.monotonic()-started)*1000), snapshot_ms if snapshot_ms is not None else (prior['last_snapshot_ms'] if prior else None)))
            if not error:
                c.execute('DELETE FROM fingerprints WHERE home_id=?', (hid,))
                c.executemany('INSERT INTO fingerprints VALUES(?,?,?)', [(hid, k, v) for k, v in fresh.items()])
                c.execute('DELETE FROM backlog WHERE home_id=?', (hid,))
                c.executemany('INSERT INTO backlog VALUES(?,?,?)', [(hid, tid, json.dumps(b)) for tid, b in backlog.items()])
                for repo, tag in self.repo_tags.items():
                    c.execute('INSERT OR REPLACE INTO projects VALUES(?,?,?,?)', (tag, hid, repo, ''))
        return error

    def ingest(self, only=None, reconcile=False):
        if not self.ingest_lock.acquire(blocking=False):
            self.dirty.set()
            return
        try:
            with file_lock(self.state / 'board-ingest.lock', blocking=False):
                errors = [self.ingest_home(hid, reconcile) for hid in ([self.hid(only)] if only else self.homes)]
                if any(errors):
                    raise Invalid('; '.join(e for e in errors if e))
        except BlockingIOError:
            self.dirty.set()
        finally:
            self.ingest_lock.release()

    def state_payload(self, project=None):
        if project and project not in TAGS and project != 'All':
            raise Invalid('unknown project')
        with self.connect() as c:
            c.execute('BEGIN')
            meta = dict(c.execute('SELECT key,value FROM meta'))
            tasks = [dict(r) for r in c.execute('SELECT * FROM tasks WHERE deleted_at IS NULL ORDER BY home_id,task_id')]
            decisions = [self.decision_dict(r) for r in c.execute('''SELECT d.* FROM decisions d
                WHERE revision=(SELECT max(revision) FROM decisions x WHERE x.home_id=d.home_id AND x.task_id=d.task_id AND x.decision_key=d.decision_key)
                AND (state NOT IN ('closed','consumed') OR (state='consumed' AND closed_at>?)) ORDER BY asked_at''',
                ((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=1)).isoformat(),))]
            for d in decisions:
                answer = c.execute('SELECT * FROM answers WHERE home_id=? AND task_id=? AND decision_key=? AND revision=? AND cancelled_at IS NULL ORDER BY received_at DESC LIMIT 1',
                                   (d['home_id'], d['task_id'], d['decision_key'], d['revision'])).fetchone()
                d['answer'] = dict(answer) if answer else None
            events = [dict(r) for r in c.execute('SELECT * FROM events ORDER BY created_at DESC LIMIT 500')]
            runs = {r['home_id']: dict(r) for r in c.execute('SELECT * FROM ingest_runs')}
        homes = []
        for hid in self.homes:
            r = runs.get(hid, {})
            age = self.age(r.get('last_ok'))
            homes.append(dict(id=hid, last_ok=r.get('last_ok'), age_s=age, stale=age is None or age > 60,
                              ingest_error=r.get('last_error')))
        counts = {tag: sum(1 for d in decisions if d['project'] == tag and d['state'] != 'consumed') for tag in TAGS}
        counts['All'] = sum(counts.values())
        if project and project != 'All':
            tasks = [r for r in tasks if r['project'] == project]
            decisions = [r for r in decisions if r['project'] == project]
            events = [r for r in events if r['project'] == project]
        return dict(rev=int(meta['rev']), generated_at=meta['generated_at'], homes=homes, tasks=tasks,
                    decisions=decisions, events=events, counts=counts,
                    connection={'transport':'sse', 'github':'Not connected yet'})

    @staticmethod
    def age(value):
        return max(0, int(time.time() - datetime.datetime.fromisoformat(value).timestamp())) if value else None

    def answer(self, records):
        if not isinstance(records, list) or not 1 <= len(records) <= 50:
            raise Invalid('answers must contain 1..50 records')
        result = []
        with self.write() as (c, changed):
            for a in records:
                if not isinstance(a, dict):
                    raise Invalid('answer must be an object')
                hid = self.hid(a.get('home', ''))
                tid = slug(a.get('task'), 'task'); key = slug(a.get('key'), 'key')
                d = self.latest(c, hid, tid, key)
                if not d:
                    raise Invalid('unknown decision')
                if type(a.get('revision')) is not int or d['revision'] != a['revision']:
                    raise Conflict('stale decision revision', self.decision_dict(d))
                choice = text(a.get('choice'), 'choice', 200)
                note = text(a.get('note', ''), 'note', empty=True)
                device = text(a.get('device', ''), 'device', 120, empty=True)
                opts = json.loads(d['options'])
                if choice not in ([o['value'] for o in opts] if opts else ['custom', 'request-options']):
                    raise Invalid('unknown option')
                if choice == 'custom' and not note.strip():
                    raise Invalid('custom answers require a note')
                digest = hashlib.sha256(note.encode()).hexdigest()
                prior = c.execute('SELECT * FROM answers WHERE home_id=? AND task_id=? AND decision_key=? AND revision=? AND choice=? AND note_hash=?',
                                  (hid, tid, key, d['revision'], choice, digest)).fetchone()
                if prior and not prior['cancelled_at']:
                    result.append(dict(prior)); continue
                if d['state'] != 'open':
                    raise Conflict('decision already has an answer', self.decision_dict(d))
                if prior:
                    # Undo removed the intent; resubmitting the identical draft is allowed.
                    c.execute('DELETE FROM answers WHERE answer_id=?', (prior['answer_id'],))
                aid = str(uuid.uuid4())
                c.execute('''INSERT INTO answers(answer_id,home_id,task_id,decision_key,revision,choice,note,note_hash,device,received_at,ready_at)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?)''', (aid,hid,tid,key,d['revision'],choice,note,digest,device,stamp(),time.time()+15))
                c.execute("UPDATE decisions SET state='queued' WHERE home_id=? AND task_id=? AND decision_key=? AND revision=?", (hid,tid,key,d['revision']))
                changed[0] = True
                result.append(dict(c.execute('SELECT * FROM answers WHERE answer_id=?', (aid,)).fetchone()))
        return {'answers': result}

    def answer_action(self, record):
        aid = str(uuid.UUID(record.get('answer_id', '')))
        with self.write() as (c, changed):
            a = c.execute('SELECT * FROM answers WHERE answer_id=?', (aid,)).fetchone()
            if not a:
                raise Invalid('unknown answer')
            if record['action'] == 'undo':
                if a['exported_at'] or a['consumed_at'] or time.time() >= a['ready_at']:
                    raise Conflict('answer can no longer be undone')
                if not a['cancelled_at']:
                    c.execute('UPDATE answers SET cancelled_at=? WHERE answer_id=?', (stamp(),aid))
                    c.execute("UPDATE decisions SET state='open' WHERE home_id=? AND task_id=? AND decision_key=? AND revision=?", (a['home_id'],a['task_id'],a['decision_key'],a['revision']))
                    changed[0] = True
                return {'ok':True}
            if record['action'] != 'correction' or not a['consumed_at']:
                raise Invalid('corrections require a consumed answer')
            note = text(record.get('note'), 'correction note')
            digest = hashlib.sha256(note.encode()).hexdigest()
            new_id = str(uuid.uuid4())
            c.execute('''INSERT OR IGNORE INTO answers(answer_id,home_id,task_id,decision_key,revision,choice,note,note_hash,device,received_at,ready_at,action)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?)''', (new_id,a['home_id'],a['task_id'],a['decision_key'],a['revision'],'correction',note,digest,'',stamp(),time.time()+15,'correction'))
            changed[0] = c.execute('SELECT changes()').fetchone()[0] > 0
            return {'ok':True}

    def export(self):
        with file_lock(self.state / 'board-inbox/export.lock'):
            with self.write() as (c, changed):
                rows = c.execute('SELECT * FROM answers WHERE exported_at IS NULL AND error IS NOT NULL AND cancelled_at IS NULL AND ready_at<=? ORDER BY received_at', (time.time(),)).fetchall()
                if not rows:
                    return
                path = self.state / 'board-inbox/answers.jsonl'
                data = path.read_bytes() if path.exists() else b''
                lines = data.splitlines(keepends=True)
                if lines and not lines[-1].endswith(b'\n'):
                    raise Invalid('answer log contains an incomplete line')
                seen = {json.loads(line).get('answer_id') for line in lines}
                burst = []
                for a in rows:
                    if a['answer_id'] not in seen:
                        burst.append(json.dumps(dict(ts=a['received_at'],home=a['home_id'],task=a['task_id'],
                            choice=a['choice'],note=a['note'],key=a['decision_key'],answer_id=a['answer_id'])) + '\n')
                if burst:
                    atomic(path, data + ''.join(burst).encode())
                for a in rows:
                    c.execute('UPDATE answers SET exported_at=? WHERE answer_id=?', (stamp(),a['answer_id']))
                    changed[0] = True

    def export_pending(self):
        # Do not split one in-progress handler burst across multiple source fires.
        try:
            with file_lock(self.state / 'board-inbox/route.lock',blocking=False):
                self.export()
        except BlockingIOError:
            pass

    def answered(self, aid):
        aid = str(uuid.UUID(aid))
        with self.write() as (c, changed):
            a = c.execute('SELECT * FROM answers WHERE answer_id=?', (aid,)).fetchone()
            if not a or a['cancelled_at'] or (not a['routing_at'] and not a['error']):
                raise Invalid('answer must have been routed or escalated before consumption')
            if not a['consumed_at']:
                c.execute('UPDATE answers SET consumed_at=?,error=NULL WHERE answer_id=?', (stamp(),aid))
                if a['action'] == 'answer':
                    c.execute("UPDATE decisions SET state='consumed',closed_at=? WHERE home_id=? AND task_id=? AND decision_key=? AND revision=?", (stamp(),a['home_id'],a['task_id'],a['decision_key'],a['revision']))
                changed[0] = True
        return {'ok':True}

    def failed(self, aid, error):
        with self.write() as (c, changed):
            a = c.execute('SELECT * FROM answers WHERE answer_id=?', (aid,)).fetchone()
            if a and a['error'] != error:
                c.execute('UPDATE answers SET error=? WHERE answer_id=?', (error,aid))
                if a['action'] == 'answer':
                    c.execute("UPDATE decisions SET state='failed' WHERE home_id=? AND task_id=? AND decision_key=? AND revision=?", (a['home_id'],a['task_id'],a['decision_key'],a['revision']))
                changed[0] = True

    def live(self, args):
        hid = self.hid(args.home); slug(args.task, 'task'); url(args.url)
        text(args.env, 'environment', 100); text(args.evidence, 'evidence', empty=True)
        with self.write() as (c, changed):
            row = c.execute('SELECT project FROM tasks WHERE home_id=? AND task_id=?', (hid,args.task)).fetchone()
            if not row:
                raise Invalid('live requires an ingested task')
            c.execute('INSERT INTO events VALUES(?,?,?,?,?,?,?,?,?,?,?)', (str(uuid.uuid4()),hid,args.task,'live',row['project'],
                'Verified live',args.url,args.env,stamp(),args.evidence,stamp()))
            changed[0] = True
        self.reload()
        return {'ok':True}

    def backup(self):
        with file_lock(self.state / 'board-backup.lock'):
            path = self.state / 'backups' / f'board-{datetime.date.today()}-{uuid.uuid4().hex[:8]}.sqlite'
            with self.connect() as c:
                c.execute('VACUUM INTO ?', (str(path),))
            os.chmod(path, 0o600)
            for old in sorted(path.parent.glob('board-*.sqlite'), key=lambda p:p.stat().st_mtime, reverse=True)[7:]:
                old.unlink()
        return {'backup':str(path)}

    def arm(self):
        env = dict(os.environ, FM_HOME=str(self.home), FM_BOARD_CONFIG=str(self.config_path), FM_ROOT_OVERRIDE=str(ROOT))
        for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_PROJECTS_OVERRIDE'):
            env.pop(key, None)
        run([ROOT / 'bin/fm-procevent.sh', 'register', 'board-answers', self.source_id, '--',
             sys.executable, ROOT / 'bin/board/board-answers-source.py', '--config', self.config_path], self.home)
        if self.runner is None or self.runner.poll() is not None:
            with open(self.state / 'logs/board-answers.log', 'ab') as log:
                self.runner = subprocess.Popen([str(ROOT / 'bin/fm-procevent.sh'),'start',self.source_id],
                    cwd=self.home, env=env, stdout=log, stderr=log, start_new_session=True)
        self.armed = self.runner.poll() is None
        return {'answers_armed':self.armed}

    def health(self):
        with self.connect() as c:
            db_ok = c.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
            runs = {r['home_id']: dict(r) for r in c.execute('SELECT * FROM ingest_runs')}
            outbox = c.execute('SELECT count(*) FROM answers WHERE consumed_at IS NULL AND cancelled_at IS NULL AND error IS NULL').fetchone()[0]
        ages = {hid:self.age(runs.get(hid,{}).get('last_ok')) for hid in self.homes}
        errors = {hid:runs.get(hid,{}).get('last_error') for hid in self.homes}
        armed = self.armed and self.runner is not None and self.runner.poll() is None
        return dict(ok=db_ok and all(v is not None and v < 60 for v in ages.values()) and not any(errors.values()) and armed,
                    db_ok=db_ok, ingest_age_s=ages, ingest_error=errors,
                    last_snapshot_ms={hid:runs.get(hid,{}).get('last_snapshot_ms') for hid in self.homes},
                    sse_clients=len(self.clients),outbox_backlog=outbox,answers_armed=armed)

    def version(self):
        with self.connect() as c:
            m = dict(c.execute('SELECT key,value FROM meta'))
            runs = {r['home_id']: dict(r) for r in c.execute('SELECT * FROM ingest_runs')}
        homes = []
        for hid in self.homes:
            row = runs.get(hid,{})
            age = self.age(row.get('last_ok'))
            homes.append(dict(id=hid,last_ok=row.get('last_ok'),age_s=age,stale=age is None or age>60,ingest_error=row.get('last_error')))
        return dict(rev=int(m['rev']),generated_at=m['generated_at'],homes=homes)

    def notify(self):
        payload = self.version()
        with self.client_lock:
            for client in self.clients:
                try:
                    client.put_nowait(payload)
                except queue.Full:
                    with contextlib.suppress(queue.Empty):
                        client.get_nowait()
                    client.put_nowait(payload)
        return payload

    def ingest_loop(self):
        last_reconcile = 0
        last_wake = time.monotonic()
        refresh_seen = None
        while not self.stop.is_set():
            self.dirty.wait(5)
            self.dirty.clear()
            now = time.monotonic()
            refresh = self.state / 'board-refresh'
            current = refresh.stat().st_mtime_ns if refresh.exists() else None
            reconcile = now-last_reconcile >= 900 or now-last_wake > 30 or current != refresh_seen
            try:
                self.ingest(reconcile=reconcile)
            except Exception as e:
                self.log(f'ingest_error: {e}')
            if reconcile:
                last_reconcile = now
                refresh_seen = current
            last_wake = time.monotonic()

    def log(self, message):
        with open(self.state / 'logs/board.log', 'a') as f:
            f.write(stamp() + ' ' + str(message).replace('\n',' ')[:2000] + '\n')

    def route_loop(self):
        while not self.stop.wait(0.5):
            try:
                with self.connect() as c:
                    pending = c.execute('SELECT 1 FROM answers WHERE consumed_at IS NULL AND error IS NULL AND cancelled_at IS NULL AND ready_at<=? LIMIT 1', (time.time(),)).fetchone()
                if pending:
                    run([ROOT / 'bin/board/board-answers-handle.sh','route','--config',self.config_path], self.home, 600)
            except Exception as e:
                self.log(f'answer handler: {e}')
                self.stop.wait(2)

    def service_loop(self):
        last_rev = -1
        last_day = None
        last_tick = 0
        while not self.stop.wait(0.5):
            try:
                if time.monotonic() - last_tick >= 5:
                    self.dirty.set()
                    last_tick = time.monotonic()
                self.export_pending()
                if self.runner is None or self.runner.poll() is not None:
                    self.arm()
                with self.connect() as c:
                    rev = int(c.execute("SELECT value FROM meta WHERE key='rev'").fetchone()[0])
                if rev != last_rev:
                    self.notify(); last_rev = rev
                today = datetime.date.today()
                if today != last_day:
                    self.backup()
                    with self.write() as (c, changed):
                        c.execute('DELETE FROM events WHERE created_at<?', ((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=30)).isoformat(),))
                        changed[0] = c.execute('SELECT changes()').fetchone()[0] > 0
                    last_day = today
                for path in (self.state / 'logs').glob('board*.log'):
                    if path.stat().st_size > 5 * 1024 * 1024:
                        # copy/truncate preserves launchd's inherited descriptors.
                        atomic(path.with_suffix('.log.1'), path.read_bytes())
                        with path.open('w'):
                            pass
            except Exception as e:
                self.log(e)
                self.stop.wait(2)

    def serve(self):
        with file_lock(self.state / 'board-daemon.lock', blocking=False):
            server_class = http.server.ThreadingHTTPServer
            if ':' in self.host:
                class V6Server(server_class):
                    address_family = socket.AF_INET6
                server_class = V6Server
            server = server_class((self.host,self.port), handler(self))
            server.daemon_threads = True
            internal = None
            try:
                addresses = {info[4][0] for info in socket.getaddrinfo(self.host,self.port)}
                if '127.0.0.1' not in addresses:
                    internal = http.server.ThreadingHTTPServer(('127.0.0.1',self.port), handler(self,internal=True))
                    threading.Thread(target=internal.serve_forever,daemon=True).start()
            except OSError:
                server.server_close()
                raise
            def shutdown(signum, frame):
                self.stop.set()
                threading.Thread(target=server.shutdown, daemon=True).start()
            signal.signal(signal.SIGTERM, shutdown)
            signal.signal(signal.SIGINT, shutdown)
            self.arm()
            workers = [threading.Thread(target=self.ingest_loop,daemon=True), threading.Thread(target=self.service_loop,daemon=True), threading.Thread(target=self.route_loop,daemon=True)]
            for worker in workers:
                worker.start()
            self.dirty.set()
            try:
                server.serve_forever(poll_interval=0.25)
            finally:
                self.stop.set(); self.dirty.set()
                server.server_close()
                if internal:
                    internal.shutdown(); internal.server_close()
                if self.runner and self.runner.poll() is None:
                    with contextlib.suppress(ProcessLookupError):
                        os.killpg(self.runner.pid, signal.SIGTERM)
                    with contextlib.suppress(subprocess.TimeoutExpired):
                        self.runner.wait(5)
                for worker in workers:
                    worker.join(95)


def handler(board, internal=False):
    class Handler(http.server.BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(20)

        def log_message(self, fmt, *args):
            # Never log the bookmark secret or notes.
            pass

        def respond(self, code, data, content='application/json'):
            raw = json.dumps(data).encode() if content == 'application/json' else data
            self.send_response(code)
            self.send_header('Content-Type',content)
            self.send_header('Content-Length',str(len(raw)))
            self.send_header('Cache-Control','no-store')
            if getattr(self,'etag',None):
                self.send_header('ETag',self.etag)
            self.send_header('X-Content-Type-Options','nosniff')
            self.send_header('Referrer-Policy','no-referrer')
            self.send_header('Content-Security-Policy',"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
            self.end_headers()
            self.wfile.write(raw)

        def authorized(self, post=False):
            host = self.headers.get('Host','').lower()
            allowed = {f'127.0.0.1:{board.port}'} if internal else board.authorities
            internal_reload = self.path == '/internal/reload' and self.client_address[0] == '127.0.0.1'
            if internal_reload:
                allowed = allowed | {f'127.0.0.1:{board.port}'}
            if len(self.headers.get_all('Host', [])) != 1 or host not in allowed:
                self.respond(403,{'error':'invalid Host'}); return False
            origins = self.headers.get_all('Origin', [])
            if origins and (len(origins) != 1 or origins[0] not in board.origins):
                self.respond(403,{'error':'invalid Origin'}); return False
            public_page = not post and urllib.parse.urlsplit(self.path).path == '/' and not internal
            if not public_page and not hmac.compare_digest(self.headers.get('Authorization','').encode(),f'Bearer {board.secret}'.encode()):
                self.respond(403,{'error':'secret required'}); return False
            return True

        def do_GET(self):
            try:
                if not self.authorized():
                    return
                if internal:
                    self.respond(404,{'error':'route not found'}); return
                parsed = urllib.parse.urlsplit(self.path)
                if parsed.path == '/':
                    self.respond(200,(ROOT / 'bin/board/dashboard.html').read_bytes(),'text/html; charset=utf-8')
                elif parsed.path == '/api/state':
                    project = urllib.parse.parse_qs(parsed.query).get('project',[None])[0]
                    state = board.state_payload(project)
                    etag = f'"{state["rev"]}"'
                    if self.headers.get('If-None-Match') == etag:
                        self.send_response(304)
                        self.send_header('ETag',etag)
                        self.end_headers()
                    else:
                        self.etag = etag
                        self.respond(200,state)
                elif parsed.path == '/healthz':
                    self.respond(200,board.health())
                elif parsed.path == '/events':
                    self.events()
                else:
                    self.respond(404,{'error':'route not found'})
            except (BrokenPipeError,ConnectionResetError,TimeoutError):
                pass
            except Invalid as e:
                self.respond(400,{'error':str(e)})

        def events(self):
            client = queue.Queue(maxsize=1)
            with board.client_lock:
                if len(board.clients) >= 32:
                    self.respond(503,{'error':'SSE client limit'}); return
                board.clients.add(client)
            try:
                self.send_response(200)
                self.send_header('Content-Type','text/event-stream')
                self.send_header('Cache-Control','no-cache')
                self.send_header('Connection','keep-alive')
                self.end_headers()
                payload = board.version()
                previous = -1
                while not board.stop.is_set():
                    event = 'changed' if payload['rev'] != previous else 'heartbeat'
                    self.wfile.write(f'event: {event}\nid: {payload["rev"]}\ndata: {json.dumps(payload)}\n\n'.encode())
                    self.wfile.flush()
                    previous = payload['rev']
                    try:
                        payload = client.get(timeout=15)
                    except queue.Empty:
                        payload = board.version()
            finally:
                with board.client_lock:
                    board.clients.discard(client)

        def do_POST(self):
            try:
                if not self.authorized(True):
                    return
                if self.path == '/internal/reload':
                    if self.client_address[0] != '127.0.0.1':
                        self.respond(403,{'error':'loopback only'}); return
                    if self.headers.get('Content-Length') != '2' or self.rfile.read(2) != b'{}':
                        raise Invalid('internal reload requires an empty JSON object')
                    board.notify()
                    self.respond(200,{'ok':True}); return
                if internal or self.path not in ('/answer','/answers'):
                    self.respond(404,{'error':'route not found'}); return
                if self.headers.get('Transfer-Encoding') or len(self.headers.get_all('Content-Length', [])) != 1:
                    raise Invalid('one Content-Length is required')
                length = int(self.headers.get('Content-Length','0'))
                if not 0 < length <= 65536:
                    raise Invalid('request must contain 1..65536 bytes')
                body = self.rfile.read(length)
                if len(body) != length:
                    raise Invalid('incomplete request')
                data = json.loads(body)
                if not isinstance(data, dict):
                    raise Invalid('request must be an object')
                if self.path == '/answer' and 'action' in data:
                    result = board.answer_action(data)
                else:
                    result = board.answer(data.get('answers') if self.path == '/answers' else [data])
                self.respond(200,result)
            except Conflict as e:
                self.respond(409,{'error':str(e),'current':e.current})
            except (ValueError,TypeError,KeyError) as e:
                self.respond(400,{'error':str(e)})
            except (BrokenPipeError,ConnectionResetError,TimeoutError):
                pass
    return Handler


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Invalid(message)


def parser():
    p = Parser(description='Captain dashboard: one local daemon, deterministic fleet ingest.')
    sub = p.add_subparsers(dest='command',required=True,parser_class=Parser)
    for name in ('serve','ingest','decision','live','answered','refresh','arm-answers','backup'):
        cmd = sub.add_parser(name)
        cmd.add_argument('--config', help='config path (default FM_BOARD_CONFIG or FM_HOME/config/board.json)')
        if name == 'ingest':
            cmd.add_argument('--once', action='store_true',required=True)
            cmd.add_argument('--home')
        elif name == 'decision':
            for arg in ('home','task','key'):
                cmd.add_argument(arg)
            cmd.add_argument('--project',choices=TAGS,required=True)
            cmd.add_argument('--title',required=True)
            cmd.add_argument('--option',action='append',required=True)
            cmd.add_argument('--rec',default='')
            cmd.add_argument('--why',default='')
        elif name == 'live':
            cmd.add_argument('home'); cmd.add_argument('task')
            cmd.add_argument('--url',required=True); cmd.add_argument('--env',required=True)
            cmd.add_argument('--evidence',default='')
        elif name == 'answered':
            cmd.add_argument('answer_id')
    return p


def main():
    os.umask(0o077)
    try:
        args = parser().parse_args()
        b = Board(args.config)
        result = None
        if args.command == 'serve':
            b.serve()
        elif args.command == 'ingest':
            b.ingest(args.home)
        elif args.command == 'decision':
            result = b.register(args)
        elif args.command == 'live':
            result = b.live(args)
        elif args.command == 'answered':
            result = b.answered(args.answer_id)
        elif args.command == 'refresh':
            (b.state / 'board-refresh').touch()
        elif args.command == 'arm-answers':
            result = b.arm()
        elif args.command == 'backup':
            result = b.backup()
        if result is not None:
            print(json.dumps(result))
    except (OSError,ValueError,TypeError,KeyError,AttributeError,sqlite3.Error) as e:
        print('fm-board: ' + str(e).replace('\n',' ')[:1000],file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
