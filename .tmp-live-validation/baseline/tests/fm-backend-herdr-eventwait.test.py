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


if __name__ == "__main__":
    unittest.main()
