#!/usr/bin/env python3
"""Local HTTP bridge for the fail-closed detect-secrets Jev gate."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOST = "127.0.0.1"
PORT = int(os.environ.get("JEV_SAFETY_PORT", "48752"))

SERVICE_NAME = "firstmate-jev-safety"
VENV_PYTHON = ROOT / ".claude/jev-safety/.venv/bin/python"
if not VENV_PYTHON.exists():
    sys.stderr.write(f"error: Jev safety virtualenv not found at {VENV_PYTHON}\n")
    sys.exit(1)
PYTHON_BIN = str(VENV_PYTHON)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802 - stdlib callback name
        if self.path != "/health":
            self.send_error(404)
            return
        if self.client_address[0] != HOST:
            self.send_error(403)
            return
        body = json.dumps({"status": "ok", "service": SERVICE_NAME}, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802 - stdlib callback name
        if self.path != "/check":
            self.send_error(404)
            return
        if self.client_address[0] != HOST:
            self.send_error(403)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 4_000_000:
                self.close_connection = True
                verdict = {
                    "allowed": False,
                    "reason": "payload_too_large",
                    "service": SERVICE_NAME,
                }
                body = json.dumps(verdict, separators=(",", ":")).encode()
                self.send_response(200)
                self.send_header("content-type", "application/json")
                self.send_header("content-length", str(len(body)))
                self.send_header("connection", "close")
                self.end_headers()
                self.wfile.write(body)
                return

            raw = self.rfile.read(length).decode("utf-8")
            result = subprocess.run(
                [PYTHON_BIN, str(ROOT / ".claude/jev-safety/check.py")],
                input=raw,
                capture_output=True,
                text=True,
                cwd=ROOT,
                timeout=30,
                check=False,
            )
            verdict = json.loads(result.stdout) if result.stdout else {
                "allowed": False,
                "reason": "scanner_unavailable",
            }
            if result.returncode not in (0, 3):
                verdict = {"allowed": False, "reason": "scanner_unavailable"}
        except Exception:
            verdict = {"allowed": False, "reason": "scanner_unavailable"}

        verdict["service"] = SERVICE_NAME
        body = json.dumps(verdict, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def check_health() -> bool:
    import urllib.request

    try:
        req = urllib.request.Request(f"http://{HOST}:{PORT}/health")
        with urllib.request.urlopen(req, timeout=0.5) as resp:
            if resp.status == 200:
                data = json.loads(resp.read().decode("utf-8"))
                return data.get("status") == "ok" and data.get("service") == SERVICE_NAME
    except Exception:
        return False
    return False


def ensure() -> None:
    import time

    if check_health():
        return
    subprocess.Popen(
        [PYTHON_BIN, str(Path(__file__).resolve()), "--serve"],
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = time.monotonic() + 2.5
    while time.monotonic() < deadline:
        time.sleep(0.05)
        if check_health():
            return
    sys.stderr.write("error: Jev safety server did not become ready within 2.5s\n")
    sys.exit(1)


if __name__ == "__main__":
    if "--serve" in sys.argv:
        ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
    else:
        ensure()
