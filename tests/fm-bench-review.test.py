import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bench_gate", ROOT / "bin/fm-bench-gate.py")
gate = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = gate
spec.loader.exec_module(gate)


class BenchmarkReviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fm-bench-review-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)
        return path

    def replay(self, mode="score", package=None):
        sample = self.root / "sample"
        sample.mkdir()
        tree = self.root / "tree"
        tree.mkdir()
        (tree / "work.json").write_text('{"value":4}\n')
        capture = {"deterministic": 4, "tree": "a" * 40,
                   "capture_hash": hashlib.sha256((tree / "work.json").read_bytes()).hexdigest()}
        (sample / "capture.json").write_text(json.dumps(capture) + "\n")
        (sample / "candidate.bundle").write_bytes(b"untouched original candidate")
        program = self.executable(sample / "score.py", f'''#!{sys.executable}
import hashlib, json, sys
from pathlib import Path
root = Path(__file__).parent
assert not (root / "candidate.bundle").exists()
if {mode!r} == "echo":
    print((root / "capture.json").read_text(), end="")
else:
    assert not (root / "capture.json").exists()
    data = (Path(sys.argv[1]) / "work.json").read_bytes()
    value = json.loads(data)["value"]
    score = 4 if {mode!r} == "metadata" else value
    print(json.dumps({{"deterministic": score, "tree": "a" * 40,
                      "capture_hash": hashlib.sha256(data).hexdigest()}}))
''')
        files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sample.iterdir()}
        record = {"files": files, "tree_binding": {"original_tree": "a" * 40},
                  "groups": {"capture_and_scoring": ["score.py", "capture.json"],
                             "bundle": ["candidate.bundle"]},
                  "evaluator_rerun": {"argv": [program.name], "result_hash": files["capture.json"],
                                      "package_files": package or [program.name],
                                      "scored_inputs": ["work.json"],
                                      "input_perturbations": {"work.json": {"kind": "json-value", "pointer": "/value"}}}}
        declaration, detail = gate.validate_archived_evaluator_declaration(sample, record, tree)
        if declaration is None:
            return False, detail, {}
        wrapper = self.executable(self.root / "execute.py", f'''#!{sys.executable}
import os, sys
os.chdir(sys.argv[1])
os.execv(sys.argv[2], sys.argv[2:])
''')
        return gate.rerun_archived_evaluator(sample, record, tree, [str(wrapper), "{root}"], declaration)

    def test_scored_measurement_changes_and_private_package(self):
        passed, detail, inputs = self.replay()
        self.assertTrue(passed, detail)
        self.assertEqual(inputs, {"work.json": "proven"})

    def test_metadata_change_does_not_prove_measurement(self):
        passed, detail, _ = self.replay("metadata")
        self.assertFalse(passed)
        self.assertIn("did not change the deterministic measurement", detail)

    def test_answer_echo_cannot_read_archived_result(self):
        passed, detail, _ = self.replay("echo")
        self.assertFalse(passed)
        self.assertIn("execution exited", detail)

    def test_package_cannot_declare_answer_or_original_bundle(self):
        passed, detail, _ = self.replay(package=["score.py", "capture.json", "candidate.bundle"])
        self.assertFalse(passed)
        self.assertIn("only addressed scoring code and measurement inputs", detail)

    def test_timeout_disposition_and_deadline(self):
        plan = {"timing": {"no_commit_timeout_s": 600, "no_commit_disposition": "void_and_rerun"}}
        failure = {"class": "no_commit_timeout", "status": "void", "blocker_class": False,
                   "no_commit_timeout": {"dispatch_accepted_at": 100, "observed_at": 700,
                                         "first_valid_final_commit_at": None}}
        gate.validate_attempt_failure(plan, failure, "void")
        self.assertTrue(gate.valid_attempt_intervals({"failure": failure, "intervals": {}}))
        self.assertFalse(gate.valid_attempt_intervals({"failure": failure, "intervals": {
            name: 600 for name in gate.REQUIRED_TIMING_INTERVALS}}))
        for field, value in (("observed_at", 699), ("observed_at", float("nan")),
                             ("observed_at", True), ("first_valid_final_commit_at", 500)):
            changed = json.loads(json.dumps(failure))
            changed["no_commit_timeout"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(gate.GateError):
                gate.validate_attempt_failure(plan, changed, "void")
        failure["status"] = "scored"
        with self.assertRaises(gate.GateError):
            gate.validate_attempt_failure(plan, failure, "scored", 10, [10])

    def test_task_status_report_and_inbox_transport(self):
        host, private, data = [self.root / name for name in ("host", "private", "data")]
        for path in (host, private, data):
            path.mkdir()
        task = "bench-worker"
        (host / "sibling.status").write_text("untouched\n")
        inbox = host / f"{task}.inbox"
        inbox.mkdir()
        (inbox / "0001.msg").write_text("task instruction\n")
        child = self.executable(self.root / "worker.py", f'''#!{sys.executable}
from pathlib import Path
import time
root = Path({str(private)!r})
message = root / "{task}.inbox/0001.msg"
deadline = time.monotonic() + 5
while not message.exists():
    assert time.monotonic() < deadline
    time.sleep(0.02)
assert message.read_text() == "task instruction\\n"
message.rename(message.parent / "handled" / message.name)
(root / "{task}.status").write_text("working: first\\npartial")
time.sleep(0.3)
with (root / "{task}.status").open("a") as stream:
    stream.write(" line\\n")
(root / "{task}.report.md").write_text("scout result\\n")
''')
        subprocess.run([sys.executable, str(ROOT / "bin/fm-bench-lifecycle.py"), str(private), str(host), task,
                        str(ROOT / "bin/fm-busy-event.sh"), "--report", str(data / "report.md"), "--", str(child)],
                       check=True, timeout=10)
        self.assertEqual((host / f"{task}.status").read_text(), "working: first\npartial line\n")
        self.assertEqual((data / "report.md").read_text(), "scout result\n")
        self.assertEqual((host / "sibling.status").read_text(), "untouched\n")
        self.assertFalse((inbox / "0001.msg").exists())
        self.assertEqual((inbox / "handled/0001.msg").read_text(), "task instruction\n")

    def test_launch_rewrites_brief_dependencies_and_cursor_binding(self):
        bench, worktree, code, state, data = [self.root / name for name in ("bench", "tree", "code", "state", "data")]
        for path in (bench, worktree, code, state, data):
            path.mkdir()
        task = "bench-worker"
        (code / "bin").mkdir()
        for name in ("fm-operational-input.sh", "fm-busy-event.sh", "fm-busy-lib.sh"):
            shutil.copyfile(ROOT / "bin" / name, code / "bin" / name)
        self.executable(code / "bin/helper.sh", "#!/bin/sh\nprintf 'helper output\\n'\n")
        brief = data / "brief.md"
        brief.write_text(f"{shlex.quote(str(code / 'bin/helper.sh'))} > {shlex.quote(str(state / (task + '.status')))}\n"
                         f"printf 'scout output\\n' > {shlex.quote(str(data / 'report.md'))}\n")
        private = {}
        for name in ("private_object_store", "private_tmp", "private_home", "private_session"):
            path = worktree / name
            path.mkdir()
            private[name] = str(path)
        wrapper = self.executable(self.root / "launch.sh", '#!/bin/sh\nexec "$@"\n')
        isolation = {"launch_wrapper": [str(wrapper)], "entrants": [{"id": task, "root": str(worktree),
                     "track": "A", "candidate": "test", "provider_network": "test", "provider_proxy": "test",
                     "provider_proxy_container": "test", **private}]}
        payload = json.dumps(isolation).encode()
        (bench / "isolation.json").write_bytes(payload)
        (bench / "preflight.receipt").write_text(json.dumps({"isolation_sha256": hashlib.sha256(payload).hexdigest()}))
        (bench / "benchmark.json").write_text(json.dumps({"tracks": {"A": {"entrants": [
            {"name": "test", "harness": "cursor", "model": "model", "effort": "high"}]}}}))
        (state / f"{task}.cursor-session").write_text("projects_root=/host/home/.cursor/projects\n")
        shell = '. "$1/bin/fm-bench-launch-lib.sh"\nfm_refuse_ungated_benchmark_entrant() { return 0; }\n' \
                'fm_bench_wrap_entrant_launch "$2" "$3" "$4" cursor model high 0 scout "$5" "$6" "$7" "$7/$2.turn-ended"'
        result = subprocess.run(["bash", "-c", shell, "_", str(ROOT), task, str(worktree),
                                 "sh " + shlex.quote(str(brief)), str(brief), str(code), str(state)],
                                env={**os.environ, "FM_BENCH_ROOT": str(bench)}, text=True, capture_output=True, check=True)
        shutil.rmtree(code)
        brief.unlink()
        subprocess.run(["bash", "-c", result.stdout], check=True, timeout=10)
        self.assertEqual((state / f"{task}.status").read_text(), "helper output\n")
        self.assertEqual((data / "report.md").read_text(), "scout output\n")
        binding = dict(line.split("=", 1) for line in (state / f"{task}.cursor-session").read_text().splitlines())
        self.assertEqual(binding["projects_root"], str(Path(private["private_home"]) / ".cursor/projects"))
        self.assertEqual(binding["workspace_root"], str(worktree))
        project = Path(binding["projects_root"]) / "workspace"
        transcript = project / "agent-transcripts/current/current.jsonl"
        transcript.parent.mkdir(parents=True)
        transcript.write_text('{"type":"turn_started"}\n')
        (project / ".workspace-trusted").write_text(json.dumps({"workspacePath": str(worktree)}))
        reader = subprocess.run(["bash", "-c", '. "$1/bin/fm-busy-lib.sh"; fm_busy_cursor_transcript "$2" "$3"',
                                 "_", str(ROOT), str(state), task], check=True, capture_output=True, text=True)
        self.assertEqual(reader.stdout, str(transcript))


if __name__ == "__main__":
    unittest.main()
