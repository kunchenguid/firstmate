#!/usr/bin/env python3
"""Standard-library unittest for bin/fm_task_timeline.py.

Fixture records are built here with coherent timestamps, written under a
temporary home, and read back through build_timeline/format_timeline exactly
as the console's `t` key does. The no-mistakes CLI is a fake shell script on a
temporary PATH; HOME is a temporary directory so ~/.claude and ~/.codex never
resolve to the developer's real session logs. Invoked by the colocated
tests/fm-task-timeline.test.sh.
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "bin" / "fm_task_timeline.py"
SPEC = importlib.util.spec_from_file_location("fm_task_timeline", MODULE_PATH)
tl = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(tl)

UTC = dt.timezone.utc
T0 = dt.datetime(2026, 9, 13, 10, 0, tzinfo=UTC)


def at(minutes: float) -> dt.datetime:
    return T0 + dt.timedelta(minutes=minutes)


def stamp(minutes: float) -> str:
    return at(minutes).strftime("%Y-%m-%dT%H:%M:%SZ")


def ulid_for(when: dt.datetime) -> str:
    """Inverse of fm_task_timeline.ulid_start: 10 Crockford time chars + 16 zeros."""
    ms = int(when.timestamp() * 1000)
    chars = []
    for _ in range(10):
        chars.append(tl.ULID_ALPHABET[ms % 32])
        ms //= 32
    return "".join(reversed(chars)) + "0" * 16


RUN_ID = ulid_for(at(60))  # validation starts one hour after dispatch


def write_fake_no_mistakes(directory: Path, body: str, exit_code: int = 0) -> None:
    script = directory / "no-mistakes"
    script.write_text(
        "#!/usr/bin/env bash\n"
        f"cat <<'EOF'\n{body}\nEOF\n"
        f"exit {exit_code}\n"
    )
    script.chmod(script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


RUN_STATUS = f"""current_branch: fm/task
other_branch_run:
  id: "{RUN_ID}"
  branch: fm/task
  status: completed
  head_sha: abc123
  steps[5]{{step,status,findings,duration_ms}}:
    intent,completed,0,5
    review,completed,0,3600000
    test,completed,0,600000
    lint,completed,0,400
    ci,skipped,0,0
outcome: passed"""


def claude_log_lines(first: dt.datetime, last: dt.datetime) -> str:
    def line(when: dt.datetime, context: int, output: int) -> str:
        return json.dumps({
            "timestamp": when.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "message": {
                "role": "assistant",
                "model": "claude-sonnet-4",
                "usage": {"input_tokens": context, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0, "output_tokens": output},
            },
        })
    return "\n".join([line(first, 1000, 40), line(first + dt.timedelta(minutes=30), 50000, 900), line(last, 120000, 60)]) + "\n"


class TimelineHome:
    """A throwaway FM_HOME + HOME + PATH for one test."""

    def __init__(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="fm-task-timeline-")
        self.root = Path(self.tmp.name)
        self.home = self.root / "fm-home"
        self.user = self.root / "user-home"
        self.fake = self.root / "fakebin"
        for path in (self.home / "state", self.home / "data", self.user, self.fake):
            path.mkdir(parents=True)
        self.saved = {k: os.environ.get(k) for k in ("HOME", "PATH", "FM_HOME", "FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE")}
        os.environ["HOME"] = str(self.user)
        os.environ["PATH"] = f"{self.fake}:{self.saved['PATH'] or ''}"
        os.environ.pop("FM_STATE_OVERRIDE", None)
        os.environ.pop("FM_DATA_OVERRIDE", None)
        os.environ["FM_HOME"] = str(self.home)

    def close(self) -> None:
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def session_log(self, worktree: str, first: dt.datetime, last: dt.datetime) -> str:
        directory = tl.snap.claude_dir_for_path(worktree)
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / "session.jsonl"
        path.write_text(claude_log_lines(first, last))
        return str(path)

    def write_record(self, record: dict) -> Path:
        path = tl.record_path(self.home / "data", record["task_id"])
        tl.write_record(path, record)
        return path


def finished_record(task_id: str, mode: str, runs: list[dict], session_path: str | None) -> dict:
    return {
        "schema": tl.SCHEMA,
        "task_id": task_id,
        "kind": "ship",
        "project": "/proj",
        "mode": mode,
        "yolo": "off",
        "dispatches": [{
            "at": stamp(0), "relaunch": False, "spawn_gen": "s1", "harness": "claude", "model": "default",
            "effort": "default", "backend": "tmux", "worktree": "/wt", "window": "firstmate:fm-x",
        }],
        "cleanup": {
            "at": stamp(180),
            "status_log": {
                "present": True, "path": "/state/x.status", "last_modified": stamp(150),
                "events": [{"seq": 1, "state": "working", "note": "setup done"}, {"seq": 2, "state": "done", "note": "PR https://example.test/pr/1"}],
            },
            "no_mistakes": {
                "queried": True,
                "reason": "no pipeline run: this task shipped direct-PR" if not runs else "no-mistakes axi status in the worktree, branch fm/task",
                "branch": "fm/task",
                "runs": runs,
            },
            "session_logs": [{"harness": "claude", "path": session_path, "first_at": stamp(2), "last_at": stamp(150)}] if session_path else [],
            "session_logs_reason": "Claude session logs modified since dispatch" if session_path else "no session log with assistant activity matched",
            "pr": "https://example.test/pr/1",
        },
    }


class NoMistakesTaskTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = TimelineHome()
        self.addCleanup(self.env.close)
        write_fake_no_mistakes(self.env.fake, RUN_STATUS)
        self.session = self.env.session_log("/wt", at(2), at(150))
        runs = [{"run_id": RUN_ID, "branch": "fm/task", "status": "completed", "outcome": "passed", "head_sha": "abc123"}]
        self.env.write_record(finished_record("nm-task", "no-mistakes", runs, self.session))
        self.result = tl.build_timeline(str(self.env.home), "nm-task")
        self.text = tl.format_timeline(self.result)

    def test_phases_sum_to_elapsed_within_tolerance(self):
        self.assertEqual(self.result["status"], "finished")
        self.assertEqual(self.result["elapsed_seconds"], 180 * 60)
        accounted = sum(p["seconds"] for p in self.result["phases"])
        self.assertAlmostEqual(accounted + self.result["unaccounted_seconds"], self.result["elapsed_seconds"])
        self.assertLessEqual(abs(self.result["unaccounted_seconds"]), self.result["tolerance_seconds"])
        names = [p["name"] for p in self.result["phases"]]
        self.assertEqual(names[0], "startup (dispatch to first agent turn)")
        self.assertEqual(names[1], "working before validation")
        self.assertTrue(names[2].startswith("validation run 1 (passed"), names)
        self.assertEqual(names[3], "working after validation")
        self.assertEqual(names[4], "waiting for merge and cleanup")
        seconds = [p["seconds"] for p in self.result["phases"]]
        # 2m startup, 58m working, run = 5ms+1h+10m+400ms, 20m after (to the last
        # session turn at +150m minus the run end at +130m), 30m waiting to +180m.
        self.assertEqual(seconds[0], 120)
        self.assertEqual(seconds[1], 58 * 60)
        self.assertAlmostEqual(seconds[2], 3600 + 600 + 0.405)
        self.assertAlmostEqual(seconds[3], 20 * 60 - 0.405)
        self.assertEqual(seconds[4], 30 * 60)

    def test_biggest_cost_is_named_with_its_largest_step(self):
        biggest = self.result["biggest"]
        self.assertTrue(biggest["name"].startswith("validation run 1"), biggest)
        self.assertIn("review step", biggest["detail"])
        self.assertIn("biggest cost: validation run 1", self.text)
        self.assertIn("largest part: review step, 1h 00m", self.text)

    def test_tokens_and_events_are_rendered(self):
        self.assertIn("claude session 1: 3 turns, 1,000 output tokens, peak context 120,000 (60% of 200,000)", self.text)
        self.assertIn("status events (order only, no per-line timestamps", self.text)
        self.assertIn("2. done: PR https://example.test/pr/1", self.text)
        self.assertIn("PR: https://example.test/pr/1", self.text)
        self.assertIn("relaunches: 0", self.text)

    def test_run_step_durations_unavailable_is_stated_not_zero(self):
        write_fake_no_mistakes(self.env.fake, 'error: run not found', exit_code=1)
        result = tl.build_timeline(str(self.env.home), "nm-task")
        text = tl.format_timeline(result)
        self.assertTrue(any("step durations unavailable" in m for m in result["missing"]), result["missing"])
        self.assertIn("not available:", text)
        self.assertNotIn("validation run 1", "\n".join(p["name"] for p in result["phases"]))
        # The run's hour is now unplaced, so the working span absorbs it and the
        # sum still reconciles to elapsed exactly.
        accounted = sum(p["seconds"] for p in result["phases"])
        self.assertAlmostEqual(accounted + result["unaccounted_seconds"], result["elapsed_seconds"])


class DirectPrTaskTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = TimelineHome()
        self.addCleanup(self.env.close)
        write_fake_no_mistakes(self.env.fake, "unexpected call", exit_code=3)
        self.session = self.env.session_log("/wt", at(2), at(150))
        self.env.write_record(finished_record("pr-task", "direct-PR", [], self.session))

    def test_says_no_pipeline_run_and_still_sums(self):
        result = tl.build_timeline(str(self.env.home), "pr-task")
        text = tl.format_timeline(result)
        self.assertEqual(result["status"], "finished")
        self.assertIn("no pipeline run: this task shipped direct-PR", text)
        self.assertEqual(result["runs"], [])
        names = [p["name"] for p in result["phases"]]
        self.assertIn("working (agent session span)", names)
        self.assertNotIn("validation", " ".join(names))
        self.assertLessEqual(abs(result["unaccounted_seconds"]), result["tolerance_seconds"])
        self.assertIn("biggest cost: working (agent session span), 2h 28m", text)


class MissingAndPartialRecordTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = TimelineHome()
        self.addCleanup(self.env.close)

    def test_missing_record_says_so(self):
        result = tl.build_timeline(str(self.env.home), "ghost")
        self.assertEqual(result["status"], "missing")
        text = tl.format_timeline(result)
        self.assertIn("no timeline record for ghost", text)
        self.assertIn("finished before timeline records shipped", text)

    def test_dispatch_only_record_is_partial(self):
        record = finished_record("half", "no-mistakes", [], None)
        record["cleanup"] = None
        self.env.write_record(record)
        result = tl.build_timeline(str(self.env.home), "half")
        self.assertEqual(result["status"], "partial")
        self.assertIn("cleanup checkpoint never ran", tl.format_timeline(result))

    def test_live_task_reads_live_sources(self):
        worktree = self.env.root / "wt"
        worktree.mkdir()
        meta = self.env.home / "state" / "live.meta"
        meta.write_text(f"worktree={worktree}\nharness=claude\nkind=ship\nmode=no-mistakes\nspawn_gen=s{int(T0.timestamp())}.1.1\n")
        status = self.env.home / "state" / "live.status"
        status.write_text("working: setup done\n")
        os.utime(status, (at(40).timestamp(), at(40).timestamp()))
        write_fake_no_mistakes(self.env.fake, "No run exists for this branch")
        self.env.session_log(str(worktree), at(2), at(40))
        result = tl.build_timeline(str(self.env.home), "live", now=at(45))
        self.assertEqual(result["status"], "live")
        self.assertTrue(any("dispatch time inferred" in m for m in result["missing"]), result["missing"])
        self.assertEqual(result["status_events"][0]["note"], "setup done")
        self.assertTrue(any("found no run" in m for m in result["missing"]), result["missing"])
        text = tl.format_timeline(result)
        self.assertIn("live, so far", text)
        self.assertIn("since last recorded activity", text)


class CheckpointTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = TimelineHome()
        self.addCleanup(self.env.close)
        self.paths = tl.home_paths(str(self.env.home))
        self.worktree = self.env.root / "wt"
        self.worktree.mkdir()
        (self.env.home / "state" / "cp.meta").write_text(
            f"window=firstmate:fm-cp\nworktree={self.worktree}\nproject=/proj\nharness=claude\nkind=ship\n"
            "mode=no-mistakes\nyolo=off\nmodel=default\neffort=high\nspawn_gen=s1.1.1\npr=https://example.test/pr/2\n"
        )

    def test_dispatch_then_relaunch_then_cleanup(self):
        tl.checkpoint_dispatch(self.paths, "cp", relaunch=False)
        tl.checkpoint_dispatch(self.paths, "cp", relaunch=True)
        record = tl.load_record(tl.record_path(self.paths["data"], "cp"))
        self.assertEqual(len(record["dispatches"]), 2)
        self.assertFalse(record["dispatches"][0]["relaunch"])
        self.assertTrue(record["dispatches"][1]["relaunch"])
        self.assertEqual(record["dispatches"][0]["effort"], "high")
        self.assertIsNone(record["cleanup"])
        (self.env.home / "state" / "cp.status").write_text("working: setup done\nblocked: need a key [key=k1]\nresolved: [key=k1] answered\n")
        write_fake_no_mistakes(self.env.fake, "No run exists for this branch")
        tl.checkpoint_cleanup(self.paths, "cp")
        record = tl.load_record(tl.record_path(self.paths["data"], "cp"))
        cleanup = record["cleanup"]
        self.assertEqual([e["state"] for e in cleanup["status_log"]["events"]], ["working", "blocked", "resolved"])
        self.assertTrue(cleanup["no_mistakes"]["queried"])
        self.assertEqual(cleanup["no_mistakes"]["runs"], [])
        self.assertEqual(cleanup["pr"], "https://example.test/pr/2")
        self.assertEqual(cleanup["session_logs"], [])
        result = tl.build_timeline(str(self.env.home), "cp")
        self.assertEqual(result["relaunches"], 1)
        self.assertEqual(result["status"], "finished")

    def test_checkpoint_without_meta_raises_for_the_wrapper_to_warn(self):
        with self.assertRaises(RuntimeError):
            tl.checkpoint_dispatch(self.paths, "absent", relaunch=False)


class HelperTests(unittest.TestCase):
    def test_ulid_start_roundtrip(self):
        when = dt.datetime(2026, 9, 13, 11, 0, 0, 500000, tzinfo=UTC)
        self.assertEqual(tl.ulid_start(ulid_for(when)), when)
        self.assertIsNone(tl.ulid_start("run-codex"))
        self.assertIsNone(tl.ulid_start(None))

    def test_format_duration(self):
        self.assertEqual(tl.format_duration(59), "59s")
        self.assertEqual(tl.format_duration(61), "1m 01s")
        self.assertEqual(tl.format_duration(3661), "1h 01m")
        self.assertEqual(tl.format_duration(-90), "-1m 30s")
        self.assertEqual(tl.format_duration(None), "unknown")

    def test_compute_phases_reconciles_when_run_overruns_the_window(self):
        runs = [{"run_id": RUN_ID, "start": stamp(60), "seconds": 4 * 3600, "steps": [{"step": "ci", "status": "running", "seconds": 4 * 3600}], "outcome": "running"}]
        computed = tl.compute_phases(at(0), at(120), [], runs, None, finished=False)
        accounted = sum(p["seconds"] for p in computed["phases"])
        self.assertAlmostEqual(accounted + computed["unaccounted_seconds"], computed["elapsed_seconds"])
        self.assertIn("past the window", computed["phases"][-1]["detail"])


if __name__ == "__main__":
    unittest.main()
