"""Durable SQLite persistence for the Admiral's Fleet Dashboard.

One task = one card. Every mutation goes through this module so the schema
stays the single owner of the board's shape. No table here mirrors any
fleet backlog; the board owns its own records deliberately (see docs/dashboard.md
"Why the board owns its own records" for the drift-risk tradeoff this implies).
"""

from __future__ import annotations

import calendar
import os
import random
import re
import sqlite3
import string
import threading
import time
from contextlib import contextmanager

STATUSES = ("needs_attention", "not_started", "working", "paused", "waiting", "testing", "complete")
CAPTAINS = ("firstmate", "captain_dj", "captain_river")
NOTE_TABS = ("interpretation", "communication", "needs")
NOTE_AUTHORS = ("agent", "firstmate", "admiral")

SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  agent TEXT NOT NULL DEFAULT '',
  captain TEXT NOT NULL,
  status TEXT NOT NULL,
  waiting_on_id TEXT,
  waiting_reason TEXT,
  needs_attention_reason TEXT,
  starred INTEGER NOT NULL DEFAULT 0,
  backlog_ref TEXT,
  initial_prompt TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL REFERENCES tasks(id),
  tab TEXT NOT NULL,
  author TEXT NOT NULL,
  text TEXT NOT NULL DEFAULT '',
  link_url TEXT,
  link_label TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_task ON notes(task_id);

CREATE TABLE IF NOT EXISTS status_history (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT NOT NULL REFERENCES tasks(id),
  from_status TEXT,
  to_status TEXT NOT NULL,
  changed_at TEXT NOT NULL,
  note TEXT
);
CREATE INDEX IF NOT EXISTS idx_history_task ON status_history(task_id);

CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id TEXT,
  kind TEXT NOT NULL,
  text TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS audit_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at TEXT,
  completed_at TEXT NOT NULL,
  duration_seconds REAL NOT NULL,
  tasks_checked INTEGER NOT NULL,
  discrepancies_found INTEGER NOT NULL DEFAULT 0,
  forced INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
"""

DEFAULT_AUDIT_INTERVAL_MINUTES = 15

# Columns added after the initial schema. CREATE TABLE IF NOT EXISTS leaves an
# already-created table untouched, so a database created before a column
# existed needs it added explicitly - this keeps existing cards and their
# history intact instead of requiring a fresh database.
_TASK_COLUMN_MIGRATIONS = (
    ("needs_attention_reason", "TEXT"),
)

_AUDIT_RUN_COLUMN_MIGRATIONS = (
    ("forced", "INTEGER NOT NULL DEFAULT 0"),
)

# Settings keys used for the auditor's own liveness, distinct from the
# audit_runs history. A tick is recorded on every timer invocation, whether or
# not it decided a sweep was due, so a dead timer becomes a stale heartbeat
# rather than a silently-aging "last run" that could still look recent. The
# sweep lock is single-row state (not a table) for the same reason: one
# auditor sweep at a time, no queue, claimed and released through ordinary
# settings reads/writes under the existing write lock.
SETTING_LAST_TICK_AT = "audit_last_tick_at"
SETTING_SWEEP_RUNNING = "audit_sweep_running"
SETTING_SWEEP_STARTED_AT = "audit_sweep_started_at"
SETTING_SWEEP_FORCED = "audit_sweep_forced"

# A claimed sweep that has not released itself within this long is treated as
# abandoned (crashed subprocess, killed server) rather than left stuck forever
# refusing every future tick and button press. Overridable so a test can prove
# the reclaim path without a real 10-minute wait.
MAX_SWEEP_SECONDS = int(os.environ.get("FM_AUDIT_MAX_SWEEP_SECONDS", "600"))

_write_lock = threading.Lock()


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _iso_to_epoch(iso: str) -> float:
    return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))


class Store:
    def __init__(self, db_path: str):
        self.db_path = db_path
        directory = os.path.dirname(os.path.abspath(db_path))
        if directory:
            os.makedirs(directory, exist_ok=True)
        with self._connect() as conn:
            conn.executescript(SCHEMA)
            existing_columns = {row[1] for row in conn.execute("PRAGMA table_info(tasks)")}
            for name, coltype in _TASK_COLUMN_MIGRATIONS:
                if name not in existing_columns:
                    conn.execute(f"ALTER TABLE tasks ADD COLUMN {name} {coltype}")
            existing_run_columns = {row[1] for row in conn.execute("PRAGMA table_info(audit_runs)")}
            for name, coltype in _AUDIT_RUN_COLUMN_MIGRATIONS:
                if name not in existing_run_columns:
                    conn.execute(f"ALTER TABLE audit_runs ADD COLUMN {name} {coltype}")
            conn.execute(
                "INSERT OR IGNORE INTO settings(key, value) VALUES ('audit_interval_minutes', ?)",
                (str(DEFAULT_AUDIT_INTERVAL_MINUTES),),
            )

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=30)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=30000")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    @contextmanager
    def _cursor(self, write: bool = False):
        if write:
            _write_lock.acquire()
        conn = self._connect()
        try:
            cur = conn.cursor()
            yield cur
            if write:
                conn.commit()
        finally:
            conn.close()
            if write:
                _write_lock.release()

    # ---- id generation ----

    def _slug(self, title: str) -> str:
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        return slug[:40] or "task"

    def _new_id(self, cur: sqlite3.Cursor, title: str) -> str:
        base = self._slug(title)
        for _ in range(20):
            suffix = "".join(random.choices(string.ascii_lowercase + string.digits, k=4))
            candidate = f"{base}-{suffix}"
            cur.execute("SELECT 1 FROM tasks WHERE id = ?", (candidate,))
            if cur.fetchone() is None:
                return candidate
        raise RuntimeError("could not allocate a unique task id")

    # ---- tasks ----

    def add_task(
        self,
        title: str,
        captain: str,
        initial_prompt: str,
        agent: str = "",
        status: str = "not_started",
        backlog_ref: str | None = None,
        needs_attention_reason: str | None = None,
    ) -> dict:
        if captain not in CAPTAINS:
            raise ValueError(f"unknown captain: {captain!r}")
        if status not in STATUSES:
            raise ValueError(f"unknown status: {status!r}")
        # Mirrors set_status: the reason column is only ever populated for
        # the status it belongs to, so a later transition away from
        # needs_attention can't leave a stale reason rendering on the card.
        needs_attention_reason = needs_attention_reason if status == "needs_attention" else None
        ts = now_iso()
        with self._cursor(write=True) as cur:
            task_id = self._new_id(cur, title)
            cur.execute(
                """INSERT INTO tasks
                   (id, title, agent, captain, status, waiting_on_id, waiting_reason,
                    needs_attention_reason, starred, backlog_ref, initial_prompt, created_at, updated_at)
                   VALUES (?, ?, ?, ?, ?, NULL, NULL, ?, 0, ?, ?, ?, ?)""",
                (task_id, title, agent, captain, status, needs_attention_reason,
                 backlog_ref, initial_prompt, ts, ts),
            )
            cur.execute(
                """INSERT INTO status_history (task_id, from_status, to_status, changed_at, note)
                   VALUES (?, NULL, ?, ?, 'created')""",
                (task_id, status, ts),
            )
        return self.get_task(task_id)

    def get_task(self, task_id: str) -> dict | None:
        with self._cursor() as cur:
            cur.execute("SELECT * FROM tasks WHERE id = ?", (task_id,))
            row = cur.fetchone()
            if row is None:
                return None
            task = dict(row)
            cur.execute(
                "SELECT * FROM notes WHERE task_id = ? ORDER BY created_at ASC, id ASC",
                (task_id,),
            )
            task["notes"] = [dict(r) for r in cur.fetchall()]
            cur.execute(
                "SELECT * FROM status_history WHERE task_id = ? ORDER BY changed_at ASC, id ASC",
                (task_id,),
            )
            task["status_history"] = [dict(r) for r in cur.fetchall()]
        return task

    def list_tasks(self, status: str | None = None, captain: str | None = None,
                    starred: bool | None = None) -> list[dict]:
        query = "SELECT * FROM tasks WHERE 1=1"
        params: list = []
        if status:
            query += " AND status = ?"
            params.append(status)
        if captain:
            query += " AND captain = ?"
            params.append(captain)
        if starred is not None:
            query += " AND starred = ?"
            params.append(1 if starred else 0)
        query += " ORDER BY updated_at DESC"
        with self._cursor() as cur:
            cur.execute(query, params)
            return [dict(r) for r in cur.fetchall()]

    def task_exists(self, task_id: str) -> bool:
        with self._cursor() as cur:
            cur.execute("SELECT 1 FROM tasks WHERE id = ?", (task_id,))
            return cur.fetchone() is not None

    def update_task(self, task_id: str, **fields) -> dict:
        if not self.task_exists(task_id):
            raise KeyError(task_id)
        allowed = {"title", "agent", "captain", "backlog_ref", "starred"}
        sets, params = [], []
        for key, value in fields.items():
            if key not in allowed:
                raise ValueError(f"cannot update field: {key!r}")
            if key == "captain" and value not in CAPTAINS:
                raise ValueError(f"unknown captain: {value!r}")
            sets.append(f"{key} = ?")
            params.append(int(value) if key == "starred" else value)
        if not sets:
            return self.get_task(task_id)
        sets.append("updated_at = ?")
        params.append(now_iso())
        params.append(task_id)
        with self._cursor(write=True) as cur:
            cur.execute(f"UPDATE tasks SET {', '.join(sets)} WHERE id = ?", params)
        return self.get_task(task_id)

    def set_status(self, task_id: str, status: str, waiting_on_id: str | None = None,
                    reason: str | None = None) -> dict:
        if status not in STATUSES:
            raise ValueError(f"unknown status: {status!r}")
        current = self.get_task(task_id)
        if current is None:
            raise KeyError(task_id)
        if waiting_on_id and not self.task_exists(waiting_on_id):
            raise ValueError(f"waiting_on_id does not exist: {waiting_on_id!r}")
        # `reason` is repurposed per status: what a card is waiting on for
        # `waiting`, what is being asked of him for `needs_attention`. The two
        # are mutually exclusive, so only the active status's column is kept.
        waiting_reason = reason if status == "waiting" else None
        needs_attention_reason = reason if status == "needs_attention" else None
        if status != "waiting":
            waiting_on_id = None
        ts = now_iso()
        with self._cursor(write=True) as cur:
            cur.execute(
                """UPDATE tasks SET status = ?, waiting_on_id = ?, waiting_reason = ?,
                   needs_attention_reason = ?, updated_at = ? WHERE id = ?""",
                (status, waiting_on_id, waiting_reason, needs_attention_reason, ts, task_id),
            )
            cur.execute(
                """INSERT INTO status_history (task_id, from_status, to_status, changed_at, note)
                   VALUES (?, ?, ?, ?, ?)""",
                (task_id, current["status"], status, ts, reason),
            )
        return self.get_task(task_id)

    def delete_task(self, task_id: str) -> None:
        with self._cursor(write=True) as cur:
            cur.execute("DELETE FROM notes WHERE task_id = ?", (task_id,))
            cur.execute("DELETE FROM status_history WHERE task_id = ?", (task_id,))
            cur.execute("DELETE FROM audit_log WHERE task_id = ?", (task_id,))
            cur.execute("UPDATE tasks SET waiting_on_id = NULL WHERE waiting_on_id = ?", (task_id,))
            cur.execute("DELETE FROM tasks WHERE id = ?", (task_id,))

    # ---- notes (interpretation / communication / needs tabs) ----

    def add_note(self, task_id: str, tab: str, author: str, text: str = "",
                 link_url: str | None = None, link_label: str | None = None) -> dict:
        if tab not in NOTE_TABS:
            raise ValueError(f"unknown tab: {tab!r}")
        if author not in NOTE_AUTHORS:
            raise ValueError(f"unknown author: {author!r}")
        if not text and not link_url:
            raise ValueError("a note needs text, a link, or both")
        if not self.task_exists(task_id):
            raise KeyError(task_id)
        ts = now_iso()
        with self._cursor(write=True) as cur:
            cur.execute(
                """INSERT INTO notes (task_id, tab, author, text, link_url, link_label, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (task_id, tab, author, text, link_url, link_label, ts),
            )
            cur.execute("UPDATE tasks SET updated_at = ? WHERE id = ?", (ts, task_id))
        return self.get_task(task_id)

    # ---- settings (key/value) ----

    def _get_setting(self, cur: sqlite3.Cursor, key: str) -> str | None:
        cur.execute("SELECT value FROM settings WHERE key = ?", (key,))
        row = cur.fetchone()
        return row["value"] if row else None

    def _set_setting(self, cur: sqlite3.Cursor, key: str, value: str) -> None:
        cur.execute(
            "INSERT INTO settings(key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )

    # ---- audit ----

    def get_audit_interval_minutes(self) -> int:
        with self._cursor() as cur:
            cur.execute("SELECT value FROM settings WHERE key = 'audit_interval_minutes'")
            row = cur.fetchone()
            return int(row["value"]) if row else DEFAULT_AUDIT_INTERVAL_MINUTES

    def set_audit_interval_minutes(self, minutes: int) -> int:
        if minutes < 1:
            raise ValueError("audit interval must be at least 1 minute")
        with self._cursor(write=True) as cur:
            cur.execute(
                "INSERT INTO settings(key, value) VALUES ('audit_interval_minutes', ?) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                (str(minutes),),
            )
        return minutes

    def record_audit_finding(self, kind: str, text: str, task_id: str | None = None) -> None:
        if kind not in ("discrepancy", "error"):
            raise ValueError(f"unknown audit finding kind: {kind!r}")
        with self._cursor(write=True) as cur:
            cur.execute(
                "INSERT INTO audit_log (task_id, kind, text, created_at) VALUES (?, ?, ?, ?)",
                (task_id, kind, text, now_iso()),
            )

    def record_audit_run(self, duration_seconds: float, tasks_checked: int,
                          discrepancies_found: int = 0, started_at: str | None = None,
                          forced: bool = False) -> None:
        # A completed run is the normal, successful way a claimed sweep ends,
        # so recording one also releases the lock - see release_audit_sweep
        # for the separate path a sweep that errors out uses instead.
        with self._cursor(write=True) as cur:
            cur.execute(
                """INSERT INTO audit_runs
                   (started_at, completed_at, duration_seconds, tasks_checked, discrepancies_found, forced)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (started_at, now_iso(), duration_seconds, tasks_checked, discrepancies_found, int(forced)),
            )
            self._set_setting(cur, SETTING_SWEEP_RUNNING, "0")

    def record_audit_tick(self) -> str:
        ts = now_iso()
        with self._cursor(write=True) as cur:
            self._set_setting(cur, SETTING_LAST_TICK_AT, ts)
        return ts

    def claim_audit_sweep(self, forced: bool = False) -> dict:
        """Atomically claim the single sweep slot, or report who already holds it.

        A claim held past MAX_SWEEP_SECONDS is treated as abandoned (the
        subprocess that held it crashed or was killed without releasing) and
        is silently reclaimed rather than left stuck refusing every future
        tick and button press.
        """
        ts = now_iso()
        with self._cursor(write=True) as cur:
            running = self._get_setting(cur, SETTING_SWEEP_RUNNING) == "1"
            started_at = self._get_setting(cur, SETTING_SWEEP_STARTED_AT)
            if running and started_at:
                age = _iso_to_epoch(ts) - _iso_to_epoch(started_at)
                if age > MAX_SWEEP_SECONDS:
                    running = False
            if running:
                return {
                    "claimed": False,
                    "running_since": started_at,
                    "forced": self._get_setting(cur, SETTING_SWEEP_FORCED) == "1",
                }
            self._set_setting(cur, SETTING_SWEEP_RUNNING, "1")
            self._set_setting(cur, SETTING_SWEEP_STARTED_AT, ts)
            self._set_setting(cur, SETTING_SWEEP_FORCED, "1" if forced else "0")
        return {"claimed": True, "started_at": ts, "forced": forced}

    def release_audit_sweep(self) -> None:
        """Release a claimed sweep slot without recording a completed run.

        Used when a sweep fails before it can call record_audit_run, so a
        failed check never leaves the board looking like it is still sweeping
        (or, worse, permanently locked out of ever sweeping again).
        """
        with self._cursor(write=True) as cur:
            self._set_setting(cur, SETTING_SWEEP_RUNNING, "0")

    def get_audit_status(self, log_limit: int = 100) -> dict:
        with self._cursor() as cur:
            cur.execute(
                "SELECT * FROM audit_runs ORDER BY completed_at DESC, id DESC LIMIT 1"
            )
            last_run = cur.fetchone()
            cur.execute(
                "SELECT * FROM audit_log ORDER BY created_at DESC, id DESC LIMIT ?",
                (log_limit,),
            )
            log = [dict(r) for r in cur.fetchall()]
            last_tick_at = self._get_setting(cur, SETTING_LAST_TICK_AT)
            running = self._get_setting(cur, SETTING_SWEEP_RUNNING) == "1"
            started_at = self._get_setting(cur, SETTING_SWEEP_STARTED_AT)
            forced = self._get_setting(cur, SETTING_SWEEP_FORCED) == "1"
        return {
            "last_run": dict(last_run) if last_run else None,
            "log": log,
            "interval_minutes": self.get_audit_interval_minutes(),
            "last_tick_at": last_tick_at,
            "sweep_lock": {"running": running, "started_at": started_at if running else None,
                            "forced": forced if running else False},
        }
