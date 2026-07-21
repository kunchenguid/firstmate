#!/usr/bin/env python3
"""Hermetic AI Department portal fixture for connector tests.

The bearer token is read from a private file path, never argv text.
The server logs nothing and exposes only body hashes through its test stats API.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

if len(sys.argv) != 3:
    raise SystemExit("usage: fake-portal.py <token-file> <port-file>")

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    TOKEN = handle.read().rstrip("\r\n")
PORT_FILE = sys.argv[2]

lock = threading.Lock()
next_id = 1
messages: list[dict[str, object]] = []
idempotency: dict[str, tuple[str, dict[str, object]]] = {}
controls: dict[str, int] = {}
request_counts = {"poll": 0, "post": 0, "ack": 0, "unauthorized": 0}
KEY_RE = re.compile(r"^[!-~]{1,128}$")


def consume(name: str) -> bool:
    with lock:
        count = controls.get(name, 0)
        if count <= 0:
            return False
        controls[name] = count - 1
        return True


def new_message(direction: str, body: str) -> dict[str, object]:
    global next_id
    message = {
        "id": next_id,
        "direction": direction,
        "body": body.strip(),
        "created_at": f"2026-07-21T00:00:{next_id:02d}.000Z",
        "read_at": None,
        "delivered_at": None,
    }
    next_id += 1
    messages.append(message)
    return message


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_json(self, status: int, value: object) -> None:
        data = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def read_json(self) -> object:
        try:
            length = int(self.headers.get("content-length", "0"))
        except ValueError:
            return None
        if length < 0 or length > 300_000:
            return None
        try:
            return json.loads(self.rfile.read(length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return None

    def authorized(self) -> bool:
        if self.headers.get("authorization") == f"Bearer {TOKEN}":
            return True
        with lock:
            request_counts["unauthorized"] += 1
        self.send_json(403, {"error": "unauthorized"})
        return False

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/_test/stats":
            with lock:
                inbound = [m for m in messages if m["direction"] == "inbound"]
                outbound = [m for m in messages if m["direction"] == "outbound"]
                self.send_json(
                    200,
                    {
                        "reply_count": len(inbound),
                        "outbound_count": len(outbound),
                        "reply_hashes": [hashlib.sha256(str(m["body"]).encode()).hexdigest() for m in inbound],
                        "acknowledged_ids": [m["id"] for m in outbound if m["delivered_at"] is not None],
                        "idempotency_keys": len(idempotency),
                        "request_counts": dict(request_counts),
                    },
                )
            return
        if parsed.path != "/api/integration/messages":
            self.send_json(404, {"error": "not found"})
            return
        if not self.authorized():
            return
        with lock:
            request_counts["poll"] += 1
        if consume("poll_timeout"):
            time.sleep(6)
        if consume("poll_malformed"):
            data = b'{"messages":"bad"}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if consume("poll_oversized"):
            data = b"x" * 270_000
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        query = parse_qs(parsed.query)
        try:
            after = int(query.get("after_id", ["0"])[0])
            limit = min(max(int(query.get("limit", ["20"])[0]), 1), 100)
        except ValueError:
            self.send_json(400, {"error": "bad cursor"})
            return
        with lock:
            found = [
                {"id": m["id"], "body": m["body"], "created_at": m["created_at"]}
                for m in messages
                if m["direction"] == "outbound" and int(m["id"]) > after
            ][:limit]
        self.send_json(200, {"messages": found, "last_id": found[-1]["id"] if found else max(after, 0)})

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/_test/reset":
            global next_id
            with lock:
                next_id = 1
                messages.clear()
                idempotency.clear()
                controls.clear()
                request_counts.update({"poll": 0, "post": 0, "ack": 0, "unauthorized": 0})
            self.send_json(200, {"ok": True})
            return
        if parsed.path == "/_test/message":
            value = self.read_json()
            if not isinstance(value, dict) or not isinstance(value.get("body"), str):
                self.send_json(400, {"error": "bad body"})
                return
            with lock:
                message = new_message("outbound", value["body"])
            self.send_json(201, {"id": message["id"]})
            return
        if parsed.path == "/_test/control":
            value = self.read_json()
            if not isinstance(value, dict) or any(not isinstance(v, int) or v < 0 for v in value.values()):
                self.send_json(400, {"error": "bad control"})
                return
            with lock:
                controls.update(value)
            self.send_json(200, {"ok": True})
            return
        if parsed.path not in ("/api/integration/messages", "/api/integration/ack"):
            self.send_json(404, {"error": "not found"})
            return
        if not self.authorized():
            return
        value = self.read_json()
        if parsed.path == "/api/integration/messages":
            with lock:
                request_counts["post"] += 1
            if consume("post_fail_before"):
                self.send_json(503, {"error": "transient"})
                return
            key = self.headers.get("idempotency-key", "")
            if not KEY_RE.fullmatch(key):
                self.send_json(400, {"error": "bad idempotency key"})
                return
            if not isinstance(value, dict) or set(value) != {"body"} or not isinstance(value.get("body"), str):
                self.send_json(400, {"error": "bad body"})
                return
            body = value["body"].strip()
            if not body or len(body) > 4000:
                self.send_json(400, {"error": "bad body"})
                return
            with lock:
                prior = idempotency.get(key)
                if prior is not None:
                    if prior[0] != body:
                        self.send_json(409, {"error": "idempotency conflict"})
                        return
                    message = prior[1]
                    status = 200
                else:
                    message = new_message("inbound", body)
                    idempotency[key] = (body, message)
                    status = 201
            if consume("post_drop_after_commit"):
                self.close_connection = True
                return
            if consume("post_malformed_after_commit"):
                self.send_json(status, {"message": {"id": "bad"}})
                return
            self.send_json(status, {"message": message})
            return
        with lock:
            request_counts["ack"] += 1
        if not isinstance(value, dict) or set(value) != {"last_id"} or not isinstance(value.get("last_id"), int):
            self.send_json(400, {"error": "bad ack"})
            return
        acknowledged = 0
        with lock:
            for message in messages:
                if (
                    message["direction"] == "outbound"
                    and int(message["id"]) <= value["last_id"]
                    and message["delivered_at"] is None
                ):
                    message["delivered_at"] = "2026-07-21T00:01:00.000Z"
                    acknowledged += 1
        if consume("ack_drop_after_commit"):
            self.close_connection = True
            return
        self.send_json(200, {"acknowledged": acknowledged})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
os.chmod(PORT_FILE, 0o600)
server.serve_forever()
