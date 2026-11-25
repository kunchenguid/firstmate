#!/usr/bin/env python3
"""Exercise resource wrappers without invoking ShellCheck or lint analysis."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parent.parent


class ResidentLimitTest(unittest.TestCase):
    def run_workload(self, limit, body):
        with tempfile.TemporaryDirectory(prefix=".resident-test-", dir=ROOT) as tmp:
            rss = Path(tmp) / "rss"
            pid_file = Path(tmp) / "pid"
            code = (
                "import os,sys,time; "
                "open(sys.argv[1], 'w').write(str(os.getpid())); " + body
            )
            command = [
                "bash", str(ROOT / "bin/fm-lint.sh"), "--internal-timed", "5", "1",
                "bash", str(ROOT / "bin/fm-lint.sh"), "--internal-root",
                str(rss), "resident", str(limit), sys.executable, "-c", code,
                str(pid_file),
            ]
            result = subprocess.run(
                command, env={**os.environ, "FM_LINT_INTERNAL": "1"},
                capture_output=True, text=True, timeout=12,
            )
            if pid_file.exists():
                pid = int(pid_file.read_text())
                for _ in range(20):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.05)
                else:
                    self.fail(f"workload {pid} survived wrapper exit")
            return result, rss.read_text() if rss.exists() else ""

    def test_populated_allocation_is_memory_not_deadline(self):
        # Contract: a 64 MiB populated allocation exceeds a 32 MiB ceiling
        # and must produce memory exit 98, not deadline exit 124. Repeating
        # rejects the intermittent missed samples observed on macOS.
        for attempt in range(3):
            with self.subTest(attempt=attempt):
                result, record = self.run_workload(
                    32768,
                    "payload=bytearray(os.urandom(64*1024*1024)); time.sleep(30)",
                )
                self.assertEqual(result.returncode, 98, result.stderr)
                self.assertIn("exceeded the per-root limit", result.stderr)
                self.assertGreater(int(record.strip().split("=")[1]), 32768)

    def test_under_limit_exit_is_preserved(self):
        result, _ = self.run_workload(131072, "time.sleep(.8); sys.exit(7)")
        self.assertEqual(result.returncode, 7, result.stderr)


if __name__ == "__main__":
    unittest.main()
