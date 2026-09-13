import json
import os
import tempfile
import unittest
from pathlib import Path

import importlib.util


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("fm_bridge_snapshot", ROOT / "bin" / "fm_bridge_snapshot.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class BridgeSnapshotParserTest(unittest.TestCase):
    def test_codex_context_returns_null_reason_without_token_event(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            session_dir = home / ".codex" / "sessions" / "2026" / "09" / "13"
            session_dir.mkdir(parents=True)
            worktree = home / "worktree"
            worktree.mkdir()
            (session_dir / "s.jsonl").write_text(
                json.dumps({"type": "session_meta", "payload": {"cwd": str(worktree)}}) + "\n"
            )
            old_home = os.environ.get("HOME")
            os.environ["HOME"] = str(home)
            try:
                context, tokens, reason = MODULE.codex_context([str(worktree)])
            finally:
                if old_home is None:
                    os.environ.pop("HOME", None)
                else:
                    os.environ["HOME"] = old_home
            self.assertIsNone(context)
            self.assertIsNone(tokens)
            self.assertIn("no token_count", reason)

    def test_no_mistakes_step_table_parser(self):
        parsed = MODULE.parse_no_mistakes_status(
            """current_run:
  id: "run-1"
  branch: fm/x
  status: running
  steps[2]{step,status,findings,duration_ms}:
    review,completed,0,100
    test,running,2,200
"""
        )
        self.assertEqual(parsed["run_id"], "run-1")
        self.assertEqual(parsed["current_step"], "test")
        self.assertEqual(parsed["steps"][1]["findings"], 2)

    def test_no_mistakes_empty_current_branch_is_unmeasured(self):
        self.assertIsNone(MODULE.parse_no_mistakes_status("current_branch: fm/x\nruns_on_current_branch: 0\n"))

    def test_claude_path_mangles_dots_and_slashes(self):
        self.assertEqual(
            MODULE.claude_dir_for_path("/tmp/.treehouse/work"),
            Path.home() / ".claude" / "projects" / "-tmp--treehouse-work",
        )

    def test_macos_process_elapsed_time(self):
        self.assertEqual(MODULE.elapsed_process_time("15-04:05:06"), 15 * 86400 + 4 * 3600 + 5 * 60 + 6)

    def test_started_at_uses_spawn_generation_not_date_only_backlog(self):
        self.assertEqual(
            MODULE.started_at_from_meta({"spawn_gen": "s1700000000.123.1"}, None),
            "2023-11-14T22:13:20Z",
        )


if __name__ == "__main__":
    unittest.main()
