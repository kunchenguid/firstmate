#!/usr/bin/env python3
# fm_status_server.py - read-only localhost HTTP/SSE status backend for
# bin/fm-status-server.sh.
#
# Serves the fleet view firstmate already computes, never re-deriving state:
#   - state/home-summary.json (bin/fm-home-summary-refresh.sh's published
#     ledger) is read verbatim as the fleet snapshot.
#   - Each active child's live one-line state comes from bin/fm-crew-state.sh
#     <id>, called fresh per request so it never goes stale between ledger
#     refreshes, alongside its recorded PR URL (null when absent) from
#     bin/fm-status-pr-url.sh <id>, which defers to fm-pr-lib.sh's own pr=
#     parser rather than re-reading state/<id>.meta by hand.
#   - quota-axi --json --no-credential-refresh supplies capacity data,
#     strictly read-only (no credential renewal, no keychain prompt).
# None of those sources embed tokens, credentials, .env values, brief text,
# or raw pane/scrollback content, and this server adds none of its own: it
# passes their output through unmodified. GET /status returns one JSON
# document; GET /events streams the same document over SSE on an interval.
# Every other path and every non-GET method is refused. The server accepts
# no request body, no write, and no command of any kind.
import argparse
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def _run(argv, timeout, env=None):
    """Run argv, returning (ok, stdout_text). Never raises."""
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            env=env,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return False, str(exc)
    if proc.returncode != 0:
        detail = (proc.stderr or proc.stdout or "").strip()
        return False, detail[:500] if detail else f"exit {proc.returncode}"
    return True, proc.stdout


def read_home_summary(state_dir):
    path = os.path.join(state_dir, "home-summary.json")
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh), None
    except FileNotFoundError:
        return None, "home-summary.json not yet published for this home"
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"home-summary.json unreadable: {exc}"


def build_task_rows(fm_root, fm_home, state_dir, task_ids, timeout):
    crew_state_bin = os.path.join(fm_root, "bin", "fm-crew-state.sh")
    pr_url_bin = os.path.join(fm_root, "bin", "fm-status-pr-url.sh")
    env = dict(os.environ)
    env["FM_HOME"] = fm_home
    env["FM_STATE_OVERRIDE"] = state_dir
    rows = []
    for task_id in task_ids:
        ok, out = _run([crew_state_bin, task_id], timeout, env=env)
        state_line = (
            out.strip() if ok else f"state: unknown · source: none · {out.strip()}"
        )
        pr_ok, pr_out = _run([pr_url_bin, task_id], timeout, env=env)
        pr_url = pr_out.strip() if pr_ok and pr_out.strip() else None
        rows.append({"id": task_id, "state": state_line, "pr_url": pr_url})
    return rows


def read_quota(timeout):
    ok, out = _run(
        ["quota-axi", "--json", "--no-credential-refresh"], timeout
    )
    if not ok:
        return None, out.strip()
    try:
        return json.loads(out), None
    except json.JSONDecodeError as exc:
        return None, f"quota-axi returned unparsable JSON: {exc}"


def build_payload(fm_root, fm_home, state_dir, timeout):
    summary, summary_error = read_home_summary(state_dir)
    task_ids = []
    if summary:
        task_ids = [
            child.get("id")
            for child in summary.get("active_children", [])
            if isinstance(child, dict) and child.get("id")
        ]
    tasks = build_task_rows(fm_root, fm_home, state_dir, task_ids, timeout)
    quota, quota_error = read_quota(timeout)
    return {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "home": fm_home,
        "home_summary": summary,
        "home_summary_error": summary_error,
        "tasks": tasks,
        "quota": quota,
        "quota_error": quota_error,
    }


class StatusHandler(BaseHTTPRequestHandler):
    server_version = "fm-status-server/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: A003 - stdlib override
        sys.stderr.write("fm-status-server: %s\n" % (fmt % args))

    def _refuse_write(self):
        self.send_response(405)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", "0")
        self.send_header("Allow", "GET")
        self.end_headers()

    do_POST = _refuse_write
    do_PUT = _refuse_write
    do_DELETE = _refuse_write
    do_PATCH = _refuse_write

    def _payload(self):
        return build_payload(
            self.server.fm_root,
            self.server.fm_home,
            self.server.state_dir,
            self.server.probe_timeout,
        )

    def do_GET(self):
        if self.path == "/status":
            self._serve_status()
        elif self.path == "/events":
            self._serve_events()
        else:
            self.send_response(404)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", "0")
            self.end_headers()

    def _serve_status(self):
        body = json.dumps(self._payload(), indent=2).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        interval = self.server.sse_interval
        try:
            while True:
                chunk = json.dumps(self._payload())
                self.wfile.write(f"data: {chunk}\n\n".encode("utf-8"))
                self.wfile.flush()
                time.sleep(interval)
        except (BrokenPipeError, ConnectionResetError):
            return


class StatusServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(
        description="Read-only localhost HTTP/SSE fleet status endpoint."
    )
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--fm-root", required=True)
    parser.add_argument("--fm-home", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--probe-timeout", type=float, default=10.0)
    args = parser.parse_args()

    server = StatusServer(("127.0.0.1", args.port), StatusHandler)
    server.fm_root = args.fm_root
    server.fm_home = args.fm_home
    server.state_dir = args.state_dir
    server.sse_interval = max(args.interval, 0.5)
    server.probe_timeout = max(args.probe_timeout, 1.0)
    sys.stderr.write(
        f"fm-status-server: listening on http://127.0.0.1:{args.port} "
        f"(GET /status, GET /events)\n"
    )
    sys.stderr.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
