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
import time
import struct
import zlib
import unittest
from unittest import mock
import contextlib
import io

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

    def freeze_scoring(self, sample, record):
        root = sample.parent.parent
        mapping = {}
        for name in record["evaluator_rerun"]["package_files"]:
            if name in ("capture.json", "candidate.bundle"):
                continue
            source = "scoring/" + name
            target = root / source
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(sample / name, target)
            mapping[name] = source
        for name in gate.EVALUATOR_CONFIG_FILES:
            source = "evaluator/" + name
            target = root / source
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps({"bonus": 3 if name == "lock.json" else 0}) + "\n")
            archived = "frozen-" + name
            (sample / archived).write_bytes(target.read_bytes())
            mapping[archived] = source
            record["evaluator_rerun"]["package_files"].append(archived)
            record["groups"]["capture_and_scoring"].append(archived)
            record["files"][archived] = hashlib.sha256(target.read_bytes()).hexdigest()
        record["evaluator_rerun"]["frozen_package"] = mapping
        contract = root / "evaluator/execution.json"
        program = mapping[record["evaluator_rerun"]["argv"][0]]
        contract.write_text(json.dumps({"program": program, "archive_packages": {
            program: {"argv": record["evaluator_rerun"]["argv"], "frozen_package": mapping}}}))
        hashes = {source: hashlib.sha256((root / source).read_bytes()).hexdigest() for source in mapping.values()}
        hashes["evaluator/execution.json"] = hashlib.sha256(contract.read_bytes()).hexdigest()
        (root / "freeze.json").write_text(json.dumps({"schema": gate.FREEZE_SCHEMA, "hashes": hashes}))
        (root / "preflight.receipt").write_text(json.dumps({"schema": gate.RECEIPT_SCHEMA, "verdict": "pass",
                                                         "evaluator_sha256": gate.evaluator_identity(hashes)}))

    def replay(self, mode="score", package=None, tamper=None, verify=False):
        sample = self.root / "archive/sample"
        sample.mkdir(parents=True)
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
    score += json.loads((root / "frozen-score-map.json").read_text())["bonus"]
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
        if mode == "png":
            def chunk(kind, data):
                return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
            raw = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 0, 0, 0, 0))
                   + chunk(b"IDAT", zlib.compress(b"\x00\x04", level=9)) + chunk(b"IEND", b""))
            (tree / "image.png").write_bytes(raw)
            perturbation = {"kind": "png-pixel", "x": 0, "y": 0, "channel": 0}
            canonical = gate.prepare_png_differential(raw, perturbation)[0]
            self.assertNotEqual(raw, canonical)
            capture["capture_hash"] = hashlib.sha256(canonical).hexdigest()
            (sample / "capture.json").write_text(json.dumps(capture) + "\n")
            record["files"]["capture.json"] = hashlib.sha256((sample / "capture.json").read_bytes()).hexdigest()
            record["evaluator_rerun"]["result_hash"] = record["files"]["capture.json"]
            record["evaluator_rerun"]["scored_inputs"] = ["image.png"]
            record["evaluator_rerun"]["input_perturbations"] = {"image.png": perturbation}
            program.write_text(program.read_text().replace("import hashlib, json, sys", "import hashlib, json, sys, zlib")
                               .replace('"work.json"', '"image.png"')
                               .replace('value = json.loads(data)["value"]',
                                        'value = zlib.decompress(data[41:41 + int.from_bytes(data[33:37], "big")])[1]'))
            record["files"]["score.py"] = hashlib.sha256(program.read_bytes()).hexdigest()
        self.freeze_scoring(sample, record)
        if tamper == "layout":
            mapping = record["evaluator_rerun"]["frozen_package"]
            left, right = "frozen-lock.json", "frozen-score-map.json"
            mapping[left], mapping[right] = mapping[right], mapping[left]
            a, b = (sample / left).read_bytes(), (sample / right).read_bytes()
            (sample / left).write_bytes(b)
            (sample / right).write_bytes(a)
            for name in (left, right):
                record["files"][name] = hashlib.sha256((sample / name).read_bytes()).hexdigest()
        if tamper:
            target = program if tamper == "code" else sample / "frozen-score-map.json"
            if tamper != "layout":
                target.write_text(target.read_text().replace("else value", "else value + 3") if tamper == "code" else '{"bonus":3}\n')
            record["files"][target.name] = hashlib.sha256(target.read_bytes()).hexdigest()
            capture["deterministic"] += 3
            (sample / "capture.json").write_text(json.dumps(capture) + "\n")
            record["files"]["capture.json"] = hashlib.sha256((sample / "capture.json").read_bytes()).hexdigest()
            record["evaluator_rerun"]["result_hash"] = record["files"]["capture.json"]
        if verify:
            def git(*args):
                return subprocess.check_output(["git", "-C", str(tree), *args], stderr=subprocess.DEVNULL).decode().strip()
            git("init", "--quiet")
            git("add", ".")
            git("-c", "user.name=test", "-c", "user.email=test@example.org", "commit", "-qm", "candidate")
            head, tree_id = git("rev-parse", "HEAD"), git("rev-parse", "HEAD^{tree}")
            git("bundle", "create", str(sample / "candidate.bundle"), "HEAD")
            record["tree_binding"] = {"original_sha": head, "original_tree": tree_id}
            capture["tree"] = tree_id
            program.write_text(program.read_text().replace('"a" * 40', repr(tree_id)))
            record["files"]["score.py"] = hashlib.sha256(program.read_bytes()).hexdigest()
            record["groups"]["candidate_bundle_and_projection"] = ["candidate.bundle"]
            record["files"]["candidate.bundle"] = hashlib.sha256((sample / "candidate.bundle").read_bytes()).hexdigest()
            record["evaluator_rerun"]["package_files"] = ["score.py"]
            self.freeze_scoring(sample, record)
            wrapper = self.executable(self.root / "execute.py", f'#!{sys.executable}\nimport os, sys\nos.chdir(sys.argv[1])\nos.execv(sys.argv[2], sys.argv[2:])\n')
            with mock.patch.object(gate, "restore_confinement", return_value=([str(wrapper), "{root}"], "test")):
                for score in (4, 7):
                    capture["deterministic"] = score
                    (sample / "capture.json").write_text(json.dumps(capture) + "\n")
                    digest = hashlib.sha256((sample / "capture.json").read_bytes()).hexdigest()
                    record["files"]["capture.json"] = record["evaluator_rerun"]["result_hash"] = digest
                    if score == 4:
                        self.assertEqual(gate.load_archived_measurements(sample, record)["deterministic"], 4)
                        if mode == "png":
                            declaration, detail = gate.validate_archived_evaluator_declaration(sample, record, tree)
                            self.assertIsNotNone(declaration, detail)
                            passed, detail, inputs = gate.rerun_archived_evaluator(
                                sample, record, tree, [str(wrapper), "{root}"], declaration)
                            self.assertTrue(passed, detail)
                            self.assertEqual(inputs, {"image.png": "proven"})
                    else:
                        with self.assertRaisesRegex(gate.GateError, "differ from genuine evaluator output"):
                            gate.load_archived_measurements(sample, record)
            return
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

    def test_every_consumed_measurement_requires_genuine_output(self):
        self.replay(verify=True)

    def test_png_measurement_and_differential_use_identical_genuine_bytes(self):
        self.replay(mode="png", verify=True)

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
        self.assertIn("frozen source mapping", detail)

    def test_changed_scorer_cannot_gain_a_candidate_bonus(self):
        passed, detail, _ = self.replay(tamper="code")
        self.assertFalse(passed)
        self.assertIn("differs from its frozen identity", detail)

    def test_changed_configuration_is_not_accepted_as_frozen(self):
        passed, detail, _ = self.replay(tamper="config")
        self.assertFalse(passed)
        self.assertIn("differs from its frozen identity", detail)

    def test_frozen_configuration_cannot_be_remapped(self):
        passed, detail, _ = self.replay(tamper="layout")
        self.assertFalse(passed)
        self.assertIn("layout differs from its frozen mapping", detail)

    def test_scored_archive_requires_timing_before_cleanup(self):
        sample = self.root / "archive/sample"
        sample.mkdir(parents=True)
        groups = {name: sorted(gate.ARCHIVE_GROUP_REQUIREMENTS.get(name, set())) for name in gate.REQUIRED_ARCHIVE_GROUPS}
        groups["candidate_bundle_and_projection"] = ["candidate.bundle", "projection.diff"]
        groups["capture_and_scoring"].append("scoring.py")
        for names in groups.values():
            for name in names:
                (sample / name).write_text("{}\n")
        (sample / "judging.json").write_text('{"scores":[4]}')
        failure = {"status": "scored", "class": "none", "blocker_class": False}
        record = {"schema": gate.ARCHIVE_SCHEMA, "sample": "sample", "groups": groups,
                  "identity": {"track": "A", "role": "entrant", "candidate": "candidate", "packet": "A1"},
                  "attempt": {"id": "one", "status": "scored", "supersedes": None},
                  "tree_binding": {key: "a" * 40 for key in
                                   ("original_sha", "original_tree", "neutral_sha", "neutral_tree", "base_tree", "patch_hash")}}
        identity = ("A", "entrant", "candidate", "A1")
        with mock.patch.object(gate, "check_result_plan_binding"), \
             mock.patch.object(gate, "planned_sample_identities", return_value={identity}), \
             mock.patch.object(gate, "validate_archived_projection"), \
             mock.patch.object(gate, "load_archived_measurements", return_value={"deterministic": 4}):
            for intervals, expected in ((dict.fromkeys(gate.REQUIRED_TIMING_INTERVALS, 10), True), ({}, False)):
                (sample / "timing.json").write_text(json.dumps({"failure": failure, "intervals": intervals}))
                record["files"] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in sample.iterdir() if path.name != "manifest.json"}
                (sample / "manifest.json").write_text(json.dumps(record))
                report = gate.Report("archive-verify")
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    passed, _ = gate.check_archive(self.root, {}, report)
                self.assertEqual(passed, expected, output.getvalue())
                if not expected:
                    self.assertIn("scored attempt lacks valid timing intervals", output.getvalue())

    def test_container_images_require_explicit_digests(self):
        confine = str(ROOT / "bin/fm-bench-confine.sh")
        for value in (None, "runtime:latest", "runtime@sha256:test"):
            options = [] if value is None else ["--image", value]
            wrapper = [confine, "--mechanism", "container", *options, "--allow", "{root}", "--"]
            mechanism, detail = gate.validate_confinement_wrapper(wrapper, require_enforcing=True)
            self.assertIsNone(mechanism)
            self.assertIn("immutable", detail)
            result = subprocess.run([confine, "--mechanism", "container", *options, "--allow", str(self.root),
                                     "--", "/bin/true"], env={**os.environ, "FM_BENCH_CONFINE_IMAGE": "sha256:" + "a" * 64},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn("immutable", result.stderr)
        mechanism, detail = gate.validate_confinement_wrapper(
            [confine, "--mechanism", "container", "--image", "runtime@sha256:" + "a" * 64,
             "--allow", "{root}", "--"], require_enforcing=True)
        self.assertEqual(mechanism, "container", detail)

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

    def test_neutral_projection_reconstructs_archived_tree(self):
        repo, sample = self.root / "repo", self.root / "archive"
        repo.mkdir(); sample.mkdir()
        def git(*args):
            return subprocess.check_output(["git", "-C", str(repo), *args]).decode().strip()
        git("init", "-q")
        git("config", "user.name", "test")
        git("config", "user.email", "test@example.invalid")
        git("commit", "--allow-empty", "-qm", "base")
        base = git("rev-parse", "HEAD^{tree}")
        (repo / "answer").write_text("candidate\n")
        git("add", "answer"); git("commit", "-qm", "candidate")
        sha, tree = git("rev-parse", "HEAD"), git("rev-parse", "HEAD^{tree}")
        patch = (git("diff", "--binary", base, tree) + "\n").encode()
        (repo / "answer").write_text("different\n")
        git("commit", "-qam", "different")
        other = git("rev-parse", "HEAD")
        git("bundle", "create", str(sample / "candidate.bundle"), "HEAD")
        binding = {"original_sha": sha, "neutral_sha": sha, "original_tree": tree,
                   "neutral_tree": tree, "base_tree": base, "patch_hash": hashlib.sha256(patch).hexdigest()}
        record = {"tree_binding": binding, "groups": {"candidate_bundle_and_projection": ["candidate.bundle", "projection.diff"]}}
        def publish(content, binding_document=None):
            (sample / "projection.diff").write_bytes(content)
            (sample / "tree-binding.json").write_text(json.dumps(binding if binding_document is None else binding_document))
            record["files"] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sample.iterdir()}
        publish(patch)
        gate.validate_archived_projection(sample, record)
        publish(b"unrelated prose\n")
        with self.assertRaisesRegex(gate.GateError, "patch hash"):
            gate.validate_archived_projection(sample, record)
        binding["patch_hash"] = hashlib.sha256(b"unrelated prose\n").hexdigest()
        publish(b"unrelated prose\n")
        with self.assertRaises(gate.GateError):
            gate.validate_archived_projection(sample, record)
        binding["patch_hash"] = hashlib.sha256(patch).hexdigest()
        binding["neutral_sha"] = other
        publish(patch)
        with self.assertRaisesRegex(gate.GateError, "commit identities"):
            gate.validate_archived_projection(sample, record)
        binding["neutral_sha"] = sha
        publish(patch, {**binding, "base_tree": tree})
        with self.assertRaisesRegex(gate.GateError, "tree-binding.json differs"):
            gate.validate_archived_projection(sample, record)

    def test_container_liveness_is_bound_to_task_generation(self):
        host, private, runtime = [self.root / name for name in ("host", "private", "runtime")]
        for path in (host, private, runtime):
            path.mkdir()
        task = "bench-worker"
        meta = host / f"{task}.meta"
        meta.write_text("spawn_gen=one\n")
        info, stop = self.root / "docker.json", self.root / "stop"
        self.executable(runtime / "docker", f'''#!{sys.executable}
import json, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
info = Path({str(info)!r})
if args[0] == "info":
    raise SystemExit(0)
if args[:2] == ["network", "inspect"]:
    print("true proxy ")
elif args[0] == "inspect":
    print(info.read_text())
elif args[0] == "run":
    cid = "f" * 64
    Path(args[args.index("--cidfile") + 1]).write_text(cid)
    labels = dict(args[index + 1].split("=", 1) for index, arg in enumerate(args) if arg == "--label")
    info.write_text(json.dumps([{{"Id": cid, "State": {{"Running": True}}, "Config": {{"Labels": labels}}}}]))
    raise SystemExit(subprocess.call(args[args.index("runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") + 1:]))
''')
        child = self.executable(private / "worker.py", f'''#!{sys.executable}
from pathlib import Path
import time
while not Path({str(stop)!r}).exists():
    time.sleep(0.02)
''')
        env = {**os.environ, "PATH": str(runtime) + os.pathsep + os.environ["PATH"]}
        command = [sys.executable, str(ROOT / "bin/fm-bench-lifecycle.py"), str(private), str(host), task,
                   str(ROOT / "bin/fm-busy-event.sh"), "--container", "--", str(ROOT / "bin/fm-bench-confine.sh"),
                   "--purpose", "entrant", "--mechanism", "container", "--image", "runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                   "--provider-network", "test", "--provider-proxy", "http://proxy:8080",
                   "--provider-proxy-container", "proxy", "--allow", str(private), "--", str(child)]
        process = subprocess.Popen(command, env=env)
        try:
            deadline = time.monotonic() + 5
            while not info.exists():
                self.assertIsNone(process.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
            script = '''FM_BACKEND_LIB_DIR=$1/bin
STATE=$2
. "$FM_BACKEND_LIB_DIR/backends/tmux.sh"
tmux() { printf 'worker\n'; }
fm_backend_tmux_foreground_comms() { printf python3; }
fm_backend_tmux_foreground_argv0s() { printf python3; }
fm_backend_tmux_foreground_pids() { printf '%s\n' "$TEST_RELAY_PID"; }
fm_backend_tmux_foreground_args() { printf python3; }
fm_backend_tmux_current_command() { printf python3; }
fm_gemini_pid_is_gemini() { return 1; }
fm_gemini_args_are_gemini() { return 1; }
fm_backend_tmux_agent_state session:worker
'''
            def classify():
                return subprocess.check_output(["bash", "-c", script, "_", str(ROOT), str(host)],
                                               env={**env, "TEST_RELAY_PID": str(process.pid)}, text=True)
            self.assertEqual(classify(), "alive")
            meta.write_text("spawn_gen=two\n")
            self.assertEqual(classify(), "ambiguous")
            meta.write_text("spawn_gen=one\n")
            container = json.loads(info.read_text())
            container[0]["State"]["Running"] = False
            info.write_text(json.dumps(container))
            self.assertEqual(classify(), "ambiguous")
            container[0]["State"]["Running"] = True
            container[0]["Config"]["Labels"]["fm.bench.launch"] = "another-launch"
            info.write_text(json.dumps(container))
            self.assertEqual(classify(), "ambiguous")
        finally:
            stop.touch()
            process.wait(timeout=5)
        self.assertEqual(process.returncode, 0)
        self.assertFalse((host / f".bench-container-{process.pid}.json").exists())

    def test_review_entrypoint_is_in_benchmark_family(self):
        listed = subprocess.check_output([str(ROOT / "bin/fm-test-run.sh"), "--list", "--family", "benchmark-gate"],
                                         cwd=ROOT, text=True).splitlines()
        self.assertIn("tests/fm-bench-review.test.sh", listed)

    def test_void_timing_tracks_available_endpoints(self):
        for failure_class in ("provider_outage", "quota_exhaustion", "evaluator_infrastructure"):
            failure = {"class": failure_class, "status": "void", "blocker_class": False}
            plan = {"failure_policy": gate.REQUIRED_FAILURE_POLICY}
            gate.validate_attempt_failure(plan, failure, "void")
            for assistant, commit in ((None, None), (110, None), (110, 120)):
                observations = {"dispatch_accepted_at": 100, "first_assistant_event_at": assistant,
                                "first_valid_final_commit_at": commit, "observed_at": 130}
                intervals = {} if commit is None else dict(zip(gate.REQUIRED_TIMING_INTERVALS, (20, 10)))
                timing = {"failure": failure, "observations": observations, "intervals": intervals}
                with self.subTest(failure_class=failure_class, assistant=assistant, commit=commit):
                    self.assertTrue(gate.valid_attempt_intervals(timing))
                    for field, value in (("observed_at", 90), ("observed_at", float("inf")),
                                         ("first_assistant_event_at", 140), ("first_valid_final_commit_at", 99)):
                        invalid = {**timing, "observations": {**observations, field: value}}
                        self.assertFalse(gate.valid_attempt_intervals(invalid))
                    invalid = {**timing, "intervals": {gate.REQUIRED_TIMING_INTERVALS[0]: 999}}
                    self.assertFalse(gate.valid_attempt_intervals(invalid))
            self.assertFalse(gate.valid_attempt_intervals({"failure": failure, "intervals": {}}))
        self.assertFalse(gate.valid_attempt_intervals({"failure": {"class": "none", "status": "scored"},
                                                       "observations": observations, "intervals": intervals}))

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
(root / "{task}.status").write_bytes("working: first\\npartial é".encode()[:-1])
(root / "{task}.report.md").write_bytes("scout résult".encode()[:8])
time.sleep(0.3)
with (root / "{task}.status").open("ab") as stream:
    stream.write("é".encode()[1:] + b" line\\n")
(root / "{task}.report.md").write_text("scout result\\n")
''')
        subprocess.run([sys.executable, str(ROOT / "bin/fm-bench-lifecycle.py"), str(private), str(host), task,
                        str(ROOT / "bin/fm-busy-event.sh"), "--report", str(data / "report.md"), "--", str(child)],
                       check=True, timeout=10)
        self.assertEqual((host / f"{task}.status").read_text(), "working: first\npartial é line\n")
        self.assertEqual((data / "report.md").read_text(), "scout result\n")
        self.assertEqual((host / "sibling.status").read_text(), "untouched\n")
        self.assertFalse((inbox / "0001.msg").exists())
        self.assertEqual((inbox / "handled/0001.msg").read_text(), "task instruction\n")

    def test_launch_rewrites_brief_dependencies_and_cursor_binding(self):
        bench, code, state, data = [self.root / name for name in ("bench", "code", "state", "data")]
        worktree = code / "projects/entrant"
        for path in (bench, worktree, code, state, data):
            path.mkdir(parents=True, exist_ok=True)
        task = "bench-worker"
        (worktree / "keep").write_text("candidate file")
        runtime = self.executable(worktree / "runtime", '#!/bin/sh\n[ "$1" = --workspace ] || exit 2\ncd "$2" || exit 3\nexec sh "$3"\n')
        (code / "bin").mkdir()
        for name in ("fm-operational-input.sh", "fm-busy-event.sh", "fm-busy-lib.sh"):
            shutil.copyfile(ROOT / "bin" / name, code / "bin" / name)
        self.executable(code / "bin/helper.sh", "#!/bin/sh\nprintf 'helper output\\n'\n")
        brief = data / "brief.md"
        brief.write_text(f"test -f {shlex.quote(str(worktree / 'keep'))} || exit 4\n"
                         f"{shlex.quote(str(code / 'bin/helper.sh'))} > {shlex.quote(str(state / (task + '.status')))}\n"
                         f"printf 'scout output\\n' > {shlex.quote(str(data / 'report.md'))}\n")
        worker = self.executable(worktree / "receive.py", f'''#!{sys.executable}
import shlex, sys, time
from pathlib import Path
line = shlex.split(sys.stdin.readline())
inbox = Path(line[line.index("list") + 1].removesuffix("/*.msg"))
assert inbox.is_relative_to(Path({str(worktree)!r}) / "private_session")
message = inbox / "0001.msg"
deadline = time.monotonic() + 5
while not message.exists():
    assert time.monotonic() < deadline
    time.sleep(0.02)
assert message.read_text() == "ordinary steering\\n"
message.rename(inbox / "handled/0001.msg")
''')
        with brief.open("a") as stream:
            stream.write(shlex.quote(str(worker)) + "\n")
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
                'fm_bench_wrap_entrant_launch "$2" "$3" "$4" cursor model high 0 scout "$5" "$6" "$7" "$7/$2.turn-ended" "$8"'
        result = subprocess.run(["bash", "-c", shell, "_", str(ROOT), task, str(worktree),
                                 "\'" + str(runtime) + "\' --workspace " + shlex.quote(str(worktree)) + " " + shlex.quote(str(brief)),
                                 str(brief), str(code), str(state), str(runtime)],
                                env={**os.environ, "FM_BENCH_ROOT": str(bench)}, text=True, capture_output=True, check=True)
        shutil.rmtree(code / "bin")
        brief.unlink()
        inbox = state / f"{task}.inbox"
        message = inbox / "0001.msg"
        message.write_text("ordinary steering\n")
        bell = subprocess.run(["bash", "-c", '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_doorbell_line "$2"',
                               "_", str(ROOT), str(message)], check=True, capture_output=True, text=True).stdout
        meta = state / f"{task}.meta"
        meta.write_text("spawn_gen=replacement\n")
        stale = subprocess.run(["bash", "-c", '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_doorbell_line "$2"',
                                "_", str(ROOT), str(message)], capture_output=True, text=True)
        self.assertNotEqual(stale.returncode, 0)
        self.assertEqual(stale.stdout, "")
        meta.unlink()
        subprocess.run(["bash", "-c", result.stdout], input=bell + "\n", text=True, check=True, timeout=10)
        self.assertEqual((inbox / "handled/0001.msg").read_text(), "ordinary steering\n")
        self.assertFalse((inbox / ".worker-path").exists())
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
