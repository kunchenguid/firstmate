#!/usr/bin/env python3
"""FirstMate Phase 2 programme registry (SQLite).

Machine authority for programmes, tasks, transitions, heartbeats, and events.
Conversation memory is never authoritative.
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
import uuid
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1

VALID_STATES = frozenset(
    {
        "planned",
        "ready",
        "assigned",
        "implementing",
        "awaiting_tests",
        "awaiting_review",
        "changes_requested",
        "awaiting_ci",
        "approved",
        "merged",
        "blocked",
        "failed",
        "cancelled",
    }
)

# Allowed directed transitions (from -> to). Same-state no-ops are refused.
TRANSITIONS: dict[str, frozenset[str]] = {
    "planned": frozenset({"ready", "cancelled", "blocked"}),
    "ready": frozenset({"assigned", "cancelled", "blocked"}),
    "assigned": frozenset({"implementing", "ready", "cancelled", "blocked", "failed"}),
    "implementing": frozenset(
        {
            "awaiting_tests",
            "awaiting_review",
            "blocked",
            "failed",
            "cancelled",
            "changes_requested",
        }
    ),
    "awaiting_tests": frozenset(
        {"awaiting_review", "implementing", "blocked", "failed", "cancelled"}
    ),
    "awaiting_review": frozenset(
        {
            "changes_requested",
            "awaiting_ci",
            "approved",
            "blocked",
            "failed",
            "cancelled",
        }
    ),
    "changes_requested": frozenset(
        {"implementing", "awaiting_review", "cancelled", "blocked", "failed"}
    ),
    "awaiting_ci": frozenset(
        {"approved", "implementing", "blocked", "failed", "cancelled", "changes_requested"}
    ),
    "approved": frozenset({"merged", "blocked", "cancelled"}),
    "merged": frozenset(),
    "blocked": frozenset({"ready", "planned", "cancelled", "failed"}),
    "failed": frozenset({"ready", "planned", "cancelled", "blocked"}),
    "cancelled": frozenset(),
}


def fm_home() -> Path:
    return Path(os.environ.get("FM_HOME", Path.cwd())).resolve()


def db_path(home: Path | None = None) -> Path:
    h = home or fm_home()
    return h / "state" / "programme.db"


def connect(home: Path | None = None) -> sqlite3.Connection:
    path = db_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=30, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    return conn


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS programmes (
          id TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          phase TEXT NOT NULL DEFAULT 'init',
          status TEXT NOT NULL DEFAULT 'active',
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          notes TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS tasks (
          id TEXT PRIMARY KEY,
          programme_id TEXT NOT NULL REFERENCES programmes(id),
          title TEXT NOT NULL,
          status TEXT NOT NULL,
          priority INTEGER NOT NULL DEFAULT 100,
          worker_type TEXT NOT NULL DEFAULT 'backend_engineer',
          branch TEXT NOT NULL DEFAULT '',
          worktree TEXT NOT NULL DEFAULT '',
          heartbeat_at REAL,
          attempts INTEGER NOT NULL DEFAULT 0,
          commit_sha TEXT NOT NULL DEFAULT '',
          pull_request TEXT NOT NULL DEFAULT '',
          ci_run TEXT NOT NULL DEFAULT '',
          review TEXT NOT NULL DEFAULT '',
          no_mistake TEXT NOT NULL DEFAULT '',
          blocker TEXT NOT NULL DEFAULT '',
          next_action TEXT NOT NULL DEFAULT '',
          packet_dir TEXT NOT NULL DEFAULT '',
          ownership_globs TEXT NOT NULL DEFAULT '[]',
          risk TEXT NOT NULL DEFAULT 'normal',
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          CHECK (status IN (
            'planned','ready','assigned','implementing','awaiting_tests',
            'awaiting_review','changes_requested','awaiting_ci','approved',
            'merged','blocked','failed','cancelled'
          ))
        );
        CREATE TABLE IF NOT EXISTS dependencies (
          task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
          depends_on TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
          PRIMARY KEY (task_id, depends_on),
          CHECK (task_id != depends_on)
        );
        CREATE TABLE IF NOT EXISTS transitions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          task_id TEXT NOT NULL,
          from_status TEXT NOT NULL,
          to_status TEXT NOT NULL,
          reason TEXT NOT NULL DEFAULT '',
          actor TEXT NOT NULL DEFAULT 'phase2',
          at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS events (
          id TEXT PRIMARY KEY,
          task_id TEXT NOT NULL DEFAULT '',
          kind TEXT NOT NULL,
          dedupe_key TEXT NOT NULL,
          payload TEXT NOT NULL DEFAULT '{}',
          created_at REAL NOT NULL,
          processed_at REAL,
          UNIQUE(task_id, kind, dedupe_key)
        );
        CREATE TABLE IF NOT EXISTS workers (
          task_id TEXT PRIMARY KEY REFERENCES tasks(id) ON DELETE CASCADE,
          profile TEXT NOT NULL,
          pid INTEGER,
          pane TEXT NOT NULL DEFAULT '',
          started_at REAL NOT NULL,
          last_heartbeat REAL,
          failures INTEGER NOT NULL DEFAULT 0
        );
        """
    )
    row = conn.execute("SELECT value FROM meta WHERE key='schema_version'").fetchone()
    if row is None:
        conn.execute(
            "INSERT INTO meta(key, value) VALUES ('schema_version', ?)",
            (str(SCHEMA_VERSION),),
        )


def now() -> float:
    return time.time()


def emit_json(obj: Any) -> None:
    print(json.dumps(obj, indent=2, sort_keys=True))


def create_programme(conn: sqlite3.Connection, pid: str, title: str, phase: str) -> dict:
    t = now()
    conn.execute(
        "INSERT INTO programmes(id, title, phase, status, created_at, updated_at) VALUES (?,?,?,?,?,?)",
        (pid, title, phase, "active", t, t),
    )
    return dict(conn.execute("SELECT * FROM programmes WHERE id=?", (pid,)).fetchone())


def set_phase(conn: sqlite3.Connection, pid: str, phase: str) -> dict:
    conn.execute(
        "UPDATE programmes SET phase=?, updated_at=? WHERE id=?",
        (phase, now(), pid),
    )
    row = conn.execute("SELECT * FROM programmes WHERE id=?", (pid,)).fetchone()
    if not row:
        raise SystemExit(f"programme not found: {pid}")
    return dict(row)


def add_task(
    conn: sqlite3.Connection,
    *,
    task_id: str,
    programme_id: str,
    title: str,
    worker_type: str,
    priority: int,
    deps: list[str],
    ownership: list[str],
    risk: str,
    packet_dir: str,
) -> dict:
    t = now()
    status = "planned"
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute(
            """INSERT INTO tasks(
              id, programme_id, title, status, priority, worker_type,
              ownership_globs, risk, packet_dir, created_at, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?)""",
            (
                task_id,
                programme_id,
                title,
                status,
                priority,
                worker_type,
                json.dumps(ownership),
                risk,
                packet_dir,
                t,
                t,
            ),
        )
        for dep in deps:
            conn.execute(
                "INSERT INTO dependencies(task_id, depends_on) VALUES (?,?)",
                (task_id, dep),
            )
        conn.execute(
            "INSERT INTO transitions(task_id, from_status, to_status, reason, actor, at) VALUES (?,?,?,?,?,?)",
            (task_id, "", status, "created", "phase2", t),
        )
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return get_task(conn, task_id)


def get_task(conn: sqlite3.Connection, task_id: str) -> dict:
    row = conn.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
    if not row:
        raise SystemExit(f"task not found: {task_id}")
    d = dict(row)
    deps = [
        r["depends_on"]
        for r in conn.execute(
            "SELECT depends_on FROM dependencies WHERE task_id=?", (task_id,)
        )
    ]
    d["depends_on"] = deps
    d["ownership_globs"] = json.loads(d["ownership_globs"] or "[]")
    return d


def transition(
    conn: sqlite3.Connection,
    task_id: str,
    to_status: str,
    reason: str = "",
    actor: str = "phase2",
    fields: dict[str, Any] | None = None,
) -> dict:
    if to_status not in VALID_STATES:
        raise SystemExit(f"invalid status: {to_status}")
    fields = fields or {}
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = conn.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone()
        if not row:
            raise SystemExit(f"task not found: {task_id}")
        from_status = row["status"]
        if from_status == to_status:
            conn.execute("COMMIT")
            return get_task(conn, task_id)
        allowed = TRANSITIONS.get(from_status, frozenset())
        if to_status not in allowed:
            raise SystemExit(f"illegal transition {from_status} -> {to_status}")
        sets = ["status=?", "updated_at=?"]
        vals: list[Any] = [to_status, now()]
        for key in (
            "branch",
            "worktree",
            "commit_sha",
            "pull_request",
            "ci_run",
            "review",
            "no_mistake",
            "blocker",
            "next_action",
            "worker_type",
        ):
            if key in fields:
                sets.append(f"{key}=?")
                vals.append(fields[key])
        if "attempts_inc" in fields:
            sets.append("attempts=attempts+1")
        if to_status == "assigned":
            sets.append("attempts=attempts+1")
        vals.append(task_id)
        conn.execute(f"UPDATE tasks SET {', '.join(sets)} WHERE id=?", vals)
        conn.execute(
            "INSERT INTO transitions(task_id, from_status, to_status, reason, actor, at) VALUES (?,?,?,?,?,?)",
            (task_id, from_status, to_status, reason, actor, now()),
        )
        conn.execute("COMMIT")
    except Exception:
        conn.execute("ROLLBACK")
        raise
    return get_task(conn, task_id)


def deps_satisfied(conn: sqlite3.Connection, task_id: str) -> bool:
    rows = conn.execute(
        """
        SELECT t.status FROM dependencies d
        JOIN tasks t ON t.id = d.depends_on
        WHERE d.task_id = ?
        """,
        (task_id,),
    ).fetchall()
    return all(r["status"] == "merged" for r in rows)


def refresh_ready(conn: sqlite3.Connection, programme_id: str | None = None) -> list[str]:
    """Promote planned -> ready when all deps are merged."""
    q = "SELECT id, programme_id, status FROM tasks WHERE status='planned'"
    args: tuple = ()
    if programme_id:
        q += " AND programme_id=?"
        args = (programme_id,)
    promoted: list[str] = []
    for row in conn.execute(q, args):
        if deps_satisfied(conn, row["id"]):
            transition(conn, row["id"], "ready", reason="deps_satisfied")
            promoted.append(row["id"])
    return promoted


def list_ready(conn: sqlite3.Connection, programme_id: str | None = None) -> list[dict]:
    refresh_ready(conn, programme_id)
    q = "SELECT * FROM tasks WHERE status='ready'"
    args: tuple = ()
    if programme_id:
        q += " AND programme_id=?"
        args = (programme_id,)
    q += " ORDER BY priority ASC, created_at ASC"
    out = []
    for row in conn.execute(q, args):
        d = dict(row)
        d["ownership_globs"] = json.loads(d["ownership_globs"] or "[]")
        out.append(d)
    return out


def heartbeat(conn: sqlite3.Connection, task_id: str) -> dict:
    t = now()
    conn.execute(
        "UPDATE tasks SET heartbeat_at=?, updated_at=? WHERE id=?",
        (t, t, task_id),
    )
    conn.execute(
        "UPDATE workers SET last_heartbeat=? WHERE task_id=?",
        (t, task_id),
    )
    return {"ok": True, "task_id": task_id, "heartbeat_at": t}


def record_event(
    conn: sqlite3.Connection,
    *,
    task_id: str,
    kind: str,
    dedupe_key: str,
    payload: dict,
) -> dict:
    eid = str(uuid.uuid4())
    t = now()
    try:
        conn.execute(
            """INSERT INTO events(id, task_id, kind, dedupe_key, payload, created_at)
               VALUES (?,?,?,?,?,?)""",
            (eid, task_id, kind, dedupe_key, json.dumps(payload), t),
        )
        return {"ok": True, "id": eid, "duplicate": False}
    except sqlite3.IntegrityError:
        return {"ok": True, "duplicate": True, "task_id": task_id, "kind": kind, "dedupe_key": dedupe_key}


def snapshot(conn: sqlite3.Connection, programme_id: str | None = None) -> dict:
    if programme_id:
        prog = conn.execute("SELECT * FROM programmes WHERE id=?", (programme_id,)).fetchone()
    else:
        prog = conn.execute(
            "SELECT * FROM programmes WHERE status='active' ORDER BY updated_at DESC LIMIT 1"
        ).fetchone()
    tasks = []
    q = "SELECT * FROM tasks"
    args: tuple = ()
    if prog:
        q += " WHERE programme_id=?"
        args = (prog["id"],)
    for row in conn.execute(q + " ORDER BY priority, created_at", args):
        d = dict(row)
        d["ownership_globs"] = json.loads(d["ownership_globs"] or "[]")
        tasks.append(d)
    workers = [dict(r) for r in conn.execute("SELECT * FROM workers")]
    by_status: dict[str, int] = {}
    for t in tasks:
        by_status[t["status"]] = by_status.get(t["status"], 0) + 1
    return {
        "programme": dict(prog) if prog else None,
        "tasks": tasks,
        "workers": workers,
        "counts": by_status,
        "ready": list_ready(conn, prog["id"] if prog else None),
    }


def stale_workers(conn: sqlite3.Connection, grace_secs: float) -> list[dict]:
    t = now()
    out = []
    for row in conn.execute(
        """SELECT t.*, w.last_heartbeat, w.failures, w.pid, w.profile
           FROM tasks t
           LEFT JOIN workers w ON w.task_id = t.id
           WHERE t.status IN ('assigned','implementing','awaiting_tests','awaiting_review','awaiting_ci')"""
    ):
        hb = row["heartbeat_at"] or row["last_heartbeat"]
        if hb is None or (t - float(hb)) > grace_secs:
            out.append(dict(row))
    return out


def update_fields(conn: sqlite3.Connection, task_id: str, fields: dict[str, Any]) -> dict:
    if not fields:
        return get_task(conn, task_id)
    sets = ["updated_at=?"]
    vals: list[Any] = [now()]
    for k, v in fields.items():
        if k == "ownership_globs" and isinstance(v, list):
            v = json.dumps(v)
        sets.append(f"{k}=?")
        vals.append(v)
    vals.append(task_id)
    conn.execute(f"UPDATE tasks SET {', '.join(sets)} WHERE id=?", vals)
    return get_task(conn, task_id)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="fm-phase2-registry")
    p.add_argument("--home", default=None, help="FM_HOME override")
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init")

    cp = sub.add_parser("create-programme")
    cp.add_argument("id")
    cp.add_argument("title")
    cp.add_argument("--phase", default="init")

    sp = sub.add_parser("set-phase")
    sp.add_argument("id")
    sp.add_argument("phase")

    at = sub.add_parser("add-task")
    at.add_argument("id")
    at.add_argument("programme_id")
    at.add_argument("title")
    at.add_argument("--worker-type", default="backend_engineer")
    at.add_argument("--priority", type=int, default=100)
    at.add_argument("--dep", action="append", default=[])
    at.add_argument("--own", action="append", default=[])
    at.add_argument("--risk", default="normal")
    at.add_argument("--packet-dir", default="")

    gt = sub.add_parser("get-task")
    gt.add_argument("id")

    tr = sub.add_parser("transition")
    tr.add_argument("id")
    tr.add_argument("to_status")
    tr.add_argument("--reason", default="")
    tr.add_argument("--actor", default="phase2")
    tr.add_argument("--field", action="append", default=[], help="key=value")

    sub.add_parser("ready").add_argument("--programme", default=None)
    sub.add_parser("snapshot").add_argument("--programme", default=None)

    hb = sub.add_parser("heartbeat")
    hb.add_argument("id")

    ev = sub.add_parser("event")
    ev.add_argument("kind")
    ev.add_argument("--task", default="")
    ev.add_argument("--dedupe", required=True)
    ev.add_argument("--payload", default="{}")

    st = sub.add_parser("stale")
    st.add_argument("--grace", type=float, default=300)

    uf = sub.add_parser("set")
    uf.add_argument("id")
    uf.add_argument("--field", action="append", default=[])

    args = p.parse_args(argv)
    if args.home:
        os.environ["FM_HOME"] = args.home
    conn = connect()
    init_db(conn)

    if args.cmd == "init":
        emit_json({"ok": True, "db": str(db_path())})
        return 0
    if args.cmd == "create-programme":
        emit_json(create_programme(conn, args.id, args.title, args.phase))
        return 0
    if args.cmd == "set-phase":
        emit_json(set_phase(conn, args.id, args.phase))
        return 0
    if args.cmd == "add-task":
        packet = args.packet_dir or str(fm_home() / "data" / args.id / "packet")
        emit_json(
            add_task(
                conn,
                task_id=args.id,
                programme_id=args.programme_id,
                title=args.title,
                worker_type=args.worker_type,
                priority=args.priority,
                deps=args.dep,
                ownership=args.own,
                risk=args.risk,
                packet_dir=packet,
            )
        )
        return 0
    if args.cmd == "get-task":
        emit_json(get_task(conn, args.id))
        return 0
    if args.cmd == "transition":
        fields = {}
        for item in args.field:
            if "=" not in item:
                raise SystemExit(f"bad --field {item}")
            k, v = item.split("=", 1)
            fields[k] = v
        emit_json(transition(conn, args.id, args.to_status, args.reason, args.actor, fields))
        return 0
    if args.cmd == "ready":
        emit_json(list_ready(conn, args.programme))
        return 0
    if args.cmd == "snapshot":
        emit_json(snapshot(conn, args.programme))
        return 0
    if args.cmd == "heartbeat":
        emit_json(heartbeat(conn, args.id))
        return 0
    if args.cmd == "event":
        emit_json(
            record_event(
                conn,
                task_id=args.task,
                kind=args.kind,
                dedupe_key=args.dedupe,
                payload=json.loads(args.payload),
            )
        )
        return 0
    if args.cmd == "stale":
        emit_json(stale_workers(conn, args.grace))
        return 0
    if args.cmd == "set":
        fields = {}
        for item in args.field:
            if "=" not in item:
                raise SystemExit(f"bad --field {item}")
            k, v = item.split("=", 1)
            if k == "ownership_globs":
                fields[k] = json.loads(v)
            else:
                fields[k] = v
        emit_json(update_fields(conn, args.id, fields))
        return 0
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        sys.exit(0)
