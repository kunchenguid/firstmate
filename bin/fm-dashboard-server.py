#!/usr/bin/env python3
"""fm-dashboard-server - read-only live fleet dashboard HTTP server.

Python 3 stdlib only. Launched by bin/fm-dashboard.sh (lifecycle owner).

Reads fleet state via bin/fm-fleet-snapshot.sh --json when present, else a
minimal composition from state/*.meta, status tails, tasks-axi, and report
index. Soft-caches the snapshot for a few seconds. Writes only under
state/dashboard/ (this process creates no other files). Never acquires the
firstmate session lock.

Environment (set by fm-dashboard.sh):
  FM_HOME, FM_ROOT_OVERRIDE
  FM_DASHBOARD_BIND_HOST, FM_DASHBOARD_BIND_PORT
  FM_DASHBOARD_TOKEN
  FM_DASHBOARD_STATIC
  FM_DASHBOARD_SNAPSHOT  path to fm-fleet-snapshot.sh
  FM_STATE_OVERRIDE, FM_DATA_OVERRIDE, FM_CONFIG_OVERRIDE  (tests)
"""

from __future__ import annotations

import http.cookies
import http.server
import json
import os
import secrets
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
from pathlib import Path
from typing import Any

SCHEMA_SNAPSHOT = "fm-dashboard-snapshot.v1"
CACHE_TTL_S = 4.0
STATUS_TAIL_LINES = 20
COOKIE_NAME = "fm_dash"
START_MONOTONIC = time.monotonic()

_WILDCARD_HOSTS = frozenset({"0.0.0.0", "::", "[::]", "*", "[::0]", ""})


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def resolve_paths() -> dict[str, Path]:
    fm_home = Path(_env("FM_HOME") or ".").resolve()
    state = Path(_env("FM_STATE_OVERRIDE") or (fm_home / "state")).resolve()
    data = Path(_env("FM_DATA_OVERRIDE") or (fm_home / "data")).resolve()
    config = Path(_env("FM_CONFIG_OVERRIDE") or (fm_home / "config")).resolve()
    fm_root = Path(_env("FM_ROOT_OVERRIDE") or fm_home).resolve()
    static = Path(_env("FM_DASHBOARD_STATIC") or (fm_root / "bin" / "fm-dashboard-static")).resolve()
    snapshot = Path(
        _env("FM_DASHBOARD_SNAPSHOT") or (fm_root / "bin" / "fm-fleet-snapshot.sh")
    ).resolve()
    return {
        "fm_home": fm_home,
        "state": state,
        "data": data,
        "config": config,
        "fm_root": fm_root,
        "static": static,
        "snapshot": snapshot,
        "dashboard_state": state / "dashboard",
    }


def assert_bind_host(host: str) -> str:
    host = (host or "").strip()
    if host in _WILDCARD_HOSTS:
        raise SystemExit(
            f"fm-dashboard-server: refusing wildcard bind host {host!r}"
        )
    # Also reject IPv6 any and common misconfigs.
    if host.startswith("0.0.0.0") or host == "::0":
        raise SystemExit(
            f"fm-dashboard-server: refusing wildcard bind host {host!r}"
        )
    return host


class SnapshotCache:
    """Thread-safe soft cache for the expensive snapshot build."""

    def __init__(self, ttl_s: float = CACHE_TTL_S) -> None:
        self.ttl_s = ttl_s
        self._lock = threading.Lock()
        self._payload: dict[str, Any] | None = None
        self._fetched_at = 0.0
        self._raw_body: bytes | None = None

    def get(self, builder) -> tuple[bytes, dict[str, Any]]:
        now = time.monotonic()
        with self._lock:
            if (
                self._payload is not None
                and self._raw_body is not None
                and (now - self._fetched_at) < self.ttl_s
            ):
                return self._raw_body, self._payload
        payload = builder()
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode(
            "utf-8"
        )
        with self._lock:
            self._payload = payload
            self._raw_body = body
            self._fetched_at = time.monotonic()
            return body, payload


SNAPSHOT_CACHE = SnapshotCache()


def _utc_now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _run_cmd(
    argv: list[str],
    *,
    cwd: Path | None,
    env: dict[str, str],
    timeout: float,
) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            argv,
            cwd=str(cwd) if cwd else None,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError as exc:
        return 127, "", str(exc)
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"


def build_snapshot(paths: dict[str, Path]) -> dict[str, Any]:
    """Build the dashboard snapshot JSON (read-only over state/ and data/)."""
    generated = _utc_now()
    sources: list[dict[str, Any]] = []
    env = os.environ.copy()
    env["FM_HOME"] = str(paths["fm_home"])
    # Prefer the canonical aggregator when present.
    snap_path = paths["snapshot"]
    fleet: dict[str, Any] | None = None
    src: dict[str, Any] = {
        "id": "fleet-snapshot",
        "command": str(snap_path),
        "fetched_at": generated,
        "ok": False,
        "age_s": 0,
        "stale": False,
    }
    if snap_path.is_file() and os.access(snap_path, os.X_OK):
        t0 = time.monotonic()
        rc, out, err = _run_cmd(
            [str(snap_path), "--json"],
            cwd=paths["fm_home"],
            env=env,
            timeout=90.0,
        )
        src["duration_ms"] = int((time.monotonic() - t0) * 1000)
        src["exit_code"] = rc
        if rc == 0 and out.strip():
            try:
                fleet = json.loads(out)
                src["ok"] = True
            except json.JSONDecodeError as exc:
                src["error"] = f"json decode: {exc}"
                src["stderr_tail"] = (err or "")[-400:]
        else:
            src["error"] = f"exit {rc}"
            src["stderr_tail"] = (err or "")[-400:]
    else:
        src["error"] = "fm-fleet-snapshot.sh missing or not executable"
    sources.append(src)

    if fleet is None:
        fleet = compose_minimal_snapshot(paths, env, sources)
        # Mark the fleet source as composed fallback when the primary failed.
        if not src["ok"]:
            sources.append(
                {
                    "id": "fleet-compose-fallback",
                    "fetched_at": generated,
                    "ok": True,
                    "age_s": 0,
                    "stale": False,
                    "note": "composed from state/data after snapshot tool failure",
                }
            )

    # Side sources for later waves: honest stubs with ok=false so the UI can
    # label "wired in wave 2" without inventing values.
    for side_id, note in (
        ("quota", "wired in wave 2"),
        ("prs", "wired in wave 2"),
        ("trains", "wired in wave 2"),
        ("production", "wired in wave 2"),
        ("events", "wired in wave 2"),
    ):
        sources.append(
            {
                "id": side_id,
                "fetched_at": generated,
                "ok": False,
                "age_s": 0,
                "stale": False,
                "deferred": True,
                "note": note,
            }
        )

    # Project decision-oriented view without inventing holds.
    decisions = extract_decisions(fleet)
    out: dict[str, Any] = {
        "schema": SCHEMA_SNAPSHOT,
        "generated": generated,
        "fm_home": str(paths["fm_home"]),
        "server": {
            "uptime_s": int(time.monotonic() - START_MONOTONIC),
            "bind_host": _env("FM_DASHBOARD_BIND_HOST"),
            "bind_port": int(_env("FM_DASHBOARD_BIND_PORT") or "0"),
        },
        "sources": sources,
        "fleet": fleet,
        "decisions": decisions,
        # Wave-2 placeholders so the UI shell can render labeled empty states.
        # null = deferred to a later wave (UI shows "wired in wave 2").
        # empty list would mean "loaded and currently empty".
        "events": None,
        "open_prs": None,
        "trains": None,
        "quota": None,
        "production": None,
        "wave": {
            "id": 1,
            "scopes": ["D1", "D2", "D4"],
            "deferred": ["D3", "D5", "D6", "D7", "D8", "D9", "D10"],
        },
    }
    return out


def compose_minimal_snapshot(
    paths: dict[str, Path],
    env: dict[str, str],
    sources: list[dict[str, Any]],
) -> dict[str, Any]:
    """Fallback composition when fm-fleet-snapshot.sh is unavailable."""
    state = paths["state"]
    data = paths["data"]
    generated = _utc_now()
    tasks: list[dict[str, Any]] = []
    for meta in sorted(state.glob("*.meta")):
        task_id = meta.name[: -len(".meta")]
        fields: dict[str, str] = {}
        try:
            text = meta.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            if "=" in line:
                k, _, v = line.partition("=")
                fields[k.strip()] = v.strip()
        status_path = state / f"{task_id}.status"
        last_event = ""
        if status_path.is_file():
            try:
                lines = status_path.read_text(
                    encoding="utf-8", errors="replace"
                ).splitlines()
                if lines:
                    last_event = lines[-1]
            except OSError:
                pass
        tasks.append(
            {
                "id": task_id,
                "kind": fields.get("kind", ""),
                "harness": fields.get("harness", ""),
                "backend": fields.get("backend", ""),
                "project": fields.get("project", ""),
                "pr": {"url": fields.get("pr") or None},
                "current_state": {
                    "state": "unknown",
                    "source": "compose-fallback",
                    "detail": last_event,
                    "raw": last_event,
                    "observed_at": generated,
                    "freshness": "unknown",
                },
                "hints": {
                    "last_event_text": last_event,
                    "pending_decision": "needs-decision" in last_event,
                    "blocked_event": last_event.startswith("blocked:"),
                    "open_decisions": [],
                    "scout_report_present": (
                        data / task_id / "report.md"
                    ).is_file(),
                },
                "paths": {
                    "status_log": {
                        "path": str(status_path),
                        "last_event": last_event,
                    },
                    "report": {
                        "path": str(data / task_id / "report.md"),
                        "present": (data / task_id / "report.md").is_file(),
                    },
                },
            }
        )

    backlog_records: list[dict[str, Any]] = []
    t0 = time.monotonic()
    rc, out, err = _run_cmd(
        ["tasks-axi", "list", "--json"],
        cwd=paths["fm_home"],
        env=env,
        timeout=30.0,
    )
    src = {
        "id": "tasks-axi",
        "fetched_at": generated,
        "ok": rc == 0,
        "age_s": 0,
        "stale": False,
        "duration_ms": int((time.monotonic() - t0) * 1000),
        "exit_code": rc,
    }
    if rc == 0 and out.strip():
        try:
            parsed = json.loads(out)
            if isinstance(parsed, list):
                backlog_records = parsed
            elif isinstance(parsed, dict) and isinstance(parsed.get("records"), list):
                backlog_records = parsed["records"]
            elif isinstance(parsed, dict) and isinstance(parsed.get("tasks"), list):
                backlog_records = parsed["tasks"]
            src["ok"] = True
        except json.JSONDecodeError as exc:
            src["ok"] = False
            src["error"] = f"json decode: {exc}"
    else:
        src["error"] = (err or f"exit {rc}")[-400:]
    sources.append(src)

    scout_reports: list[dict[str, Any]] = []
    if data.is_dir():
        for report in sorted(data.glob("*/report.md")):
            scout_reports.append(
                {
                    "id": report.parent.name,
                    "path": str(report),
                    "present": True,
                }
            )

    return {
        "schema": "fm-fleet-snapshot.v1",
        "generated": generated,
        "fm_home": str(paths["fm_home"]),
        "composed_fallback": True,
        "tasks": tasks,
        "backlog": {
            "path": str(data / "backlog.md"),
            "present": (data / "backlog.md").is_file(),
            "records": backlog_records,
        },
        "scout_reports": scout_reports,
    }


def extract_decisions(fleet: dict[str, Any]) -> list[dict[str, Any]]:
    """Stable decision cards from backlog holds / captain_actionable rows.

    Each card carries a stable `key` (hold / backlog id) so wave 3 write-back
    (answer / dismiss / snooze) attaches without rework. Wave 1 is read-only;
    action buttons are present in the DOM model but not wired to POST.
    """
    records = []
    backlog = fleet.get("backlog") or {}
    if isinstance(backlog, dict):
        records = backlog.get("records") or []
    if not isinstance(records, list):
        return []

    decisions: list[dict[str, Any]] = []
    for rec in records:
        if not isinstance(rec, dict):
            continue
        key = str(rec.get("id") or "").strip()
        if not key:
            continue
        state = str(rec.get("state") or "").lower()
        if state in {"done", "resolved"}:
            continue
        captain_actionable = bool(rec.get("captain_actionable"))
        hold_kind = str(rec.get("hold_kind") or "").lower()
        kind = str(rec.get("kind") or "").lower()
        # Tight bar for wave 1: captain_actionable rows, or explicit captain holds.
        if not captain_actionable and hold_kind != "captain" and kind != "captain":
            continue
        title = str(rec.get("title") or rec.get("raw") or key)
        body = str(
            rec.get("hold_reason")
            or rec.get("blocked_reason")
            or rec.get("notes")
            or rec.get("detail")
            or ""
        )
        decisions.append(
            {
                "key": key,
                "title": title,
                "body": body,
                "hold_kind": rec.get("hold_kind") or rec.get("kind") or "",
                "hold_reason": rec.get("hold_reason") or "",
                "captain_actionable": captain_actionable,
                "state": rec.get("state") or "",
                "recommendation": rec.get("recommendation") or "",
                "options": rec.get("options") or [],
                # Wave 3 attaches answer/dismiss/snooze here; architect now.
                "actions_supported": ["answer", "dismiss", "snooze"],
                "origin": rec.get("repo") or rec.get("origin_task") or "",
                "pr_url": rec.get("pr_url") or "",
                "report_path": rec.get("report_path") or "",
            }
        )
    return decisions


UNLOCK_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fleet dashboard - unlock</title>
<style>
  :root { color-scheme: dark light; }
  body { margin:0; font:15px/1.5 -apple-system,Segoe UI,Helvetica,sans-serif;
    background:#131A17; color:#E9E4D4; min-height:100vh; display:flex;
    align-items:center; justify-content:center; padding:24px; }
  @media (prefers-color-scheme: light) {
    body { background:#F7F3E9; color:#2A2A24; }
    .card { background:#fff; border-color:#D9D2C0; }
    input { background:#fff; color:#2A2A24; border-color:#C9C2AE; }
  }
  .card { width:min(420px,100%); background:#1B2420; border:1px solid #31403A;
    border-radius:12px; padding:22px 20px; }
  h1 { font:400 20px Georgia,serif; margin:0 0 8px; }
  p { margin:0 0 14px; color:#96A198; font-size:13.5px; }
  label { display:block; font:600 11px sans-serif; letter-spacing:.12em;
    text-transform:uppercase; color:#C9A24B; margin-bottom:6px; }
  input { width:100%; box-sizing:border-box; padding:10px 12px; border-radius:8px;
    border:1px solid #31403A; background:#131A17; color:#E9E4D4; font:13px ui-monospace,Menlo,monospace; }
  button { margin-top:12px; width:100%; padding:11px 14px; border:0; border-radius:8px;
    background:#C9A24B; color:#131A17; font:600 13px sans-serif; cursor:pointer; }
  .err { color:#C46A5A; font-size:13px; margin-top:10px; min-height:1.2em; }
</style>
</head>
<body>
  <form class="card" method="post" action="/unlock" id="f">
    <h1>Unlock live fleet</h1>
    <p>Paste the bearer token from <code>config/dashboard-token</code> on the host. It is stored as an HttpOnly cookie on this device.</p>
    <label for="token">Token</label>
    <input id="token" name="token" type="password" autocomplete="current-password" required>
    <button type="submit">Unlock</button>
    <div class="err" id="err"></div>
  </form>
  <script>
    const q = new URLSearchParams(location.search);
    if (q.get('e') === '1') document.getElementById('err').textContent = 'Invalid token.';
  </script>
</body>
</html>
"""


class DashboardHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    paths: dict[str, Path] = {}
    token: str = ""

    def log_message(self, fmt: str, *args: Any) -> None:
        # Prefer compact access lines on stdout (captured by server.log).
        sys.stderr.write(
            "%s - %s\n" % (self.log_date_time_string(), fmt % args)
        )

    def _send(
        self,
        code: int,
        body: bytes,
        content_type: str,
        *,
        extra_headers: list[tuple[str, str]] | None = None,
    ) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        if extra_headers:
            for k, v in extra_headers:
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code: int, obj: Any) -> None:
        body = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode(
            "utf-8"
        )
        self._send(code, body, "application/json; charset=utf-8")

    def _authorized(self) -> bool:
        expected = self.token
        if not expected:
            return False
        auth = self.headers.get("Authorization", "")
        if auth.lower().startswith("bearer "):
            got = auth[7:].strip()
            if secrets.compare_digest(got, expected):
                return True
        cookie_header = self.headers.get("Cookie", "")
        if cookie_header:
            cookies = http.cookies.SimpleCookie()
            try:
                cookies.load(cookie_header)
            except http.cookies.CookieError:
                cookies = http.cookies.SimpleCookie()
            morsel = cookies.get(COOKIE_NAME)
            if morsel is not None and secrets.compare_digest(
                morsel.value, expected
            ):
                return True
        return False

    def _require_auth(self) -> bool:
        if self._authorized():
            return True
        # Browsers navigating to / get the unlock page; API callers get 401 JSON.
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html", "/unlock") and self.command in (
            "GET",
            "HEAD",
        ):
            body = UNLOCK_HTML.encode("utf-8")
            self._send(401, body, "text/html; charset=utf-8")
            return False
        self._json(401, {"ok": False, "error": "unauthorized"})
        return False

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch_read()

    def do_HEAD(self) -> None:  # noqa: N802
        self._dispatch_read()

    def do_POST(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/unlock":
            self._handle_unlock()
            return
        self._json(404, {"ok": False, "error": "not found"})

    def _dispatch_read(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path or "/"
        if path == "/healthz":
            self._handle_healthz()
            return
        if path == "/unlock":
            body = UNLOCK_HTML.encode("utf-8")
            self._send(200, body, "text/html; charset=utf-8")
            return
        if not self._require_auth():
            return
        if path in ("/", "/index.html"):
            self._serve_static("index.html", "text/html; charset=utf-8")
            return
        if path == "/api/v1/snapshot":
            self._handle_snapshot()
            return
        if path.startswith("/static/"):
            rel = path[len("/static/") :]
            self._serve_static(rel, None)
            return
        # Allow bare asset names next to index for offline simplicity.
        if path.lstrip("/") in ("app.js", "app.css"):
            ctype = (
                "application/javascript; charset=utf-8"
                if path.endswith(".js")
                else "text/css; charset=utf-8"
            )
            self._serve_static(path.lstrip("/"), ctype)
            return
        self._json(404, {"ok": False, "error": "not found"})

    def _handle_healthz(self) -> None:
        payload = {
            "ok": True,
            "uptime_s": int(time.monotonic() - START_MONOTONIC),
        }
        self._json(200, payload)

    def _handle_snapshot(self) -> None:
        try:
            body, _ = SNAPSHOT_CACHE.get(lambda: build_snapshot(self.paths))
        except Exception as exc:  # pragma: no cover - defensive
            self._json(
                500,
                {
                    "ok": False,
                    "error": "snapshot failed",
                    "detail": str(exc)[:400],
                },
            )
            return
        self._send(200, body, "application/json; charset=utf-8")

    def _handle_unlock(self) -> None:
        length = int(self.headers.get("Content-Length") or "0")
        if length < 0 or length > 8192:
            self._json(400, {"ok": False, "error": "bad request"})
            return
        raw = self.rfile.read(length) if length else b""
        ctype = self.headers.get("Content-Type", "")
        token = ""
        if "application/json" in ctype:
            try:
                obj = json.loads(raw.decode("utf-8") or "{}")
                token = str(obj.get("token") or "")
            except json.JSONDecodeError:
                token = ""
        else:
            form = urllib.parse.parse_qs(raw.decode("utf-8", errors="replace"))
            token = (form.get("token") or [""])[0]
        token = token.strip()
        if not token or not secrets.compare_digest(token, self.token):
            # Form posts from browsers: redirect back with error.
            if "application/json" in ctype:
                self._json(401, {"ok": False, "error": "unauthorized"})
            else:
                body = b""
                self._send(
                    303,
                    body,
                    "text/plain; charset=utf-8",
                    extra_headers=[("Location", "/unlock?e=1")],
                )
            return
        # 180 days; omit Secure so HTTP-on-tailnet works (documented).
        cookie = (
            f"{COOKIE_NAME}={token}; Path=/; Max-Age=15552000; "
            "HttpOnly; SameSite=Strict"
        )
        if "application/json" in ctype:
            self._send(
                200,
                b'{"ok":true}',
                "application/json; charset=utf-8",
                extra_headers=[("Set-Cookie", cookie)],
            )
        else:
            self._send(
                303,
                b"",
                "text/plain; charset=utf-8",
                extra_headers=[
                    ("Set-Cookie", cookie),
                    ("Location", "/"),
                ],
            )

    def _serve_static(self, rel: str, content_type: str | None) -> None:
        # Path traversal guard: only basename-safe relative paths under static.
        rel = rel.lstrip("/")
        if not rel or ".." in rel.split("/") or rel.startswith("/"):
            self._json(404, {"ok": False, "error": "not found"})
            return
        base = self.paths["static"]
        target = (base / rel).resolve()
        try:
            target.relative_to(base.resolve())
        except ValueError:
            self._json(404, {"ok": False, "error": "not found"})
            return
        if not target.is_file():
            self._json(404, {"ok": False, "error": "not found"})
            return
        if content_type is None:
            if target.suffix == ".html":
                content_type = "text/html; charset=utf-8"
            elif target.suffix == ".js":
                content_type = "application/javascript; charset=utf-8"
            elif target.suffix == ".css":
                content_type = "text/css; charset=utf-8"
            elif target.suffix == ".svg":
                content_type = "image/svg+xml"
            else:
                content_type = "application/octet-stream"
        try:
            body = target.read_bytes()
        except OSError:
            self._json(500, {"ok": False, "error": "read failed"})
            return
        self._send(200, body, content_type)


class DualStackServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self) -> None:
        # Force IPv4 bind to the exact host; refuse wildcards again at bind time.
        host, port = self.server_address  # type: ignore[misc]
        host = assert_bind_host(str(host))
        self.server_address = (host, int(port))
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        http.server.HTTPServer.server_bind(self)


def main() -> int:
    host = assert_bind_host(_env("FM_DASHBOARD_BIND_HOST"))
    port_s = _env("FM_DASHBOARD_BIND_PORT", "8391")
    try:
        port = int(port_s)
    except ValueError as exc:
        raise SystemExit(f"fm-dashboard-server: bad port {port_s!r}") from exc
    token = _env("FM_DASHBOARD_TOKEN")
    if not token:
        raise SystemExit("fm-dashboard-server: FM_DASHBOARD_TOKEN is required")
    paths = resolve_paths()
    if not paths["static"].is_dir():
        raise SystemExit(
            f"fm-dashboard-server: static dir missing: {paths['static']}"
        )
    # Ensure dashboard state dir exists (only write root besides logs from shell).
    paths["dashboard_state"].mkdir(parents=True, exist_ok=True)

    handler = type(
        "BoundDashboardHandler",
        (DashboardHandler,),
        {"paths": paths, "token": token},
    )
    try:
        httpd = DualStackServer((host, port), handler)
    except OSError as exc:
        raise SystemExit(
            f"fm-dashboard-server: bind failed on {host}:{port}: {exc}"
        ) from exc

    # Final safety: confirm the listening address is not a wildcard.
    bound_host, bound_port = httpd.server_address  # type: ignore[misc]
    assert_bind_host(str(bound_host))
    sys.stderr.write(
        f"fm-dashboard-server: listening on http://{bound_host}:{bound_port} "
        f"home={paths['fm_home']}\n"
    )
    sys.stderr.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        sys.stderr.write("fm-dashboard-server: interrupted\n")
    finally:
        httpd.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
