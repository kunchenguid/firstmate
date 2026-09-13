#!/usr/bin/env python3
"""SQLite ownership for the optional local WhatsApp text bridge.

Schema version 1; a database binds permanently to mode, agent, creator and home.
Transport records reference canonical Firstmate task homes/ids/revisions; they
never own backlog transitions. Transactions use BEGIN IMMEDIATE, WAL and FULL
sync. Outbox 'sending' is committed before HTTP, and becomes delivery_unknown
on restart. Acknowledgement from the remote API is not recipient delivery.
Response events, decisions and ordered chunks commit in the same transaction.
Do not delete receipts, events, rate timestamps or the DB to retry an operation.
"""

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import time


class BridgeError(Exception):
    """Safe-to-display diagnostic with no input body or credential."""


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(encode(value).encode()).hexdigest()


def token(value, name="identifier"):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,180}", value):
        raise BridgeError("invalid " + name)
    return value


def integer(value, low, high, name):
    if type(value) is not int or not low <= value <= high:
        raise BridgeError("invalid " + name)
    return value


class Config:
    def __init__(self, path):
        self.path = Path(path).resolve()
        self.raw = json.loads(self.path.read_text())
        r = self.raw
        self.mode = r.get("mode", "simulated")
        if self.mode not in ("simulated", "live"):
            raise BridgeError("mode must be simulated or live")
        self.home = self.absolute(r["fm_home"])
        self.state = self.absolute(r["state_dir"])
        self.agent = token(r["agent_id"], "agent_id")
        self.creator = token(r["creator_id"], "creator_id")
        if not self.creator.startswith("user:") or not self.creator[5:]:
            raise BridgeError("creator_id must be locally bound user:<id>")
        self.timeout = integer(r.get("poll_timeout", 25), 0, 25, "poll_timeout")
        self.send_timeout = integer(r.get("send_timeout", 90), 30, 300, "send_timeout")
        self.limit = integer(r.get("poll_limit", 50), 1, 100, "poll_limit")
        self.startup = r.get("startup_policy", "new-only")
        if self.startup != "new-only":
            raise BridgeError("startup_policy must be new-only; historical replay is unsupported")
        self.rates = {"updates": 15, "messages": 12, "statuses": 12,
                      "media-upload": 12, "media-metadata": 12, "media-delete": 12}
        for endpoint, limit in r.get("rate_limits", {}).items():
            if endpoint not in self.rates:
                raise BridgeError("unknown endpoint rate bucket")
            self.rates[endpoint] = integer(limit, 1, self.rates[endpoint], "rate limit")
        self.enabled = r.get("enabled", False) is True
        self.outbound = r.get("outbound_authorized", False) is True
        self.token_file = Path(r["token_file"]) if r.get("token_file") else None
        if self.token_file is not None and not self.token_file.is_absolute():
            raise BridgeError("token_file must be absolute")
        if self.mode == "live" and not self.token_file:
            raise BridgeError("live mode requires a private token_file path")
        if any(r.get(k) for k in ("media", "typing", "read_receipts", "tts", "external_llm")):
            raise BridgeError("optional media/status/model features are pending stage 2/3")

    @staticmethod
    def absolute(value):
        path = Path(value)
        if not path.is_absolute():
            raise BridgeError("configuration paths must be absolute")
        return path.resolve()

    def environment(self):
        # No inherited FM_* overrides, model credentials or bearer reach children.
        env = {k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "LANG") if k in os.environ}
        env["FM_HOME"] = str(self.home)
        return env


class Store:
    def __init__(self, config, clock=time.time):
        self.config, self.clock = config, clock
        config.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        if config.state.stat().st_uid != os.getuid() or config.state.stat().st_mode & 0o077:
            raise BridgeError("state_dir must be owner-only (chmod 700)")
        path = config.state / "bridge.sqlite3"
        if path.is_symlink():
            raise BridgeError("database must not be a symlink")
        self.db = sqlite3.connect(path, timeout=10, isolation_level=None)
        os.chmod(path, 0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS inbound(
          wamid TEXT PRIMARY KEY, request TEXT UNIQUE NOT NULL, sender TEXT NOT NULL,
          stamp INTEGER, kind TEXT, body TEXT, raw TEXT NOT NULL, state TEXT NOT NULL,
          note_id TEXT, envelope TEXT, received REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS contacts(id TEXT PRIMARY KEY, name TEXT);
        CREATE TABLE IF NOT EXISTS task_refs(
          request TEXT NOT NULL, home TEXT NOT NULL, task TEXT NOT NULL,
          revision TEXT NOT NULL, fingerprint TEXT NOT NULL,
          PRIMARY KEY(request,home,task));
        CREATE TABLE IF NOT EXISTS responses(
          event TEXT PRIMARY KEY, request TEXT NOT NULL, kind TEXT NOT NULL,
          body TEXT NOT NULL, payload TEXT NOT NULL, actor TEXT NOT NULL, at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS decisions(
          id TEXT PRIMARY KEY, request TEXT NOT NULL, home TEXT NOT NULL,
          task TEXT NOT NULL, revision TEXT NOT NULL, action TEXT NOT NULL,
          fingerprint TEXT NOT NULL, expires REAL NOT NULL, state TEXT NOT NULL,
          answer_wamid TEXT UNIQUE, consumed REAL);
        CREATE TABLE IF NOT EXISTS outbox(
          seq INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL,
          request TEXT NOT NULL, part INTEGER NOT NULL, body TEXT NOT NULL,
          state TEXT NOT NULL, wamid TEXT UNIQUE, due REAL NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0, UNIQUE(event,part));
        CREATE TABLE IF NOT EXISTS attempts(
          id INTEGER PRIMARY KEY, seq INTEGER NOT NULL, at REAL NOT NULL,
          outcome TEXT, http INTEGER, code INTEGER, trace TEXT);
        CREATE TABLE IF NOT EXISTS redeliveries(
          key TEXT PRIMARY KEY, source TEXT NOT NULL, event TEXT UNIQUE NOT NULL,
          at REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS receipts(
          wamid TEXT NOT NULL, status TEXT NOT NULL, stamp TEXT NOT NULL,
          PRIMARY KEY(wamid,status,stamp));
        CREATE TABLE IF NOT EXISTS rates(endpoint TEXT NOT NULL, at REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS rate_window ON rates(endpoint,at);
        CREATE TABLE IF NOT EXISTS sim_sends(seq INTEGER PRIMARY KEY, payload TEXT NOT NULL);
        """)
        binding = encode({"schema": 1, "mode": config.mode, "agent": config.agent,
                          "creator": config.creator, "home": str(config.home)})
        try:
            with self.tx():
                if self.get("binding") not in (None, binding):
                    raise BridgeError("database identity mismatch; preserve state and use a new binding")
                self.put("binding", binding)
                if self.get("cursor") is None:
                    self.put("cursor", "0")
                    self.put("startup", config.startup)
                elif self.get("startup") != config.startup:
                    raise BridgeError("startup policy is immutable for an existing database")
        except BaseException:
            self.db.close()
            raise

    @contextmanager
    def tx(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def get(self, key):
        row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
        return row[0] if row else None

    def activate(self):
        if not self.config.enabled:
            raise BridgeError("bridge is disabled in local configuration")
        with self.tx():
            if self.get("activated") is None:
                self.put("activated", self.clock())

    def accept_send(self, seq, wamid):
        receipts = self.rows("SELECT status FROM receipts WHERE wamid=?", (wamid,))
        state = ("read" if any(r["status"] == "read" for r in receipts) else
                 "delivered" if receipts else "accepted")
        self.db.execute("UPDATE outbox SET state=?,wamid=? WHERE seq=?", (state, wamid, seq))
        return state

    def redeliver(self, event, key):
        token(key, "redelivery key")
        with self.tx():
            previous = self.db.execute("SELECT source,event FROM redeliveries WHERE key=?", (key,)).fetchone()
            if previous:
                if previous["source"] != event:
                    raise BridgeError("redelivery key reused for another response")
                return {"event": previous["event"], "new_delivery": False}
            response = self.db.execute("SELECT * FROM responses WHERE event=?", (event,)).fetchone()
            if response is None or response["kind"] not in ("completed", "failed") or response["actor"] == "bridge":
                raise BridgeError("redelivery requires a persisted terminal response")
            if self.request(response["request"])["state"] != response["kind"]:
                raise BridgeError("terminal request state mismatch")
            latest = self.db.execute("SELECT event FROM redeliveries WHERE source=? ORDER BY rowid DESC LIMIT 1",
                                     (event,)).fetchone()
            parts = self.rows("SELECT state FROM outbox WHERE event=?", (latest["event"] if latest else event,))
            if not parts or any(p["state"] not in ("accepted", "delivered", "read", "abandoned") for p in parts):
                raise BridgeError("resolve all outstanding response parts before authorizing redelivery")
            if not any(p["state"] == "abandoned" for p in parts):
                raise BridgeError("redelivery requires an explicitly abandoned response part")
            delivery = "redelivery-" + digest(key)
            now = self.now()
            self.db.execute("INSERT INTO redeliveries VALUES(?,?,?,?)", (key, event, delivery, now))
            self.enqueue(delivery, response["request"], response["body"], now)
            return {"event": delivery, "new_delivery": True}

    def put(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO meta VALUES(?,?)", (key, str(value)))

    def rows(self, query, args=()):
        return [dict(r) for r in self.db.execute(query, args)]

    def now(self):
        # A backward wall-clock jump must not free a rolling-window reservation.
        now = max(self.clock(), float(self.get("last_clock") or 0))
        self.put("last_clock", now)
        return now

    def reserve(self, endpoint):
        with self.tx():
            now = self.now()
            rows = self.rows("SELECT at FROM rates WHERE endpoint=? AND at>? ORDER BY at",
                             (endpoint, now - 60))
            limit = self.config.rates[endpoint]
            if len(rows) >= limit:
                return max(0.01, rows[-limit]["at"] + 60 - now)
            self.db.execute("DELETE FROM rates WHERE at<=?", (now - 60,))
            self.db.execute("INSERT INTO rates VALUES(?,?)", (endpoint, now))
        return 0

    def request(self, request):
        row = self.db.execute("SELECT * FROM inbound WHERE request=?", (request,)).fetchone()
        if row is None or row["sender"] != self.config.creator or row["state"] in (
                "quarantined", "historical", "unsupported", "invalid"):
            raise BridgeError("request is not an authorized text request")
        return dict(row)

    def emit(self, event, request, kind, body, actor, payload=None):
        # Caller holds transaction. The entire result is preserved before splitting.
        if not isinstance(body, str) or not body.strip() or len(body) > 200000:
            raise BridgeError("response must contain 1-200000 characters")
        if re.search(r"\b(?:user|agent):\S+", body):
            raise BridgeError("participant identifiers must not appear in responses")
        if re.search(r"\b(?:Authorization\s*:|Bearer\s+\S+|api[_ -]?key\s*[:=])", body, re.IGNORECASE):
            raise BridgeError("response contains credential-shaped material")
        token(event, "event id")
        payload = encode(payload or {})
        old = self.db.execute("SELECT * FROM responses WHERE event=?", (event,)).fetchone()
        if old:
            if (old["request"], old["kind"], old["body"], old["payload"]) != (request, kind, body, payload):
                raise BridgeError("event id reused with different response")
            return
        now = self.now()
        self.db.execute("INSERT INTO responses VALUES(?,?,?,?,?,?,?)",
                        (event, request, kind, body, payload, actor, now))
        self.enqueue(event, request, body, now)

    def enqueue(self, event, request, body, now):
        # Python slices preserve Unicode code points and do not lose any suffix.
        for part, start in enumerate(range(0, len(body), 4096)):
            self.db.execute("INSERT INTO outbox(event,request,part,body,state,due) VALUES(?,?,?,?,?,?)",
                            (event, request, part, body[start:start + 4096], "pending", now))

    def snapshot(self):
        return {"schema": "fm-whatsapp-status.v1", "cursor": int(self.get("cursor")),
                "halt": self.get("halt"), "supervision": self.get("supervision") or "unavailable",
                "poll_diagnostic": json.loads(self.get("poll_diagnostic") or "null"),
                "requests": self.rows("SELECT request,state,note_id FROM inbound WHERE sender=? ORDER BY received",
                                      (self.config.creator,)),
                "responses": self.rows("SELECT event,request,kind,body,at FROM responses ORDER BY at,rowid"),
                "outbox": self.rows("SELECT seq,event,part,state,wamid,attempts FROM outbox ORDER BY seq")}
