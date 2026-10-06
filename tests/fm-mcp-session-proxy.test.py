#!/usr/bin/env python3
"""Behavior tests for bin/fm-mcp-session-proxy.py.

Every case drives the shipped executable over real HTTP and asserts on the JSONL
log it writes, so the contract under test is the observable one: a caller can read
a call's chronology, including the session id at each step, out of the log.

Run directly, or through bin/fm-test-run.sh as tests/fm-mcp-session-proxy.test.py.
"""

import contextlib
import json
import os
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).parents[1]
PROXY = ROOT / "bin" / "fm-mcp-session-proxy.py"
# Sessions the fake gateway issues, and the id it starts rejecting once the
# switch file appears. Both are well-formed UUIDs so only gateway state, not
# id shape, distinguishes unknown-session-id from session-lost.
ISSUED = "mcp-session-11111111-2222-3333-4444-555555555555"
REJECTED = "mcp-session-11111111-2222-3333-4444-666666666666"
# The real gateway parses the id and answers 404 "Invalid session ID" for one it
# cannot parse, and its client then reports "session terminated". Measured rule:
# the literal prefix "mcp-session-" then a hex UUID.
UUID_RE = re.compile(
    r"\Amcp-session-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\Z"
)


def free_port():
    with contextlib.closing(socket.socket()) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for_port(port, deadline=10.0):
    end = time.time() + deadline
    while time.time() < end:
        with contextlib.suppress(OSError):
            with contextlib.closing(socket.create_connection(("127.0.0.1", port), 0.5)):
                return True
        time.sleep(0.05)
    return False


class FakeGatewayHandler(BaseHTTPRequestHandler):
    """A stand-in gateway whose behavior the test switches by writing state files."""

    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    @property
    def state(self):
        with open(self.server.state_path) as handle:
            return json.load(handle)

    def _send(self, status, payload=b"", headers=()):
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        try:
            rpc = json.loads(body).get("method", "")
        except ValueError:
            rpc = ""
        session = self.headers.get("Mcp-Session-Id")
        if rpc == "initialize":
            self._send(
                200,
                b'{"jsonrpc":"2.0","id":1,"result":{}}',
                [("Content-Type", "application/json"), ("Mcp-Session-Id", ISSUED)],
            )
        elif rpc == "auth_probe":
            seen = (self.headers.get("Authorization") or "") + "|" + (self.headers.get("Cookie") or "")
            self._send(
                200,
                json.dumps({"jsonrpc": "2.0", "id": 1, "result": {"seen": seen}}).encode(),
                [("Content-Type", "application/json")],
            )
        elif rpc == "stream_error":
            self._stream(
                [
                    b"event: message\n",
                    b'data: {"jsonrpc":"2.0","id":2,"error":{"code":-32603,'
                    b'"message":"upstream tool exploded"}}\n\n',
                ]
            )
        elif rpc == "stream_slow":
            self._stream([b"chunk-%d\n" % n for n in range(40)], delay=0.05)
        elif rpc == "stream_silent":
            # Holds the stream open and sends nothing, which is what a gateway does
            # on the SSE leg; a client abandoning it produces no write-side error.
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            time.sleep(self.state.get("silent_seconds", 3))
        elif session is None or not UUID_RE.match(session):
            self._send(404, b"Invalid session ID", [("Content-Type", "text/plain; charset=utf-8")])
        elif session == REJECTED and self.state.get("reject_rejected"):
            self._send(404, b"Invalid session ID", [("Content-Type", "text/plain; charset=utf-8")])
        elif session == ISSUED and self.state.get("reject_issued"):
            self._send(404, b"Invalid session ID", [("Content-Type", "text/plain; charset=utf-8")])
        else:
            self._send(200, b'{"jsonrpc":"2.0","id":3,"result":{}}', [("Content-Type", "application/json")])

    def _stream(self, lines, delay=0.0):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            for line in lines:
                self.wfile.write(b"%x\r\n" % len(line) + line + b"\r\n")
                self.wfile.flush()
                time.sleep(delay)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except OSError:
            # The client vanished mid-stream, which is the case under test.
            self.close_connection = True

    def do_DELETE(self):
        self._send(200)


class ProxyUnderTest:
    """Runs the fake gateway and the shipped proxy, and reads the log back."""

    def __init__(self, tmpdir, extra_args=()):
        self.tmpdir = Path(tmpdir)
        self.log_path = self.tmpdir / "session-proxy.jsonl"
        self.state_path = self.tmpdir / "fake-state.json"
        self.state_path.write_text(json.dumps({"reject_rejected": False}))
        self.upstream_port = free_port()
        self.proxy_port = free_port()
        gateway = ThreadingHTTPServer(("127.0.0.1", self.upstream_port), FakeGatewayHandler)
        gateway.state_path = str(self.state_path)
        self.gateway = gateway
        self.thread = threading.Thread(target=gateway.serve_forever, daemon=True)
        self.thread.start()
        self.proc = subprocess.Popen(
            [
                sys.executable,
                str(PROXY),
                "--listen-port",
                str(self.proxy_port),
                "--upstream-port",
                str(self.upstream_port),
                "--log",
                str(self.log_path),
                *extra_args,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        if not wait_for_port(self.proxy_port):
            self.close()
            raise AssertionError("proxy did not start listening")

    def set_state(self, **fields):
        self.state_path.write_text(json.dumps(fields))

    def post(self, body, session=None, headers=(), raw_close=False):
        """Send one POST through the proxy and return (status, raw_body_bytes)."""
        head = [
            "POST /v0/groups/firstmate/mcp HTTP/1.1",
            "Host: 127.0.0.1",
            "Content-Type: application/json",
            "Accept: application/json, text/event-stream",
            "Content-Length: %d" % len(body),
            "Connection: close",
        ]
        if session:
            head.append("Mcp-Session-Id: %s" % session)
        head.extend(headers)
        raw = ("\r\n".join(head) + "\r\n\r\n").encode() + body
        return self._exchange(raw, raw_close)

    def delete(self, session):
        raw = (
            "DELETE /v0/groups/firstmate/mcp HTTP/1.1\r\n"
            "Host: 127.0.0.1\r\nMcp-Session-Id: %s\r\nConnection: close\r\n\r\n" % session
        ).encode()
        return self._exchange(raw)

    def _exchange(self, raw, raw_close=False):
        with contextlib.closing(socket.create_connection(("127.0.0.1", self.proxy_port), 10)) as sock:
            if raw_close:
                # Force an RST so the proxy's write to this client fails immediately.
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            sock.sendall(raw)
            if raw_close:
                head = b""
                deadline = time.time() + 5
                while b"\r\n\r\n" not in head and time.time() < deadline:
                    chunk = sock.recv(4096)
                    if not chunk:
                        break
                    head += chunk
                sock.close()
                return head, b""
            chunks = []
            while True:
                chunk = sock.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
        payload = b"".join(chunks)
        status = int(payload.split(b" ", 2)[1]) if payload else 0
        return status, payload

    def events(self):
        if not self.log_path.exists():
            return []
        return [json.loads(line) for line in self.log_path.read_text().splitlines() if line.strip()]

    def responses(self):
        return [event for event in self.events() if event["event"] == "response"]

    def wait_for_response(self, count, deadline=10.0):
        end = time.time() + deadline
        while time.time() < end:
            found = self.responses()
            if len(found) >= count:
                return found
            time.sleep(0.05)
        raise AssertionError("expected %d response events, saw %d" % (count, len(self.responses())))
    def close(self):
        with contextlib.suppress(Exception):
            self.proc.send_signal(signal.SIGTERM)
            self.proc.wait(timeout=5)
        with contextlib.suppress(Exception):
            if self.proc.poll() is None:
                self.proc.kill()
        with contextlib.suppress(Exception):
            self.proc.stderr.close()
        with contextlib.suppress(Exception):
            self.gateway.shutdown()
            self.gateway.server_close()


class McpSessionProxyTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.harness = None

    def harness_for(self, extra_args=()):
        self.harness = ProxyUnderTest(self._tmp.name, extra_args)
        self.addCleanup(self.harness.close)
        return self.harness

    def test_healthy_call_reads_as_a_session_ided_sequence(self):
        harness = self.harness_for()
        harness.post(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
        harness.post(b'{"jsonrpc":"2.0","method":"notifications/initialized"}', ISSUED)
        harness.post(b'{"jsonrpc":"2.0","id":2,"method":"tools/call"}', ISSUED)
        responses = harness.wait_for_response(3)

        self.assertEqual([event["verdict"] for event in responses], ["ok", "ok", "ok"])
        self.assertEqual(responses[0]["session"], "absent")
        self.assertEqual(responses[0]["session_issued"], ISSUED)
        self.assertEqual(responses[0]["session_state"], "absent")
        self.assertEqual([event["session"] for event in responses[1:]], [ISSUED, ISSUED])
        self.assertEqual([event["session_state"] for event in responses[1:]], ["tracked", "tracked"])
        self.assertEqual(
            [event["rpc"] for event in harness.events() if event["event"] == "request"],
            ["initialize", "notifications/initialized", "tools/call"],
        )

        created = [event for event in harness.events() if event["event"] == "session_created"]
        self.assertEqual([event["session"] for event in created], [ISSUED])
        timestamps = [event["ts"] for event in harness.events()]
        self.assertEqual(timestamps, sorted(timestamps))

    def test_delete_records_the_deletion(self):
        harness = self.harness_for()
        harness.post(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
        harness.wait_for_response(1)
        harness.delete(ISSUED)
        harness.wait_for_response(2)
        deleted = [event for event in harness.events() if event["event"] == "session_deleted"]
        self.assertEqual([event["session"] for event in deleted], [ISSUED])
        self.assertTrue(deleted[0]["tracked"])

    def test_absent_session_is_named_as_such(self):
        harness = self.harness_for()
        status, _ = harness.post(b'{"jsonrpc":"2.0","id":4,"method":"tools/call"}')
        self.assertEqual(status, 404)
        response = harness.wait_for_response(1)[0]
        self.assertEqual(response["verdict"], "missing-session-id")
        self.assertEqual(response["session"], "absent")
        self.assertEqual(response["error_message"], "Invalid session ID")

    def test_unparseable_session_id_is_distinguished(self):
        harness = self.harness_for()
        harness.post(b'{"jsonrpc":"2.0","id":4,"method":"tools/call"}', "not-a-uuid")
        response = harness.wait_for_response(1)[0]
        self.assertEqual(response["verdict"], "unparseable-id")
        self.assertEqual(response["session"], "not-a-uuid")

    def test_unknown_session_is_visible_even_when_the_gateway_accepts_it(self):
        # The real gateway answers 200 to a well-formed id it never issued; the log
        # must still say the id is untracked rather than call the call healthy.
        harness = self.harness_for()
        harness.post(b'{"jsonrpc":"2.0","id":4,"method":"tools/call"}', REJECTED)
        first = harness.wait_for_response(1)[0]
        self.assertEqual(first["verdict"], "ok")
        self.assertEqual(first["session_state"], "untracked")

        harness.set_state(reject_rejected=True)
        harness.post(b'{"jsonrpc":"2.0","id":5,"method":"tools/call"}', REJECTED)
        second = harness.wait_for_response(2)[1]
        self.assertEqual(second["verdict"], "unknown-session-id")
        self.assertEqual(second["session_state"], "untracked")

    def test_a_known_session_the_gateway_drops_is_named_a_lost_session(self):
        # This is the "session terminated" shape: the id was issued here and the
        # gateway later rejects it, which is the gateway losing the session.
        harness = self.harness_for()
        harness.post(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
        harness.wait_for_response(1)
        harness.set_state(reject_issued=True)
        lost = harness.post(b'{"jsonrpc":"2.0","id":6,"method":"tools/call"}', ISSUED)[0]
        self.assertEqual(lost, 404)
        response = harness.wait_for_response(2)[1]
        self.assertEqual(response["verdict"], "session-lost")
        self.assertEqual(response["session"], ISSUED)
        self.assertEqual(response["session_state"], "tracked")
        self.assertEqual(response["status"], 404)
        self.assertEqual(response["error_message"], "Invalid session ID")

    def test_sse_error_code_reaches_the_log_and_the_stream_stays_intact(self):
        harness = self.harness_for()
        status, payload = harness.post(
            b'{"jsonrpc":"2.0","id":6,"method":"stream_error"}', ISSUED
        )
        self.assertEqual(status, 200)
        self.assertIn(b"upstream tool exploded", payload)
        self.assertIn(b"Transfer-Encoding: chunked", payload)
        response = harness.wait_for_response(1)[0]
        self.assertEqual(response["error_code"], -32603)
        self.assertEqual(response["error_message"], "upstream tool exploded")

    def test_a_client_that_leaves_after_a_complete_body_is_not_a_premature_end(self):
        # A caller that closes as soon as it has the whole body must not be logged
        # as having terminated the call early, or every failed verdict becomes
        # unreliable. The declared length is what settles it.
        harness = self.harness_for()
        status, raw = harness.post(b'{"jsonrpc":"2.0","id":9,"method":"tools/list"}', ISSUED)
        self.assertEqual(status, 200)
        self.assertIn(b"\r\n\r\n", raw)
        response = harness.wait_for_response(1)[0]
        self.assertEqual(response["verdict"], "ok")
        self.assertEqual(response["bytes_to_client"], len(raw.split(b"\r\n\r\n", 1)[1]))

    def test_client_hanging_up_is_reported_separately(self):
        harness = self.harness_for()
        harness.post(b'{"jsonrpc":"2.0","id":7,"method":"stream_slow"}', ISSUED, raw_close=True)
        response = harness.wait_for_response(1)[0]
        self.assertEqual(response["verdict"], "client-closed")

    def test_client_hanging_up_on_a_silent_stream_is_reported(self):
        # A silent open stream never produces a write-side error, so the closure
        # is only visible if the proxy watches the client connection itself.
        harness = self.harness_for()
        harness.set_state(silent_seconds=5)
        started = time.time()
        harness.post(b'{"jsonrpc":"2.0","id":8,"method":"stream_silent"}', ISSUED, raw_close=True)
        response = harness.wait_for_response(1, deadline=8.0)[0]
        self.assertEqual(response["verdict"], "client-closed")
        self.assertLess(time.time() - started, 4.0, "closure was not noticed until the stream ended")

    def test_response_declares_a_single_request_connection(self):
        # A fronting proxy reuses its upstream connection unless told not to, and a
        # reused connection that this side has closed surfaces to the caller as 502.
        harness = self.harness_for()
        _, raw = harness.post(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
        head = raw.split(b"\r\n\r\n", 1)[0].lower()
        self.assertIn(b"connection: close", head)

    def test_repeated_calls_all_succeed(self):
        harness = self.harness_for()
        statuses = [
            harness.post(b'{"jsonrpc":"2.0","id":%d,"method":"tools/list"}' % n, ISSUED)[0]
            for n in range(5)
        ]
        self.assertEqual(statuses, [200] * 5)
        self.assertEqual([event["verdict"] for event in harness.wait_for_response(5)], ["ok"] * 5)

    def test_credentials_are_forwarded_but_never_logged(self):
        # Forwarding is the point: an authenticated MCP caller breaks the moment
        # Authorization stops reaching the gateway. Logging is the other half: the
        # value must not be written down.
        harness = self.harness_for()
        token = "super-secret-token-value"
        _, raw = harness.post(
            b'{"jsonrpc":"2.0","id":1,"method":"auth_probe"}',
            headers=("Authorization: Bearer %s" % token, "Cookie: session=%s" % token),
        )
        self.assertIn(token.encode(), raw, "the gateway never saw the credential")
        request = next(event for event in harness.events() if event["event"] == "request")
        self.assertTrue(request["auth_present"])
        self.assertNotIn(token, self.harness.log_path.read_text())

    def test_real_client_address_is_recorded_and_secrets_are_not(self):
        harness = self.harness_for()
        harness.post(
            b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
            headers=(
                "X-Forwarded-For: 100.101.102.103, 127.0.0.1",
                "Tailscale-User-Login: trillium@github",
                "Tailscale-User-Name: Trillium Smith",
                "Authorization: Bearer super-secret-token-value",
            ),
        )
        request = next(
            event for event in harness.events() if event["event"] == "request"
        )
        self.assertEqual(request["client"], "100.101.102.103")
        self.assertEqual(request["tailscale_login"], "trillium@github")
        self.assertEqual(request["tailscale_name"], "Trillium Smith")
        self.assertTrue(request["auth_present"])
        self.assertNotIn("super-secret-token-value", self.harness.log_path.read_text())

    def test_idle_session_is_marked_expired(self):
        harness = self.harness_for(("--session-idle-ttl", "1", "--sweep-interval", "1"))
        harness.post(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}')
        harness.wait_for_response(1)
        deadline = time.time() + 10
        while time.time() < deadline:
            expired = [event for event in harness.events() if event["event"] == "session_expired"]
            if expired:
                self.assertEqual([event["session"] for event in expired], [ISSUED])
                return
            time.sleep(0.2)
        self.fail("no session_expired event within 10s")


if __name__ == "__main__":
    unittest.main()