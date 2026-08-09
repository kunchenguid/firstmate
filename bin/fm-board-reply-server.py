#!/usr/bin/env python3
"""fm-board-reply-server.py - the mission control board's direct reply service.

Launch it through `bin/fm-procevent-board-reply.sh serve <board.html>`, which owns
identity derivation and passes every path here explicitly. Running this file by
hand is supported but the adapter is the interface.

Usage:
  fm-board-reply-server.py --board <board.html> --requests <log>
                           --replies <log>
                           --parser <fm-board-request-parse.pl>
                           --registration <procevent source record>
                           [--port <n>] [--host 127.0.0.1]
                           [--max-body <bytes>]

WHAT IT DOES, and nothing else. One loopback port:

  GET  any path                 the board file, read fresh from disk every time
  GET  ?fm-board-reply=probe    a small JSON presence answer for the board's own probe
  GET  ?fm-board-reply=thread   the Ask-firstmate conversation, for display
  POST any path                 validate one captain request and durably record it

The thread read is display only, in both directions. It merges the captain `ask`
requests already recorded here with the replies firstmate posted through
`bin/fm-procevent-board-reply.sh say`, and it is the ONLY thing that reads the
reply log. Nothing acts on a reply, nothing wakes from one, and no path here
lets a reply reach the request log: the two logs are separate files and only the
request log is what the wake source reads.

Recording a request is not the same as firstmate collecting it, so both answers
report `armed`: whether a wake is registered for this board right now. The board
uses it to keep its confirmation truthful, and startup prints it so a service
launched against the wrong FM_HOME says so instead of quietly accepting requests
nothing will ever read.

AUTHORITY: none. A POST here performs nothing. It appends one line to a private
append-only log and returns; firstmate later reads that line as captain INTENT and
adjudicates it under its own contract, exactly as if the captain had said the same
words in chat. Nothing here merges, answers, defers, or touches fleet state, and
reaching this port is never authorization for any of that.

Binding. Loopback only, and a non-loopback --host is refused rather than bound.
Tailnet reachability is provided by reverse-proxying this port, which is the
project's existing trust boundary for every captain-facing local surface; see
docs/mission-control.md "The board reply service".

Same-site only, without a token layer. A loopback port is reachable by any page
the captain has open in the same browser, so a cross-site POST is refused three
independent ways: `Content-Type: application/json` and the required
`X-Fm-Board-Reply` header are both outside what a cross-origin request may send
without a preflight, no OPTIONS preflight is ever granted, and a browser-asserted
`Sec-Fetch-Site` that is present and not `same-origin` is rejected outright.
`Access-Control-Allow-*` is never sent on any response.

Validation is not implemented here. Every admitted request is validated by
bin/fm-board-request-parse.pl, over the exact record line this server is about to
store, so the rules that admit a request at the door and the rules that read it at
wake time are one implementation and cannot drift.

Path-agnostic on purpose: a reverse proxy may or may not strip its mount prefix,
so every GET that is not a `fm-board-reply` query serves the board and a POST is
accepted on any path. The board therefore posts to its own URL and needs no path
convention.

Every answer here, the thread included, is protected by exactly what protects the
board page itself: this port serves the board to any GET, no `Access-Control-
Allow-*` is ever sent, so another origin can issue a read but can never see the
answer. The thread adds no kind of exposure the board file did not already have.

Exit codes: 0 clean shutdown, 1 startup or runtime failure, 2 usage error.
"""

import argparse
import http.server
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

SERVICE = "fm-board-reply"
PROBE_PARAM = "fm-board-reply"
GUARD_HEADER = "X-Fm-Board-Reply"
LOOPBACK = ("127.0.0.1", "::1", "localhost")
DEFAULT_MAX_BODY = 8192
ATTEMPT_MAX = 80
# The thread is a conversation on a board, not an archive, so both ends are
# bounded and a bound that actually dropped something is disclosed rather than
# left to read as the whole story.
THREAD_MAX_MESSAGES = 50
THREAD_TAIL_BYTES = 262144


def die(message):
    sys.stderr.write("fm-board-reply-server: %s\n" % message)
    raise SystemExit(1)


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def json_line_field(value):
    """One field of a tabular record line, as a JSON string literal.

    The whole captain-supplied text becomes one JSON string on one physical line,
    so a body carrying newlines, a forged `prompts[...]` header, or extra record
    lines stays inside its own field and can never contribute tokens to the parse.
    """
    return json.dumps(value, ensure_ascii=False)


def attempt_ok(value):
    if not isinstance(value, str) or not value.startswith("fm-board:"):
        return False
    if len(value) > ATTEMPT_MAX:
        return False
    tail = value[len("fm-board:"):]
    if not tail:
        return False
    return all(c.isalnum() or c in "-._" for c in tail)


def no_duplicate_keys(pairs):
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError("duplicate key %s" % key)
        seen[key] = value
    return seen


def tail_records(path, max_bytes):
    """The last whole record lines of an append-only log, and whether any were cut.

    Only complete lines are records, so a write in progress at the end of the file
    contributes nothing, and a line that would end the parser's tabular block early
    is dropped here rather than being allowed to silently swallow every record
    after it.
    """
    try:
        with open(path, "rb") as log:
            log.seek(0, os.SEEK_END)
            size = log.tell()
            start = max(0, size - max_bytes)
            log.seek(start)
            raw = log.read()
    except OSError:
        return [], False
    lines = raw.decode("utf-8", "replace").split("\n")[:-1]
    cut = start > 0
    if cut and lines:
        lines = lines[1:]
    usable = [line for line in lines if line[:1] in (" ", "\t") and "\r" not in line]
    cut = cut or len(usable) != len(lines)
    return usable, cut


def leading_strings(line, count):
    """The first `count` JSON string fields of a record line, or None."""
    text = line.lstrip(" \t")
    decoder = json.JSONDecoder()
    values = []
    for _ in range(count):
        try:
            value, end = decoder.raw_decode(text)
        except ValueError:
            return None
        if not isinstance(value, str):
            return None
        values.append(value)
        text = text[end:]
        if text.startswith(","):
            text = text[1:]
    return values


class Thread:
    """The Ask-firstmate conversation on one board, for display and nothing else.

    Both sides run through the one shared validator, so a line neither side could
    have written is never rendered as something either of them said. The captain
    side reads the request log and keeps `ask` alone, which is what scopes this to
    the Ask-firstmate control: an answer, a merge request, a note, or a set-aside
    is a one-action control and never becomes conversation.
    """

    def __init__(self, requests_log, replies_log, parser):
        self.requests_log = requests_log
        self.replies_log = replies_log
        self.parser = parser
        self.lock = threading.Lock()
        self.cache = {}

    def read_side(self, path, kind, intent, sender):
        """Every message one log contributes, newest last, plus whether any were cut.

        Cached against the log's own size and modification time, so an idle board
        polling on its refresh cadence re-reads nothing and re-parses nothing.
        """
        try:
            stamp = os.stat(path)
            fingerprint = (stamp.st_size, stamp.st_mtime_ns)
        except OSError:
            fingerprint = None
        cached = self.cache.get(path)
        if cached is not None and cached[0] == fingerprint:
            return cached[1], cached[2]
        lines, cut = tail_records(path, THREAD_TAIL_BYTES)
        messages = self.parse(lines, kind, intent, sender) if lines else []
        self.cache[path] = (fingerprint, messages, cut)
        return messages, cut

    def parse(self, lines, kind, intent, sender):
        handle, staged = tempfile.mkstemp(prefix=".thread.",
                                          dir=os.path.dirname(self.requests_log))
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as candidate:
                candidate.write("prompts[%d]{received,attempt,prompt}:\n" % len(lines))
                for line in lines:
                    candidate.write(line + "\n")
                candidate.write("board-delta-end=0\n")
            try:
                done = subprocess.run(["perl", self.parser, staged],
                                      capture_output=True, timeout=20)
            except (OSError, subprocess.SubprocessError):
                return []
            if done.returncode != 0:
                return []
            messages = []
            for raw in done.stdout.decode("utf-8", "replace").splitlines():
                if not raw.strip():
                    continue
                try:
                    record = json.loads(raw)
                except ValueError:
                    continue
                if record.get("kind") != kind or record.get("intent") != intent:
                    continue
                at = record.get("record")
                if not isinstance(at, int) or not 1 <= at <= len(lines):
                    continue
                provenance = leading_strings(lines[at - 1], 2) or ["", ""]
                messages.append({"id": provenance[1], "at": provenance[0],
                                 "from": sender, "text": record.get("note") or ""})
            return messages
        finally:
            try:
                os.unlink(staged)
            except OSError:
                pass

    def messages(self):
        with self.lock:
            asked, asked_cut = self.read_side(self.requests_log, "request", "ask", "captain")
            said, said_cut = self.read_side(self.replies_log, "reply", "say", "firstmate")
        # Stable by the time each message was RECORDED, which is all either log
        # knows. The captain side is laid out first, so a same-second tie reads as
        # the ask preceding the answer to it rather than the other way round.
        merged = sorted(asked + said, key=lambda message: message["at"])
        cut = asked_cut or said_cut
        if len(merged) > THREAD_MAX_MESSAGES:
            merged = merged[-THREAD_MAX_MESSAGES:]
            cut = True
        return merged, cut


class Receiver:
    """Validation and durable append. One instance, shared by every request."""

    def __init__(self, board, requests_log, parser, registration, max_body):
        self.board = board
        self.requests_log = requests_log
        self.parser = parser
        self.registration = registration
        self.max_body = max_body
        self.lock = threading.Lock()

    def armed(self):
        """Whether a wake is registered for this board right now.

        Recording a request is not the same as firstmate collecting it: a
        continuity break retires the source until an operator rebases it, and a
        deployment that never armed leaves the same gap from the start. The board
        needs this to keep its confirmation truthful, so it is read fresh rather
        than cached.
        """
        return os.path.isfile(self.registration) and not os.path.islink(self.registration)

    def record_line(self, received, attempt, wire):
        return "  %s,%s,%s\n" % (json_line_field(received),
                                 json_line_field(attempt),
                                 json_line_field(wire))

    def validate(self, line):
        """Run the shared validator over this exact record line.

        Returns None when the line normalizes to exactly one request, and a short
        refusal reason otherwise. A refusal is the captain's own request being
        rejected, so the reason is safe to show them.
        """
        handle, path = tempfile.mkstemp(prefix=".admit.", dir=os.path.dirname(self.requests_log))
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as candidate:
                candidate.write("prompts[1]{received,attempt,prompt}:\n")
                candidate.write(line)
                candidate.write("board-delta-end=0\n")
            try:
                done = subprocess.run(["perl", self.parser, path],
                                      capture_output=True, timeout=20)
            except (OSError, subprocess.SubprocessError):
                return "the request could not be validated"
            if done.returncode != 0:
                return "the request could not be validated"
            requests = 0
            refusal = None
            for raw in done.stdout.decode("utf-8", "replace").splitlines():
                if not raw.strip():
                    continue
                try:
                    record = json.loads(raw)
                except ValueError:
                    return "the request could not be validated"
                kind = record.get("kind")
                if kind == "request":
                    requests += 1
                elif kind == "unrecognized":
                    refusal = record.get("reason") or "the request was refused"
                elif kind == "message":
                    refusal = "the request carries no board request marker"
            if refusal is not None:
                return refusal
            if requests != 1:
                return "the request did not resolve to exactly one board request"
            return None
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass

    def already_stored(self, attempt):
        """True when this exact enqueue attempt is already recorded.

        The board reuses one attempt identity when a send is interrupted, so a
        retry after a reload replaces nothing and appends nothing rather than
        recording the captain's one answer twice.
        """
        needle = "," + json_line_field(attempt) + ","
        try:
            with open(self.requests_log, "r", encoding="utf-8", errors="replace") as log:
                for line in log:
                    if needle in line:
                        return True
        except FileNotFoundError:
            return False
        return False

    def accept(self, body):
        """Validate and durably record one request. Returns (status, payload)."""
        if len(body) > self.max_body:
            return 413, {"ok": False, "reason": "the request is larger than the accepted bound"}
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            return 400, {"ok": False, "reason": "the request body is not valid UTF-8"}
        try:
            envelope = json.loads(text, object_pairs_hook=no_duplicate_keys)
        except ValueError:
            return 400, {"ok": False, "reason": "the request body is not one JSON object"}
        if not isinstance(envelope, dict) or set(envelope) != {"wire", "attempt"}:
            return 400, {"ok": False,
                         "reason": "the request body must carry exactly one wire and one attempt"}
        wire = envelope["wire"]
        attempt = envelope["attempt"]
        if not isinstance(wire, str) or not wire:
            return 400, {"ok": False, "reason": "the request carries no wire text"}
        if not attempt_ok(attempt):
            return 400, {"ok": False, "reason": "the request carries no usable attempt identity"}

        received = iso_now()
        line = self.record_line(received, attempt, wire)
        refusal = self.validate(line)
        if refusal is not None:
            return 422, {"ok": False, "reason": refusal}

        with self.lock:
            if self.already_stored(attempt):
                return 200, {"ok": True, "received": received, "duplicate": True,
                             "armed": self.armed()}
            try:
                self.append(line)
            except OSError:
                return 500, {"ok": False, "reason": "the request could not be recorded"}
        return 200, {"ok": True, "received": received, "armed": self.armed()}

    def append(self, line):
        """One durable append. The log is append-only and never rewritten here."""
        raw = line.encode("utf-8")
        fd = os.open(self.requests_log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            written = 0
            while written < len(raw):
                written += os.write(fd, raw[written:])
            os.fsync(fd)
        finally:
            os.close(fd)

    def board_bytes(self):
        with open(self.board, "rb") as page:
            return page.read()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "fm-board-reply"
    sys_version = ""
    receiver = None
    thread = None

    def log_message(self, fmt, *args):  # noqa: A003 - BaseHTTPRequestHandler hook
        """Quiet by default: a captain surface is not a request log."""
        if os.environ.get("FM_BOARD_REPLY_VERBOSE") == "1":
            sys.stderr.write("fm-board-reply: %s\n" % (fmt % args))

    def send_payload(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, status, payload):
        body = (json.dumps(payload) + "\n").encode("utf-8")
        self.send_payload(status, body, "application/json; charset=utf-8")

    def ask(self):
        """The value of the `fm-board-reply` query parameter, or None."""
        query = self.path.partition("?")[2].partition("#")[0]
        for part in query.split("&"):
            name, _, value = part.partition("=")
            if name == PROBE_PARAM:
                return value
        return None

    def do_GET(self):
        asked = self.ask()
        if asked == "thread":
            messages, truncated = self.thread.messages()
            self.send_json(200, {"service": SERVICE, "v": 1,
                                 "armed": self.receiver.armed(),
                                 "messages": messages, "truncated": truncated})
            return
        if asked is not None:
            self.send_json(200, {"service": SERVICE, "v": 1,
                                 "armed": self.receiver.armed()})
            return
        try:
            body = self.receiver.board_bytes()
        except OSError:
            self.send_json(503, {"ok": False, "reason": "the board has not been rendered yet"})
            return
        self.send_payload(200, body, "text/html; charset=utf-8")

    def do_HEAD(self):
        self.do_GET()

    def same_site_refusal(self):
        """Why this write must not be accepted, or None when it may be.

        A cross-site page cannot set either of the two conditions below without a
        preflight, and no preflight is ever granted, so this is what keeps a
        loopback port from being a cross-site write surface.
        """
        site = self.headers.get("Sec-Fetch-Site")
        if site is not None and site.strip().lower() != "same-origin":
            return "the request did not come from the board itself"
        if self.headers.get(GUARD_HEADER) != "1":
            return "the request did not come from the board itself"
        kind = (self.headers.get("Content-Type") or "").partition(";")[0].strip().lower()
        if kind != "application/json":
            return "the request must be sent as application/json"
        return None

    def do_POST(self):
        refusal = self.same_site_refusal()
        if refusal is not None:
            self.send_json(403, {"ok": False, "reason": refusal})
            return
        raw_length = self.headers.get("Content-Length")
        try:
            length = int(raw_length)
        except (TypeError, ValueError):
            self.send_json(411, {"ok": False, "reason": "the request needs a content length"})
            return
        if length < 0:
            self.send_json(400, {"ok": False, "reason": "the request length is not usable"})
            return
        if length > self.receiver.max_body:
            self.send_json(413, {"ok": False,
                                 "reason": "the request is larger than the accepted bound"})
            return
        body = self.rfile.read(length) if length else b""
        status, payload = self.receiver.accept(body)
        self.send_json(status, payload)

    def do_OPTIONS(self):
        """Never a preflight grant: no Access-Control-Allow-* is ever sent."""
        self.send_json(405, {"ok": False, "reason": "this service accepts only GET and POST"})

    def do_PUT(self):
        self.send_json(405, {"ok": False, "reason": "this service accepts only GET and POST"})

    do_DELETE = do_PUT
    do_PATCH = do_PUT


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main(argv):
    parser = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    parser.add_argument("--board", required=True)
    parser.add_argument("--requests", required=True)
    parser.add_argument("--replies", required=True)
    parser.add_argument("--parser", required=True)
    parser.add_argument("--registration", required=True)
    parser.add_argument("--port", type=int, default=4321)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--max-body", type=int, default=DEFAULT_MAX_BODY)
    try:
        options = parser.parse_args(argv)
    except SystemExit as exit_request:
        raise SystemExit(2 if exit_request.code else 0)

    if options.host not in LOOPBACK:
        die("refusing to bind %s; this service is loopback only" % options.host)
    if options.port < 0 or options.port > 65535:
        die("port is out of range: %s" % options.port)
    if options.max_body < 1:
        die("--max-body must be positive")
    if not os.path.isfile(options.parser):
        die("request validator not found: %s" % options.parser)

    log_dir = os.path.dirname(os.path.abspath(options.requests))
    try:
        os.makedirs(log_dir, mode=0o700, exist_ok=True)
    except OSError as error:
        die("cannot create the request log directory: %s" % error)
    if os.path.islink(options.requests):
        die("the request log is a symlink: %s" % options.requests)
    if os.path.islink(options.replies):
        die("the reply log is a symlink: %s" % options.replies)

    Handler.receiver = Receiver(os.path.abspath(options.board),
                                os.path.abspath(options.requests),
                                os.path.abspath(options.parser),
                                os.path.abspath(options.registration),
                                options.max_body)
    Handler.thread = Thread(os.path.abspath(options.requests),
                            os.path.abspath(options.replies),
                            os.path.abspath(options.parser))
    family = socket.AF_INET6 if ":" in options.host else socket.AF_INET
    Server.address_family = family
    try:
        server = Server((options.host, options.port), Handler)
    except OSError as error:
        die("cannot listen on %s:%s: %s" % (options.host, options.port, error))
    port = server.server_address[1]
    sys.stdout.write("listening: http://%s:%s/\n" % (options.host, port))
    sys.stdout.write("board: %s\n" % Handler.receiver.board)
    sys.stdout.write("requests: %s\n" % Handler.receiver.requests_log)
    sys.stdout.write("replies: %s\n" % Handler.thread.replies_log)
    sys.stdout.write("armed: %s\n" % ("yes" if Handler.receiver.armed()
                                      else "no (nothing is collecting replies for this board yet)"))
    sys.stdout.flush()
    try:
        server.serve_forever(poll_interval=0.2)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
