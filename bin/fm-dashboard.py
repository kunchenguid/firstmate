#!/usr/bin/env python3
"""Small read-only localhost dashboard service for Firstmate."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import signal
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


SCRIPT_DIR = Path(__file__).resolve().parent
SNAPSHOT_COMMAND = SCRIPT_DIR / "fm-dashboard-snapshot.sh"
SECRET_RE = re.compile(
    r"(?i)(?:token|secret|password|passwd|api[_-]?key|authorization)"
    r"\s*[:=]\s*[^\s,;]+"
)
STATUS_RE = re.compile(
    r"^([a-z][a-z0-9-]*)(?:\s+\[key=([^\]]+)\])?(?::\s*(.*))?$"
)
SECOND_MATE_TRANSITION_VERBS = {
    "blocked",
    "cancelled",
    "canceled",
    "done",
    "failed",
    "needs-decision",
    "paused",
}


def now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace(
        "+00:00", "Z"
    )


def clean_text(value: object, limit: int = 500) -> str:
    text = str(value).replace("\x1b", "").replace("\r", " ").replace("\n", " ")
    text = "".join(char if (char == "\t" or ord(char) >= 32) else " " for char in text)
    text = SECRET_RE.sub("<redacted>", text)
    return re.sub(r"\s+", " ", text).strip()[:limit]


def safe_value(value: object) -> object:
    if isinstance(value, dict):
        safe = {}
        for key, item in value.items():
            key_text = str(key)
            if re.search(
                r"(?i)(?:token|secret|password|passwd|api[_-]?key|authorization)",
                key_text,
            ):
                safe[key_text] = "<redacted>"
            else:
                safe[key_text] = safe_value(item)
        return safe
    if isinstance(value, list):
        return [safe_value(item) for item in value]
    if isinstance(value, str):
        return clean_text(value, 2000)
    return value


def file_age(path: Path) -> int | None:
    try:
        return max(0, int(time.time() - path.stat().st_mtime))
    except OSError:
        return None


def atomic_json_write(path: Path, value: object) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def stable_view(value: object) -> object:
    """Remove observation clocks so polling does not create fake events."""
    if isinstance(value, dict):
        ignored = {
            "generated",
            "beacon",
            "heartbeat_age_seconds",
            "last_update_age_seconds",
            "last_success_at",
        }
        return {
            key: stable_view(item)
            for key, item in value.items()
            if key not in ignored
        }
    if isinstance(value, list):
        return [stable_view(item) for item in value]
    return value


def changed_surfaces(old: object, new: object) -> list[str]:
    if not isinstance(old, dict) or not isinstance(new, dict):
        return ["snapshot"]
    ignored = {"generated", "heartbeat_age_seconds", "last_update_age_seconds", "last_success_at"}
    surfaces = []
    for key in sorted(set(old) | set(new)):
        if key in ignored:
            continue
        if stable_view(old.get(key)) != stable_view(new.get(key)):
            surfaces.append(key)
    return surfaces or ["snapshot"]


class DashboardStore:
    def __init__(self, home: Path, interval: float, stale_seconds: int, include_prs: bool):
        self.home = home
        self.state = Path(os.environ.get("FM_STATE_OVERRIDE", home / "state"))
        self.directory = self.state / ".dashboard"
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        self.snapshot_path = self.directory / "snapshot.json"
        self.events_path = self.directory / "events.jsonl"
        self.cursors_path = self.directory / "status-cursors.json"
        self.listen_path = self.directory / "listen.json"
        self.pid_path = self.directory / "service.pid"
        self.interval = interval
        self.stale_seconds = stale_seconds
        self.include_prs = include_prs
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.stop_event = threading.Event()
        self.snapshot: dict[str, object] = self._load_snapshot()
        self.events: list[dict[str, object]] = self._load_events()
        self.cursors, persisted_sources = self._load_cursors()
        self.next_event_id = max([int(event["id"]) for event in self.events] or [0]) + 1
        self.last_error: str | None = None
        self.last_success_at: str | None = None
        self.initialized = bool(self.snapshot)
        self.status_sources: dict[str, Path] = {}
        self.secondmate_status_sources: dict[str, Path] = {}
        self.secondmate_source_metadata: dict[str, dict[str, str]] = {}
        self.active_secondmate_status_sources: set[str] = set()
        self.secondmate_transitions_consumed: set[str] = set()
        for task_id, source in persisted_sources.items():
            if self._valid_persisted_secondmate_source(task_id, source):
                self.secondmate_status_sources[task_id] = Path(source["path"])
                self.secondmate_source_metadata[task_id] = {
                    "home_id": source["home_id"],
                    "home": source["home"],
                    "child_id": source["child_id"],
                }
            else:
                self.cursors.pop(task_id, None)

    def _load_snapshot(self) -> dict[str, object]:
        try:
            value = json.loads(self.snapshot_path.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    def _load_events(self) -> list[dict[str, object]]:
        events: list[dict[str, object]] = []
        try:
            with self.events_path.open(encoding="utf-8") as stream:
                for line in stream:
                    try:
                        value = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(value, dict) and isinstance(value.get("id"), int):
                        events.append(value)
        except OSError:
            pass
        return events

    def _load_cursors(self) -> tuple[dict[str, int], dict[str, dict[str, str]]]:
        cursors: dict[str, int] = {}
        sources: dict[str, dict[str, str]] = {}
        try:
            value = json.loads(self.cursors_path.read_text(encoding="utf-8"))
            if not isinstance(value, dict):
                return cursors, sources
            for key, entry in value.items():
                task_id = str(key)
                if isinstance(entry, int) and not isinstance(entry, bool) and entry >= 0:
                    cursors[task_id] = entry
                    continue
                if not isinstance(entry, dict):
                    continue
                offset = entry.get("offset")
                path = entry.get("path")
                home_id = entry.get("home_id")
                home = entry.get("home")
                child_id = entry.get("child_id")
                if (
                    not isinstance(offset, int)
                    or isinstance(offset, bool)
                    or offset < 0
                    or not all(isinstance(item, str) and item for item in (path, home_id, home, child_id))
                ):
                    continue
                cursors[task_id] = offset
                sources[task_id] = {
                    "path": path,
                    "home_id": home_id,
                    "home": home,
                    "child_id": child_id,
                }
        except (OSError, ValueError, AttributeError):
            pass
        return cursors, sources

    def _valid_persisted_secondmate_source(
        self, task_id: str, source: dict[str, str]
    ) -> bool:
        home_id = source["home_id"]
        home = Path(source["home"])
        child_id = source["child_id"]
        if not home.is_absolute() or not child_id or Path(child_id).name != child_id:
            return False
        if task_id != f"{home_id}/{child_id}":
            return False
        expected = home / "state" / f"{child_id}.status"
        try:
            if Path(source["path"]).resolve() != expected.resolve():
                return False
            return (
                (home / ".fm-secondmate-home").read_text(encoding="utf-8").strip()
                == home_id
            )
        except (OSError, RuntimeError):
            return False

    def _persist_cursors(self) -> None:
        value: dict[str, object] = dict(self.cursors)
        for task_id, path in self.secondmate_status_sources.items():
            offset = self.cursors.get(task_id)
            metadata = self.secondmate_source_metadata.get(task_id)
            if offset is None or metadata is None:
                continue
            value[task_id] = {
                "offset": offset,
                "path": str(path),
                **metadata,
            }
        atomic_json_write(self.cursors_path, value)

    def _append_event(self, kind: str, data: dict[str, object]) -> None:
        event = {
            "id": self.next_event_id,
            "type": kind,
            "at": now_iso(),
            "data": safe_value(data),
        }
        self.next_event_id += 1
        with self.events_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(event, sort_keys=True) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(self.events_path, 0o600)
        self.events.append(event)

    def _public_snapshot(self, raw: dict[str, object]) -> dict[str, object]:
        fleet = copy.deepcopy(raw.get("fleet", {}))
        if not isinstance(fleet, dict):
            fleet = {}
        paths = {
            str(row.get("id")): row
            for row in fleet.pop("paths", [])
            if isinstance(row, dict) and row.get("id")
        }
        endpoints = {
            str(row.get("id")): row
            for row in fleet.pop("endpoints", [])
            if isinstance(row, dict) and row.get("id")
        }
        tasks = []
        status_sources: dict[str, Path] = {}
        secondmate_sources: dict[str, Path] = {}
        for row in fleet.get("in_flight", []):
            if not isinstance(row, dict):
                continue
            task_id = str(row.get("id", ""))
            path_row = paths.get(task_id, {})
            status_value = str(path_row.get("status", ""))
            meta_value = str(path_row.get("meta", ""))
            status_path = Path(status_value) if status_value else None
            meta_path = Path(meta_value) if meta_value else None
            if status_path:
                status_sources[task_id] = status_path
            age = file_age(status_path) if status_path else None
            if age is None and meta_path:
                age = file_age(meta_path)
            state = str(row.get("state", "unknown"))
            if state in {"done", "failed"}:
                attention = "terminal"
            elif state == "paused":
                attention = "paused"
            elif age is None:
                attention = "unknown"
            elif age >= self.stale_seconds:
                attention = "possible-wedge" if state == "working" else "stale"
            else:
                attention = "fresh"
            endpoint_row = endpoints.get(task_id)
            endpoint = None
            if isinstance(endpoint_row, dict):
                endpoint = {
                    "backend": endpoint_row.get("backend"),
                    "exists": endpoint_row.get("exists"),
                    "agent": endpoint_row.get("agent"),
                }
            tasks.append(
                {
                    "id": task_id,
                    "kind": row.get("kind"),
                    "phase": state,
                    "doing": row.get("doing"),
                    "last_update_age_seconds": age,
                    "attention": attention,
                    "endpoint": endpoint,
                }
            )
        for row in fleet.pop("secondmate_work", []):
            if not isinstance(row, dict):
                continue
            home_id = str(row.get("home_id", ""))
            child_id = str(row.get("id", ""))
            home_value = row.get("home")
            if not home_id or not child_id or not isinstance(home_value, str):
                continue
            home_path = Path(home_value)
            if not home_path.is_absolute():
                continue
            task_id = f"{home_id}/{child_id}"
            status_path = home_path / "state" / f"{child_id}.status"
            previous_path = self.secondmate_status_sources.get(task_id)
            if previous_path is not None and previous_path.resolve() != status_path.resolve():
                self.cursors.pop(task_id, None)
            self.secondmate_source_metadata[task_id] = {
                "home_id": home_id,
                "home": str(home_path),
                "child_id": child_id,
            }
            secondmate_sources[task_id] = status_path
            age = file_age(status_path)
            state = str(row.get("state", "unknown"))
            if state in {"done", "failed"}:
                attention = "terminal"
            elif state == "paused":
                attention = "paused"
            elif age is None:
                attention = "unknown"
            elif age >= self.stale_seconds:
                attention = "possible-wedge" if state == "working" else "stale"
            else:
                attention = "fresh"
            tasks.append(
                {
                    "id": task_id,
                    "kind": row.get("kind"),
                    "phase": state,
                    "doing": row.get("doing"),
                    "last_update_age_seconds": age,
                    "attention": attention,
                    "endpoint": None,
                }
            )
        self.status_sources = status_sources
        active_secondmate_sources = set(secondmate_sources)
        retired = False
        for task_id in list(self.secondmate_status_sources):
            if task_id in active_secondmate_sources:
                self.secondmate_transitions_consumed.discard(task_id)
            elif task_id in self.secondmate_transitions_consumed:
                del self.secondmate_status_sources[task_id]
                del self.secondmate_source_metadata[task_id]
                self.cursors.pop(task_id, None)
                self.secondmate_transitions_consumed.discard(task_id)
                retired = True
        self.secondmate_status_sources.update(secondmate_sources)
        self.active_secondmate_status_sources = active_secondmate_sources
        self.status_sources.update(self.secondmate_status_sources)
        if retired:
            self._persist_cursors()
        service = {
            "state": "degraded" if self.last_error else "ready",
            "snapshot_error": self.last_error,
            "last_success_at": self.last_success_at,
            "poll_interval_seconds": self.interval,
        }
        return safe_value(
            {
                "schema": "fm-dashboard-snapshot.v1",
                "generated": raw.get("generated", now_iso()),
                "home": raw.get("home", str(self.home)),
                "fleet": fleet,
                "tasks": tasks,
                "supervision": raw.get("supervision", {"state": "unknown"}),
                "service": service,
            }
        )

    def _refresh_snapshot(self) -> None:
        environment = os.environ.copy()
        environment["FM_HOME"] = str(self.home)
        environment["FM_DASHBOARD_INCLUDE_PRS"] = "1" if self.include_prs else "0"
        try:
            result = subprocess.run(
                [str(SNAPSHOT_COMMAND), "--json"],
                cwd=str(SCRIPT_DIR.parent),
                env=environment,
                capture_output=True,
                text=True,
                timeout=float(os.environ.get("FM_DASHBOARD_SNAPSHOT_TIMEOUT", "45")),
                check=False,
            )
            if result.returncode != 0:
                raise RuntimeError(f"snapshot command exited {result.returncode}")
            raw = json.loads(result.stdout)
            if not isinstance(raw, dict) or raw.get("schema") != "fm-dashboard-snapshot.v1":
                raise RuntimeError("snapshot command returned an invalid schema")
            with self.lock:
                self.last_success_at = now_iso()
                public = self._public_snapshot(raw)
                previous = self.snapshot
                self.snapshot = public
                self.last_error = None
                atomic_json_write(self.snapshot_path, public)
                if self.initialized and stable_view(previous) != stable_view(public):
                    self._append_event(
                        "snapshot",
                        {"changed": changed_surfaces(previous, public)},
                    )
                self.initialized = True
                self.condition.notify_all()
        except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
            with self.lock:
                self.last_error = clean_text(str(error), 160) or "snapshot unavailable"
                if self.snapshot:
                    was_degraded = (
                        isinstance(self.snapshot.get("service"), dict)
                        and self.snapshot["service"].get("state") == "degraded"
                    )
                    self.snapshot = copy.deepcopy(self.snapshot)
                    supervision = self.snapshot.get("supervision")
                    if not isinstance(supervision, dict):
                        supervision = {}
                    self.snapshot["supervision"] = {
                        **supervision,
                        "state": "observation-stale",
                        "watcher_active": False,
                    }
                    self.snapshot["service"] = {
                        **(self.snapshot.get("service", {}) if isinstance(self.snapshot.get("service"), dict) else {}),
                        "state": "degraded",
                        "snapshot_error": self.last_error,
                    }
                    atomic_json_write(self.snapshot_path, self.snapshot)
                    if not was_degraded:
                        self._append_event("service", {"state": "observation-stale"})
                else:
                    self.snapshot = {
                        "schema": "fm-dashboard-snapshot.v1",
                        "generated": now_iso(),
                        "home": str(self.home),
                        "fleet": {},
                        "tasks": [],
                        "supervision": {"state": "observation-stale", "watcher_active": False},
                        "service": {
                            "state": "degraded",
                            "snapshot_error": self.last_error,
                            "poll_interval_seconds": self.interval,
                        },
                    }
                    atomic_json_write(self.snapshot_path, self.snapshot)
                self.condition.notify_all()

    def _scan_status_events(self) -> None:
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        changed = False
        status_paths = {
            status_path.stem: status_path for status_path in sorted(self.state.glob("*.status"))
        }
        status_paths.update(self.status_sources)
        status_paths.update(self.secondmate_status_sources)
        with self.lock:
            for task_id, status_path in sorted(status_paths.items()):
                try:
                    size = status_path.stat().st_size
                except OSError:
                    continue
                if task_id not in self.cursors:
                    self.cursors[task_id] = size
                    changed = True
                    continue
                offset = self.cursors[task_id]
                if size < offset:
                    offset = 0
                try:
                    with status_path.open("rb") as stream:
                        stream.seek(offset)
                        content = stream.read()
                except OSError:
                    continue
                complete_length = content.rfind(b"\n") + 1
                complete = content[:complete_length]
                transition_seen = False
                for raw_line in complete.splitlines():
                    line = raw_line.decode("utf-8", "replace").strip()
                    match = STATUS_RE.match(line)
                    if not match or not match.group(1):
                        continue
                    verb, key, note = match.groups()
                    if (
                        task_id in self.secondmate_status_sources
                        and verb in SECOND_MATE_TRANSITION_VERBS
                    ):
                        transition_seen = True
                    self._append_event(
                        "status",
                        {
                            "task_id": task_id,
                            "verb": verb,
                            "key": clean_text(key, 80) if key else None,
                            "summary": clean_text(note or verb, 360),
                        },
                    )
                new_offset = offset + complete_length
                if new_offset != self.cursors[task_id]:
                    self.cursors[task_id] = new_offset
                    changed = True
                if transition_seen:
                    self.secondmate_transitions_consumed.add(task_id)
                    if task_id not in self.active_secondmate_status_sources:
                        self.secondmate_status_sources.pop(task_id, None)
                        self.secondmate_transitions_consumed.discard(task_id)
            if changed:
                self._persist_cursors()
            if changed:
                self.condition.notify_all()

    def refresh(self) -> None:
        self._refresh_snapshot()
        self._scan_status_events()

    def run(self) -> None:
        while not self.stop_event.is_set():
            self.refresh()
            self.stop_event.wait(self.interval)

    def events_after(self, cursor: int) -> list[dict[str, object]]:
        with self.lock:
            return [event for event in self.events if int(event["id"]) > cursor]

    def current_snapshot(self) -> dict[str, object]:
        with self.lock:
            return copy.deepcopy(self.snapshot)


HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Firstmate Dashboard</title>
<style>
:root{color-scheme:dark;--bg:#0d1520;--panel:#152235;--line:#29415d;--ink:#e6eef8;--muted:#9db0c6;--good:#71d49b;--warn:#f4c96d;--bad:#ff8b8b}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.4 system-ui,sans-serif}main{max-width:1200px;margin:auto;padding:24px}header{display:flex;justify-content:space-between;gap:16px;align-items:baseline;margin-bottom:18px}h1,h2{margin:0}h1{font-size:22px}h2{font-size:15px;margin-bottom:10px}.muted{color:var(--muted)}.status{font-weight:650}.good{color:var(--good)}.warn{color:var(--warn)}.bad{color:var(--bad)}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:12px;margin-bottom:12px}.panel{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px}.metric{font-size:24px;font-weight:700}.row{display:grid;grid-template-columns:minmax(100px,1fr) 100px 100px minmax(120px,2fr);gap:10px;padding:9px 0;border-top:1px solid var(--line);align-items:center}.row:first-of-type{border-top:0}.pill{border-radius:99px;padding:2px 8px;font-size:12px;white-space:nowrap;background:#223650}.pill.good{background:#173a2b}.pill.warn{background:#49391b}.pill.bad{background:#482628}.event{padding:7px 0;border-top:1px solid var(--line)}.event:first-child{border-top:0}a{color:#9bc9ff}#events{max-height:220px;overflow:auto}@media(max-width:700px){main{padding:14px}.row{grid-template-columns:1fr 1fr}.row .doing{grid-column:1/-1}}
</style>
</head>
<body><main>
<header><div><h1>Firstmate fleet</h1><div id="home" class="muted">Loading snapshot...</div></div><div id="connection" class="status warn">Connecting</div></header>
<section class="grid"><div class="panel"><h2>Supervision</h2><div id="supervision" class="status">Loading...</div><div id="supervision-detail" class="muted"></div></div><div class="panel"><h2>Active work</h2><div id="active-count" class="metric">-</div><div class="muted">current tasks</div></div><div class="panel"><h2>Open decisions</h2><div id="decision-count" class="metric">-</div><div class="muted">captain attention</div></div><div class="panel"><h2>Pull requests</h2><div id="pr-state" class="status">Loading...</div><div id="pr-count" class="muted"></div></div></section>
<section class="panel"><h2>Active work</h2><div id="tasks"></div></section>
<section class="grid"><div class="panel"><h2>Captain decisions</h2><div id="decisions"></div></div><div class="panel"><h2>Recently landed</h2><div id="landed"></div></div></section>
<section class="panel"><h2>Live events</h2><div id="events" class="muted">Waiting for events...</div></section>
</main>
<script>
let source=null,lastEvent=0,reconnectTimer=null;
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const age=s=>s==null?'unknown':s<60?`${s}s ago`:s<3600?`${Math.floor(s/60)}m ago`:`${Math.floor(s/3600)}h ago`;
function paint(s){if(!s)return;const f=s.fleet||{},tasks=s.tasks||[],sup=s.supervision||{},svc=s.service||{};
 document.querySelector('#home').textContent=`${s.home||''} · observed ${age(Math.max(0,(Date.now()-Date.parse(s.generated))/1000|0))}`;
 const supClass=sup.state==='healthy'?'good':sup.state==='not_needed'?'good':'bad';
 document.querySelector('#supervision').innerHTML=`<span class="${supClass}">${esc(sup.state||'unknown')}</span>`;
 document.querySelector('#supervision-detail').textContent=`heartbeat ${esc(sup.beacon||'never')} · ${sup.in_flight||0} task(s) · service ${esc(svc.state||'unknown')}`;
 document.querySelector('#active-count').textContent=tasks.length;document.querySelector('#decision-count').textContent=(f.decisions_open||[]).length;
 const prs=f.candidate_prs||[];document.querySelector('#pr-state').textContent=f.prs||'not requested';document.querySelector('#pr-count').textContent=`${prs.length} visible · ${prs.map(p=>p.checks).filter(Boolean).join(', ')}`;
 document.querySelector('#tasks').innerHTML=tasks.length?tasks.map(t=>`<div class="row"><div><strong>${esc(t.id)}</strong><div class="muted">${esc(t.kind||'work')}</div></div><div>${esc(t.phase||'unknown')}</div><div class="pill ${t.attention==='fresh'?'good':t.attention==='possible-wedge'||t.attention==='stale'?'warn':t.attention==='unknown'?'bad':''}">${esc(t.attention)}</div><div class="doing">${esc(t.doing||'')} <span class="muted">· ${age(t.last_update_age_seconds)}</span></div></div>`).join(''):'<div class="muted">No active work.</div>';
 document.querySelector('#decisions').innerHTML=(f.decisions_open||[]).length?f.decisions_open.map(d=>`<div class="event"><strong>${esc(d.id)}</strong><div>${esc(d.summary||d.verb||'decision pending')}</div></div>`).join(''):'<div class="muted">No open decisions.</div>';
 document.querySelector('#landed').innerHTML=(f.landed||[]).length?f.landed.map(d=>`<div class="event"><strong>${esc(d.id)}</strong><div>${esc(d.what||'')}</div></div>`).join(''):'<div class="muted">No recent landed work.</div>';
 if(sup.state!=='healthy'&&sup.state!=='not_needed')document.querySelector('#supervision').innerHTML+=` <span class="bad">attention required</span>`;
}
function addEvent(e){lastEvent=Math.max(lastEvent,Number(e.lastEventId||0));const data=JSON.parse(e.data||'{}'),box=document.querySelector('#events');if(box.classList.contains('muted')){box.classList.remove('muted');box.innerHTML=''};const row=document.createElement('div');row.className='event';row.innerHTML=`<span class="muted">${esc(data.at||'now')}</span> <strong>${esc(data.type||'event')}</strong> ${esc(data.data?.task_id||'')} ${esc(data.data?.summary||data.data?.changed?.join(', ')||'')}`;box.prepend(row);while(box.children.length>30)box.lastElementChild.remove();}
async function load(){try{const r=await fetch('/api/snapshot',{cache:'no-store'});paint(await r.json());document.querySelector('#connection').textContent='Live';document.querySelector('#connection').className='status good';}catch(_){document.querySelector('#connection').textContent='Snapshot unavailable';document.querySelector('#connection').className='status bad';}}
function connect(){if(source)source.close();source=new EventSource(`/events?since=${lastEvent}`);source.onopen=()=>{document.querySelector('#connection').textContent='Live';document.querySelector('#connection').className='status good'};source.onerror=()=>{document.querySelector('#connection').textContent='Reconnecting';document.querySelector('#connection').className='status warn';source.close();clearTimeout(reconnectTimer);reconnectTimer=setTimeout(connect,1000)};source.onmessage=addEvent;source.addEventListener('status',e=>{addEvent(e);load()});source.addEventListener('snapshot',e=>{addEvent(e);load()});}
load();connect();setInterval(load,30000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "FirstmateDashboard/1"

    @property
    def store(self) -> DashboardStore:
        return self.server.store  # type: ignore[attr-defined]

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _send(self, content_type: str, body: bytes, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._send("text/html; charset=utf-8", HTML.encode("utf-8"))
            return
        if parsed.path == "/api/snapshot":
            body = json.dumps(self.store.current_snapshot(), sort_keys=True).encode("utf-8")
            self._send("application/json; charset=utf-8", body)
            return
        if parsed.path == "/health":
            body = json.dumps({"ok": True, "schema": "fm-dashboard-health.v1"}).encode("utf-8")
            self._send("application/json; charset=utf-8", body)
            return
        if parsed.path == "/events":
            self._events(parsed)
            return
        self._send("text/plain; charset=utf-8", b"not found\n", 404)

    def _events(self, parsed) -> None:
        query = parse_qs(parsed.query)
        try:
            cursor = int(self.headers.get("Last-Event-ID", query.get("since", ["0"])[0]))
        except ValueError:
            cursor = 0
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        try:
            while True:
                events = self.store.events_after(cursor)
                if events:
                    for event in events:
                        payload = json.dumps(event, sort_keys=True)
                        self.wfile.write(f"id: {event['id']}\nevent: {event['type']}\ndata: {payload}\n\n".encode())
                        self.wfile.flush()
                        cursor = int(event["id"])
                with self.store.condition:
                    self.store.condition.wait(timeout=15)
                self.wfile.write(b": keep-alive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            return


def pid_alive(pid_path: Path) -> bool:
    try:
        pid = int(pid_path.read_text(encoding="utf-8").strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def serve(args: argparse.Namespace) -> int:
    if args.host != "127.0.0.1":
        print("fm-dashboard: only 127.0.0.1 is supported", file=os.sys.stderr)
        return 2
    home = Path(os.environ.get("FM_HOME", os.environ.get("FM_ROOT_OVERRIDE", SCRIPT_DIR.parent))).resolve()
    store = DashboardStore(home, args.interval, args.stale_seconds, args.include_prs)
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.store = store  # type: ignore[attr-defined]
    httpd.daemon_threads = True
    store.pid_path.write_text(f"{os.getpid()}\n", encoding="utf-8")
    os.chmod(store.pid_path, 0o600)
    atomic_json_write(
        store.listen_path,
        {"host": args.host, "port": httpd.server_port, "url": f"http://{args.host}:{httpd.server_port}/"},
    )
    thread = threading.Thread(target=store.run, name="dashboard-poll", daemon=True)
    thread.start()

    def stop(_signum, _frame) -> None:
        store.stop_event.set()
        threading.Thread(target=httpd.shutdown, name="dashboard-shutdown", daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        httpd.serve_forever(poll_interval=0.2)
    finally:
        store.stop_event.set()
        httpd.server_close()
        try:
            if store.pid_path.read_text(encoding="utf-8").strip() == str(os.getpid()):
                store.pid_path.unlink()
            if store.listen_path.exists():
                store.listen_path.unlink()
        except OSError:
            pass
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Firstmate read-only local dashboard service")
    subparsers = parser.add_subparsers(dest="command", required=True)
    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--host", default="127.0.0.1")
    serve_parser.add_argument("--port", type=int, default=8765)
    serve_parser.add_argument("--interval", type=float, default=float(os.environ.get("FM_DASHBOARD_INTERVAL", "5")))
    serve_parser.add_argument("--stale-seconds", type=int, default=int(os.environ.get("FM_STALE_ESCALATE_SECS", "240")))
    serve_parser.add_argument("--include-prs", action=argparse.BooleanOptionalAction, default=os.environ.get("FM_DASHBOARD_INCLUDE_PRS", "1") != "0")
    args = parser.parse_args()
    if args.command == "serve":
        return serve(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
