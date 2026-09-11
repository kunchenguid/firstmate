#!/usr/bin/env python3
import importlib.util
import io
import socket
import time
import unittest
from pathlib import Path
from unittest import mock


READER_PATH = Path(__file__).parents[1] / "bin" / "backends" / "herdr-eventwait.py"
SPEC = importlib.util.spec_from_file_location("herdr_eventwait", READER_PATH)
READER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READER)


class FailingSocket:
    def settimeout(self, _timeout):
        pass

    def recv(self, _size):
        raise OSError("receive failed")


class ClosingStreamSocket:
    def __init__(self):
        self.chunks = [
            b'{"result":{"type":"subscription_started"}}\n',
            b"",
        ]

    def settimeout(self, _timeout):
        pass

    def connect(self, _path):
        pass

    def sendall(self, _request):
        pass

    def recv(self, _size):
        return self.chunks.pop(0)


class RejectedSubscriptionSocket(ClosingStreamSocket):
    def __init__(self):
        self.chunks = [b'{"result":{"type":"not_started"}}\n']


class EventWaitReadLineTest(unittest.TestCase):
    def test_deadline_is_clean_timeout(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        self.addCleanup(right.close)

        line, buf, outcome = READER._read_line(left, b"", time.monotonic())

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "timeout")

    def test_peer_closure_is_runtime_failure(self):
        left, right = socket.socketpair()
        self.addCleanup(left.close)
        right.close()

        line, buf, outcome = READER._read_line(
            left, b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "closed")

    def test_receive_error_is_runtime_failure(self):
        line, buf, outcome = READER._read_line(
            FailingSocket(), b"", time.monotonic() + 1
        )

        self.assertIsNone(line)
        self.assertEqual(buf, b"")
        self.assertEqual(outcome, "error")

    def test_main_reports_early_stream_closure(self):
        stdout = io.StringIO()
        with mock.patch.object(READER.socket, "socket", return_value=ClosingStreamSocket()):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 4)
        self.assertEqual(stdout.getvalue(), "@subscribed\n")

    def test_main_does_not_signal_readiness_before_valid_ack(self):
        stdout = io.StringIO()
        with mock.patch.object(
            READER.socket, "socket", return_value=RejectedSubscriptionSocket()
        ):
            with mock.patch.object(READER.sys, "stdout", stdout):
                result = READER.main(["herdr-eventwait.py", "socket", "1", "pane"])

        self.assertEqual(result, 3)
        self.assertEqual(stdout.getvalue(), "")

    def test_main_saturated_stream_stays_within_budget(self):
        # 2026-08-21 quiet-fleet crash-loop regression: a stream that keeps
        # producing events (a pending-backlog replay, a fast-flapping agent)
        # with a consumer slower than the stream must not make the reader
        # outlive its deadline - neither in the stream loop nor inside a
        # blocking stdout write on a full pipe. Drive the REAL reader process
        # against a saturating fake server and a throttled stdout consumer and
        # assert it exits at the deadline (rc 0, a clean bounded wait).
        import json as _json
        import os
        import subprocess
        import sys as _sys
        import tempfile
        import threading

        timeout = 2
        tmpdir = tempfile.mkdtemp(prefix="fm-eventwait-budget.")
        self.addCleanup(
            lambda: __import__("shutil").rmtree(tmpdir, ignore_errors=True)
        )
        sock_path = os.path.join(tmpdir, "s.sock")
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(sock_path)
        server.listen(1)
        self.addCleanup(server.close)
        stop = threading.Event()

        def serve():
            try:
                conn, _ = server.accept()
                with conn:
                    conn.recv(65536)
                    conn.sendall(
                        b'{"id":"x","result":{"type":"subscription_started"}}\n'
                    )
                    event = (
                        _json.dumps(
                            {
                                "event": "pane.agent_status_changed",
                                "data": {
                                    "pane_id": "w1:p2",
                                    "workspace_id": "w1",
                                    "agent_status": "working",
                                    "agent": "claude",
                                },
                            }
                        )
                        + "\n"
                    ).encode()
                    while not stop.is_set():
                        conn.sendall(event)
            except OSError:
                pass

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()

        proc = subprocess.Popen(
            [_sys.executable, str(READER_PATH), sock_path, str(timeout), "w1:p2"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        )

        def consume_slowly():
            while True:
                line = proc.stdout.readline()
                if not line:
                    return
                time.sleep(0.02)

        consumer = threading.Thread(target=consume_slowly, daemon=True)
        consumer.start()

        deadline = time.monotonic() + timeout + 6
        while time.monotonic() < deadline:
            if proc.poll() is not None:
                break
            time.sleep(0.1)

        try:
            self.assertIsNotNone(
                proc.poll(),
                "reader still alive long past its wait budget under a "
                "saturated stream (quiet-fleet crash-loop regression)",
            )
            self.assertEqual(proc.returncode, 0)
        finally:
            stop.set()
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    unittest.main()
