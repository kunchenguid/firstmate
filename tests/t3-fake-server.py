#!/usr/bin/env python3
"""Fake T3 Code server for tests/fm-backend-t3.test.sh.

Serves the three owner-authenticated HTTP surfaces bin/backends/t3.sh drives -
GET /api/orchestration/shell, GET /api/orchestration/threads/<id>, and
POST /api/orchestration/dispatch - with the response and error shapes observed
on T3 Code v0.0.42 (docs/verification/runtime-backends.md "T3 Code").

Usage: t3-fake-server.py <state-dir>

The state directory is the whole model, so a bash test can seed, inspect, and
mutate it with jq between calls:
  origin          written once the socket is bound: http://127.0.0.1:<port>
  tokens          accepted bearer tokens, one per line (the fake `t3` CLI
                  appends what it mints); a request carrying none of them is
                  401 auth_invalid, exactly like the real server
  state.json      {"projects": {id: {...}}, "threads": {id: {...}}}, re-read on
                  every request and rewritten after every mutation
  dispatch.log    one JSON line per accepted dispatch command
  http.log        one line per request: METHOD PATH STATUS
  on-turn-status  session status a thread.turn.start sets (default running)
  on-interrupt-status  session status thread.turn.interrupt sets (default
                  stopped, the v0.0.42 behavior: T3 stops the provider)
  fail-thread-create   presence makes thread.create answer 500
  fail-thread-read     presence makes every thread detail read answer 500
  fail-thread-read-once  presence makes the next thread detail read answer
                       500, then removes itself
  fail-turn-start      presence makes thread.turn.start answer 500
  unlanded-turn-start  presence makes thread.turn.start answer 200 without
                       appending the message: a defensive model of a turn
                       accepted but not yet visible in a readable thread's
                       transcript, a shape never observed on v0.0.42
  fail-session-stop    presence makes thread.session.stop answer 200 but
                       change nothing (the ignored stop observed after archive)
  fail-runtime-mode-set  presence makes thread.runtime-mode.set answer 200
                       but change nothing
  fail-archive         presence makes thread.archive answer 200 but change
                       nothing, so a re-read still finds the thread
  no-dispatch-route    presence makes POST /api/orchestration/dispatch answer
                       404 with an empty body, the shape v0.0.42 gives an
                       unknown route and the surface T3's Orchestrator V2
                       leaves behind (bin/backends/t3.sh's version pin)
  fail-dispatch        presence makes every authorized dispatch answer 500,
                       the capability probe's empty command included
  dispatch-thread-not-found  presence makes every well-formed command answer
                       404 thread_not_found: a defensive model of a dispatch
                       404 that names a resource, a shape never observed on
                       v0.0.42 (which answers such commands 500)
Archived and deleted threads answer 404 thread_not_found and vanish from the
shell listing, as the real server does.
"""
from __future__ import annotations

import json
import os
import sys
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit

STATE_DIR = sys.argv[1]
SEQ = [1000]


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def path(name: str) -> str:
    return os.path.join(STATE_DIR, name)


def load_state() -> dict:
    try:
        with open(path("state.json"), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        data = {}
    data.setdefault("projects", {})
    data.setdefault("threads", {})
    return data


def save_state(data: dict) -> None:
    tmp = path("state.json.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
    os.replace(tmp, path("state.json"))


def append(name: str, line: str) -> None:
    with open(path(name), "a", encoding="utf-8") as fh:
        fh.write(line + "\n")


def flag(name: str) -> bool:
    return os.path.exists(path(name))


def flag_text(name: str, default: str) -> str:
    try:
        with open(path(name), encoding="utf-8") as fh:
            value = fh.read().strip()
    except OSError:
        return default
    return value or default


def thread_visible(thread: dict) -> bool:
    return thread.get("archivedAt") is None and thread.get("deletedAt") is None


def thread_summary(thread: dict) -> dict:
    summary = {k: v for k, v in thread.items() if k not in ("messages", "activities")}
    return summary


class Handler(BaseHTTPRequestHandler):
    server_version = "fake-t3/0.0.42"

    def log_message(self, fmt, *args):  # noqa: D401 - silence default logging
        return

    def _send(self, code: int, body) -> None:
        raw = b"" if body is None else json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        if raw:
            self.wfile.write(raw)
        append("http.log", f"{self.command} {self.path} {code}")

    def _error(self, code: int, tag: str, reason: str, err_code: str) -> None:
        self._send(code, {"_tag": tag, "code": err_code, "reason": reason, "traceId": uuid.uuid4().hex})

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            self._error(401, "EnvironmentAuthInvalidError", "missing_credential", "auth_invalid")
            return False
        token = header[len("Bearer "):].strip()
        try:
            with open(path("tokens"), encoding="utf-8") as fh:
                accepted = {line.strip() for line in fh if line.strip()}
        except OSError:
            accepted = set()
        if token not in accepted:
            self._error(401, "EnvironmentAuthInvalidError", "invalid_credential", "auth_invalid")
            return False
        return True

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            return
        parts = urlsplit(self.path)
        data = load_state()
        if parts.path == "/api/orchestration/shell":
            threads = [thread_summary(t) for t in data["threads"].values() if thread_visible(t)]
            self._send(200, {
                "snapshotSequence": SEQ[0],
                "projects": list(data["projects"].values()),
                "threads": threads,
                "updatedAt": now(),
            })
            return
        prefix = "/api/orchestration/threads/"
        if parts.path.startswith(prefix):
            if flag("fail-thread-read-once"):
                os.remove(path("fail-thread-read-once"))
                self._error(500, "EnvironmentInternalError", "orchestration_read_failed", "internal_error")
                return
            if flag("fail-thread-read"):
                self._error(500, "EnvironmentInternalError", "orchestration_read_failed", "internal_error")
                return
            thread_id = parts.path[len(prefix):]
            thread = data["threads"].get(thread_id)
            if thread is None or not thread_visible(thread):
                self._error(404, "EnvironmentResourceNotFoundError", "thread_not_found", "not_found")
                return
            self._send(200, {"snapshotSequence": SEQ[0], "thread": thread})
            return
        self._error(404, "EnvironmentResourceNotFoundError", "route_not_found", "not_found")

    def do_POST(self) -> None:  # noqa: N802
        parts = urlsplit(self.path)
        if parts.path == "/api/orchestration/dispatch" and flag("no-dispatch-route"):
            self._send(404, None)
            return
        if not self._authorized():
            return
        if parts.path != "/api/orchestration/dispatch":
            self._error(404, "EnvironmentResourceNotFoundError", "route_not_found", "not_found")
            return
        if flag("fail-dispatch"):
            self._error(500, "EnvironmentInternalError", "orchestration_dispatch_failed", "internal_error")
            return
        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            cmd = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            self._send(400, None)
            return
        if not isinstance(cmd, dict) or not isinstance(cmd.get("type"), str):
            self._send(400, None)
            return
        if flag("dispatch-thread-not-found"):
            self._error(404, "EnvironmentResourceNotFoundError", "thread_not_found", "not_found")
            return
        data = load_state()
        kind = cmd["type"]
        threads = data["threads"]
        ts = now()

        def internal():
            self._error(500, "EnvironmentInternalError", "orchestration_dispatch_failed", "internal_error")

        if kind == "project.create":
            for key in ("projectId", "title", "workspaceRoot"):
                if not cmd.get(key):
                    self._send(400, None)
                    return
            data["projects"][cmd["projectId"]] = {
                "id": cmd["projectId"],
                "title": cmd["title"],
                "workspaceRoot": cmd["workspaceRoot"],
                "defaultModelSelection": None,
                "createdAt": ts,
                "updatedAt": ts,
            }
        elif kind == "thread.create":
            if flag("fail-thread-create"):
                internal()
                return
            for key in ("threadId", "projectId", "title", "modelSelection", "runtimeMode"):
                if key not in cmd:
                    self._send(400, None)
                    return
            if cmd["projectId"] not in data["projects"]:
                internal()
                return
            threads[cmd["threadId"]] = {
                "id": cmd["threadId"],
                "projectId": cmd["projectId"],
                "title": cmd["title"],
                "modelSelection": cmd["modelSelection"],
                "runtimeMode": cmd["runtimeMode"],
                "interactionMode": cmd.get("interactionMode", "default"),
                "branch": cmd.get("branch"),
                "worktreePath": cmd.get("worktreePath"),
                "messages": [],
                "activities": [],
                "session": None,
                "latestTurn": None,
                "createdAt": ts,
                "updatedAt": ts,
                "archivedAt": None,
                "deletedAt": None,
            }
        elif kind in ("thread.turn.start", "thread.turn.interrupt", "thread.session.stop",
                      "thread.runtime-mode.set", "thread.archive", "thread.delete"):
            thread = threads.get(cmd.get("threadId", ""))
            if thread is None:
                internal()
                return
            if kind == "thread.turn.start":
                if flag("fail-turn-start"):
                    internal()
                    return
                if thread_visible(thread) and not flag("unlanded-turn-start"):
                    message = cmd.get("message") or {}
                    thread["messages"].append({
                        "id": message.get("messageId", str(uuid.uuid4())),
                        "role": "user",
                        "text": message.get("text", ""),
                        "createdAt": ts,
                    })
                    turn_id = str(uuid.uuid4())
                    status = flag_text("on-turn-status", "running")
                    thread["session"] = {
                        "threadId": thread["id"],
                        "status": status,
                        "providerName": "claudeAgent",
                        "providerInstanceId": "claudeAgent",
                        "runtimeMode": thread["runtimeMode"],
                        "activeTurnId": turn_id if status in ("starting", "running") else None,
                        "lastError": None,
                        "updatedAt": ts,
                    }
                    thread["latestTurn"] = {
                        "turnId": turn_id,
                        "state": "running" if status in ("starting", "running") else "completed",
                        "requestedAt": ts,
                        "startedAt": ts,
                        "completedAt": None,
                    }
            elif kind == "thread.turn.interrupt":
                if thread.get("session"):
                    thread["session"]["status"] = flag_text("on-interrupt-status", "stopped")
                    thread["session"]["activeTurnId"] = None
                if thread.get("latestTurn"):
                    thread["latestTurn"]["state"] = "completed"
            elif kind == "thread.session.stop":
                if thread.get("session") and not flag("fail-session-stop"):
                    thread["session"]["status"] = "stopped"
                    thread["session"]["activeTurnId"] = None
            elif kind == "thread.runtime-mode.set":
                if not cmd.get("runtimeMode"):
                    self._send(400, None)
                    return
                if not flag("fail-runtime-mode-set"):
                    thread["runtimeMode"] = cmd["runtimeMode"]
                    if thread.get("session"):
                        thread["session"]["runtimeMode"] = cmd["runtimeMode"]
            elif kind == "thread.archive":
                if not flag("fail-archive"):
                    thread["archivedAt"] = ts
            elif kind == "thread.delete":
                thread["deletedAt"] = ts
            thread["updatedAt"] = ts
        else:
            self._send(400, None)
            return
        SEQ[0] += 1
        save_state(data)
        append("dispatch.log", json.dumps(cmd, sort_keys=True))
        self._send(200, {"sequence": SEQ[0]})


def main() -> None:
    os.makedirs(STATE_DIR, exist_ok=True)
    if not os.path.exists(path("state.json")):
        save_state({"projects": {}, "threads": {}})
    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(path("origin.tmp"), "w", encoding="utf-8") as fh:
        fh.write(f"http://127.0.0.1:{server.server_address[1]}\n")
    os.replace(path("origin.tmp"), path("origin"))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
