#!/usr/bin/env python3
"""Exercise the Vibe state reader through its executable interface."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

READER = Path(__file__).resolve().parents[1] / "bin/fm-vibe-state.py"


class VibeStateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / "work"
        self.session = self.root / "sessions" / "session"
        self.session.mkdir(parents=True)
        self.write(self.session / "meta.json", {"origin_directory": str(self.work)})
        self.write(self.session / "CURRENT", {"generation": "0001"})
        self.projection = self.session / "generations/0001/projection-state.json"
        self.checkpoint("completed")

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def checkpoint(self, status):
        self.write(self.projection, {"snapshot_sequence": 1, "snapshot": {"latestTurn": {"status": status}}})

    def verdict(self):
        return subprocess.check_output(["python3", str(READER), str(self.session.parent), str(self.work)], text=True).strip()

    def test_checkpoint_states(self):
        for status, expected in (("completed", "idle"), ("in_progress", "busy"), ("interrupted", "idle"), ("failed", "idle"), ("new_vendor_status", "unknown")):
            with self.subTest(status=status):
                self.checkpoint(status)
                self.assertEqual(self.verdict(), expected)

    def test_journal_overrides_stale_checkpoint(self):
        journal = self.session / "journal/0002.jsonl"
        self.write(journal, {"sequence": 2, "payload": {"delta": [{"op": "set_envelope", "state": {"latestTurn": {"status": "in_progress"}}}]}})
        self.assertEqual(self.verdict(), "busy")
        with journal.open("a") as stream:
            stream.write('\n' + json.dumps({"sequence": 3, "payload": {"delta": [{"op": "set_envelope", "state": {"latestTurn": {"status": "interrupted"}}}]}}))
        self.assertEqual(self.verdict(), "idle")

    def test_ambiguous_missing_and_corrupt_are_unknown(self):
        other = self.session.parent / "other/meta.json"
        self.write(other, {"origin_directory": str(self.work)})
        self.assertEqual(self.verdict(), "unknown")
        other.unlink()
        self.projection.write_text("{")
        self.assertEqual(self.verdict(), "unknown")
        self.projection.unlink()
        self.assertEqual(self.verdict(), "unknown")

    def test_incomplete_journal_does_not_claim_idle(self):
        journal = self.session / "journal/0002.jsonl"
        journal.parent.mkdir()
        journal.write_text('{"sequence":2')
        self.assertEqual(self.verdict(), "unknown")

    def test_replacement_directory_ignores_previous_session(self):
        previous = self.root / "previous/session/meta.json"
        self.write(previous, {"origin_directory": str(self.work)})
        self.assertEqual(self.verdict(), "idle")


if __name__ == "__main__":
    unittest.main()
