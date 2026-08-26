#!/usr/bin/env python3
"""Always-on loopback server and Kanban projection for the Firstmate fleet board.

The server is deliberately dependency-free and local-only.
It reads bin/fm-fleet-snapshot.sh, keeps a short single-flight cache, serves the
bundled application, and sends captain actions through bin/fm-inbox.sh.
It never writes task status or carries a second task store.
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import json
import os
import pathlib
import re
import secrets
import selectors
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


LANES = [
    {"id": "backlog", "label": "Backlog", "description": "Ready to start"},
    {"id": "in_progress", "label": "In Progress", "description": "Crew is working"},
    {"id": "verification", "label": "Verification", "description": "Tests and review"},
    {"id": "needs_you", "label": "Needs You", "description": "Captain decision"},
    {"id": "waiting", "label": "Waiting", "description": "Blocked or paused"},
    {"id": "done", "label": "Done", "description": "Recently landed"},
]
LANE_PRIORITY = {
    "done": 0,
    "backlog": 1,
    "waiting": 2,
    "in_progress": 3,
    "verification": 4,
    "needs_you": 5,
}
SLUG = re.compile(r"^[A-Za-z0-9._-]{1,160}$")
MAX_ACTION_BYTES = 8_192
MAX_REQUEST_BYTES = MAX_ACTION_BYTES * 6 + 2_048
MAX_HEALTH_BYTES = 4_096
MAX_HEALTH_HEADER_BYTES = 16_384
MAX_ACTION_STATUS_IDS = 100
DEFAULT_SNAPSHOT_STDOUT_BYTES = 32 * 1_024 * 1_024
DEFAULT_SNAPSHOT_STDERR_BYTES = 64 * 1_024
MAX_CONFIGURED_SNAPSHOT_BYTES = 256 * 1_024 * 1_024
STATIC_ASSETS = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/board-state.js": ("board-state.js", "text/javascript; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
}


class BoardError(RuntimeError):
    """A safe, user-facing board failure."""


def compact(value: Any, limit: int = 240) -> str | None:
    if value is None:
        return None
    text = re.sub(r"\s+", " ", str(value)).strip()
    if not text:
        return None
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def stored_request_matches(path: pathlib.Path, request_id: str) -> bool:
    try:
        with path.open("r", encoding="utf-8") as note:
            header = note.read(2_048).split("\n--\n", 1)[0]
    except (OSError, UnicodeDecodeError):
        return False
    return f"\nrequest_id={request_id}\n" in f"\n{header}\n"


def configured_byte_limit(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as error:
        raise BoardError(f"{name} must be an integer byte count") from error
    if not 1_024 <= value <= MAX_CONFIGURED_SNAPSHOT_BYTES:
        raise BoardError(
            f"{name} must be between 1024 and {MAX_CONFIGURED_SNAPSHOT_BYTES} bytes"
        )
    return value


def home_key(namespace: str, home_id: str) -> str:
    return f"{namespace}:{home_id}"


def card_key(namespace: str, home_id: str, task_id: str) -> str:
    return f"{home_key(namespace, home_id)}:{task_id}"


def operation_scope(home: pathlib.Path) -> str:
    return hashlib.sha256(str(home).encode("utf-8")).hexdigest()


def safe_risk(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        return {"level": "unknown", "rationale": None, "source": "absent"}
    level = value.get("level")
    rationale = compact(value.get("rationale"), 240)
    source = value.get("source")
    if level not in {"low", "medium", "high"}:
        return {
            "level": "unknown",
            "rationale": None,
            "source": source if source in {"absent", "invalid"} else "absent",
        }
    return {"level": level, "rationale": rationale, "source": source or "task-body"}


def evidence_for(record: dict[str, Any], task: dict[str, Any] | None) -> list[dict[str, Any]]:
    evidence: list[dict[str, Any]] = []
    pr_url = record.get("pr_url") or ((task or {}).get("pr") or {}).get("url")
    report_path = record.get("report_path") or (
        (((task or {}).get("paths") or {}).get("report") or {}).get("path")
        if (((task or {}).get("paths") or {}).get("report") or {}).get("present")
        else None
    )
    if pr_url:
        evidence.append({"kind": "pull_request", "label": "Pull request", "value": pr_url, "url": pr_url})
    if report_path:
        evidence.append({"kind": "report", "label": "Report", "value": report_path, "url": None})
    state = (task or {}).get("current_state") or {}
    if compact(state.get("detail"), 280):
        evidence.append({"kind": "activity", "label": "Current activity", "value": compact(state.get("detail"), 280), "url": None})
    blockers = record.get("unresolved_blocker_ids") or []
    if blockers:
        evidence.append({"kind": "blockers", "label": "Blocked by", "value": ", ".join(map(str, blockers)), "url": None})
    for url in record.get("links") or []:
        if url != pr_url:
            evidence.append({"kind": "link", "label": "Evidence link", "value": url, "url": url})
    return evidence


def main_lane(record: dict[str, Any], task: dict[str, Any] | None) -> str:
    current = (task or {}).get("current_state") or {}
    current_state = current.get("state")
    if record.get("state") == "done" and (task is None or current_state == "done"):
        return "done"
    if record.get("deferred_marker"):
        return "waiting"
    hints = (task or {}).get("hints") or {}
    if record.get("captain_actionable") or hints.get("pending_decision") or hints.get("blocked_event"):
        return "needs_you"
    if hints.get("open_decisions"):
        return "needs_you"
    if record.get("state") == "in_flight" and record.get("current_role") == "program":
        return "in_progress"
    # A task's live state is newer than its backlog row. Backlog movement can lag
    # worker startup, so a still-Queued row must not hide work already underway.
    state = current_state
    source = current.get("source")
    if state == "working" and source == "run-step":
        return "verification"
    if state == "working":
        return "in_progress"
    if state == "done":
        return "verification"
    if record.get("state") == "queued":
        if record.get("hold_reason") or record.get("unresolved_blocker_ids"):
            return "waiting"
        return "backlog"
    if state in {"parked", "paused", "blocked", "failed", "unknown"} or task is None:
        return "waiting"
    return "in_progress"


def status_for(lane: str, record: dict[str, Any], task: dict[str, Any] | None) -> dict[str, Any]:
    current = (task or {}).get("current_state") or {}
    detail = compact(current.get("detail"), 280)
    wait_reason = compact(
        record.get("hold_reason")
        or record.get("blocked_reason")
        or ("Marked deferred in task context" if record.get("deferred_marker") else None)
        or (detail if lane in {"waiting", "needs_you"} else None),
        280,
    )
    labels = {
        "backlog": "Ready in backlog",
        "in_progress": "Work underway",
        "verification": "Being verified",
        "needs_you": "Waiting for you",
        "waiting": "Waiting",
        "done": "Completed",
    }
    return {
        "label": labels[lane],
        "detail": detail,
        "source": current.get("source") or ("backlog" if record.get("state") else "unknown"),
        "wait_reason": wait_reason,
        "waiting_for_captain": lane == "needs_you",
    }


def decisions_for(
    record: dict[str, Any], task: dict[str, Any] | None, task_id: str | None, lane: str
) -> list[dict[str, Any]]:
    decisions: list[dict[str, Any]] = []
    hints = (task or {}).get("hints") or {}
    open_decisions = hints.get("open_decisions") or []
    candidates = open_decisions if isinstance(open_decisions, list) else []
    if record.get("verb") in {"needs-decision", "captain-hold"}:
        candidates = [record, *candidates]
    for candidate in candidates:
        if not isinstance(candidate, dict):
            continue
        key = candidate.get("key")
        if not isinstance(key, str) or not SLUG.fullmatch(key):
            continue
        decision = {
            "key": key,
            "verb": compact(candidate.get("verb"), 40) or "needs-decision",
            "summary": compact(
                candidate.get("summary") or candidate.get("reason") or record.get("hold_reason"),
                280,
            )
            or "Captain decision required",
            "reason": compact(candidate.get("reason"), 280),
        }
        if not any(existing["key"] == key for existing in decisions):
            decisions.append(decision)
    if not decisions and task_id and lane == "needs_you":
        decisions.append(
            {
                "key": task_id,
                "verb": "captain-hold",
                "summary": compact(
                    record.get("hold_reason")
                    or record.get("blocked_reason")
                    or ((task or {}).get("current_state") or {}).get("detail"),
                    280,
                )
                or "Captain decision required",
                "reason": None,
            }
        )
    return decisions


def base_card(
    *,
    key: str,
    task_id: str | None,
    title: str,
    lane: str,
    home_namespace: str,
    home_id: str,
    home_label: str,
    remote: bool,
    record: dict[str, Any],
    task: dict[str, Any] | None,
    generated: str,
) -> dict[str, Any]:
    is_open = lane != "done"
    decisions = decisions_for(record, task, task_id, lane)
    return {
        "key": key,
        "id": task_id,
        "title": compact(title, 180) or "Untitled task",
        "lane": lane,
        "home": {
            "key": home_key(home_namespace, home_id),
            "namespace": home_namespace,
            "id": home_id,
            "label": home_label,
            "remote": remote,
        },
        "repo": compact(record.get("repo") or (task or {}).get("project"), 120),
        "kind": compact(record.get("kind") or (task or {}).get("kind"), 40),
        "risk": safe_risk(record.get("risk")),
        "status": status_for(lane, record, task),
        "context": compact(record.get("context") or record.get("body_excerpt"), 1200),
        "evidence": evidence_for(record, task),
        "decisions": decisions,
        "blocked_by": record.get("unresolved_blocker_ids") or record.get("blocked_by_ids") or [],
        "actions": {
            "answer": bool(task_id and lane == "needs_you" and decisions),
            "request_details": bool(task_id and is_open),
        },
        "provenance": "registered-secondmate" if home_namespace == "secondmate" else "primary-home",
        "observed_at": generated,
    }


def merge_card(cards: dict[str, dict[str, Any]], card: dict[str, Any]) -> None:
    existing = cards.get(card["key"])
    if not existing:
        cards[card["key"]] = card
        return
    if LANE_PRIORITY[card["lane"]] >= LANE_PRIORITY[existing["lane"]]:
        preferred, fallback = card, existing
    else:
        preferred, fallback = existing, card
    merged = copy.deepcopy(preferred)
    for field in ("title", "repo", "kind", "context"):
        if not merged.get(field):
            merged[field] = fallback.get(field)
    if merged["risk"]["level"] == "unknown" and fallback["risk"]["level"] != "unknown":
        merged["risk"] = fallback["risk"]
    seen = {(item.get("kind"), item.get("value")) for item in merged["evidence"]}
    merged["evidence"].extend(
        item for item in fallback["evidence"] if (item.get("kind"), item.get("value")) not in seen
    )
    decision_keys = {item.get("key") for item in merged["decisions"]}
    merged["decisions"].extend(
        item for item in fallback["decisions"] if item.get("key") not in decision_keys
    )
    merged["actions"] = {
        "answer": bool(merged["actions"]["answer"] or fallback["actions"]["answer"]),
        "request_details": bool(
            merged["actions"]["request_details"] or fallback["actions"]["request_details"]
        ),
    }
    cards[card["key"]] = merged


def board_from_snapshot(snapshot: Any) -> dict[str, Any]:
    if not isinstance(snapshot, dict):
        raise BoardError("Firstmate returned a malformed fleet snapshot")
    if snapshot.get("schema") != "fm-fleet-snapshot.v1":
        raise BoardError("Firstmate returned an unsupported fleet snapshot")
    generated = snapshot.get("generated") or ""
    home_path = snapshot.get("fm_home") or ""
    home_label = pathlib.Path(home_path).name or "Firstmate"
    tasks = {
        row.get("id"): row
        for row in snapshot.get("tasks") or []
        if row.get("id") and row.get("kind") != "secondmate"
    }
    cards: dict[str, dict[str, Any]] = {}
    warnings: list[str] = []

    structured_backlog_ids: set[str] = set()
    for record in (snapshot.get("backlog") or {}).get("records") or []:
        if not record.get("structured"):
            if record.get("state") == "done":
                continue
            key = card_key("primary", "primary", f"unstructured:{record.get('order', len(cards))}")
            card = base_card(
                key=key,
                task_id=None,
                title=record.get("raw") or "Unstructured backlog item",
                lane="backlog" if record.get("state") == "queued" else "waiting",
                home_namespace="primary",
                home_id="primary",
                home_label=home_label,
                remote=False,
                record=record,
                task=None,
                generated=generated,
            )
            merge_card(cards, card)
            continue
        task_id = record.get("id")
        if isinstance(task_id, str):
            structured_backlog_ids.add(task_id)
        task = tasks.get(task_id)
        lane = main_lane(record, task)
        card = base_card(
            key=card_key("primary", "primary", str(task_id)),
            task_id=task_id,
            title=record.get("title") or task_id,
            lane=lane,
            home_namespace="primary",
            home_id="primary",
            home_label=home_label,
            remote=False,
            record=record,
            task=task,
            generated=generated,
        )
        merge_card(cards, card)
        task_state = ((task or {}).get("current_state") or {}).get("state")
        if record.get("state") == "done" and task and task_state != "done":
            warnings.append(
                f"{task_id}: live primary task state {task_state or 'unknown'} conflicts with its Done backlog row"
            )
        elif record.get("state") == "queued" and task_state in {"working", "done"}:
            warnings.append(
                f"{task_id}: live primary task state {task_state} conflicts with its Queued backlog row"
            )

    for task_id, task in tasks.items():
        if task_id in structured_backlog_ids:
            continue
        current = task.get("current_state") or {}
        record = {
            "repo": task.get("project"),
            "kind": task.get("kind"),
            "risk": {"level": "unknown", "rationale": None, "source": "absent"},
            "context": current.get("detail"),
            "links": [],
        }
        lane = main_lane(record, task)
        merge_card(
            cards,
            base_card(
                key=card_key("primary", "primary", task_id),
                task_id=task_id if SLUG.fullmatch(task_id) else None,
                title=task_id,
                lane=lane,
                home_namespace="primary",
                home_id="primary",
                home_label=home_label,
                remote=False,
                record=record,
                task=task,
                generated=generated,
            ),
        )
        warnings.append(f"{task_id}: live primary task has no structured backlog record")

    inventory = snapshot.get("main_inventory") or {}
    if inventory.get("valid") is False:
        warnings.append(compact(inventory.get("reason"), 240) or "Primary task inventory is incomplete")

    secondmates = snapshot.get("secondmate_current") or {}
    registry = secondmates.get("registry") or {}
    if registry.get("complete") is False:
        registry_reason = compact(registry.get("reason"), 180)
        if not registry_reason:
            registry_reason = compact(", ".join(map(str, registry.get("reasons") or [])), 180)
        warnings.append(
            "Secondmate registry is incomplete"
            + (f": {registry_reason}" if registry_reason else "")
        )
    if secondmates.get("truncated"):
        warnings.append(f"{secondmates['truncated']} secondmate homes are omitted by the snapshot bound")
    for mate in secondmates.get("records") or []:
        mate_id = str(mate.get("id") or "unknown")
        mate_label = mate_id
        remote = bool(mate.get("remote"))
        if (mate.get("current") or {}).get("state") == "unknown":
            warnings.append(
                f"{mate_label}: {compact((mate.get('current') or {}).get('reason'), 180) or 'state unavailable'}"
            )
        counted_omissions: set[str] = set()
        for surface in (
            "programs",
            "active_children",
            "decisions_open",
            "holds",
            "queued",
            "landed",
            "endpoints",
        ):
            total = (mate.get("counts") or {}).get(surface)
            records = mate.get(surface)
            if not isinstance(total, int) or isinstance(total, bool) or not isinstance(records, list):
                continue
            shown = len(records)
            if total > shown:
                counted_omissions.add(surface)
                warnings.append(
                    f"{mate_label}: {total - shown} {surface.replace('_', ' ')} omitted by the snapshot bound"
                )
            elif total < shown:
                counted_omissions.add(surface)
                warnings.append(
                    f"{mate_label}: {surface.replace('_', ' ')} count reports {total}, but {shown} records were shown"
                )
        for omitted in mate.get("omitted") or []:
            if omitted.get("surface") in counted_omissions:
                continue
            warnings.append(
                f"{mate_label}: {omitted.get('count', 0)} {omitted.get('surface', 'records')} omitted by the snapshot bound"
            )

        def mate_card(
            item: dict[str, Any],
            lane: str,
            title: str | None = None,
            source: str | None = None,
        ) -> dict[str, Any]:
            task_id = str(item.get("id") or item.get("key") or "")
            record = dict(item)
            if lane == "needs_you":
                record["hold_reason"] = (
                    item.get("reason") or item.get("summary") or record.get("hold_reason")
                )
            elif lane == "waiting":
                record["hold_reason"] = item.get("reason") or record.get("hold_reason")
            task = {
                "id": task_id,
                "kind": item.get("kind"),
                "project": item.get("repo"),
                "current_state": {
                    "state": item.get("state"),
                    "source": item.get("source") or source,
                    "detail": item.get("doing") or item.get("reason"),
                },
            }
            return base_card(
                key=card_key("secondmate", mate_id, task_id),
                task_id=task_id if SLUG.fullmatch(task_id) else None,
                title=title or item.get("title") or item.get("summary") or task_id,
                lane=lane,
                home_namespace="secondmate",
                home_id=mate_id,
                home_label=mate_label,
                remote=remote,
                record=record,
                task=task,
                generated=generated,
            )

        for item in mate.get("queued") or []:
            if item.get("deferred_marker"):
                lane = "waiting"
            elif item.get("captain_actionable"):
                lane = "needs_you"
            elif item.get("hold_reason") or item.get("unresolved_blocker_ids"):
                lane = "waiting"
            else:
                lane = "backlog"
            merge_card(cards, mate_card(item, lane, source="backlog"))
        for item in mate.get("holds") or []:
            merge_card(cards, mate_card(item, "waiting"))
        for item in mate.get("programs") or []:
            lane = "waiting" if item.get("deferred_marker") else "in_progress"
            merge_card(cards, mate_card(item, lane, source="backlog"))
        for item in mate.get("active_children") or []:
            lane = "verification" if item.get("source") == "run-step" else "in_progress"
            merge_card(cards, mate_card(item, lane))
        for item in mate.get("decisions_open") or []:
            lane = "waiting" if item.get("deferred_marker") else "needs_you"
            merge_card(cards, mate_card(item, lane))
        for item in mate.get("landed") or []:
            merge_card(cards, mate_card(item, "done", source="backlog"))

    rows = list(cards.values())
    rows.sort(
        key=lambda card: (
            0 if card["lane"] == "needs_you" else 1,
            {"high": 0, "medium": 1, "low": 2, "unknown": 3}[card["risk"]["level"]],
            card["title"].casefold(),
        )
    )
    counts = {lane["id"]: sum(card["lane"] == lane["id"] for card in rows) for lane in LANES}
    homes = sorted(
        {card["home"]["key"]: card["home"] for card in rows}.values(),
        key=lambda home: (home["namespace"] != "primary", home["label"].casefold()),
    )
    return {
        "schema": "fm-fleet-board.v1",
        "generated": generated,
        "lanes": LANES,
        "cards": rows,
        "counts": counts,
        "summary": {
            "open": sum(card["lane"] != "done" for card in rows),
            "needs_you": counts["needs_you"],
            "high_risk_open": sum(
                card["lane"] != "done" and card["risk"]["level"] == "high" for card in rows
            ),
        },
        "homes": homes,
        "warnings": list(dict.fromkeys(warnings)),
    }


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    if process.poll() is not None:
        return
    try:
        process.wait(timeout=0.5)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    process.wait()


def run_bounded_snapshot(
    command: list[str],
    *,
    env: dict[str, str],
    timeout: float,
    stdout_limit: int,
    stderr_limit: int,
) -> subprocess.CompletedProcess[bytes]:
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        start_new_session=True,
    )
    assert process.stdout is not None
    assert process.stderr is not None
    streams = {
        process.stdout: ("stdout", stdout_limit),
        process.stderr: ("stderr", stderr_limit),
    }
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    selector = selectors.DefaultSelector()
    deadline = time.monotonic() + timeout
    try:
        for stream, metadata in streams.items():
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, metadata)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout)
            events = selector.select(remaining)
            if not events:
                raise subprocess.TimeoutExpired(command, timeout)
            for key, _ in events:
                stream_name, limit = key.data
                buffer = buffers[stream_name]
                read_size = min(65_536, limit - len(buffer) + 1)
                try:
                    chunk = os.read(key.fd, max(1, read_size))
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                buffer.extend(chunk)
                if len(buffer) > limit:
                    raise BoardError(f"Fleet snapshot {stream_name} exceeded {limit} bytes")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, timeout)
        returncode = process.wait(timeout=remaining)
        return subprocess.CompletedProcess(
            command,
            returncode,
            bytes(buffers["stdout"]),
            bytes(buffers["stderr"]),
        )
    except BaseException:
        terminate_process_group(process)
        raise
    finally:
        selector.close()
        for stream in streams:
            if not stream.closed:
                stream.close()


class SnapshotCache:
    def __init__(self, root: pathlib.Path, home: pathlib.Path) -> None:
        self.root = root
        self.home = home
        self.lock = threading.Lock()
        self.board: dict[str, Any] | None = None
        self.loaded_at = 0.0
        self.attempted_at = 0.0
        self.last_error: str | None = None
        self.ttl = max(1.0, float(os.environ.get("FM_FLEET_BOARD_CACHE_SECONDS", "3")))
        self.timeout = max(3.0, float(os.environ.get("FM_FLEET_BOARD_SNAPSHOT_TIMEOUT", "18")))
        self.stdout_limit = configured_byte_limit(
            "FM_FLEET_BOARD_SNAPSHOT_STDOUT_BYTES", DEFAULT_SNAPSHOT_STDOUT_BYTES
        )
        self.stderr_limit = configured_byte_limit(
            "FM_FLEET_BOARD_SNAPSHOT_STDERR_BYTES", DEFAULT_SNAPSHOT_STDERR_BYTES
        )

    def get(self, force: bool = False) -> dict[str, Any]:
        with self.lock:
            attempt_age = time.monotonic() - self.attempted_at
            if not force and attempt_age < self.ttl:
                if self.board is not None:
                    return self._response()
                if self.last_error is not None:
                    raise BoardError(self.last_error)
            try:
                env = os.environ.copy()
                env["FM_HOME"] = str(self.home)
                env.setdefault("FM_SNAPSHOT_SECONDMATES", "0")
                env.setdefault("FM_SNAPSHOT_SECONDMATE_CHILDREN", "200")
                env.setdefault("FM_SNAPSHOT_SECONDMATE_QUEUED", "200")
                env.setdefault("FM_SNAPSHOT_SECONDMATE_DECISIONS", "200")
                env.setdefault("FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME", "30")
                env.setdefault("FM_SNAPSHOT_SECONDMATE_MAX_BYTES", "2097152")
                env.setdefault(
                    "FM_SNAPSHOT_SECONDMATE_TOTAL_TIMEOUT",
                    str(max(1, int(self.timeout) - 2)),
                )
                completed = run_bounded_snapshot(
                    [str(self.root / "bin" / "fm-fleet-snapshot.sh"), "--json"],
                    env=env,
                    timeout=self.timeout,
                    stdout_limit=self.stdout_limit,
                    stderr_limit=self.stderr_limit,
                )
                stdout = completed.stdout.decode("utf-8")
                stderr = completed.stderr.decode("utf-8")
                if completed.returncode != 0:
                    detail = compact(stderr, 300) or f"exit {completed.returncode}"
                    raise BoardError(f"Fleet snapshot failed: {detail}")
                snapshot = json.loads(stdout)
                try:
                    self.board = board_from_snapshot(snapshot)
                except (AttributeError, KeyError, TypeError, ValueError) as error:
                    raise BoardError("Firstmate returned a malformed fleet snapshot") from error
                self.loaded_at = self.attempted_at = time.monotonic()
                self.last_error = None
                return self._response()
            except (
                OSError,
                UnicodeDecodeError,
                subprocess.TimeoutExpired,
                json.JSONDecodeError,
                BoardError,
            ) as error:
                self.attempted_at = time.monotonic()
                self.last_error = compact(str(error), 320) or "Fleet snapshot failed"
                if self.board is None:
                    raise BoardError(self.last_error) from error
                return self._response()

    def _response(self) -> dict[str, Any]:
        assert self.board is not None
        stale = self.last_error is not None
        result = copy.deepcopy(self.board)
        result["health"] = {
            "stale": stale,
            "error": self.last_error if stale else None,
            "cache_age_seconds": round(max(0.0, time.monotonic() - self.loaded_at), 1),
        }
        return result

    def peek(self) -> dict[str, Any] | None:
        with self.lock:
            return self._response() if self.board is not None else None


class FleetBoardServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(
        self,
        address: tuple[str, int],
        handler: type[BaseHTTPRequestHandler],
        *,
        root: pathlib.Path,
        home: pathlib.Path,
        instance: str,
    ) -> None:
        super().__init__(address, handler)
        self.root = root
        self.home = home
        self.instance = instance
        self.operation_scope = operation_scope(home)
        self.csrf = secrets.token_urlsafe(32)
        self.cache = SnapshotCache(root, home)
        self.actions_lock = threading.Lock()


class FleetBoardHandler(BaseHTTPRequestHandler):
    server: FleetBoardServer

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write(f"fleet-board: {self.address_string()} {fmt % args}\n")

    def log_request(self, code: int | str = "-", size: int | str = "-") -> None:
        if self.path.split("?", 1)[0] == "/api/v1/board":
            return
        if isinstance(code, int) and code >= 400:
            super().log_request(code, size)

    def end_headers(self) -> None:
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
            "connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
        )
        super().end_headers()

    def allowed_hosts(self) -> set[str]:
        port = self.server.server_port
        return {f"127.0.0.1:{port}", f"localhost:{port}"}

    def reject_foreign_host(self) -> bool:
        if self.headers.get("Host") in self.allowed_hosts():
            return False
        self.send_error(HTTPStatus.FORBIDDEN, "Host header does not name this loopback board")
        return True

    def json_response(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self) -> None:  # noqa: N802
        if self.reject_foreign_host():
            return
        path = self.path.split("?", 1)[0]
        asset = STATIC_ASSETS.get(path)
        if not asset:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        file_path = pathlib.Path(__file__).resolve().parent / asset[0]
        try:
            length = file_path.stat().st_size
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", asset[1])
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(length))
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.reject_foreign_host():
            return
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            self.json_response(
                HTTPStatus.OK,
                {"ok": True, "instance": self.server.instance, "pid": os.getpid()},
            )
            return
        if path == "/api/v1/board":
            try:
                board = self.server.cache.get(force="refresh=1" in self.path)
                board["actions"] = {
                    "csrf_token": self.server.csrf,
                    "max_text_bytes": MAX_ACTION_BYTES,
                    "operation_scope": self.server.operation_scope,
                }
                self.json_response(HTTPStatus.OK, board)
            except BoardError as error:
                self.json_response(HTTPStatus.SERVICE_UNAVAILABLE, {"error": str(error)})
            return
        asset = STATIC_ASSETS.get(path)
        if not asset:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        file_path = pathlib.Path(__file__).resolve().parent / asset[0]
        try:
            body = file_path.read_bytes()
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", asset[1])
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802
        if self.reject_foreign_host():
            return
        if self.path not in {"/api/v1/actions", "/api/v1/action-status"}:
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        origin = self.headers.get("Origin")
        expected_origins = {f"http://{host}" for host in self.allowed_hosts()}
        if origin and origin not in expected_origins:
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "Cross-origin action refused"})
            return
        if not secrets.compare_digest(self.headers.get("X-Firstmate-CSRF", ""), self.server.csrf):
            self.json_response(HTTPStatus.FORBIDDEN, {"error": "Action token is invalid; reload the board"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.json_response(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "Action is too large"})
            return
        try:
            payload = json.loads(self.rfile.read(length))
            result = (
                self.queue_action(payload)
                if self.path == "/api/v1/actions"
                else self.action_status(payload)
            )
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.json_response(HTTPStatus.BAD_REQUEST, {"error": "Action body must be valid JSON"})
            return
        except BoardError as error:
            self.json_response(HTTPStatus.BAD_REQUEST, {"error": str(error)})
            return
        self.json_response(
            HTTPStatus.ACCEPTED if self.path == "/api/v1/actions" else HTTPStatus.OK,
            result,
        )

    def action_status(self, payload: Any) -> dict[str, Any]:
        if not isinstance(payload, dict) or not isinstance(payload.get("request_ids"), list):
            raise BoardError("Action status body must contain request_ids")
        request_ids = payload["request_ids"]
        if len(request_ids) > MAX_ACTION_STATUS_IDS:
            raise BoardError("Too many action identities requested")
        inbox = pathlib.Path(
            os.environ.get("FM_STATE_OVERRIDE", str(self.server.home / "state"))
        ) / "inbox"
        statuses: dict[str, str] = {}
        for request_id in request_ids:
            if not isinstance(request_id, str) or not SLUG.fullmatch(request_id):
                raise BoardError("Request id is invalid")
            if request_id in statuses:
                continue
            pending = inbox / f"request-{request_id}.note"
            handled = inbox / "handled" / f"request-{request_id}.note"
            if stored_request_matches(handled, request_id):
                statuses[request_id] = "handled"
            elif stored_request_matches(pending, request_id):
                statuses[request_id] = "pending"
            else:
                statuses[request_id] = "absent"
        return {"schema": "fm-fleet-board-action-status.v1", "statuses": statuses}

    def queue_action(self, payload: Any) -> dict[str, Any]:
        if not isinstance(payload, dict):
            raise BoardError("Action body must be an object")
        action = payload.get("action")
        task_id = payload.get("task_id")
        home_namespace = payload.get("home_namespace")
        home_id = payload.get("home_id")
        text = payload.get("text")
        request_id = payload.get("request_id")
        decision_key = payload.get("decision_key")
        if action not in {"answer", "request_details"}:
            raise BoardError("Unknown action")
        if not isinstance(task_id, str) or not SLUG.fullmatch(task_id):
            raise BoardError("Task id is invalid")
        if home_namespace not in {"primary", "secondmate"}:
            raise BoardError("Home namespace is invalid")
        if not isinstance(home_id, str) or not SLUG.fullmatch(home_id):
            raise BoardError("Home id is invalid")
        if not isinstance(request_id, str) or not SLUG.fullmatch(request_id):
            raise BoardError("Request id is invalid")
        if not isinstance(text, str):
            raise BoardError("Action text is required")
        text = text.strip()
        if not text:
            raise BoardError("Action text is required")
        if len(text.encode("utf-8")) > MAX_ACTION_BYTES:
            raise BoardError("Action text is too long")
        if action == "answer" and (
            not isinstance(decision_key, str) or not SLUG.fullmatch(decision_key)
        ):
            raise BoardError("Select the captain decision being answered")
        with self.server.actions_lock:
            label = "Captain answer" if action == "answer" else "Captain request for more details"
            decision_line = f"Decision: {decision_key}\n" if action == "answer" else ""
            note = (
                "Fleet board instruction.\n"
                f"Home: {home_namespace}:{home_id}\n"
                f"Task: {task_id}\n"
                f"Action: {action}\n"
                f"{decision_line}"
                "Board observation: stale-last-good or fresh projection, revalidated at submission.\n"
                f"{label}:\n{text}\n"
                "Revalidate the canonical task and its authority before acting, then update canonical state."
            )
            classification, classified = self.call_inbox(request_id, note, classify=True)
            existing = classification.get("saved") is True and classification.get("duplicate") is True
            absent = (
                classification.get("saved") is False
                and classification.get("duplicate") is False
                and classification.get("error") == "request-id-absent"
            )
            if not existing and not absent:
                detail = compact(classification.get("error"), 240) or compact(classified.stderr, 240)
                raise BoardError(f"Firstmate did not accept the action identity: {detail or 'unknown error'}")

            if existing:
                board = self.server.cache.peek()
                observation = (
                    "stale-last-good"
                    if board and (board.get("health") or {}).get("stale")
                    else "fresh" if board else "persisted-action"
                )
            else:
                board = self.server.cache.get(force=True)
                observation = "stale-last-good" if (board.get("health") or {}).get("stale") else "fresh"
                card = next(
                    (
                        item
                        for item in board.get("cards") or []
                        if item.get("id") == task_id
                        and (item.get("home") or {}).get("namespace") == home_namespace
                        and (item.get("home") or {}).get("id") == home_id
                    ),
                    None,
                )
                if not card:
                    raise BoardError("Task is no longer present in the current fleet board")
                permission = "answer" if action == "answer" else "request_details"
                if not (card.get("actions") or {}).get(permission):
                    raise BoardError("This action is no longer available for the task's current state")
                if action == "answer":
                    if decision_key not in {
                        decision.get("key") for decision in card.get("decisions") or []
                    }:
                        raise BoardError("That captain decision is no longer open")

            inbox_result, completed = self.call_inbox(request_id, note)
            if (
                inbox_result.get("saved") is not True
            ):
                detail = (
                    compact((inbox_result or {}).get("error"), 240)
                    if isinstance(inbox_result, dict)
                    else None
                ) or compact(completed.stderr, 240) or f"exit {completed.returncode}"
                raise BoardError(f"Firstmate did not accept the action: {detail}")
            return {
                "queued": True,
                "duplicate": bool(inbox_result.get("duplicate")),
                "request_id": request_id,
                "observation": observation,
                "health": (board or {}).get("health"),
                "wake": inbox_result.get("wake"),
            }

    def call_inbox(
        self, request_id: str, note: str, *, classify: bool = False
    ) -> tuple[dict[str, Any], subprocess.CompletedProcess[str]]:
        env = os.environ.copy()
        env["FM_HOME"] = str(self.server.home)
        command = [
            str(self.server.root / "bin" / "fm-inbox.sh"),
            "note",
            "--request-id",
            request_id,
            "--json",
        ]
        if classify:
            command.append("--classify")
        command.append("-")
        try:
            completed = subprocess.run(
                command,
                input=note,
                text=True,
                capture_output=True,
                timeout=10,
                env=env,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise BoardError(f"Could not reach the Firstmate inbox: {compact(error, 180)}") from error
        try:
            result = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise BoardError(
                f"Firstmate returned an invalid inbox response: {compact(completed.stderr, 180) or 'invalid JSON'}"
            ) from error
        if (
            not isinstance(result, dict)
            or result.get("schema") != "fm-inbox-note.v1"
            or result.get("request_id") != request_id
        ):
            raise BoardError("Firstmate returned an invalid inbox response")
        return result, completed


def runtime_paths(home: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    state = pathlib.Path(os.environ.get("FM_STATE_OVERRIDE", str(home / "state")))
    directory = state / "fleet-board"
    return directory, directory / "runtime.json", directory / "lifecycle.lock"


def read_origin_port(path: pathlib.Path) -> int | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as error:
        raise BoardError(f"Fleet board origin record is unreadable: {path}") from error
    port = value.get("port") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or value.get("schema") != "fm-fleet-board-origin.v1"
        or not isinstance(port, int)
        or not 0 < port <= 65535
    ):
        raise BoardError(f"Fleet board origin record is invalid: {path}")
    return port


def read_runtime(path: pathlib.Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def health(runtime: dict[str, Any], timeout: float = 0.8) -> dict[str, Any] | None:
    port = runtime.get("port")
    if not isinstance(port, int):
        return None
    deadline = time.monotonic() + timeout
    connection: socket.socket | None = None

    def remaining() -> float:
        return max(0.001, deadline - time.monotonic())

    try:
        connection = socket.create_connection(("127.0.0.1", port), timeout=remaining())
        connection.settimeout(remaining())
        connection.sendall(
            f"GET /healthz HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n".encode()
        )
        response = b""
        while b"\r\n\r\n" not in response:
            if time.monotonic() >= deadline or len(response) >= MAX_HEALTH_HEADER_BYTES:
                return None
            connection.settimeout(remaining())
            chunk = connection.recv(min(4_096, MAX_HEALTH_HEADER_BYTES - len(response)))
            if not chunk:
                return None
            response += chunk
        raw_headers, body = response.split(b"\r\n\r\n", 1)
        lines = raw_headers.split(b"\r\n")
        status = lines[0].split(b" ", 2)
        if (
            len(status) < 2
            or status[0] not in {b"HTTP/1.0", b"HTTP/1.1"}
            or status[1] != b"200"
        ):
            return None
        headers: dict[bytes, list[bytes]] = {}
        for line in lines[1:]:
            name, separator, value = line.partition(b":")
            if not separator:
                return None
            headers.setdefault(name.strip().lower(), []).append(value.strip())
        lengths = headers.get(b"content-length", [])
        if len(lengths) != 1 or b"transfer-encoding" in headers:
            return None
        try:
            length = int(lengths[0])
        except ValueError:
            return None
        if length < 0 or length > MAX_HEALTH_BYTES:
            return None
        while len(body) < length:
            if time.monotonic() >= deadline:
                return None
            connection.settimeout(remaining())
            chunk = connection.recv(min(4_096, length - len(body)))
            if not chunk:
                return None
            body += chunk
        value = json.loads(body[:length])
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    finally:
        if connection is not None:
            connection.close()
    return value if isinstance(value, dict) and value.get("instance") == runtime.get("instance") else None


def process_exists(pid: Any) -> bool:
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def process_matches_runtime(runtime: dict[str, Any]) -> bool | None:
    """Distinguish this server from an unrelated process that reused its PID."""
    pid = runtime.get("pid")
    instance = runtime.get("instance")
    if not process_exists(pid) or not isinstance(instance, str) or not instance:
        return False
    try:
        completed = subprocess.run(
            ["ps", "-ww", "-p", str(pid), "-o", "args="],
            text=True,
            capture_output=True,
            timeout=1,
            check=False,
        )
    except (OSError, UnicodeDecodeError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    command = completed.stdout.strip()
    server_path = str(pathlib.Path(__file__).resolve())
    instance_argument = re.compile(
        rf"(?:^|\s)--instance\s+{re.escape(instance)}(?:\s|$)"
    )
    return (
        server_path in command
        and re.search(r"(?:^|\s)--serve(?:\s|$)", command) is not None
        and instance_argument.search(command) is not None
    )


def atomic_runtime(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(4)}")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def serve(root: pathlib.Path, home: pathlib.Path, port: int, instance: str) -> int:
    directory, runtime_path, _ = runtime_paths(home)
    directory.mkdir(parents=True, exist_ok=True)
    ownership_path = directory / "server.lock"
    ownership = ownership_path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(ownership.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as error:
        ownership.close()
        raise BoardError("Fleet board is already serving this Firstmate home") from error
    try:
        origin_path = directory / "origin.json"
        selected_port = read_origin_port(origin_path) if port == 0 else port
        try:
            server = FleetBoardServer(
                ("127.0.0.1", selected_port or 0),
                FleetBoardHandler,
                root=root,
                home=home,
                instance=instance,
            )
        except OSError as error:
            if port == 0 and selected_port:
                raise BoardError(
                    f"Fleet board cannot reclaim its saved loopback port {selected_port}; "
                    "set FM_FLEET_BOARD_PORT to choose a new origin"
                ) from error
            raise BoardError(f"Fleet board could not bind its loopback port: {error}") from error
        atomic_runtime(
            origin_path,
            {"schema": "fm-fleet-board-origin.v1", "port": server.server_port},
        )
        payload = {
            "schema": "fm-fleet-board-runtime.v1",
            "instance": instance,
            "pid": os.getpid(),
            "port": server.server_port,
            "url": f"http://127.0.0.1:{server.server_port}/",
            "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        atomic_runtime(runtime_path, payload)

        def stop_server(_signum: int, _frame: Any) -> None:
            threading.Thread(target=server.shutdown, daemon=True).start()

        signal.signal(signal.SIGTERM, stop_server)
        signal.signal(signal.SIGINT, stop_server)
        try:
            server.serve_forever(poll_interval=0.25)
        finally:
            server.server_close()
            current = read_runtime(runtime_path)
            if current and current.get("instance") == instance:
                runtime_path.unlink(missing_ok=True)
    finally:
        ownership.close()
    return 0


def lifecycle_lock(path: pathlib.Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    stream = path.open("a+", encoding="utf-8")
    fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
    return stream


def start(root: pathlib.Path, home: pathlib.Path, port: int) -> dict[str, Any]:
    directory, runtime_path, lock_path = runtime_paths(home)
    directory.mkdir(parents=True, exist_ok=True)
    with lifecycle_lock(lock_path):
        current = read_runtime(runtime_path)
        if current and health(current):
            return current
        if current:
            identity = process_matches_runtime(current)
            if identity is not False:
                state = "is still alive but unhealthy" if identity else "could not be verified"
                raise BoardError(
                    f"The recorded fleet-board process {state}; refusing to replace it. "
                    f"Inspect {runtime_path}"
                )
        runtime_path.unlink(missing_ok=True)
        log_path = directory / "server.log"
        if log_path.exists() and log_path.stat().st_size > 1_048_576:
            rotated = directory / "server.log.previous"
            rotated.unlink(missing_ok=True)
            log_path.replace(rotated)
        instance = uuid.uuid4().hex
        with log_path.open("ab", buffering=0) as log:
            child = subprocess.Popen(
                [
                    sys.executable,
                    str(pathlib.Path(__file__).resolve()),
                    "--serve",
                    "--port",
                    str(port),
                    "--instance",
                    instance,
                ],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=log,
                start_new_session=True,
                close_fds=True,
                env=os.environ.copy(),
            )
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise BoardError(f"Fleet board exited during startup; inspect {log_path}")
            created = read_runtime(runtime_path)
            if created and created.get("instance") == instance and health(created):
                return created
            time.sleep(0.1)
        child.terminate()
        raise BoardError(f"Fleet board did not become healthy; inspect {log_path}")


def stop(home: pathlib.Path) -> bool:
    _, runtime_path, lock_path = runtime_paths(home)
    with lifecycle_lock(lock_path):
        current = read_runtime(runtime_path)
        if not current:
            return False
        if not health(current):
            if not process_exists(current.get("pid")):
                runtime_path.unlink(missing_ok=True)
                return False
            identity = process_matches_runtime(current)
            if identity is False:
                runtime_path.unlink(missing_ok=True)
                return False
            state = "is still alive but unhealthy" if identity else "could not be verified"
            raise BoardError(
                f"The recorded fleet-board process {state}; refusing to signal it. "
                f"Inspect {runtime_path}"
            )
        pid = current.get("pid")
        os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            observed = read_runtime(runtime_path)
            if not observed or observed.get("instance") != current.get("instance"):
                runtime_path.unlink(missing_ok=True)
                return True
            if not process_exists(pid):
                runtime_path.unlink(missing_ok=True)
                return True
            time.sleep(0.1)
        raise BoardError("Fleet board did not stop within eight seconds")


def status(home: pathlib.Path) -> dict[str, Any] | None:
    _, runtime_path, _ = runtime_paths(home)
    current = read_runtime(runtime_path)
    return current if current and health(current) else None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the Firstmate fleet Kanban board")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--serve", action="store_true", help="run the HTTP server in the foreground")
    mode.add_argument("--start", action="store_true", help="start or reuse the background server")
    mode.add_argument("--stop", action="store_true", help="stop the verified background server")
    mode.add_argument("--status", action="store_true", help="report whether the background server is healthy")
    mode.add_argument("--url", action="store_true", help="print the healthy board URL")
    parser.add_argument("--port", type=int, default=int(os.environ.get("FM_FLEET_BOARD_PORT", "0")))
    parser.add_argument("--instance", default="")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = pathlib.Path(os.environ.get("FM_ROOT_OVERRIDE", pathlib.Path(__file__).resolve().parents[2])).resolve()
    home = pathlib.Path(os.environ.get("FM_HOME", root)).resolve()
    if args.port < 0 or args.port > 65535:
        raise BoardError("Port must be between 0 and 65535")
    if args.serve:
        if not args.instance:
            instance = uuid.uuid4().hex
            try:
                os.execv(
                    sys.executable,
                    [
                        sys.executable,
                        str(pathlib.Path(__file__).resolve()),
                        "--serve",
                        "--port",
                        str(args.port),
                        "--instance",
                        instance,
                    ],
                )
            except OSError as error:
                raise BoardError(f"Could not establish the foreground instance: {error}") from error
        return serve(root, home, args.port, args.instance)
    if args.start:
        print(start(root, home, args.port)["url"])
        return 0
    if args.stop:
        print("stopped" if stop(home) else "not running")
        return 0
    current = status(home)
    if args.url:
        if not current:
            raise BoardError("Fleet board is not running")
        print(current["url"])
        return 0
    if current:
        print(f"running: {current['url']} (pid {current['pid']})")
        return 0
    print("not running")
    return 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BoardError as error:
        print(f"fm-fleet-board: {error}", file=sys.stderr)
        raise SystemExit(1)
