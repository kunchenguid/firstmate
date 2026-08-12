#!/usr/bin/env python3
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(ROOT, "bin", "backends", "herdr-pane-close-bound.py")


class FakeHerdrSocket:
    def __init__(self, process_pid):
        self.process_pid = process_pid
        self.requests = []
        self.directory = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.directory.name, "herdr.sock")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(1)
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.server.close()
        self.thread.join(timeout=2)
        self.directory.cleanup()

    def serve(self):
        try:
            connection, _ = self.server.accept()
        except OSError:
            return
        with connection:
            reader = connection.makefile("r", encoding="utf-8")
            writer = connection.makefile("w", encoding="utf-8")
            for line in reader:
                request = json.loads(line)
                self.requests.append(request)
                if request["method"] != "pane.close_bound":
                    response = {
                        "id": request["id"],
                        "error": {"code": "unsupported"},
                    }
                elif request["params"]["expected_pid"] != self.process_pid:
                    response = {
                        "id": request["id"],
                        "error": {"code": "expected_pid_mismatch"},
                    }
                else:
                    response = {
                        "id": request["id"],
                        "result": {
                            "type": "pane_closed_bound",
                            "pane_id": request["params"]["pane_id"],
                            "expected_pid": self.process_pid,
                            "atomic": True,
                        },
                    }
                writer.write(json.dumps(response) + "\n")
                writer.flush()


def run_helper(socket_path, pid):
    return subprocess.run(
        [sys.executable, HELPER, socket_path, "w1:p2", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )


def test_bound_process_uses_provider_atomic_expected_pid_close():
    with FakeHerdrSocket(123) as fake:
        result = run_helper(fake.path, 123)
    assert result.returncode == 0, result.stderr
    assert len(fake.requests) == 1
    assert fake.requests[0]["method"] == "pane.close_bound"
    assert fake.requests[0]["params"] == {"pane_id": "w1:p2", "expected_pid": 123}


def test_bound_process_refuses_foreign_provider_pid():
    with FakeHerdrSocket(456) as fake:
        result = run_helper(fake.path, 123)
    assert result.returncode == 4, result.stderr
    assert len(fake.requests) == 1
    assert fake.requests[0]["method"] == "pane.close_bound"


def test_bound_process_refuses_missing_provider():
    with tempfile.TemporaryDirectory() as directory:
        result = run_helper(os.path.join(directory, "missing.sock"), 123)
    assert result.returncode == 3, result.stderr


if __name__ == "__main__":
    test_bound_process_uses_provider_atomic_expected_pid_close()
    test_bound_process_refuses_foreign_provider_pid()
    test_bound_process_refuses_missing_provider()
    print("ok: Herdr provider-bound close uses atomic expected-PID identity")
