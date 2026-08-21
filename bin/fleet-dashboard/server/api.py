"""HTTP surface for the Admiral's Fleet Dashboard.

Stdlib-only on purpose: the deploy step is "run this file with python3",
with no pip install and no build tool, matching every other piece of this
fleet's own tooling. See docs/dashboard.md "Why stdlib instead of FastAPI".

Serves the API under /api/* and the built React page (bin/fleet-dashboard/web/)
for everything else. The API is the ONLY way to change a card - agents call it
through bin/fm-dashboard.sh, never by editing web/ or the database by hand.
"""

from __future__ import annotations

import json
import mimetypes
import os
import re
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from store import CAPTAINS, NOTE_AUTHORS, NOTE_TABS, STATUSES, Store
from validation import (
    InvalidLinkError,
    InvalidReasonError,
    validate_needs_attention_reason,
    validate_review_link,
)

FLEET_DASHBOARD_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB_DIR = os.path.join(FLEET_DASHBOARD_DIR, "web")
# bin/fleet-dashboard/server/api.py -> bin/ , where fm-fleet-audit-sweep.sh
# and fm-dashboard.sh (which the sweep script calls back through) live.
BIN_DIR = os.path.dirname(FLEET_DASHBOARD_DIR)

# Set by serve() before the handler is ever asked to launch a sweep - see
# audit_force's docstring for why the Force Audit button needs both of these.
FM_HOME_FOR_SUBPROCESS = ""
SELF_URL = ""


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


ROUTES = []


def route(method: str, pattern: str):
    compiled = re.compile("^" + pattern + "$")

    def decorator(fn):
        ROUTES.append((method, compiled, fn))
        return fn

    return decorator


def _sort_tasks(tasks: list[dict], sort: str) -> list[dict]:
    if sort == "date":
        return sorted(tasks, key=lambda t: t["created_at"], reverse=True)
    if sort == "status":
        order = {s: i for i, s in enumerate(STATUSES)}
        return sorted(tasks, key=lambda t: (order.get(t["status"], 99), t["title"]))
    if sort == "title":
        return sorted(tasks, key=lambda t: t["title"].lower())
    return tasks  # default: already ordered by updated_at desc from the store


@route("GET", r"/api/health")
def health(store: Store, match, query, body):
    return 200, {"ok": True}


@route("GET", r"/api/tasks")
def list_tasks(store: Store, match, query, body):
    status = query.get("status", [None])[0]
    captain = query.get("captain", [None])[0]
    starred_raw = query.get("starred", [None])[0]
    starred = None
    if starred_raw is not None:
        starred = starred_raw.lower() in ("1", "true", "yes")
    if status and status not in STATUSES:
        raise ApiError(400, f"unknown status: {status!r}. Valid: {', '.join(STATUSES)}")
    if captain and captain not in CAPTAINS:
        raise ApiError(400, f"unknown captain: {captain!r}. Valid: {', '.join(CAPTAINS)}")
    tasks = store.list_tasks(status=status, captain=captain, starred=starred)
    sort = query.get("sort", ["updated"])[0]
    tasks = _sort_tasks(tasks, sort)
    return 200, {"tasks": tasks}


@route("POST", r"/api/tasks")
def create_task(store: Store, match, query, body):
    title = (body.get("title") or "").strip()
    captain = body.get("captain")
    prompt = body.get("initial_prompt")
    if not title:
        raise ApiError(400, "title is required")
    if captain not in CAPTAINS:
        raise ApiError(400, f"captain is required and must be one of: {', '.join(CAPTAINS)}")
    if not prompt or not prompt.strip():
        raise ApiError(400, "initial_prompt is required - his own words, verbatim")
    status = body.get("status", "not_started")
    if status not in STATUSES:
        raise ApiError(400, f"unknown status: {status!r}. Valid: {', '.join(STATUSES)}")
    reason = body.get("reason") or None
    if status == "needs_attention":
        try:
            validate_needs_attention_reason(reason)
        except InvalidReasonError as exc:
            raise ApiError(400, str(exc)) from exc
    task = store.add_task(
        title=title,
        captain=captain,
        initial_prompt=prompt,
        agent=body.get("agent", "") or "",
        status=status,
        backlog_ref=body.get("backlog_ref") or None,
        needs_attention_reason=reason,
    )
    return 201, task


@route("GET", r"/api/tasks/(?P<id>[^/]+)")
def get_task(store: Store, match, query, body):
    task = store.get_task(match["id"])
    if task is None:
        raise ApiError(404, f"no such task: {match['id']!r}")
    return 200, task


@route("PATCH", r"/api/tasks/(?P<id>[^/]+)")
def patch_task(store: Store, match, query, body):
    task_id = match["id"]
    if not store.task_exists(task_id):
        raise ApiError(404, f"no such task: {task_id!r}")
    fields = {}
    for key in ("title", "agent", "captain", "backlog_ref", "starred"):
        if key in body:
            fields[key] = body[key]
    if "captain" in fields and fields["captain"] not in CAPTAINS:
        raise ApiError(400, f"unknown captain: {fields['captain']!r}. Valid: {', '.join(CAPTAINS)}")
    try:
        task = store.update_task(task_id, **fields)
    except ValueError as exc:
        raise ApiError(400, str(exc)) from exc
    return 200, task


@route("DELETE", r"/api/tasks/(?P<id>[^/]+)")
def delete_task(store: Store, match, query, body):
    task_id = match["id"]
    if not store.task_exists(task_id):
        raise ApiError(404, f"no such task: {task_id!r}")
    store.delete_task(task_id)
    return 200, {"deleted": task_id}


@route("POST", r"/api/tasks/(?P<id>[^/]+)/status")
def set_status(store: Store, match, query, body):
    task_id = match["id"]
    status = body.get("status")
    if status not in STATUSES:
        raise ApiError(400, f"unknown status: {status!r}. Valid: {', '.join(STATUSES)}")
    reason = body.get("reason") or None
    if status == "needs_attention":
        try:
            validate_needs_attention_reason(reason)
        except InvalidReasonError as exc:
            raise ApiError(400, str(exc)) from exc
    try:
        task = store.set_status(
            task_id,
            status,
            waiting_on_id=body.get("waiting_on_id") or None,
            reason=reason,
        )
    except KeyError as exc:
        raise ApiError(404, f"no such task: {task_id!r}") from exc
    except ValueError as exc:
        raise ApiError(400, str(exc)) from exc
    return 200, task


@route("POST", r"/api/tasks/(?P<id>[^/]+)/notes")
def add_note(store: Store, match, query, body):
    task_id = match["id"]
    tab = body.get("tab")
    if tab not in NOTE_TABS:
        raise ApiError(400, f"unknown tab: {tab!r}. Valid: {', '.join(NOTE_TABS)}")
    author = body.get("author", "agent")
    if author not in NOTE_AUTHORS:
        raise ApiError(400, f"unknown author: {author!r}. Valid: {', '.join(NOTE_AUTHORS)}")
    link_url = body.get("link_url") or None
    if link_url:
        try:
            validate_review_link(link_url)
        except InvalidLinkError as exc:
            raise ApiError(400, str(exc)) from exc
    try:
        task = store.add_note(
            task_id,
            tab=tab,
            author=author,
            text=body.get("text", "") or "",
            link_url=link_url,
            link_label=body.get("link_label") or None,
        )
    except KeyError as exc:
        raise ApiError(404, f"no such task: {task_id!r}") from exc
    except ValueError as exc:
        raise ApiError(400, str(exc)) from exc
    return 201, task


@route("GET", r"/api/settings/audit-interval")
def get_audit_interval(store: Store, match, query, body):
    return 200, {"minutes": store.get_audit_interval_minutes()}


@route("PUT", r"/api/settings/audit-interval")
def set_audit_interval(store: Store, match, query, body):
    try:
        minutes = int(body.get("minutes"))
        store.set_audit_interval_minutes(minutes)
    except (TypeError, ValueError) as exc:
        raise ApiError(400, f"minutes must be a positive integer: {exc}") from exc
    return 200, {"minutes": minutes}


@route("POST", r"/api/audit/log")
def audit_log(store: Store, match, query, body):
    kind = body.get("kind", "discrepancy")
    text = (body.get("text") or "").strip()
    if not text:
        raise ApiError(400, "text is required")
    task_id = body.get("task_id") or None
    if task_id and not store.task_exists(task_id):
        raise ApiError(404, f"no such task: {task_id!r}")
    try:
        store.record_audit_finding(kind, text, task_id=task_id)
    except ValueError as exc:
        raise ApiError(400, str(exc)) from exc
    return 201, {"recorded": True}


@route("POST", r"/api/audit/run")
def audit_run(store: Store, match, query, body):
    try:
        duration = float(body.get("duration_seconds"))
        checked = int(body.get("tasks_checked"))
    except (TypeError, ValueError) as exc:
        raise ApiError(400, f"duration_seconds and tasks_checked are required numbers: {exc}") from exc
    discrepancies = int(body.get("discrepancies_found", 0) or 0)
    forced = bool(body.get("forced", False))
    store.record_audit_run(
        duration_seconds=duration,
        tasks_checked=checked,
        discrepancies_found=discrepancies,
        started_at=body.get("started_at") or None,
        forced=forced,
    )
    return 201, {"recorded": True}


@route("GET", r"/api/audit/status")
def audit_status(store: Store, match, query, body):
    return 200, store.get_audit_status()


@route("POST", r"/api/audit/tick")
def audit_tick(store: Store, match, query, body):
    return 201, {"tick_at": store.record_audit_tick()}


@route("POST", r"/api/audit/claim")
def audit_claim(store: Store, match, query, body):
    forced = bool(body.get("forced", False))
    return 200, store.claim_audit_sweep(forced=forced)


@route("POST", r"/api/audit/release")
def audit_release(store: Store, match, query, body):
    store.release_audit_sweep()
    return 200, {"released": True}


@route("POST", r"/api/audit/force")
def audit_force(store: Store, match, query, body):
    """The Force Audit button's endpoint: claim, launch, return - in that
    order, without waiting for the sweep to finish.

    The claim happens here, synchronously, so the response the button gets
    (started/already-running) is never a guess about what a background
    process will do later - it is the actual outcome of the actual claim.
    Only the sweep script itself, launched detached, does the (potentially
    slow) checking; this handler's job ends the moment it is running.
    """
    claim = store.claim_audit_sweep(forced=True)
    if not claim["claimed"]:
        return 200, {"started": False, "reason": "a sweep is already in progress",
                     "running_since": claim["running_since"]}
    sweep_script = os.path.join(BIN_DIR, "fm-fleet-audit-sweep.sh")
    env = dict(os.environ)
    env["FM_HOME"] = FM_HOME_FOR_SUBPROCESS
    env["FM_DASHBOARD_URL"] = SELF_URL
    try:
        # A fixed argv, not a shell string and not user input: nothing here
        # is built from a request body or query parameter.
        subprocess.Popen(
            [sweep_script, "--forced", "--already-claimed"],
            cwd=BIN_DIR, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        store.release_audit_sweep()
        raise ApiError(500, f"could not launch the sweep: {exc}") from exc
    return 200, {"started": True, "started_at": claim["started_at"]}


def _guess_type(path: str) -> str:
    mime, _ = mimetypes.guess_type(path)
    return mime or "application/octet-stream"


def make_handler(store: Store):
    class Handler(BaseHTTPRequestHandler):
        server_version = "FleetDashboard/1.0"

        def log_message(self, fmt, *args):  # quiet by default; rely on audit/status endpoints
            pass

        def _send_json(self, status: int, payload) -> None:
            data = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _read_body(self) -> dict:
            length = int(self.headers.get("Content-Length", 0) or 0)
            if length == 0:
                return {}
            raw = self.rfile.read(length)
            try:
                return json.loads(raw or b"{}")
            except json.JSONDecodeError as exc:
                raise ApiError(400, f"invalid JSON body: {exc}") from exc

        def _dispatch(self, method: str) -> None:
            parsed = urllib.parse.urlsplit(self.path)
            path = urllib.parse.unquote(parsed.path)
            if not path.startswith("/api/"):
                if method == "GET":
                    self._serve_static(path)
                else:
                    self._send_json(404, {"error": "not found"})
                return
            query = urllib.parse.parse_qs(parsed.query)
            try:
                body = self._read_body() if method in ("POST", "PATCH", "PUT") else {}
                for m, pattern, fn in ROUTES:
                    if m != method:
                        continue
                    match = pattern.match(path)
                    if match:
                        status, payload = fn(store, match.groupdict(), query, body)
                        self._send_json(status, payload)
                        return
                self._send_json(404, {"error": f"no route for {method} {path}"})
            except ApiError as exc:
                self._send_json(exc.status, {"error": exc.message})
            except Exception as exc:  # last resort: never a bare 500 with no message
                self._send_json(500, {"error": f"internal error: {exc}"})

        def _serve_static(self, path: str) -> None:
            if path == "/":
                path = "/index.html"
            safe = os.path.normpath(path).lstrip("/")
            full = os.path.join(WEB_DIR, safe)
            if not os.path.abspath(full).startswith(os.path.abspath(WEB_DIR)):
                self._send_json(403, {"error": "forbidden"})
                return
            if not os.path.isfile(full):
                self._send_json(404, {"error": "not found"})
                return
            with open(full, "rb") as fh:
                data = fh.read()
            self.send_response(200)
            self.send_header("Content-Type", _guess_type(full))
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._dispatch("GET")

        def do_POST(self):
            self._dispatch("POST")

        def do_PATCH(self):
            self._dispatch("PATCH")

        def do_PUT(self):
            self._dispatch("PUT")

        def do_DELETE(self):
            self._dispatch("DELETE")

    return Handler


def serve(host: str, port: int, db_path: str) -> ThreadingHTTPServer:
    global FM_HOME_FOR_SUBPROCESS, SELF_URL
    # FM_HOME is normally inherited from the environment `fm-dashboard.sh
    # start` was launched in; when it is not (a bare `python3 main.py`), fall
    # back to db_path's grandparent, since every caller passes --db as
    # <FM_HOME>/data/dashboard.db (fm-dashboard.sh's cmd_server_start does,
    # and so does the test suite). This is what the Force Audit button's
    # detached sweep subprocess uses to find the right state/ and config/.
    FM_HOME_FOR_SUBPROCESS = os.environ.get(
        "FM_HOME", os.path.dirname(os.path.dirname(os.path.abspath(db_path)))
    )
    # A bind-all host (0.0.0.0 or ::) is not itself a reachable address for
    # the loopback call the sweep subprocess makes back into this same
    # server - use 127.0.0.1 in that case instead of the bind address.
    call_host = "127.0.0.1" if host in ("0.0.0.0", "::", "") else host
    SELF_URL = f"http://{call_host}:{port}"
    store = Store(db_path)
    handler = make_handler(store)
    httpd = ThreadingHTTPServer((host, port), handler)
    return httpd
