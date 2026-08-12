#!/usr/bin/env python3
import os
import subprocess
import sys
import tempfile


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HELPER = os.path.join(ROOT, "bin", "backends", "herdr-pane-close-bound.py")


def run_helper(socket_path, pid):
    return subprocess.run(
        [sys.executable, HELPER, socket_path, "w1:p2", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )


def test_bound_process_refuses_without_atomic_provider_close():
    with tempfile.TemporaryDirectory() as directory:
        for pid in (123, 456):
            result = run_helper(os.path.join(directory, "missing.sock"), pid)
            assert result.returncode == 4, result.stderr


if __name__ == "__main__":
    test_bound_process_refuses_without_atomic_provider_close()
    print("ok: Herdr provider-bound close fails closed without atomic identity support")
