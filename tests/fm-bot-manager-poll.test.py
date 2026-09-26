#!/usr/bin/env python3
import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "bin" / "fm-bot-manager-poll.py"
ADAPTER = ROOT / "bin" / "fm-procevent-bot-manager.sh"
SPEC = importlib.util.spec_from_file_location("bot_manager_poll", SCRIPT)
POLL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLL)


class StopPolling(Exception):
    pass


class BotManagerPollTest(unittest.TestCase):
    def test_transient_transport_failure_retries(self):
        failures = [
            urllib.error.URLError("offline"),
            urllib.error.HTTPError("https://api.notion.com/", 408, "timeout", {}, None),
            urllib.error.HTTPError("https://api.notion.com/", 429, "busy", {}, None),
            urllib.error.HTTPError("https://api.notion.com/", 503, "busy", {}, None),
        ]
        for failure in failures:
            with self.subTest(failure=type(failure).__name__), tempfile.TemporaryDirectory() as tmp:
                fetch = mock.Mock(side_effect=[failure, []])
                with mock.patch.dict("os.environ", {"NOTION_TOKEN": "test-token"}), \
                        mock.patch.object(POLL, "fetch", fetch), \
                        mock.patch.object(POLL, "atomic_json"), \
                        mock.patch.object(POLL.time, "sleep", side_effect=[None, StopPolling]):
                    with self.assertRaises(StopPolling):
                        POLL.poll("database", Path(tmp) / "state.json")

                self.assertEqual(fetch.call_count, 2)
                if isinstance(failure, urllib.error.HTTPError):
                    failure.close()

    def test_permanent_http_error_is_terminal_and_supervisor_visible(self):
        for status in (400, 401, 403, 501, 505):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as tmp:
                output = io.StringIO()
                error = urllib.error.HTTPError(
                    "https://api.notion.com/", status, "private response body", {}, None
                )
                with mock.patch.dict("os.environ", {"NOTION_TOKEN": "secret-token"}), \
                        mock.patch.object(POLL, "fetch", side_effect=error), \
                        mock.patch.object(POLL.time, "sleep") as sleep, \
                        mock.patch.object(POLL.sys, "stdout", output):
                    POLL.poll("database", Path(tmp) / "state.json")
                error.close()

                result = json.loads(output.getvalue())
                self.assertEqual(result, {
                    "kind": "poll-error", "status": "error", "http_status": status
                })
                self.assertNotIn("secret-token", output.getvalue())
                self.assertNotIn("private response body", output.getvalue())
                sleep.assert_not_called()
                result_path = Path(tmp) / "result.json"
                result_path.write_text(output.getvalue())
                classified = subprocess.run(
                    [str(ADAPTER), "classify", str(result_path)],
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(classified.returncode, 0)
                self.assertEqual(classified.stdout.strip(), "poll-error")
                terminal = subprocess.run(
                    [str(ADAPTER), "terminal", str(result_path)],
                    text=True, capture_output=True, check=False,
                )
                self.assertEqual(terminal.returncode, 0)


if __name__ == "__main__":
    unittest.main()
