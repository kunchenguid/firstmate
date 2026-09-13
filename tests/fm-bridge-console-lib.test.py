#!/usr/bin/env python3
"""Standard-library unittest for bin/fm_bridge_lib.py.

No Textual import anywhere in this file or in fm_bridge_lib itself, so this
runs in any CI environment with only python3. Invoked by the colocated
tests/fm-bridge-console.test.sh, which is what tests/*.test.sh discovery
picks up.
"""

import datetime
import importlib.util
import json
import unittest
from pathlib import Path

LIB_PATH = Path(__file__).parents[1] / "bin" / "fm_bridge_lib.py"
SPEC = importlib.util.spec_from_file_location("fm_bridge_lib", LIB_PATH)
lib = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lib)

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "fm-bridge-console" / "fm-bridge-snapshot.sample.json"


class ContextBandTests(unittest.TestCase):
    def test_unknown_is_none_only(self):
        self.assertEqual(lib.context_band(None), "unknown")

    def test_zero_percent_is_normal_not_unknown(self):
        self.assertEqual(lib.context_band(0), "normal")

    def test_under_fifty_is_normal(self):
        self.assertEqual(lib.context_band(49.9), "normal")

    def test_fifty_is_amber_boundary(self):
        self.assertEqual(lib.context_band(50.0), "amber")

    def test_under_seventy_is_amber(self):
        self.assertEqual(lib.context_band(69.9), "amber")

    def test_seventy_is_red_boundary(self):
        self.assertEqual(lib.context_band(70.0), "red")

    def test_over_seventy_is_red(self):
        self.assertEqual(lib.context_band(95), "red")


class FormatContextTests(unittest.TestCase):
    def test_missing_context_is_not_measured_never_zero(self):
        text, band = lib.format_context(None)
        self.assertEqual(text, "not measured")
        self.assertEqual(band, "unknown")

    def test_missing_current_tokens_is_not_measured(self):
        text, band = lib.format_context({"current_tokens": None})
        self.assertEqual(text, "not measured")
        self.assertEqual(band, "unknown")

    def test_known_window_and_percent(self):
        text, band = lib.format_context(
            {"current_tokens": 49678, "window_tokens": 258400, "percent": 19.2}
        )
        self.assertEqual(text, "49,678 / 258,400 (19%)")
        self.assertEqual(band, "normal")

    def test_unknown_window_still_shows_tokens(self):
        text, band = lib.format_context(
            {"current_tokens": 12345, "window_tokens": None, "percent": None}
        )
        self.assertEqual(text, "12,345 / ? tokens")
        self.assertEqual(band, "unknown")

    def test_red_band_at_or_above_seventy(self):
        _text, band = lib.format_context(
            {"current_tokens": 189000, "window_tokens": 258400, "percent": 73.1}
        )
        self.assertEqual(band, "red")


class FormatElapsedTests(unittest.TestCase):
    def test_none_is_question_mark(self):
        self.assertEqual(lib.format_elapsed(None), "?")

    def test_seconds_only(self):
        self.assertEqual(lib.format_elapsed(45), "45s")

    def test_minutes_and_seconds(self):
        self.assertEqual(lib.format_elapsed(125), "2m 5s")

    def test_hours_and_minutes(self):
        self.assertEqual(lib.format_elapsed(3720), "1h 2m")

    def test_negative_is_question_mark(self):
        self.assertEqual(lib.format_elapsed(-5), "?")


class FormatAgeTests(unittest.TestCase):
    def test_missing_is_unknown(self):
        self.assertEqual(lib.format_age(None), "unknown")

    def test_garbage_is_unknown(self):
        self.assertEqual(lib.format_age("not-a-date"), "unknown")

    def test_seconds_ago(self):
        now = datetime.datetime(2026, 9, 13, 22, 0, 30, tzinfo=datetime.timezone.utc)
        self.assertEqual(lib.format_age("2026-09-13T22:00:00Z", now=now), "30s ago")

    def test_minutes_ago(self):
        now = datetime.datetime(2026, 9, 13, 22, 5, 0, tzinfo=datetime.timezone.utc)
        self.assertEqual(lib.format_age("2026-09-13T22:00:00Z", now=now), "5m ago")


class ParseSnapshotTests(unittest.TestCase):
    def test_rejects_invalid_json(self):
        with self.assertRaises(lib.SnapshotError):
            lib.parse_snapshot("{not json")

    def test_rejects_wrong_schema(self):
        with self.assertRaises(lib.SnapshotError):
            lib.parse_snapshot(json.dumps({"schema": "something-else.v1"}))

    def test_rejects_non_object(self):
        with self.assertRaises(lib.SnapshotError):
            lib.parse_snapshot(json.dumps([1, 2, 3]))

    def test_accepts_fixture(self):
        data = lib.parse_snapshot(FIXTURE_PATH.read_text())
        self.assertEqual(data["schema"], "fm-bridge-snapshot.v1")
        self.assertEqual(len(data["agents"]), 4)


class KeyMappingTests(unittest.TestCase):
    def test_direct_keys(self):
        for key, action in (
            ("r", "refresh"),
            ("q", "refresh_quota"),
            ("u", "check_upstream"),
            ("p", "peek"),
            ("o", "open_links"),
        ):
            self.assertEqual(lib.classify_key(key), ("direct", action))

    def test_queued_keys(self):
        for key, action in (
            ("s", "ask_firstmate"),
            ("/", "route"),
            ("f", "propose_restart"),
            ("U", "take_upstream"),
        ):
            self.assertEqual(lib.classify_key(key), ("queued", action))

    def test_unmapped_key(self):
        self.assertEqual(lib.classify_key("t"), (None, None))
        self.assertEqual(lib.classify_key("z"), (None, None))

    def test_no_overlap_between_direct_and_queued(self):
        self.assertEqual(set(lib.DIRECT_KEYS) & set(lib.QUEUED_KEYS), set())


class QueueNoteTextTests(unittest.TestCase):
    def test_ask_firstmate(self):
        text = lib.queue_note_text("ask_firstmate", text="what's blocking cim-signal?")
        self.assertIn("ask firstmate", text)
        self.assertIn("what's blocking cim-signal?", text)

    def test_route_names_target_and_body(self):
        text = lib.queue_note_text("route", target="fleet-secondmate", text="pick this up")
        self.assertIn("fleet-secondmate", text)
        self.assertIn("pick this up", text)

    def test_route_defaults_to_main(self):
        text = lib.queue_note_text("route", target=None, text="pick this up")
        self.assertIn("main", text)

    def test_propose_restart_names_target(self):
        text = lib.queue_note_text("propose_restart", target="cim-signal")
        self.assertIn("cim-signal", text)
        self.assertIn("restart", text)

    def test_take_upstream_fixed_text(self):
        text = lib.queue_note_text("take_upstream")
        self.assertIn("upstream", text)
        self.assertIn("PR", text)

    def test_unknown_action_raises(self):
        with self.assertRaises(ValueError):
            lib.queue_note_text("not-a-real-action")


class QuotaAdapterTests(unittest.TestCase):
    def test_maps_provider_and_scope_rows(self):
        raw = {
            "generatedAt": "2026-09-13T22:00:49Z",
            "providers": [
                {
                    "provider": "claude",
                    "state": {"status": "fresh", "stale": False},
                    "windows": [
                        {"id": "seven_day", "resetsAt": "2026-09-14T00:00:00Z"},
                    ],
                    "quotaSemantics": {
                        "status": "known",
                        "effectiveAvailability": [
                            {
                                "scope": "all_models",
                                "effectivePercentRemaining": 5,
                                "limitingWindowIds": ["seven_day"],
                                "runway": {"status": "through_reset"},
                                "selection": {"spendPriority": 3.19},
                            }
                        ],
                    },
                }
            ],
        }
        out = lib.quota_from_quota_axi_json(raw)
        self.assertEqual(out["observed_at"], "2026-09-13T22:00:49Z")
        self.assertEqual(len(out["providers"]), 1)
        row = out["providers"][0]
        self.assertEqual(row["provider"], "claude")
        self.assertEqual(row["percent_remaining"], 5)
        self.assertEqual(row["resets_at"], "2026-09-14T00:00:00Z")
        self.assertEqual(out["attention"], [])

    def test_stale_state_becomes_attention(self):
        raw = {
            "providers": [
                {
                    "provider": "kimi",
                    "state": {"status": "auth_error", "stale": True},
                    "windows": [],
                    "quotaSemantics": {"status": "known", "effectiveAvailability": []},
                }
            ]
        }
        out = lib.quota_from_quota_axi_json(raw)
        self.assertEqual(len(out["attention"]), 1)
        self.assertEqual(out["attention"][0]["provider"], "kimi")


class ParseLavishSessionsTests(unittest.TestCase):
    SAMPLE = (
        'bin: /opt/homebrew/bin/lavish-axi\n'
        'description: "..."\n'
        'sessions[2]{file,status,url,pending_prompts}:\n'
        '  /Users/x/.lavish/a.html,open,"http://127.0.0.1:4387/session/aaa",0\n'
        '  /Users/x/.lavish/b.html,feedback,"http://127.0.0.1:4387/session/bbb",1\n'
        'playbooks[1]{id,use_when}:\n'
        '  diagram,"Explain things"\n'
    )

    def test_extracts_rows_within_section_only(self):
        rows = lib.parse_lavish_sessions(self.SAMPLE)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["file"], "/Users/x/.lavish/a.html")
        self.assertEqual(rows[0]["status"], "open")
        self.assertEqual(rows[0]["url"], "http://127.0.0.1:4387/session/aaa")
        self.assertEqual(rows[1]["pending_prompts"], "1")

    def test_no_sessions_section_is_empty(self):
        self.assertEqual(lib.parse_lavish_sessions("bin: /x\ndescription: y\n"), [])

    def test_garbage_input_is_empty_not_raising(self):
        self.assertEqual(lib.parse_lavish_sessions(""), [])


class RunCommandTests(unittest.TestCase):
    def test_missing_executable_reports_rc127(self):
        rc, _out, err = lib.run_command(["fm-bridge-definitely-not-a-real-binary"])
        self.assertEqual(rc, 127)
        self.assertIn("not found", err)

    def test_real_command_succeeds(self):
        import sys

        rc, out, _err = lib.run_command([sys.executable, "-c", "print('hi')"])
        self.assertEqual(rc, 0)
        self.assertEqual(out.strip(), "hi")


if __name__ == "__main__":
    unittest.main()
