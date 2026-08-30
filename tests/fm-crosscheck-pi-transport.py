"""Loopback-only transport regression, invoked by fm-crosscheck-azure.test.sh.

FM_TEST_PINNED_PI_CLI optionally points to the unpacked image-pinned Pi CLI.
No package installation, credential discovery or remote provider calls occur.
"""

import importlib.util
import ast
import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch


ROOT = Path(sys.argv[1])


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


runtime = load("crosscheck_transport_runtime", ROOT / "bin/fm-crosscheck-pi-reviewer.py")
core = load("crosscheck_transport_core", ROOT / "bin/fm-crosscheck.py")
observer = runtime.EvaluationDiagnostics("challenge", 1, {"safe.py"})
observer.observe({"type": "crosscheck_provider_request", "payload": "SECRET"}, 0)
observer.observe({"type": "crosscheck_provider_response", "status": 200, "headers": {"secret": "SECRET"}}, 100)
observer.observe({"type": "message_start", "message": {"role": "assistant"}}, 20)
observer.observe({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "delta": "SECRET"}}, 125)
observer.observe({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "delta": "SECRET"}}, 150)
observer.observe({"type": "message_end", "message": {"role": "assistant", "stopReason": "toolUse", "content": "SECRET"}}, 200)
observer.observe({"type": "tool_execution_start", "toolName": "report_finding", "toolCallId": "SECRET", "args": {
    "title": "SECRET", "explanation": "SECRET", "severity": "high", "merge_disposition": "must-fix",
    "citations": [{"path": "safe.py", "start_line": 1, "end_line": 2}, {"path": "/SECRET"}],
}}, 210)
observer.observe({"type": "tool_execution_end", "toolCallId": "SECRET", "result": {
    "details": {"accepted": True}, "content": [{"type": "text", "text": "SECRET"}],
}}, 220)
for i in range(200):
    observer.observe({"type": "auto_retry_start", "delayMs": 10, "errorMessage": "SECRET"}, 300 + i)
diagnostics = observer.value
assert "SECRET" not in json.dumps(diagnostics)
assert len(runtime.canonical_bytes(diagnostics)) <= observer.MAX_BYTES
assert diagnostics["truncated"] and diagnostics["omitted_events"] > 0
assert any(row.get("tool") == "report_finding" for row in diagnostics["events"])
assert diagnostics["response_wait_ms"] == 100 and diagnostics["stream_ms"] == 75
assert diagnostics["assistant_first_delta_ms"] == 105 and diagnostics["max_delta_gap_ms"] == 25
assert diagnostics["assistant_elapsed_ms"] == 180
assert diagnostics["tool_ms"] == 10 and diagnostics["retries"] == 200
print("Sanitized bounded diagnostics passed")

# A sidecar can run ahead of buffered stdout. Its future request must not
# reattribute a previous assistant's stream or fabricate missing correlations.
backlog = runtime.EvaluationDiagnostics("challenge", 1, set())
for at, kind in ((0, "request"), (100, "response"), (200, "request"), (300, "response")):
    backlog.observe({"type": "crosscheck_provider_" + kind, "status": 200}, at)
for at in (400, 500):
    backlog.observe({"type": "message_end", "message": {"role": "assistant", "stopReason": "toolUse"}}, at)
assert backlog.value["response_wait_ms"] == 200
assert backlog.value["stream_ms"] == backlog.value["assistant_elapsed_ms"] == 0
assert all("request_elapsed_ms" not in event for event in backlog.value["events"])
backlog.observe({"type": "message_start", "message": {"role": "assistant"}}, 600)
backlog.observe({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta"}}, 650)
backlog.observe({"type": "crosscheck_provider_request"}, 1000)
backlog.observe({"type": "crosscheck_provider_response", "status": 200}, 1100)
backlog.observe({"type": "message_end", "message": {"role": "assistant", "stopReason": "toolUse"}}, 700)
assert backlog.value["stream_ms"] == 50 and backlog.value["assistant_elapsed_ms"] == 100
print("Independently buffered provider/stdout timing regression passed")


def progress_contract():
    adapter = load("crosscheck_progress_adapter", ROOT / "bin/fm-crosscheck-azure.py")
    metadata = {}
    blob = {"body": b"", "exists": True}
    published = threading.Event()

    class Storage(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_PUT(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if "comp=metadata" in self.path:
                assert body == b"", "progress must never write verdict body bytes"
                if not blob["exists"]:
                    self.send_response(404)
                    self.end_headers()
                    return
            else:
                blob["body"] = body
                blob["exists"] = True
            # Both Azure operations replace metadata, but only Put Blob writes
            # body bytes. Deliberately model metadata loss unless PUT carries it.
            metadata.clear()
            # Azure preserves the metadata suffix casing of actual wire
            # headers. urllib title-cases it; curl's final PUT can be lowercase.
            metadata.update({key[len("x-ms-meta-"):]: value for key, value in self.headers.items()
                             if key.lower().startswith("x-ms-meta-")})
            self.send_response(201)
            self.end_headers()
            published.set()

    server = ThreadingHTTPServer(("127.0.0.1", 0), Storage)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="crosscheck-progress-") as temporary:
            root = Path(temporary)
            progress = root / "progress.json"
            url = root / "progress-url"
            url.write_text(f"http://127.0.0.1:{server.server_port}/blob?fixture=not-a-secret")
            clean_env = {key: os.environ[key] for key in ("PATH", "TMPDIR") if key in os.environ}
            clean_env["FM_CROSSCHECK_PROGRESS_PATH"] = str(progress)
            with patch.dict(os.environ, clean_env, clear=True):
                runtime.update_progress(stage="challenge", phase="starting", turns=0, retries=0)
                runtime.LiveProgress().observe({"type": "auto_retry_start", "attempt": 2,
                                               "maxAttempts": 3, "errorMessage": "SECRET"})
                runtime.update_progress(phase="failed", reason="pi-exit", exit_code=137)
                runtime.record_guest_failure(125)
                runtime.record_guest_failure(125, "protocol-error")  # outer challenge wrapper
                precise = json.loads(progress.read_text())
                assert precise["reason"] == "pi-exit" and precise["exit_code"] == 137
                assert precise["retries_remaining"] == 1
                runtime.update_progress(stage="synthesis", phase="starting", attempt=1)
                fresh = json.loads(progress.read_text())
                assert not {"reason", "exit_code", "retries_remaining"} & fresh.keys()
                runtime.update_progress(phase="receiving", turns=3, retries=0)

            # Real separate publisher, then hard process death before any final
            # result or EXIT flush: storage keeps its last tiny observation.
            publisher = subprocess.Popen([sys.executable, str(ROOT / "bin/fm-crosscheck-pi-reviewer.py"),
                "--publish-progress", str(url), str(progress), str(root / "stop")],
                env=clean_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                assert published.wait(5), "root-side publisher did not emit metadata"
                publisher.kill()
                publisher.wait(timeout=5)
            finally:
                if publisher.poll() is None:
                    publisher.kill()
                    publisher.wait(timeout=5)
            assert blob["body"] == b"" and not (root / "result.json").exists()
            progress.unlink()  # guest filesystem is gone; remote facts survive
            identity = {"review_generation": "a" * 24, "head_sha": "b" * 40}
            config = {"timeout_seconds": 1800, "storage": "fixture-storage"}
            with patch.dict(os.environ, {}, clear=True):
                record = adapter.ProgressRecord(core, root / "home", "case-unit", identity, config, "exact-generation/output")
            reads = []
            def fake_az(_config, args, **kwargs):
                if args[:3] == ["storage", "blob", "show"]:
                    assert kwargs["timeout"] == 3
                    reads.append(1)
                    return {"metadata": dict(metadata)}, 0, ""
                assert args[:3] == ["rest", "--method", "get"]
                return {"properties": {"instanceView": {"executionState": "Failed", "exitCode": 137,
                    "startTime": "2026-01-01T00:00:00Z", "endTime": "2026-01-01T00:40:00Z",
                    "error": "", "output": "SECRET", "statuses": [{"message": "SECRET"}]}}}, 0, ""
            with patch.object(adapter, "az", fake_az):
                config["_progress_record"] = record
                try:
                    adapter.poll_model_run(config, "/fixture-command", 1800)
                except adapter.AzureCrosscheckError:
                    pass
                else:
                    raise AssertionError("hard guest death must not return a result marker")
                assert record.value["guest"] is not None, "case-insensitive metadata observation missing"
                retained = dict(record.value["guest"])
                assert retained["stage"] == "synthesis" and "exit_code" not in retained
                record.collect()
                assert len(reads) == 1, "optional reads must respect their cadence"
                stale = {**retained, "stage": "challenge", "updated_at_ms": retained["updated_at_ms"] - 1}
                assert "Fmprogress" in metadata, "fixture must preserve urllib's actual wire casing"
                metadata["fmprogress"] = base64.b64encode(runtime.canonical_bytes(stale)).decode()
                record.collect(force=True)
                assert record.value["progress_observation"] == "malformed" and record.value["guest"] == retained
                metadata.clear()
                metadata["fMpRoGrEsS"] = base64.b64encode(runtime.canonical_bytes(stale)).decode()
                record.collect(force=True)
                assert record.value["progress_observation"] == "stale" and record.value["guest"] == retained
                for bad in (None, [], "!invalid-base64!", base64.b64encode(b'{"schema":"invalid"}').decode()):
                    metadata["fMpRoGrEsS"] = bad
                    record.collect(force=True)
                    assert record.value["guest"] == retained
                    assert record.value["progress_observation"] in {"missing", "malformed", "unavailable"}
                record.failure("controller-failure")
                record.cleanup(True)
            durable = json.loads(record.path.read_text())
            assert durable["terminal_reason"] == "azure-failed" and durable["exit_code"] == 137
            assert durable["cleanup"] == "complete" and durable["stage"] == "synthesis"
            assert durable["execution_limit_seconds"] == 2400 and durable["poll_limit_seconds"] == 2700
            assert "SECRET" not in json.dumps(durable) and "verdict" not in durable
            assert record.path.stat().st_mode & 0o777 == 0o600
            record.cleanup(False)
            assert json.loads(record.path.read_text())["cleanup"] == "ambiguous"

            # Execute the production finally block: a run-command deletion
            # exception must not skip blob cleanup or its durable outcome.
            tree = ast.parse((ROOT / "bin/fm-crosscheck-azure.py").read_text())
            function = next(node for node in tree.body if isinstance(node, ast.FunctionDef)
                            and node.name == "_run_azure_review_in_lane")
            cleanup_try = next(node for node in ast.walk(function) if isinstance(node, ast.Try)
                               and any(isinstance(part, ast.Expr) and isinstance(part.value, ast.Call)
                                   and isinstance(part.value.func, ast.Attribute)
                                   and part.value.func.attr == "collect" for part in node.finalbody))
            deleted = []
            namespace = {**adapter.__dict__, "core": core, "progress": record, "azure": config,
                "resources": {"run_command_id": "/fixture-command"}, "cleanup_error": None,
                "uploaded": {"input"}, "staged": {"output_blob": "output"},
                "ledger_identity": None, "model_identity": None,
                "az": lambda *_args, **_kwargs: (_ for _ in ()).throw(TimeoutError("SECRET")),
                "delete_exact_blob": lambda _config, name, **_kwargs: deleted.append(name)}
            with patch.object(record, "collect"):
                try:
                    exec(compile(ast.Module(body=cleanup_try.finalbody, type_ignores=[]), "cleanup-fixture", "exec"), namespace)
                except core.CrosscheckPostAdmissionToolError:
                    pass
                else:
                    raise AssertionError("cleanup uncertainty must remain a tool failure")
            assert deleted == ["input", "output"]
            durable = json.loads(record.path.read_text())
            assert durable["cleanup"] == "ambiguous" and "SECRET" not in json.dumps(durable)

            # Run the actual guest final-upload block against our storage fixture.
            # It must preserve metadata while preserving authoritative bytes.
            completed = {**retained, "phase": "complete", "exit_code": 0}
            progress.write_bytes(runtime.canonical_bytes(completed))
            output = root / "output.json"
            output.write_bytes(b'{"authoritative":"fixture"}\n')
            guest = (ROOT / "bin/fm-crosscheck-azure-model-guest.sh").read_text()
            tail = guest.split("stop_progress\nprintf ", 1)[1].split("\nBOOT_ID=", 1)[0]
            environment = {**clean_env, "BASE": str(root), "OUTPUT": str(output),
                "OUTPUT_URL": url.read_text(), "PI_REVIEWER_RUNTIME": str(ROOT / "bin/fm-crosscheck-pi-reviewer.py")}
            subprocess.run(["bash", "-euc", "printf " + tail], env=environment, check=True, capture_output=True)
            assert base64.b64decode(metadata["fmprogress"]) == runtime.canonical_bytes(completed)
            expected = hashlib.sha256(blob["body"]).hexdigest()
            # A delayed old metadata request after final publication cannot
            # change digest-bound body; after cleanup it cannot recreate it.
            progress.write_bytes(runtime.canonical_bytes(retained))
            stop = root / "stop"
            stop.touch()
            runtime.publish_progress_metadata(url, progress, stop)
            assert hashlib.sha256(blob["body"]).hexdigest() == expected
            blob["exists"] = False
            runtime.publish_progress_metadata(url, progress, stop)
            assert blob["exists"] is False

            # Conditional cleanup retries only ETag churn, only when opted in,
            # and has a strict three-attempt limit. Every delete remains bound.
            def cleanup_case(conflicts, retries, error="ConditionNotMet (412)"):
                deletes = []
                exists = [True]
                def storage(_config, args, **_kwargs):
                    action = args[2]
                    if action == "exists":
                        return {"exists": exists[0]}, 0, ""
                    if action == "show":
                        return {"etag": "etag-" + str(len(deletes))}, 0, ""
                    assert action == "delete"
                    assert args[args.index("--name") + 1] == "exact-generation/output"
                    assert args[args.index("--if-match") + 1] == "etag-" + str(len(deletes))
                    deletes.append(1)
                    if len(deletes) <= conflicts:
                        return {}, 1, error
                    exists[0] = False
                    return {}, 0, ""
                with patch.object(adapter, "az", storage):
                    try:
                        adapter.delete_exact_blob(config, "exact-generation/output", metadata_retries=retries)
                    except adapter.AzureCrosscheckError:
                        return False, len(deletes)
                return True, len(deletes)
            assert cleanup_case(1, 2) == (True, 2)
            assert cleanup_case(99, 2) == (False, 3)
            assert cleanup_case(1, 0) == (False, 1)
            assert cleanup_case(1, 2, "authorization failure") == (False, 1)
        print("Durable progress: hard death, sanitization, stage reset, final/late publication and bounded cleanup passed")
    finally:
        server.shutdown()
        server.server_close()


progress_contract()

cli_raw = os.environ.get("FM_TEST_PINNED_PI_CLI")
if not cli_raw:
    print("Pinned Pi loopback transport not requested (set FM_TEST_PINNED_PI_CLI)")
    raise SystemExit(0)
cli = Path(cli_raw).resolve()
closure = json.loads((ROOT / "docs/azure-crosscheck/model-image-closure.json").read_text())
version = json.loads((cli.parent.parent / "package.json").read_text())["version"]
assert version == closure["piVersion"]["value"], "transport fixture must use the image-pinned Pi"
for family in ("pi-agent-core", "pi-ai", "pi-client", "pi-protocol", "pi-tui", "pi-telemetry"):
    family_version = json.loads((cli.parent.parent / "node_modules/@earendil-works" / family / "package.json").read_text())["version"]
    assert family_version == version, "the transport fixture must use a consistent pinned Pi family"


def exercise(scenario):
    requests = []
    server_errors = []
    release_waiters = threading.Event()

    class Provider(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args):
            pass

        def do_POST(self):
            try:
                assert self.path == "/v1/chat/completions"
                raw = self.rfile.read(int(self.headers["content-length"]))
                body = json.loads(raw)
                requests.append(body)
                number = len(requests)
                assert number <= 10, "fixture produced an unexpected tool loop"
                # Complete one real tool exchange before inducing inactivity.
                # Exhaustion is also preceded by the tool in each outer repair.
                tool_present = any(row.get("role") == "tool" for row in body["messages"])
                if tool_present and (scenario == "exhaustion" or
                                     scenario == "headers-retry" and number == 2):
                    release_waiters.wait(4)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()

                def chunk(delta, finish=None):
                    event = {"id": "fixture", "object": "chat.completion.chunk", "created": 0,
                             "model": "fixture-model", "choices": [{"index": 0, "delta": delta,
                                                                        "finish_reason": finish}]}
                    self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                    self.wfile.flush()

                if not tool_present:
                    name, arguments = "repo_read", {"path": "safe.py", "start_line": 1, "end_line": 1}
                else:
                    if scenario == "body-retry" and number == 2:
                        chunk({"role": "assistant", "reasoning_content": "fixture"})
                        release_waiters.wait(4)
                        return
                    if scenario == "active-stream":
                        # Stream for much longer than the injected idle timeout.
                        for _ in range(16):
                            chunk({"reasoning_content": "fixture"})
                            time.sleep(0.1)
                    name, arguments = "finish_review", {
                        "verdict": "CLEAR", "summary": "Fixture only",
                        "citations": [{"path": "safe.py", "line": 1}],
                    }
                chunk({"role": "assistant", "tool_calls": [{"index": 0, "id": "call-" + str(number),
                       "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}]})
                chunk({}, "tool_calls")
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            except BaseException as exc:
                server_errors.append((type(exc).__name__, len(raw) if "raw" in locals() else None,
                                      self.headers.get("content-length"), self.headers.get("content-encoding")))

    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="crosscheck-transport-") as temporary:
            root = Path(temporary)
            account, repository = root / "account", root / "repository"
            account.mkdir()
            repository.mkdir()
            (repository / "safe.py").write_text("PRESERVED_TOOL_RESULT = 7\n")
            (account / "models.json").write_text(json.dumps({"providers": {"fixture-provider": {
                "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "api": "openai-completions",
                "apiKey": "loopback-fixture-not-a-secret", "models": [{"id": "fixture-model", "name": "Fixture",
                    "reasoning": True, "input": ["text"], "contextWindow": 100000, "maxTokens": 2000,
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                    "compat": {"supportsStrictMode": True}}],
            }}}))
            settings = {"httpIdleTimeoutMs": 1000, "retry": {"enabled": True, "maxRetries": 3, "baseDelayMs": 10}}
            (account / "settings.json").write_text(json.dumps(settings))
            schema, prompt, result = root / "schema.json", root / "prompt.txt", root / "result.json"
            schema.write_text(json.dumps(core.pi_review_output_schema(str(account), str(root / "home"))))
            prompt.write_text("Loopback fixture; read safe.py then finish the review.\n")
            # Nothing from the operator's environment reaches Pi or the fixture.
            environment = {key: os.environ[key] for key in ("PATH", "TMPDIR") if key in os.environ}
            environment.update({
                "HOME": str(root / "home"), "NO_PROXY": "127.0.0.1,localhost",
                "FM_CROSSCHECK_PI_COMMAND_JSON": json.dumps(["node", str(cli)]),
                "FM_CROSSCHECK_REPOSITORY": str(repository), "FM_CROSSCHECK_HEAD_SHA": "a" * 40,
                "FM_CROSSCHECK_BASE_SHA": "b" * 40, "FM_CROSSCHECK_EXECUTING_ACCOUNT_HOME": str(account),
                "FM_CROSSCHECK_EXECUTION_HOME": str(root / "home"), "FM_CROSSCHECK_REVIEW_STAGE": "challenge",
                "FM_CROSSCHECK_EVALUATION_DIAGNOSTICS": "1",
                "FM_CROSSCHECK_PROGRESS_PATH": str(root / "progress.json"),
            })
            completed = subprocess.run([
                sys.executable, str(ROOT / "bin/fm-crosscheck-pi-reviewer.py"), str(account),
                "fixture-model", "xhigh", "fixture-provider", str(ROOT / "bin/fm-crosscheck-pi-verdict-extension.mjs"),
                str(prompt), str(schema), str(result),
            ], cwd=repository, env=environment, capture_output=True, text=True, timeout=40)
            assert not server_errors, server_errors
            progress = json.loads((root / "progress.json").read_text())
            assert "PRESERVED_TOOL_RESULT" not in json.dumps(progress)
            assert "loopback-fixture-not-a-secret" not in json.dumps(progress)
            if scenario == "exhaustion":
                assert completed.returncode == 125 and not result.exists(), completed.stderr
                assert len(requests) == 10, len(requests)  # two outer attempts, each read + four failed requests
                assert progress["phase"] == "failed" and progress["exit_code"] != 0, progress
                assert progress["retries_remaining"] == 0 and progress["retries"] == 3, progress
                print("Pinned Pi: retry exhaustion never produced a verdict")
                return
            assert completed.returncode == 0, completed.stderr
            assert progress["phase"] == "complete" and progress["exit_code"] == 0, progress
            value = json.loads(result.read_text())
            diagnostics = value["review_diagnostics"][0]
            assert value["verdict"]["head_sha"] == "a" * 40
            assert [event["name"] for event in value["tool_events"]] == ["repo_read", "finish_review"]
            assert json.loads((account / "settings.json").read_text()) == settings
            if scenario == "active-stream":
                assert len(requests) == 2 and diagnostics["retries"] == 0
                assert diagnostics["stream_ms"] >= 1000, diagnostics
            else:
                assert len(requests) == 3 and diagnostics["retries"] == 1, diagnostics
                assert requests[1]["messages"] == requests[2]["messages"], "retry lost or changed earlier context"
                assert "PRESERVED_TOOL_RESULT" in json.dumps(requests[2]["messages"])
            assert diagnostics["requests"] == len(requests), diagnostics
            assert "PRESERVED_TOOL_RESULT" not in json.dumps(diagnostics)
            print(f"Pinned Pi {version}: {scenario} passed; requests={len(requests)} retries={diagnostics['retries']}")
    finally:
        release_waiters.set()
        server.shutdown()
        server.server_close()


for scenario in ("headers-retry", "body-retry", "active-stream", "exhaustion"):
    exercise(scenario)
