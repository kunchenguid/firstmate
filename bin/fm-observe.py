#!/usr/bin/env python3
"""Collect privacy-safe Firstmate task metrics into local SQLite.

Usage:
  fm-observe.py collect [--task ID] [--db PATH] [--dashboard PATH]
                        [--retention-days DAYS] [--max-session-files N]
                        [--max-session-bytes BYTES] [--no-dashboard]
  fm-observe.py dashboard [--db PATH] [--dashboard PATH]
  fm-observe.py prune [--db PATH] [--retention-days DAYS]

The default database is ``$FM_HOME/data/observability.sqlite3`` and the default
static report is ``$FM_HOME/data/observability.html``.  The collector has no
network code.  It reads existing Firstmate task metadata and status events,
local harness JSONL usage records, git identifiers, and the local no-mistakes
SQLite store.  It never stores prompt, response, source-code, credential,
status-note, finding-description, or command-output content.  The schema
allowlist is numbers, states, correlation identifiers, and local evidence
references only.  Entire checkpoints may be linked as evidence by their git
commit identifiers, but Entire is never read as the task or outcome authority.

This file is the single owner of schema version 1 and retention.  Version 1 has
``runs``, ``events``, ``sessions``, ``quality_findings``, and ``evidence``.
Collection is idempotent through stable primary keys and UPSERTs.  By default,
runs not seen for 365 days and all of their dependent detail are deleted.
Every collection and explicit prune applies the same policy.
Input is bounded to 500 task metadata files, the newest 200 session files per
harness, 16 MiB per session file, 1 MiB or 10,000 lines per status file, 50
no-mistakes runs with 500 rounds each, and 50 commit references per task run.
Override those limits only for a deliberate local run.  Delete the database and
HTML file to reverse the feature completely.

Collection runs only when this command is invoked.  A local, gitignored
``config/observability`` presence flag additionally opts teardown into one
best-effort collection before task records and the isolated worktree disappear.
"""

from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import html
import json
import os
from pathlib import Path
import re
import sqlite3
import statistics
import subprocess
import sys
import time
from typing import Any, Iterator, Optional

SCHEMA_VERSION = 1
DEFAULT_RETENTION_DAYS = 365
DEFAULT_MAX_SESSION_FILES = 200
DEFAULT_MAX_SESSION_BYTES = 16 * 1024 * 1024
MAX_META_FILES = 500
MAX_STATUS_BYTES = 1024 * 1024
MAX_STATUS_LINES = 10_000
MAX_COMMITS = 50
MAX_NM_RUNS = 50
TASK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
SAFE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,255}$")
STATUS_RE = re.compile(
    r"^([a-z][a-z-]*)(?: \[(?:key|corr)=([A-Za-z0-9._-]+)\])?:"
)
FIELD_RE = {
    name: re.compile(r"\[" + name + r"=([^\]\r\n]+)\]")
    for name in ("at", "run", "session")
}
SUCCESS_OUTCOMES = {"completed", "landed", "done-verified"}

SCHEMA = """
PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS runs (
  run_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  session_id TEXT,
  project_ref TEXT,
  worktree_ref TEXT,
  branch_ref TEXT,
  base_commit_ref TEXT,
  commit_ref TEXT,
  pr_ref TEXT,
  harness TEXT,
  runtime TEXT,
  model TEXT,
  effort TEXT,
  task_class TEXT NOT NULL,
  started_at INTEGER NOT NULL,
  first_activity_at INTEGER,
  last_seen_at INTEGER NOT NULL,
  ended_at INTEGER,
  outcome TEXT NOT NULL,
  tokens_input INTEGER NOT NULL DEFAULT 0,
  tokens_output INTEGER NOT NULL DEFAULT 0,
  tokens_cache_read INTEGER NOT NULL DEFAULT 0,
  tokens_cache_write INTEGER NOT NULL DEFAULT 0,
  tokens_reasoning INTEGER NOT NULL DEFAULT 0,
  tokens_total INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL,
  turns INTEGER NOT NULL DEFAULT 0,
  retries INTEGER NOT NULL DEFAULT 0,
  intervention_count INTEGER NOT NULL DEFAULT 0,
  wait_seconds INTEGER NOT NULL DEFAULT 0,
  first_pass_quality INTEGER,
  quality_findings INTEGER NOT NULL DEFAULT 0,
  quality_unresolved INTEGER NOT NULL DEFAULT 0,
  no_mistakes_runs INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS runs_task_idx ON runs(task_id, started_at);
CREATE INDEX IF NOT EXISTS runs_outcome_idx ON runs(outcome, ended_at);
CREATE TABLE IF NOT EXISTS events (
  source_key TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  observed_at INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  state TEXT,
  event_key TEXT,
  source_ref TEXT NOT NULL,
  source_line INTEGER
);
CREATE INDEX IF NOT EXISTS events_run_time_idx ON events(run_id, observed_at, source_line);
CREATE TABLE IF NOT EXISTS sessions (
  source_key TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  native_session_id TEXT,
  source TEXT NOT NULL,
  model TEXT,
  started_at INTEGER,
  ended_at INTEGER,
  tokens_input INTEGER NOT NULL DEFAULT 0,
  tokens_output INTEGER NOT NULL DEFAULT 0,
  tokens_cache_read INTEGER NOT NULL DEFAULT 0,
  tokens_cache_write INTEGER NOT NULL DEFAULT 0,
  tokens_reasoning INTEGER NOT NULL DEFAULT 0,
  tokens_total INTEGER NOT NULL DEFAULT 0,
  cost_usd REAL,
  turns INTEGER NOT NULL DEFAULT 0,
  evidence_ref TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_run_idx ON sessions(run_id);
CREATE TABLE IF NOT EXISTS quality_findings (
  source_key TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  finding_id TEXT NOT NULL,
  severity TEXT,
  resolved INTEGER NOT NULL,
  source TEXT NOT NULL,
  evidence_ref TEXT
);
CREATE INDEX IF NOT EXISTS quality_run_idx ON quality_findings(run_id, resolved);
CREATE TABLE IF NOT EXISTS evidence (
  source_key TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
  kind TEXT NOT NULL,
  ref TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS evidence_run_idx ON evidence(run_id, kind);
"""


def eprint(message: str) -> None:
    print(message, file=sys.stderr)


def stable_key(*parts: object) -> str:
    raw = "\0".join(str(part) for part in parts).encode("utf-8", "surrogateescape")
    return hashlib.sha256(raw).hexdigest()


def safe_identifier(value: Any, fallback_prefix: str = "id") -> Optional[str]:
    if value is None:
        return None
    text = str(value)
    if SAFE_ID_RE.fullmatch(text):
        return text
    return f"{fallback_prefix}-{stable_key(text)[:20]}"


def integer(value: Any) -> int:
    if isinstance(value, bool):
        return 0
    if isinstance(value, (int, float)):
        return max(0, int(value))
    if isinstance(value, str) and re.fullmatch(r"[0-9]+", value):
        return int(value)
    return 0


def number(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)) and value >= 0:
        return float(value)
    return None


def parse_time(value: Any) -> Optional[int]:
    if isinstance(value, (int, float)):
        value = float(value)
        if value > 10_000_000_000:
            value /= 1000
        return int(value) if value > 0 else None
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return int(parsed.timestamp())


def canonical(path: str) -> str:
    try:
        return str(Path(path).expanduser().resolve())
    except (OSError, RuntimeError):
        return str(Path(path).expanduser())


def run_command(args: list[str], cwd: Optional[str] = None) -> Optional[str]:
    try:
        proc = subprocess.run(
            args,
            cwd=cwd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip()


def parse_meta(path: Path) -> dict[str, str]:
    allowed = {
        "task_id", "run_id", "session_id", "started_at", "status_start_line",
        "base_commit", "worktree", "project", "harness", "kind", "model",
        "effort", "backend", "pr", "pr_head", "mode",
    }
    result: dict[str, str] = {}
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep and key in allowed and key not in result:
                    result[key] = value[:4096]
    except OSError:
        return {}
    return result


def open_database(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA busy_timeout = 5000")
    version = connection.execute("PRAGMA user_version").fetchone()[0]
    if version not in (0, SCHEMA_VERSION):
        connection.close()
        raise RuntimeError(
            f"unsupported observability schema {version}; expected {SCHEMA_VERSION}"
        )
    if version == 0:
        connection.executescript(SCHEMA)
        connection.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        connection.commit()
    os.chmod(path, 0o600)
    return connection


def evidence(connection: sqlite3.Connection, run_id: str, kind: str, ref: Optional[str]) -> None:
    if not ref:
        return
    ref = str(ref)[:4096]
    connection.execute(
        "INSERT OR IGNORE INTO evidence(source_key,run_id,kind,ref) VALUES(?,?,?,?)",
        (stable_key("evidence", run_id, kind, ref), run_id, kind, ref),
    )


def tail_status(path: Path) -> list[tuple[int, Optional[int], str]]:
    try:
        size = path.stat().st_size
        with path.open("rb") as handle:
            byte_truncated = size > MAX_STATUS_BYTES
            start_offset = 0
            if byte_truncated:
                handle.seek(-MAX_STATUS_BYTES, os.SEEK_END)
                start_offset = handle.tell()
                start_offset += len(handle.readline())
            raw = handle.read(MAX_STATUS_BYTES)
    except OSError:
        return []
    entries: list[tuple[int, Optional[int], str]] = []
    offset = start_offset
    for index, raw_line in enumerate(raw.splitlines(keepends=True)):
        line_number = None if byte_truncated else index + 1
        line = raw_line.rstrip(b"\r\n").decode("utf-8", "replace")
        entries.append((offset, line_number, line))
        offset += len(raw_line)
    return entries[-MAX_STATUS_LINES:]


def status_fields(line: str) -> tuple[Optional[str], Optional[str], Optional[int], Optional[str], Optional[str]]:
    match = STATUS_RE.match(line)
    if not match:
        return None, None, None, None, None
    values: dict[str, Optional[str]] = {}
    for name, regex in FIELD_RE.items():
        field = regex.search(line)
        values[name] = field.group(1) if field else None
    return (
        match.group(1),
        match.group(2),
        parse_time(values["at"]),
        values["run"],
        values["session"],
    )


def candidate_files(root: Path, since: int, limit: int) -> list[Path]:
    if not root.is_dir() or limit <= 0:
        return []
    candidates: list[tuple[float, Path]] = []
    scanned = 0
    try:
        for directory, _, names in os.walk(root):
            for name in names:
                if not name.endswith(".jsonl"):
                    continue
                scanned += 1
                if scanned > 5000:
                    break
                path = Path(directory) / name
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    continue
                if mtime >= since - 300:
                    candidates.append((mtime, path))
            if scanned > 5000:
                break
    except OSError:
        return []
    candidates.sort(key=lambda item: item[0], reverse=True)
    return [item[1] for item in candidates[:limit]]


def json_lines(path: Path, max_bytes: int) -> Iterator[dict[str, Any]]:
    try:
        if path.stat().st_size > max_bytes:
            return
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                if len(line) > max_bytes:
                    return
                try:
                    value = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    continue
                if isinstance(value, dict):
                    yield value
    except OSError:
        return


def blank_metrics(source: str, ref: Path) -> dict[str, Any]:
    return {
        "source": source,
        "evidence_ref": str(ref),
        "native_session_id": None,
        "model": None,
        "started_at": None,
        "ended_at": None,
        "tokens_input": 0,
        "tokens_output": 0,
        "tokens_cache_read": 0,
        "tokens_cache_write": 0,
        "tokens_reasoning": 0,
        "tokens_total": 0,
        "cost_usd": None,
        "turns": 0,
        "cwd": None,
    }


def note_time(metrics: dict[str, Any], value: Any) -> None:
    stamp = parse_time(value)
    if stamp is None:
        return
    if metrics["started_at"] is None or stamp < metrics["started_at"]:
        metrics["started_at"] = stamp
    if metrics["ended_at"] is None or stamp > metrics["ended_at"]:
        metrics["ended_at"] = stamp


def parse_pi_session(path: Path, max_bytes: int) -> dict[str, Any]:
    metrics = blank_metrics("pi", path)
    cost_known = False
    for record in json_lines(path, max_bytes):
        if record.get("type") == "session":
            metrics["native_session_id"] = safe_identifier(record.get("id"), "pi")
            metrics["cwd"] = record.get("cwd") if isinstance(record.get("cwd"), str) else None
        if record.get("type") == "model_change":
            metrics["model"] = safe_identifier(record.get("modelId"), "model")
        note_time(metrics, record.get("timestamp"))
        message = record.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        usage = message.get("usage")
        if not isinstance(usage, dict):
            continue
        metrics["model"] = safe_identifier(message.get("model"), "model") or metrics["model"]
        metrics["tokens_input"] += integer(usage.get("input"))
        metrics["tokens_output"] += integer(usage.get("output"))
        metrics["tokens_cache_read"] += integer(usage.get("cacheRead"))
        metrics["tokens_cache_write"] += integer(usage.get("cacheWrite"))
        metrics["tokens_reasoning"] += integer(usage.get("reasoning"))
        metrics["tokens_total"] += integer(usage.get("totalTokens"))
        cost = usage.get("cost")
        if isinstance(cost, dict):
            total = number(cost.get("total"))
            if total is not None:
                metrics["cost_usd"] = (metrics["cost_usd"] or 0.0) + total
                cost_known = True
        metrics["turns"] += 1
    if not cost_known:
        metrics["cost_usd"] = None
    return metrics


def parse_claude_session(path: Path, max_bytes: int) -> dict[str, Any]:
    metrics = blank_metrics("claude", path)
    for record in json_lines(path, max_bytes):
        cwd = record.get("cwd")
        if isinstance(cwd, str):
            metrics["cwd"] = cwd
        metrics["native_session_id"] = safe_identifier(record.get("sessionId"), "claude") or metrics["native_session_id"]
        note_time(metrics, record.get("timestamp"))
        message = record.get("message")
        if not isinstance(message, dict) or message.get("role") != "assistant":
            continue
        usage = message.get("usage")
        if not isinstance(usage, dict):
            continue
        metrics["model"] = safe_identifier(message.get("model"), "model") or metrics["model"]
        metrics["tokens_input"] += integer(usage.get("input_tokens"))
        metrics["tokens_output"] += integer(usage.get("output_tokens"))
        metrics["tokens_cache_read"] += integer(usage.get("cache_read_input_tokens"))
        metrics["tokens_cache_write"] += integer(usage.get("cache_creation_input_tokens"))
        metrics["tokens_total"] += (
            integer(usage.get("input_tokens"))
            + integer(usage.get("output_tokens"))
            + integer(usage.get("cache_read_input_tokens"))
            + integer(usage.get("cache_creation_input_tokens"))
        )
        metrics["turns"] += 1
    return metrics


def parse_codex_session(path: Path, max_bytes: int) -> dict[str, Any]:
    metrics = blank_metrics("codex", path)
    latest_usage: Optional[dict[str, Any]] = None
    for record in json_lines(path, max_bytes):
        note_time(metrics, record.get("timestamp"))
        payload = record.get("payload")
        if not isinstance(payload, dict):
            continue
        if record.get("type") == "session_meta":
            metrics["native_session_id"] = safe_identifier(
                payload.get("session_id") or payload.get("id"), "codex"
            )
            metrics["cwd"] = payload.get("cwd") if isinstance(payload.get("cwd"), str) else None
            note_time(metrics, payload.get("timestamp"))
        if record.get("type") == "turn_context":
            metrics["model"] = safe_identifier(payload.get("model"), "model") or metrics["model"]
        if record.get("type") == "event_msg" and payload.get("type") == "token_count":
            info = payload.get("info")
            if isinstance(info, dict) and isinstance(info.get("total_token_usage"), dict):
                latest_usage = info["total_token_usage"]
                metrics["turns"] += 1
    if latest_usage:
        metrics["tokens_input"] = integer(latest_usage.get("input_tokens"))
        metrics["tokens_output"] = integer(latest_usage.get("output_tokens"))
        metrics["tokens_cache_read"] = integer(latest_usage.get("cached_input_tokens"))
        metrics["tokens_reasoning"] = integer(latest_usage.get("reasoning_output_tokens"))
        metrics["tokens_total"] = integer(latest_usage.get("total_tokens"))
    return metrics


SESSION_PARSERS = {
    "pi": parse_pi_session,
    "claude": parse_claude_session,
    "codex": parse_codex_session,
}


def upsert_session(connection: sqlite3.Connection, run_id: str, metrics: dict[str, Any]) -> None:
    source_key = stable_key("session", run_id, metrics["source"], metrics["evidence_ref"])
    connection.execute(
        """INSERT INTO sessions(
             source_key,run_id,native_session_id,source,model,started_at,ended_at,
             tokens_input,tokens_output,tokens_cache_read,tokens_cache_write,
             tokens_reasoning,tokens_total,cost_usd,turns,evidence_ref)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(source_key) DO UPDATE SET
             native_session_id=excluded.native_session_id, model=excluded.model,
             started_at=excluded.started_at, ended_at=excluded.ended_at,
             tokens_input=excluded.tokens_input, tokens_output=excluded.tokens_output,
             tokens_cache_read=excluded.tokens_cache_read,
             tokens_cache_write=excluded.tokens_cache_write,
             tokens_reasoning=excluded.tokens_reasoning,
             tokens_total=excluded.tokens_total, cost_usd=excluded.cost_usd,
             turns=excluded.turns, evidence_ref=excluded.evidence_ref""",
        (
            source_key, run_id, metrics["native_session_id"], metrics["source"],
            metrics["model"], metrics["started_at"], metrics["ended_at"],
            metrics["tokens_input"], metrics["tokens_output"],
            metrics["tokens_cache_read"], metrics["tokens_cache_write"],
            metrics["tokens_reasoning"], metrics["tokens_total"],
            metrics["cost_usd"], metrics["turns"], metrics["evidence_ref"],
        ),
    )
    evidence(connection, run_id, f"{metrics['source']}-session", metrics["evidence_ref"])


def collect_harness_sessions(
    connection: sqlite3.Connection,
    run: dict[str, Any],
    max_files: int,
    max_bytes: int,
    ended_at: Optional[int],
) -> None:
    harness = str(run.get("harness") or "").lower()
    source = next((name for name in SESSION_PARSERS if harness.startswith(name)), None)
    if source is None:
        return
    roots = {
        "pi": Path(os.environ.get("FM_PI_SESSIONS", Path.home() / ".pi/agent/sessions")),
        "claude": Path(os.environ.get("FM_CLAUDE_SESSIONS", Path.home() / ".claude/projects")),
        "codex": Path(os.environ.get("FM_CODEX_SESSIONS", Path.home() / ".codex/sessions")),
    }
    worktree = canonical(str(run["worktree_ref"]))
    parser = SESSION_PARSERS[source]
    connection.execute(
        "DELETE FROM sessions WHERE run_id=? AND source=?",
        (run["run_id"], source),
    )
    connection.execute(
        "DELETE FROM evidence WHERE run_id=? AND kind=?",
        (run["run_id"], f"{source}-session"),
    )
    candidates: list[dict[str, Any]] = []
    for path in candidate_files(roots[source], int(run["started_at"]), max_files):
        metrics = parser(path, max_bytes)
        if not metrics.get("cwd") or canonical(str(metrics["cwd"])) != worktree:
            continue
        session_start = metrics.get("started_at")
        if session_start is not None and session_start < int(run["started_at"]) - 300:
            continue
        if ended_at is not None and (session_start is None or session_start > ended_at):
            continue
        if ended_at is not None and metrics.get("ended_at") is not None and metrics["ended_at"] > ended_at:
            continue
        candidates.append(metrics)
    if candidates:
        selected = min(
            candidates,
            key=lambda item: (
                abs(int(item.get("started_at") or run["started_at"]) - int(run["started_at"])),
                str(item["evidence_ref"]),
            ),
        )
        upsert_session(connection, str(run["run_id"]), selected)


def findings(value: Any) -> list[tuple[str, Optional[str]]]:
    if not isinstance(value, str) or not value:
        return []
    try:
        parsed = json.loads(value)
    except (json.JSONDecodeError, ValueError):
        return []
    rows = parsed.get("findings") if isinstance(parsed, dict) else parsed
    if not isinstance(rows, list):
        return []
    result: list[tuple[str, Optional[str]]] = []
    for index, row in enumerate(rows[:500]):
        if not isinstance(row, dict):
            continue
        finding_id = safe_identifier(row.get("id"), "finding") or f"finding-{index + 1}"
        severity = safe_identifier(row.get("severity"), "severity")
        result.append((finding_id, severity))
    return result


def read_only_sqlite(path: Path) -> Optional[sqlite3.Connection]:
    if not path.is_file():
        return None
    try:
        connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        connection.row_factory = sqlite3.Row
        return connection
    except sqlite3.Error:
        return None


def collect_no_mistakes(
    connection: sqlite3.Connection,
    run: dict[str, Any],
    database: Path,
) -> tuple[int, Optional[int], Optional[str], Optional[str], Optional[str], Optional[int]]:
    source = read_only_sqlite(database)
    if source is None:
        return 0, None, None, None, None, None
    branch = run.get("branch_ref") or f"fm/{run['task_id']}"
    project = canonical(str(run.get("worktree_ref") or ""))
    try:
        source.create_function("fm_canonical", 1, canonical, deterministic=True)
        where = "r.branch=? AND r.created_at>=?"
        parameters: list[Any] = [branch, int(run["started_at"]) - 300]
        if project:
            where += " AND fm_canonical(p.working_path)=?"
            parameters.append(project)
        query = f"""SELECT r.id,r.status,r.pr_url,r.pr_state,r.created_at,r.updated_at,
                           p.working_path
                      FROM runs r JOIN repos p ON p.id=r.repo_id
                     WHERE {where}"""
        query += " ORDER BY r.created_at DESC,r.id DESC LIMIT ?"
        rows = list(reversed(source.execute(
            query, [*parameters, MAX_NM_RUNS]
        ).fetchall()))
        first_row = source.execute(
            f"""SELECT r.id
                  FROM runs r JOIN repos p ON p.id=r.repo_id
                 WHERE {where}
                   AND EXISTS (
                     SELECT 1 FROM step_results s
                     JOIN step_rounds q ON q.step_result_id=s.id
                     WHERE s.run_id=r.id AND q.trigger_type='initial'
                       AND s.step_name IN ('review','test','lint'))
                 ORDER BY r.created_at,r.id LIMIT 1""",
            parameters,
        ).fetchone()
    except sqlite3.Error:
        source.close()
        return 0, None, None, None, None, None
    matched = [row for row in rows if not project or canonical(row["working_path"]) == project]
    first_pass: Optional[int] = None
    if first_row:
        try:
            initial_rounds = source.execute(
                """SELECT q.findings_json,q.user_findings_json
                     FROM step_rounds q JOIN step_results s ON s.id=q.step_result_id
                    WHERE s.run_id=? AND q.trigger_type='initial'
                      AND s.step_name IN ('review','test','lint')
                    ORDER BY s.step_name,q.round LIMIT 500""",
                (first_row["id"],),
            ).fetchall()
        except sqlite3.Error:
            initial_rounds = []
        if initial_rounds:
            initial_findings = 0
            for initial_round in initial_rounds:
                combined = findings(initial_round["findings_json"])
                existing = {item[0] for item in combined}
                combined.extend(
                    item for item in findings(initial_round["user_findings_json"])
                    if item[0] not in existing
                )
                initial_findings += len(combined)
            first_pass = 1 if initial_findings == 0 else 0
    connection.execute(
        "DELETE FROM sessions WHERE run_id=? AND source='no-mistakes'",
        (run["run_id"],),
    )
    connection.execute(
        "DELETE FROM quality_findings WHERE run_id=? AND source LIKE 'no-mistakes:%'",
        (run["run_id"],),
    )
    connection.execute(
        "DELETE FROM evidence WHERE run_id=? AND kind IN ('no-mistakes-run','no-mistakes-pr','quality-log')",
        (run["run_id"],),
    )
    for nm_run in matched:
        nm_id = safe_identifier(nm_run["id"], "nm") or stable_key(nm_run["id"])
        nm_ref = f"no-mistakes://run/{nm_id}"
        evidence(connection, str(run["run_id"]), "no-mistakes-run", nm_ref)
        if nm_run["pr_url"]:
            evidence(connection, str(run["run_id"]), "no-mistakes-pr", str(nm_run["pr_url"]))
        try:
            aggregate = source.execute(
                """SELECT COALESCE(SUM(input_tokens),0) AS input_tokens,
                          COALESCE(SUM(output_tokens),0) AS output_tokens,
                          COALESCE(SUM(cache_read_tokens),0) AS cache_read_tokens,
                          COALESCE(SUM(cache_creation_tokens),0) AS cache_write_tokens,
                          COALESCE(SUM(reasoning_tokens),0) AS reasoning_tokens,
                          COALESCE(SUM(model_roundtrips),0) AS turns,
                          MIN(started_at) AS started_at, MAX(completed_at) AS ended_at,
                          MAX(model) AS model
                     FROM agent_invocations WHERE run_id=?""",
                (nm_run["id"],),
            ).fetchone()
        except sqlite3.Error:
            aggregate = None
        if aggregate and any(integer(aggregate[key]) for key in (
            "input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"
        )):
            metrics = blank_metrics("no-mistakes", Path(nm_ref))
            metrics.update({
                "native_session_id": nm_id,
                "model": safe_identifier(aggregate["model"], "model"),
                "started_at": parse_time(aggregate["started_at"]),
                "ended_at": parse_time(aggregate["ended_at"]),
                "tokens_input": integer(aggregate["input_tokens"]),
                "tokens_output": integer(aggregate["output_tokens"]),
                "tokens_cache_read": integer(aggregate["cache_read_tokens"]),
                "tokens_cache_write": integer(aggregate["cache_write_tokens"]),
                "tokens_reasoning": integer(aggregate["reasoning_tokens"]),
                "turns": integer(aggregate["turns"]),
                "evidence_ref": nm_ref,
            })
            metrics["tokens_total"] = (
                metrics["tokens_input"] + metrics["tokens_output"]
                + metrics["tokens_cache_read"] + metrics["tokens_cache_write"]
            )
            upsert_session(connection, str(run["run_id"]), metrics)
        try:
            rounds = source.execute(
                """SELECT s.step_name,s.log_path,q.round,q.trigger_type,
                          q.findings_json,q.user_findings_json
                     FROM step_rounds q JOIN step_results s ON s.id=q.step_result_id
                    WHERE s.run_id=? ORDER BY s.step_name,q.round LIMIT 500""",
                (nm_run["id"],),
            ).fetchall()
        except sqlite3.Error:
            rounds = []
        by_step: dict[str, list[tuple[int, list[tuple[str, Optional[str]]], Optional[str], str]]] = collections.defaultdict(list)
        for round_row in rounds:
            combined = findings(round_row["findings_json"])
            user_rows = findings(round_row["user_findings_json"])
            existing = {item[0] for item in combined}
            combined.extend(item for item in user_rows if item[0] not in existing)
            step = safe_identifier(round_row["step_name"], "step") or "step"
            by_step[step].append((integer(round_row["round"]), combined, round_row["log_path"], str(round_row["trigger_type"])))
        for step, step_rounds in by_step.items():
            final_ids = {item[0] for item in step_rounds[-1][1]}
            first_seen: dict[str, tuple[Optional[str], Optional[str], int]] = {}
            for round_no, items, log_path, _ in step_rounds:
                if log_path:
                    evidence(connection, str(run["run_id"]), "quality-log", str(log_path))
                for finding_id, severity in items:
                    first_seen.setdefault(finding_id, (severity, log_path, round_no))
            for finding_id, (severity, log_path, round_no) in first_seen.items():
                source_name = f"no-mistakes:{nm_id}:{step}:{round_no}"
                source_key = stable_key("quality", run["run_id"], nm_id, step, finding_id)
                connection.execute(
                    """INSERT INTO quality_findings(
                         source_key,run_id,finding_id,severity,resolved,source,evidence_ref)
                       VALUES(?,?,?,?,?,?,?)
                       ON CONFLICT(source_key) DO UPDATE SET
                         severity=excluded.severity,resolved=excluded.resolved,
                         source=excluded.source,evidence_ref=excluded.evidence_ref""",
                    (
                        source_key, run["run_id"], finding_id, severity,
                        0 if finding_id in final_ids else 1, source_name,
                        str(log_path) if log_path else nm_ref,
                    ),
                )
    latest = matched[-1] if matched else None
    source.close()
    return (
        len(matched), first_pass,
        str(latest["status"]) if latest and latest["status"] else None,
        str(latest["pr_state"]) if latest and latest["pr_state"] else None,
        str(latest["pr_url"]) if latest and latest["pr_url"] else None,
        parse_time(latest["updated_at"]) if latest else None,
    )


def git_correlation(connection: sqlite3.Connection, run: dict[str, Any]) -> tuple[Optional[str], Optional[str]]:
    worktree = str(run.get("worktree_ref") or "")
    if not worktree or not Path(worktree).is_dir():
        return None, None
    branch = run_command(["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd=worktree)
    head = run_command(["git", "rev-parse", "--verify", "HEAD"], cwd=worktree)
    if branch:
        evidence(connection, str(run["run_id"]), "branch", branch)
    if head:
        evidence(connection, str(run["run_id"]), "commit-head", head)
    base = run.get("base_commit_ref")
    if base and head:
        commits = run_command(
            ["git", "rev-list", f"--max-count={MAX_COMMITS}", f"{base}..{head}"],
            cwd=worktree,
        )
        for commit in (commits or "").splitlines():
            if re.fullmatch(r"[0-9a-fA-F]{40,64}", commit):
                evidence(connection, str(run["run_id"]), "commit", commit)
    return branch, head


def insert_status_events(
    connection: sqlite3.Connection,
    run: dict[str, Any],
    status_path: Path,
    status_start_line: int,
) -> None:
    try:
        fallback_time = int(status_path.stat().st_mtime)
    except OSError:
        return
    for byte_offset, line_no, line in tail_status(status_path):
        state, event_key, observed, line_run, line_session = status_fields(line)
        if state is None:
            continue
        if line_run and line_run != run["run_id"]:
            continue
        if not line_run and (line_no is None or line_no <= status_start_line):
            continue
        observed = observed or fallback_time
        source_key = stable_key(
            "status", run["run_id"], status_path, byte_offset,
            event_key or "", line_session or "",
        )
        connection.execute(
            """INSERT OR IGNORE INTO events(
                 source_key,run_id,observed_at,event_type,state,event_key,source_ref,source_line)
               VALUES(?,?,?,?,?,?,?,?)""",
            (
                source_key, run["run_id"], observed, "status", state,
                event_key, str(status_path), line_no,
            ),
        )
    evidence(connection, str(run["run_id"]), "status-log", str(status_path))


def outcome_and_interventions(
    connection: sqlite3.Connection,
    run_id: str,
    now: int,
) -> tuple[str, Optional[int], Optional[int], int, int]:
    rows = connection.execute(
        "SELECT observed_at,state,event_key,source_line FROM events WHERE run_id=? ORDER BY observed_at,source_line",
        (run_id,),
    ).fetchall()
    first_activity = rows[0]["observed_at"] if rows else None
    outcome = "active"
    ended: Optional[int] = None
    intervention_count = 0
    wait_seconds = 0
    open_waits: dict[str, int] = {}
    for row in rows:
        state = row["state"]
        key = row["event_key"] or "default"
        stamp = int(row["observed_at"])
        if state in {"needs-decision", "blocked"}:
            intervention_count += 1
            open_waits[key] = stamp
        elif state in {"resolved", "captain-held"}:
            if key in open_waits:
                wait_seconds += max(0, stamp - open_waits.pop(key))
        if state == "done":
            outcome, ended = "completed", stamp
        elif state == "failed":
            outcome, ended = "failed", stamp
        elif state == "blocked":
            outcome, ended = "blocked", None
        elif state == "needs-decision":
            outcome, ended = "waiting-decision", None
        elif state == "paused":
            outcome, ended = "paused", None
        elif state in {"working", "resolved"}:
            outcome, ended = "active", None
    stop = ended or now
    for opened in open_waits.values():
        wait_seconds += max(0, stop - opened)
    return outcome, ended, first_activity, intervention_count, wait_seconds


def summarize_run(
    connection: sqlite3.Connection,
    run_id: str,
    first_pass: Optional[int],
    nm_runs: int,
) -> None:
    totals = connection.execute(
        """SELECT COALESCE(SUM(tokens_input),0) AS ti,
                  COALESCE(SUM(tokens_output),0) AS tout,
                  COALESCE(SUM(tokens_cache_read),0) AS tcr,
                  COALESCE(SUM(tokens_cache_write),0) AS tcw,
                  COALESCE(SUM(tokens_reasoning),0) AS tr,
                  COALESCE(SUM(tokens_total),0) AS tt,
                  CASE WHEN COUNT(cost_usd)>0 THEN SUM(cost_usd) END AS cost,
                  COALESCE(SUM(turns),0) AS turns
             FROM sessions WHERE run_id=?""",
        (run_id,),
    ).fetchone()
    quality = connection.execute(
        "SELECT COUNT(*) AS findings,COALESCE(SUM(CASE WHEN resolved=0 THEN 1 ELSE 0 END),0) AS unresolved FROM quality_findings WHERE run_id=?",
        (run_id,),
    ).fetchone()
    connection.execute(
        """UPDATE runs SET tokens_input=?,tokens_output=?,tokens_cache_read=?,
             tokens_cache_write=?,tokens_reasoning=?,tokens_total=?,cost_usd=?,turns=?,
             retries=?,first_pass_quality=?,quality_findings=?,quality_unresolved=?,
             no_mistakes_runs=? WHERE run_id=?""",
        (
            totals["ti"], totals["tout"], totals["tcr"], totals["tcw"],
            totals["tr"], totals["tt"], totals["cost"], totals["turns"],
            max(0, nm_runs - 1), first_pass, quality["findings"],
            quality["unresolved"], nm_runs, run_id,
        ),
    )


def collect_one(
    connection: sqlite3.Connection,
    state: Path,
    meta_path: Path,
    max_files: int,
    max_bytes: int,
    no_mistakes_db: Path,
) -> Optional[str]:
    task_id = meta_path.stem
    if not TASK_RE.fullmatch(task_id):
        return None
    meta = parse_meta(meta_path)
    if not meta:
        return None
    task_id = meta.get("task_id") if TASK_RE.fullmatch(meta.get("task_id", "")) else task_id
    meta_mtime = int(meta_path.stat().st_mtime)
    started_at = parse_time(meta.get("started_at")) or meta_mtime
    run_id = safe_identifier(meta.get("run_id"), "run") or f"legacy-{task_id}-{started_at}"
    session_id = safe_identifier(meta.get("session_id"), "session") or f"{run_id}-s1"
    worktree = meta.get("worktree") or meta.get("project") or ""
    project = meta.get("project") or worktree
    runtime = meta.get("backend") or "tmux"
    task_class = meta.get("kind") or "ship"
    now = int(time.time())
    run = {
        "run_id": run_id,
        "task_id": task_id,
        "session_id": session_id,
        "project_ref": project,
        "worktree_ref": worktree,
        "branch_ref": None,
        "base_commit_ref": meta.get("base_commit"),
        "commit_ref": meta.get("pr_head"),
        "pr_ref": meta.get("pr"),
        "harness": meta.get("harness") or "unknown",
        "runtime": runtime,
        "model": meta.get("model") or "default",
        "effort": meta.get("effort") or "default",
        "task_class": task_class,
        "started_at": started_at,
    }
    connection.execute(
        """INSERT INTO runs(
             run_id,task_id,session_id,project_ref,worktree_ref,branch_ref,
             base_commit_ref,commit_ref,pr_ref,harness,runtime,model,effort,
             task_class,started_at,last_seen_at,outcome)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(run_id) DO UPDATE SET
             task_id=excluded.task_id,session_id=excluded.session_id,
             project_ref=excluded.project_ref,worktree_ref=excluded.worktree_ref,
             base_commit_ref=COALESCE(excluded.base_commit_ref,runs.base_commit_ref),
             commit_ref=COALESCE(excluded.commit_ref,runs.commit_ref),
             pr_ref=COALESCE(excluded.pr_ref,runs.pr_ref),harness=excluded.harness,
             runtime=excluded.runtime,model=excluded.model,effort=excluded.effort,
             task_class=excluded.task_class,last_seen_at=excluded.last_seen_at""",
        (
            run_id, task_id, session_id, project, worktree, None,
            meta.get("base_commit"), meta.get("pr_head"), meta.get("pr"),
            run["harness"], runtime, run["model"], run["effort"], task_class,
            started_at, now, "active",
        ),
    )
    evidence(connection, run_id, "task-meta", str(meta_path))
    evidence(connection, run_id, "worktree", worktree)
    evidence(connection, run_id, "project", project)
    evidence(connection, run_id, "pr", meta.get("pr"))
    evidence(connection, run_id, "commit-pr-head", meta.get("pr_head"))
    branch, head = git_correlation(connection, run)
    if branch:
        run["branch_ref"] = branch
    if head:
        run["commit_ref"] = head
    connection.execute(
        "UPDATE runs SET branch_ref=COALESCE(?,branch_ref),commit_ref=COALESCE(?,commit_ref) WHERE run_id=?",
        (branch, head, run_id),
    )
    status_start = integer(meta.get("status_start_line"))
    insert_status_events(connection, run, state / f"{task_id}.status", status_start)
    outcome, ended, first_activity, interventions, waits = outcome_and_interventions(connection, run_id, now)
    nm_runs, first_pass, nm_status, nm_pr_state, nm_pr, nm_ended = collect_no_mistakes(
        connection, run, no_mistakes_db
    )
    if nm_pr:
        connection.execute("UPDATE runs SET pr_ref=? WHERE run_id=?", (nm_pr, run_id))
    if nm_pr_state == "merged":
        outcome = "landed"
        ended = nm_ended or ended
    elif nm_status == "completed" and outcome == "active":
        outcome = "done-verified"
        ended = nm_ended or ended
    collect_harness_sessions(connection, run, max_files, max_bytes, ended)
    summarize_run(connection, run_id, first_pass, nm_runs)
    connection.execute(
        """UPDATE runs SET first_activity_at=?,last_seen_at=?,ended_at=?,outcome=?,
             intervention_count=?,wait_seconds=? WHERE run_id=?""",
        (first_activity, now, ended, outcome, interventions, waits, run_id),
    )
    return run_id


def prune(connection: sqlite3.Connection, retention_days: int, now: Optional[int] = None) -> int:
    cutoff = (now or int(time.time())) - max(1, retention_days) * 86400
    cursor = connection.execute(
        "DELETE FROM runs WHERE COALESCE(ended_at,last_seen_at) < ?", (cutoff,)
    )
    return max(0, cursor.rowcount)


def fmt_duration(seconds: Optional[float]) -> str:
    if seconds is None:
        return "-"
    seconds = max(0, int(seconds))
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds / 60:.1f}m"
    if seconds < 86400:
        return f"{seconds / 3600:.1f}h"
    return f"{seconds / 86400:.1f}d"


def fmt_money(value: Optional[float]) -> str:
    return "-" if value is None else f"${value:.4f}"


def pct(numerator: int, denominator: int) -> str:
    return "-" if denominator == 0 else f"{100 * numerator / denominator:.1f}%"


def dashboard(connection: sqlite3.Connection, output: Path) -> None:
    rows = [dict(row) for row in connection.execute("SELECT * FROM runs ORDER BY started_at DESC")]
    total = len(rows)
    successes = [row for row in rows if row["outcome"] in SUCCESS_OUTCOMES]
    completed = [row for row in rows if row["ended_at"] is not None]
    known_success_costs = [float(row["cost_usd"]) for row in successes if row["cost_usd"] is not None]
    durations = [row["ended_at"] - row["started_at"] for row in completed]
    waits = [row["wait_seconds"] for row in rows if row["wait_seconds"] > 0]
    quality_rows = [row for row in rows if row["first_pass_quality"] is not None]
    quality_passes = sum(1 for row in quality_rows if row["first_pass_quality"] == 1)
    interventions = sum(int(row["intervention_count"]) for row in rows)
    outcomes = collections.Counter(row["outcome"] for row in rows)
    groups: dict[tuple[str, str, str, str], list[dict[str, Any]]] = collections.defaultdict(list)
    for row in rows:
        key = (row["model"] or "default", row["harness"] or "unknown", row["runtime"] or "tmux", row["task_class"])
        groups[key].append(row)

    def card(label: str, value: str, note: str) -> str:
        return f'<div class="card"><span>{html.escape(label)}</span><strong>{html.escape(value)}</strong><small>{html.escape(note)}</small></div>'

    outcome_rows = "".join(
        f"<tr><td>{html.escape(name)}</td><td>{count}</td><td>{pct(count,total)}</td></tr>"
        for name, count in sorted(outcomes.items())
    ) or '<tr><td colspan="3">No collected runs.</td></tr>'

    comparison_rows = []
    for (model, harness, runtime, task_class), items in sorted(groups.items()):
        good = [item for item in items if item["outcome"] in SUCCESS_OUTCOMES]
        group_costs = [float(item["cost_usd"]) for item in good if item["cost_usd"] is not None]
        group_durations = [item["ended_at"] - item["started_at"] for item in items if item["ended_at"]]
        group_quality = [item for item in items if item["first_pass_quality"] is not None]
        group_quality_pass = sum(1 for item in group_quality if item["first_pass_quality"] == 1)
        comparison_rows.append(
            "<tr>"
            f"<td>{html.escape(model)}</td><td>{html.escape(harness)}</td>"
            f"<td>{html.escape(runtime)}</td><td>{html.escape(task_class)}</td>"
            f"<td>{len(items)}</td><td>{pct(len(good),len(items))}</td>"
            f"<td>{fmt_money(sum(group_costs)/len(group_costs) if group_costs else None)}</td>"
            f"<td>{fmt_duration(statistics.median(group_durations) if group_durations else None)}</td>"
            f"<td>{pct(group_quality_pass,len(group_quality))}</td></tr>"
        )
    comparisons = "".join(comparison_rows) or '<tr><td colspan="9">No comparison samples.</td></tr>'

    recent_rows = []
    for row in rows[:50]:
        duration = row["ended_at"] - row["started_at"] if row["ended_at"] else None
        quality = "-" if row["first_pass_quality"] is None else ("pass" if row["first_pass_quality"] else "findings")
        recent_rows.append(
            "<tr>"
            f"<td><code>{html.escape(row['task_id'])}</code></td>"
            f"<td>{html.escape(row['outcome'])}</td>"
            f"<td>{html.escape(row['model'] or 'default')}</td>"
            f"<td>{fmt_duration(duration)}</td><td>{fmt_duration(row['wait_seconds'])}</td>"
            f"<td>{row['intervention_count']}</td><td>{html.escape(quality)}</td>"
            f"<td>{row['quality_findings']}</td><td>{fmt_money(row['cost_usd'])}</td>"
            f"<td>{row['tokens_total']}</td></tr>"
        )
    recent = "".join(recent_rows) or '<tr><td colspan="10">No collected runs.</td></tr>'

    generated = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    content = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Firstmate task observability</title>
<style>
:root{{--ink:#17202a;--muted:#64748b;--paper:#f5f7f9;--card:#fff;--line:#dbe2e8;--accent:#0f766e}}
*{{box-sizing:border-box}} body{{margin:0;background:var(--paper);color:var(--ink);font:14px/1.45 ui-sans-serif,system-ui,sans-serif}}
main{{max-width:1280px;margin:auto;padding:32px 20px 64px}} h1{{margin:0;font-size:30px}} .sub{{color:var(--muted);margin:4px 0 24px}}
.cards{{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px}} .card{{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px}}
.card span,.card small{{display:block;color:var(--muted)}} .card strong{{display:block;font-size:26px;margin:5px 0}} section{{margin-top:28px}}
.table{{overflow:auto;background:var(--card);border:1px solid var(--line);border-radius:12px}} table{{border-collapse:collapse;width:100%}} th,td{{padding:10px 12px;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}} th{{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}} tr:last-child td{{border-bottom:0}} code{{color:var(--accent)}}
</style></head><body><main>
<h1>Task observability</h1><p class="sub">Local, static, privacy-safe pilot · generated {html.escape(generated)} · schema v{SCHEMA_VERSION}</p>
<div class="cards">
{card('Successful outcomes',pct(len(successes),total),f'{len(successes)} of {total} retained runs')}
{card('Known cost / success',fmt_money(sum(known_success_costs)/len(known_success_costs) if known_success_costs else None),f'cost coverage {len(known_success_costs)} successful runs')}
{card('Median duration',fmt_duration(statistics.median(durations) if durations else None),f'{len(durations)} terminal samples')}
{card('Median wait',fmt_duration(statistics.median(waits) if waits else None),f'{len(waits)} runs with waits')}
{card('First-pass quality',pct(quality_passes,len(quality_rows)),f'n={len(quality_rows)} no-mistakes samples')}
{card('Interventions',str(interventions),f'across {total} retained runs')}
</div>
<section><h2>Outcomes</h2><div class="table"><table><thead><tr><th>Outcome</th><th>Runs</th><th>Share</th></tr></thead><tbody>{outcome_rows}</tbody></table></div></section>
<section><h2>Model × task class</h2><div class="table"><table><thead><tr><th>Model</th><th>Harness</th><th>Runtime</th><th>Task class</th><th>n</th><th>Success</th><th>Known cost / success</th><th>Median duration</th><th>First pass</th></tr></thead><tbody>{comparisons}</tbody></table></div></section>
<section><h2>Recent runs</h2><div class="table"><table><thead><tr><th>Task</th><th>Outcome</th><th>Model</th><th>Duration</th><th>Wait</th><th>Interventions</th><th>First pass</th><th>Findings</th><th>Known cost</th><th>Tokens</th></tr></thead><tbody>{recent}</tbody></table></div></section>
</main></body></html>"""
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(output)


def paths(args: argparse.Namespace) -> tuple[Path, Path, Path]:
    root = Path(__file__).resolve().parent.parent
    home = Path(os.environ.get("FM_HOME") or os.environ.get("FM_ROOT_OVERRIDE") or root).resolve()
    data = Path(os.environ.get("FM_DATA_OVERRIDE") or home / "data").resolve()
    database = Path(args.db).expanduser() if args.db else data / "observability.sqlite3"
    report = Path(args.dashboard).expanduser() if args.dashboard else data / "observability.html"
    return home, database, report


def parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--db", help="local SQLite path")
    common.add_argument("--dashboard", help="static HTML path")
    top = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = top.add_subparsers(dest="command", required=True)
    collect_parser = commands.add_parser("collect", parents=[common], help="collect current task records")
    collect_parser.add_argument("--task", help="collect one task id")
    collect_parser.add_argument("--retention-days", type=int, default=DEFAULT_RETENTION_DAYS)
    collect_parser.add_argument("--max-session-files", type=int, default=DEFAULT_MAX_SESSION_FILES)
    collect_parser.add_argument("--max-session-bytes", type=int, default=DEFAULT_MAX_SESSION_BYTES)
    collect_parser.add_argument("--no-dashboard", action="store_true")
    dashboard_parser = commands.add_parser("dashboard", parents=[common], help="render HTML from the database")
    dashboard_parser.set_defaults(retention_days=DEFAULT_RETENTION_DAYS)
    prune_parser = commands.add_parser("prune", parents=[common], help="apply retention without collecting")
    prune_parser.add_argument("--retention-days", type=int, default=DEFAULT_RETENTION_DAYS)
    return top


def main() -> int:
    args = parser().parse_args()
    os.umask(0o077)
    home, database, report = paths(args)
    connection = open_database(database)
    try:
        if args.command == "dashboard":
            dashboard(connection, report)
            print(f"dashboard: {report}")
            return 0
        if args.command == "prune":
            removed = prune(connection, args.retention_days)
            connection.commit()
            print(f"pruned: {removed} runs")
            return 0
        if args.task and not TASK_RE.fullmatch(args.task):
            raise RuntimeError("invalid task id")
        state = Path(os.environ.get("FM_STATE_OVERRIDE") or home / "state").resolve()
        if args.task:
            meta_files = [state / f"{args.task}.meta"]
        else:
            meta_files = sorted(state.glob("*.meta"))[:MAX_META_FILES] if state.is_dir() else []
        no_mistakes_db = Path(
            os.environ.get("FM_NO_MISTAKES_DB", str(Path.home() / ".no-mistakes/state.sqlite"))
        ).expanduser()
        collected = 0
        for meta_path in meta_files:
            if not meta_path.is_file() or meta_path.is_symlink():
                continue
            if collect_one(
                connection, state, meta_path,
                max(0, args.max_session_files), max(1, args.max_session_bytes),
                no_mistakes_db,
            ):
                collected += 1
        removed = prune(connection, args.retention_days)
        connection.commit()
        if not args.no_dashboard:
            dashboard(connection, report)
        print(f"collected: {collected} runs; pruned: {removed}; database: {database}")
        if not args.no_dashboard:
            print(f"dashboard: {report}")
        return 0
    finally:
        connection.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, sqlite3.Error) as error:
        eprint(f"error: {error}")
        raise SystemExit(1)
