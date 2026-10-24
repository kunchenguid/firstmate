#!/usr/bin/env python3
"""Loopback operator console for one explicitly selected Firstmate home.

Usage: FM_HOME=/path/to/home bin/fm-console.py [--port 8765]
The operator secret is read from FM_HOME/config/console-operator-secret at startup.
This process does not manage a fleet session or configure network exposure.
"""

import argparse
import base64
import binascii
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "web" / "console"
REQUEST_ID = re.compile(r"(?!\.)[A-Za-z0-9._:-]{1,128}\Z")
CURSOR = re.compile(r"[0-9]{12}\Z")
ABS_PATH = re.compile(r"(?<![A-Za-z0-9])(?:/[^\s,;()<>]+|~\/[^\s,;()<>]+)")
URL = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:pull|issues)/[0-9]+\Z")


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def safe_text(value, limit=240):
    if not isinstance(value, str):
        return ""
    return ABS_PATH.sub("[path]", value[:limit])


def fields(row, spec):
    if not isinstance(row, dict):
        return {}
    return {key: safe_text(row.get(key), size) for key, size in spec.items()}


def rows(value, spec, limit=30):
    return [fields(item, spec) for item in value[:limit] if isinstance(item, dict)] if isinstance(value, list) else []


def disclosures(value):
    return [safe_text(item.get("surface"), 240) for item in value[:100]
            if isinstance(item, dict) and isinstance(item.get("surface"), str)] if isinstance(value, list) else []


def fleet_view(raw):
    if not isinstance(raw, dict) or raw.get("schema") != "fm-bearings.v1":
        raise ValueError("invalid Bearings schema")
    result = {
        "schema": "fm-console-fleet.v1",
        "observed_at": safe_text(raw.get("generated"), 40),
        "in_flight": rows(raw.get("in_flight"), {"id": 100, "name": 100, "repo": 80, "state": 40, "doing": 160}),
        "secondmates": rows(raw.get("secondmates"), {"id": 100, "state": 40, "doing": 160,
                                                          "freshness": 40, "reason": 120}),
        "decisions": rows(raw.get("decisions_open"), {"id": 100, "summary": 180, "owner": 80}),
        "gates": rows(raw.get("gates"), {"id": 100, "title": 120, "reason": 120, "owner": 80}),
        "landed": rows(raw.get("landed"), {"id": 100, "what": 120, "owner": 80}),
        "omitted": disclosures(raw.get("omitted")),
    }
    for key, value in ("in_flight", raw.get("in_flight")), ("secondmates", raw.get("secondmates")), \
                      ("decisions", raw.get("decisions_open")), ("gates", raw.get("gates")), \
                      ("landed", raw.get("landed")):
        if isinstance(value, list) and len(value) > 30:
            result["omitted"].append(f"Console displays the first 30 {key} rows")
    links = {}
    for item in raw.get("recorded_prs", [])[:30] if isinstance(raw.get("recorded_prs"), list) else []:
        if isinstance(item, dict) and isinstance(item.get("id"), str) and isinstance(item.get("url"), str):
            if URL.fullmatch(item["url"]):
                links[item["id"]] = item["url"]
    for item in result["landed"]:
        item["url"] = links.get(item["id"], "")
    unhealthy = raw.get("unhealthy_endpoints")
    if isinstance(unhealthy, list):
        for item in unhealthy[:30]:
            if isinstance(item, dict):
                result["omitted"].append("Endpoint evidence: " + safe_text(item.get("id"), 100)
                                         + " agent " + safe_text(item.get("agent"), 30))
    return result


def receipt_view(raw):
    if not isinstance(raw, dict) or raw.get("schema") != "fm-inbox-receipts.v1":
        raise ValueError("invalid receipts schema")
    def body(item):
        return item["body"][:16000] if isinstance(item.get("body"), str) else ""
    def note(item):
        reply = item.get("reply") if isinstance(item.get("reply"), dict) else None
        return {
            **fields(item, {"id": 100, "at": 40, "request_id": 128}),
            "body": body(item),
            "saved": True,
            "announced": item.get("announced") if item.get("announced") in (True, False, None) else None,
            "acknowledged": item.get("acknowledged") is True,
            "replied": reply is not None,
        }
    def reply(item):
        return {**fields(item, {"id": 100, "at": 40, "cursor": 20}), "body": body(item)}
    omitted = disclosures(raw.get("omitted"))
    for group in ("pending", "handled"):
        for item in raw.get(group, [])[:20]:
            if isinstance(item, dict) and isinstance(item.get("body"), str) and len(item["body"]) > 16000:
                omitted.append("A " + group + " body was shortened for browser display")
    for item in raw.get("replies", [])[:20]:
        if isinstance(item, dict) and isinstance(item.get("body"), str) and len(item["body"]) > 16000:
            omitted.append("A reply body was shortened for browser display")
    return {
        "schema": "fm-console-receipts.v1",
        "observed_at": safe_text(raw.get("generated"), 40),
        "pending": [note(x) for x in raw.get("pending", [])[:20] if isinstance(x, dict)],
        "handled": [note(x) for x in raw.get("handled", [])[:20] if isinstance(x, dict)],
        "replies": [reply(x) for x in raw.get("replies", [])[:20] if isinstance(x, dict)],
        "reply_cursor": safe_text(raw.get("reply_cursor"), 20),
        "omitted": omitted,
    }


def readiness_view(raw):
    if not isinstance(raw, dict) or raw.get("schema") != "fm-primary-ready.v1":
        raise ValueError("invalid readiness schema")
    receive = raw.get("can_receive")
    if receive not in (True, False, "unknown"):
        receive = "unknown"
    lock = raw.get("lock") if isinstance(raw.get("lock"), dict) else {}
    wake = raw.get("wake_consumer") if isinstance(raw.get("wake_consumer"), dict) else {}
    posture = raw.get("posture") if isinstance(raw.get("posture"), dict) else {}
    return {
        "schema": "fm-console-ready.v1",
        "observed_at": safe_text(raw.get("observed_at"), 40),
        "can_receive": receive,
        "lock": safe_text(lock.get("state"), 40),
        "wake_consumer": safe_text(wake.get("state"), 40),
        "posture": safe_text(posture.get("state"), 40),
    }


class ConsoleService:
    def __init__(self, home, secret, snapshot_bin=None, inbox_bin=None, interval=15):
        self.home = Path(home).resolve()
        self.secret = secret
        self.csrf = secrets.token_urlsafe(32)
        self.snapshot_bin = Path(snapshot_bin or ROOT / "bin/fm-bearings-snapshot.sh")
        self.inbox_bin = Path(inbox_bin or ROOT / "bin/fm-inbox.sh")
        self.interval = interval
        self.lock = threading.Lock()
        self.snapshot = None
        self.observed_at = None
        self.error = "Awaiting first observation"
        self.collecting = False
        self.last_start = 0.0
        self.recent_orders = {}
        self.order_slots = threading.BoundedSemaphore(4)

    def env(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("FM_")}
        env["FM_HOME"] = str(self.home)
        env["FM_SNAPSHOT_LOCAL_READ_CONCURRENCY"] = "2"
        return env

    def command(self, argv, body=None):
        proc = subprocess.run(argv, input=body, text=True, capture_output=True,
                              timeout=45, env=self.env(), check=False)
        if len(proc.stdout) > 2_000_000:
            raise ValueError("oversized command output")
        return proc

    def json_command(self, argv):
        proc = self.command(argv)
        if proc.returncode != 0:
            raise ValueError("owner command unavailable")
        return json.loads(proc.stdout)

    def _collect(self):
        try:
            view = fleet_view(self.json_command([str(self.snapshot_bin), "--json"]))
            with self.lock:
                self.snapshot = view
                self.observed_at = view["observed_at"] or now_iso()
                self.error = ""
        except (OSError, ValueError, subprocess.TimeoutExpired, json.JSONDecodeError):
            with self.lock:
                self.error = "Bearings observation unavailable"
        finally:
            with self.lock:
                self.collecting = False

    def fleet(self):
        with self.lock:
            current = time.monotonic()
            if not self.collecting and current - self.last_start >= self.interval:
                self.collecting = True
                self.last_start = current
                threading.Thread(target=self._collect, daemon=True).start()
            return {
                "snapshot": self.snapshot,
                "observed_at": self.observed_at,
                "served_at": now_iso(),
                "collecting": self.collecting,
                "error": self.error,
            }

    def receipts(self, after):
        args = [str(self.inbox_bin), "receipts"]
        if after:
            args += ["--after", after]
        return receipt_view(self.json_command(args))

    def ready(self):
        return readiness_view(self.json_command([str(self.inbox_bin), "ready"]))

    def order(self, request_id, body):
        proc = self.command([str(self.inbox_bin), "note", "--request-id", request_id, "--json", "-"], body)
        if proc.returncode not in (0, 3):
            raise ValueError("order capture unavailable")
        raw = json.loads(proc.stdout)
        if raw.get("schema") != "fm-inbox-note.v1" or raw.get("saved") is not True:
            raise ValueError("invalid order receipt")
        return {
            "schema": "fm-console-order.v1",
            "request_id": safe_text(raw.get("request_id"), 128),
            "id": safe_text(raw.get("id"), 100),
            "outcome": safe_text(raw.get("outcome"), 30),
            "saved": True,
            "announced": raw.get("announced") if raw.get("announced") in (True, False, None) else None,
            "acknowledged": raw.get("acknowledged") is True,
            "replied": False,
        }

    def allow_order(self, request_id):
        with self.lock:
            cutoff = time.monotonic() - 60
            self.recent_orders = {key: started for key, started in self.recent_orders.items()
                                  if started > cutoff}
            if request_id in self.recent_orders:
                return True
            if len(self.recent_orders) >= 20:
                return False
            self.recent_orders[request_id] = time.monotonic()
            return True


class Handler(BaseHTTPRequestHandler):
    server_version = "FirstmateConsole/1"

    def log_message(self, fmt, *args):
        pass

    @property
    def service(self):
        return self.server.service

    def send(self, status, body, content_type="application/json"):
        if content_type == "application/json":
            body = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)

    def guarded(self):
        host = self.headers.get("Host", "")
        allowed = {f"127.0.0.1:{self.server.server_port}", f"localhost:{self.server.server_port}"}
        if host not in allowed:
            self.send(403, {"error": "invalid host"})
            return False
        origin = self.headers.get("Origin")
        if origin and origin != f"http://{host}":
            self.send(403, {"error": "cross-origin request refused"})
            return False
        if self.headers.get("Sec-Fetch-Site") not in (None, "none", "same-origin"):
            self.send(403, {"error": "cross-origin request refused"})
            return False
        authorization = self.headers.get("Authorization", "")
        try:
            kind, encoded = authorization.split(" ", 1)
            supplied = base64.b64decode(encoded, validate=True).decode()
            username, password = supplied.split(":", 1)
        except (ValueError, UnicodeError, binascii.Error):
            username = password = kind = ""
        if kind != "Basic" or username != "operator" or not hmac.compare_digest(password.encode(), self.service.secret.encode()):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Firstmate console"')
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return False
        return True

    def do_GET(self):
        if not self.guarded():
            return
        path = urlsplit(self.path)
        if path.path in ("/", "/app.css", "/app.js") and not path.query:
            name = {"/": "index.html", "/app.css": "app.css", "/app.js": "app.js"}[path.path]
            kind = "text/html; charset=utf-8" if name.endswith("html") else "text/css; charset=utf-8" if name.endswith("css") else "text/javascript; charset=utf-8"
            self.send(200, (ASSETS / name).read_bytes(), kind)
            return
        if path.path == "/api/session" and not path.query:
            self.send(200, {"csrf": self.service.csrf})
            return
        if path.path == "/api/fleet" and not path.query:
            self.send(200, self.service.fleet())
            return
        if path.path == "/api/ready" and not path.query:
            try:
                self.send(200, self.service.ready())
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send(503, {"error": "Readiness unavailable; receiving state unknown"})
            return
        if path.path == "/api/receipts":
            query = parse_qs(path.query, keep_blank_values=True)
            after = query.get("after", [""])
            if (query and set(query) != {"after"}) or len(after) != 1 or (after[0] and not CURSOR.fullmatch(after[0])):
                self.send(400, {"error": "invalid cursor"})
                return
            try:
                self.send(200, self.service.receipts(after[0]))
            except (OSError, ValueError, subprocess.TimeoutExpired):
                self.send(503, {"error": "Receipts unavailable"})
            return
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if not self.guarded():
            return
        if self.path != "/api/order":
            self.send(404, {"error": "not found"})
            return
        if self.headers.get("Origin") != f"http://{self.headers.get('Host')}":
            self.send(403, {"error": "origin required"})
            return
        if not hmac.compare_digest(self.headers.get("X-Console-CSRF", ""), self.service.csrf):
            self.send(403, {"error": "CSRF check failed"})
            return
        if self.headers.get("Content-Type") != "application/json":
            self.send(415, {"error": "JSON required"})
            return
        try:
            size = int(self.headers.get("Content-Length", ""))
            if size < 1 or size > 20000:
                raise ValueError()
            payload = json.loads(self.rfile.read(size))
            if not isinstance(payload, dict) or set(payload) != {"request_id", "text"}:
                raise ValueError()
            request_id, body = payload["request_id"], payload["text"]
            if not isinstance(request_id, str) or not REQUEST_ID.fullmatch(request_id):
                raise ValueError()
            if not isinstance(body, str) or not body.strip() or len(body.encode()) > 16000:
                raise ValueError()
        except (ValueError, UnicodeError, json.JSONDecodeError):
            self.send(400, {"error": "invalid order"})
            return
        if not self.service.allow_order(request_id) or not self.service.order_slots.acquire(blocking=False):
            self.send(429, {"error": "Order intake busy; retry with the same request ID"})
            return
        try:
            receipt = self.service.order(request_id, body)
            try:
                ready = self.service.ready()
            except (OSError, ValueError, subprocess.TimeoutExpired):
                ready = {"schema": "fm-console-ready.v1", "observed_at": now_iso(),
                         "can_receive": "unknown", "lock": "unknown", "wake_consumer": "unknown", "posture": "unknown"}
            receipt["readiness"] = ready
            receipt["pending"] = ready["can_receive"] is not True or not receipt["announced"]
            self.send(202, receipt)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            self.send(503, {"error": "Order outcome uncertain; retry with the same request ID"})
        finally:
            self.service.order_slots.release()

    def unsupported(self):
        if self.guarded():
            self.send(405, {"error": "method not allowed"})

    do_HEAD = unsupported
    do_OPTIONS = unsupported
    do_PUT = unsupported
    do_PATCH = unsupported
    do_DELETE = unsupported
    do_TRACE = unsupported


def read_secret(home):
    config = home / "config"
    path = config / "console-operator-secret"
    if config.is_symlink() or path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise ValueError("console-operator-secret must be a private regular file")
    secret = path.read_text().strip()
    if len(secret) < 32 or "\n" in secret or "\r" in secret:
        raise ValueError("console-operator-secret must contain at least 32 characters on one line")
    return secret


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be 1-65535")
    home_text = os.environ.get("FM_HOME")
    if not home_text:
        parser.error("FM_HOME must select one operational home")
    home = Path(home_text).resolve(strict=True)
    try:
        service = ConsoleService(home, read_secret(home))
    except ValueError as error:
        parser.error(str(error))
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    server.service = service
    print(f"Firstmate console listening on 127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
