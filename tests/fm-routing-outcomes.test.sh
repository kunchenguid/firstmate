#!/usr/bin/env bash
# Behavior tests for bin/fm-routing-outcomes.py through its public CLI.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_TEST_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}" python3 - <<'PY'
import copy
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(os.environ["FM_TEST_ROOT"])
CLI = ROOT / "bin" / "fm-routing-outcomes.py"


class RoutingOutcomesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="fm-routing-outcomes.")
        self.dir = Path(self.tmp.name)
        self.store = self.dir / "outcomes.jsonl"
        self.shadow_store = self.dir / "shadow.jsonl"
        self.state = self.dir / "state"
        self.state.mkdir()
        self.pi = self.dir / "pi.jsonl"
        self.quota_before = self.dir / "quota-before.json"
        self.quota_after = self.dir / "quota-after.json"
        self.write_pi(self.pi)
        self.write_quota(self.quota_before, 100, "2030-01-02T00:00:00Z")
        self.write_quota(self.quota_after, 95, "2030-01-02T00:00:00Z")

    def tearDown(self):
        self.tmp.cleanup()

    def run_cli(self, *args, ok=True):
        env = dict(os.environ, FM_STATE_OVERRIDE=str(self.state))
        result = subprocess.run([str(CLI), *map(str, args)], text=True, capture_output=True, env=env)
        if ok and result.returncode != 0:
            self.fail(f"command failed ({result.returncode}): {result.stderr}\n{result.stdout}")
        if not ok and result.returncode == 0:
            self.fail(f"command unexpectedly succeeded: {result.stdout}")
        return result

    def write_json(self, path, value):
        path.write_text(json.dumps(value), encoding="utf-8")

    def bind_task(self, task, spawn_gen="spawn-1", harness="pi"):
        (self.state / f"{task}.meta").write_text(
            f"endpoint_task_id={task}\nspawn_gen={spawn_gen}\nharness={harness}\nkind=ship\n",
            encoding="utf-8")
        return {"spawn_gen": spawn_gen}

    def check_receipt(self, *, task="task-one", spawn_gen="spawn-1", attempt="attempt-one",
                      passed=True, criterion="focused-tests", criterion_text="focused tests pass"):
        artifact = self.dir / f"check-{task}-{spawn_gen}-{attempt}-{'pass' if passed else 'fail'}.json"
        criteria = [{"id": criterion, "text": criterion_text}]
        criteria_sha = hashlib.sha256(json.dumps(
            criteria, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()
        payload = {"schema": "fm-routing-check.v1", "check_id": "unit",
                   "grader_id": "focused-tests", "criteria_ids": [criterion],
                   "task_id": task, "spawn_gen": spawn_gen, "attempt_id": attempt,
                   "acceptance_criteria_sha256": criteria_sha,
                   "passed": passed, "exit_code": 0 if passed else 1}
        self.write_json(artifact, payload)
        sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
        return {"kind": "test", "id": "unit", "passed": passed,
                "criteria_ids": [criterion], "artifact_path": str(artifact), "sha256": sha}

    def write_pi(self, path, *, custom=True, effort="max", task="task-one",
                 spawn_gen="spawn-1", duplicate=False, extra_request=None,
                 assistant_model="gpt-5.6-luna", assistant_provider="openai-codex"):
        rows = [{"type": "session", "id": "session-1", "timestamp": "2030-01-01T00:00:00Z"}]
        if custom:
            rows.append({
                "type": "custom", "id": "request-1", "parentId": "user-1",
                "customType": "fm-routing-request", "timestamp": "2030-01-01T00:00:01Z",
                "data": {"schema": "fm-routing-request.v1", "taskId": task, "spawnGen": spawn_gen,
                         "requestSequence": 1, "at": "2030-01-01T00:00:01Z",
                         "provider": "openai-codex", "selectedModel": "gpt-5.6-luna",
                         "selectedThinkingLevel": "max", "api": "openai-codex-responses",
                         "payloadModel": "gpt-5.6-luna", "payloadReasoningEffort": effort},
            })
            if extra_request is not None:
                extra = copy.deepcopy(rows[-1])
                extra["id"] = "request-2"
                extra["data"].update(extra_request)
                rows.append(extra)
        assistant = {
            "type": "message", "id": "assistant-1", "parentId": "request-1",
            "timestamp": "2030-01-01T00:00:03Z",
            "message": {"role": "assistant", "provider": assistant_provider,
                        "model": assistant_model, "api": "openai-codex-responses",
                        "content": [{"type": "text", "text": "PRIVATE PROMPT RESPONSE"}],
                        "usage": {"input": 100, "output": 20, "cacheRead": 10,
                                  "cacheWrite": 0, "reasoning": 5, "totalTokens": 130,
                                  "cost": {"total": 0.5}}},
        }
        rows.append(assistant)
        if duplicate:
            rows.append(copy.deepcopy(assistant))
        path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    def write_quota(self, path, remaining, reset, *, provider="codex", status="known", unresolved=None):
        row = {
            "provider": provider,
            "windows": [{"id": "weekly", "label": "week", "kind": "weekly",
                         "resetsAt": reset, "percentRemaining": remaining}],
            "quotaSemantics": {"status": status, "effectiveAvailability": []},
        }
        if unresolved is not None:
            row["quotaSemantics"]["unresolvedWindowIds"] = unresolved
        self.write_json(path, {"schemaVersion": 5, "generatedAt": "2030-01-01T00:00:00Z", "providers": [row]})

    def manifest(self, *, receipt=None, task="task-one", spawn_gen="spawn-1",
                 attempt="attempt-one", outcome="accepted"):
        task_binding = self.bind_task(task, spawn_gen)
        return {
            "schema": "fm-routing-attempt.v1", "task_id": task, "attempt_id": attempt,
            "task_binding": task_binding,
            "phase": "measurement", "category": "1", "task_shape": "code-change",
            "route": {"harness": "pi", "provider": "openai-codex",
                      "auth_category": "subscription", "requested_model": "gpt-5.6-luna",
                      "requested_effort": "max", "context_tier": "all", "service_tier": "standard"},
            "native_receipt": receipt or {"kind": "pi-session", "path": str(self.pi)},
            "requirements": {"effective_model": "gpt-5.6-luna", "effective_effort": "max"},
            "started_at": "2030-01-01T00:00:00Z", "finished_at": "2030-01-01T00:01:00Z",
            "time_ms": {"queue": 10, "model": 20, "tool": 5, "review": 7,
                        "retry": None, "handoff": None, "human": None},
            "billing": {"actual_incremental_usd": None, "fixed_subscription_usd": 20},
            "quota": {"provider": "codex", "before_path": str(self.quota_before),
                      "after_path": str(self.quota_after), "concurrent_activity": False,
                      "attribution": "exclusive"},
            "grading": {"method": "deterministic", "independent": True,
                        "acceptance_criteria": [{"id": "focused-tests", "text": "focused tests pass"}],
                        "grader": {"kind": "deterministic-check", "id": "focused-tests"},
                        "first_pass": "pass", "final_result": "pass", "defect_count": 0,
                        "fix_count": 0, "retry_count": 0,
                        "receipts": [self.check_receipt(task=task, spawn_gen=spawn_gen, attempt=attempt)],
                        "overhead": {"cost_basis": "no-model", "duration_ms": 3, "tokens": None,
                                     "actual_incremental_usd": None}},
            "outcome": outcome,
        }

    def import_manifest(self, manifest, *, prices=None, ok=True):
        path = self.dir / f"manifest-{manifest['task_id']}-{manifest['attempt_id']}.json"
        self.write_json(path, manifest)
        args = ["import", "--manifest", path, "--store", self.store, "--json"]
        if prices:
            args.extend(["--prices", prices])
        return self.run_cli(*args, ok=ok)

    def latest_record(self):
        rows = [json.loads(line) for line in self.store.read_text().splitlines()]
        return rows[-1]["record"]

    def test_pi_import_is_private_complete_and_idempotent(self):
        result = self.import_manifest(self.manifest())
        self.assertEqual(json.loads(result.stdout)["action"], "created")
        record = self.latest_record()
        self.assertEqual(record["native"]["effective_effort"], "max")
        self.assertEqual(record["native"]["tokens"]["input"], 100)
        self.assertEqual(record["native"]["completeness"]["effort"], "provider-request")
        self.assertEqual(record["quota"]["window_deltas"][0]["attributed_consumption_percent_points"], 5)
        self.assertNotIn("PRIVATE PROMPT RESPONSE", self.store.read_text())
        again = self.import_manifest(self.manifest())
        self.assertEqual(json.loads(again.stdout)["action"], "noop")
        self.assertEqual(len(self.store.read_text().splitlines()), 1)

    def test_concurrent_duplicate_import_is_one_revision(self):
        manifest = self.manifest()
        path = self.dir / "concurrent-manifest.json"
        self.write_json(path, manifest)
        command = [str(CLI), "import", "--manifest", str(path), "--store", str(self.store), "--json"]
        env = dict(os.environ, FM_STATE_OVERRIDE=str(self.state))
        processes = [subprocess.Popen(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env) for _ in range(8)]
        results = [process.communicate() + (process.returncode,) for process in processes]
        self.assertTrue(all(returncode == 0 for _stdout, _stderr, returncode in results), results)
        actions = [json.loads(stdout)["action"] for stdout, _stderr, _returncode in results]
        self.assertEqual(actions.count("created"), 1)
        self.assertEqual(actions.count("noop"), 7)
        self.assertEqual(len(self.store.read_text().splitlines()), 1)

    def test_resume_revision_does_not_duplicate_attempt_or_usage(self):
        self.import_manifest(self.manifest())
        changed = self.manifest()
        changed["grading"]["fix_count"] = 1
        result = self.import_manifest(changed)
        self.assertEqual(json.loads(result.stdout)["revision"], 2)
        score = self.run_cli("scorecard", "--store", self.store,
                             "--shadow-store", self.shadow_store, "--format", "json")
        data = json.loads(score.stdout)
        self.assertEqual(data["attempt_count"], 1)
        self.assertEqual(data["routes"][0]["tokens"]["input"]["known_total"], 100)

    def test_task_time_spans_failed_attempt_and_handoff_to_accepted_completion(self):
        failed = self.manifest(attempt="attempt-failed", outcome="failed")
        failed["finished_at"] = "2030-01-01T00:00:30Z"
        failed["billing"]["actual_incremental_usd"] = 0.1
        failed["grading"].update({"first_pass": "fail", "final_result": "fail",
                                  "defect_count": 1, "fix_count": 0, "retry_count": 1,
                                  "receipts": [self.check_receipt(attempt="attempt-failed", passed=False)]})
        failed["handoff"] = {"alternative_attempt_id": "attempt-accepted", "side_effects": "none",
                             "quality_preserved": True, "privacy_preserved": True,
                             "reconciliation_receipt": "no external action existed"}
        self.import_manifest(failed)
        accepted = self.manifest(attempt="attempt-accepted")
        accepted["started_at"] = "2030-01-01T00:00:31Z"
        accepted["finished_at"] = "2030-01-01T00:01:30Z"
        accepted["billing"]["actual_incremental_usd"] = 0.2
        self.import_manifest(accepted)
        result = self.run_cli("scorecard", "--store", self.store,
                              "--shadow-store", self.shadow_store, "--format", "json")
        task = json.loads(result.stdout)["tasks"][0]
        self.assertEqual(task["accepted_task_end_to_end_ms"]["known_total"], 90000)
        self.assertAlmostEqual(task["accepted_task_actual_incremental_usd"]["known_total"], 0.3)
        self.assertAlmostEqual(task["unresolved_or_failure_actual_usd"]["known_total"], 0.1)

    def test_accepted_cost_stops_at_first_acceptance_and_subscription_is_context_only(self):
        accepted = self.manifest(attempt="accepted")
        accepted["billing"]["actual_incremental_usd"] = 0.2
        accepted["grading"]["overhead"].update({"duration_ms": 3, "actual_incremental_usd": 0.05})
        self.import_manifest(accepted)
        later = self.manifest(attempt="later", outcome="failed")
        later["started_at"] = "2030-01-01T00:02:00Z"
        later["finished_at"] = "2030-01-01T00:03:00Z"
        later["billing"]["actual_incremental_usd"] = 0.9
        later["grading"]["overhead"].update({"duration_ms": 30, "actual_incremental_usd": 0.7})
        later["grading"].update({"first_pass": "fail", "final_result": "fail",
                                  "receipts": [self.check_receipt(attempt="later", passed=False)]})
        self.import_manifest(later)
        result = self.run_cli("scorecard", "--store", self.store,
                              "--shadow-store", self.shadow_store, "--format", "json")
        score = json.loads(result.stdout)
        task = score["tasks"][0]
        self.assertEqual(task["accepted_task_actual_incremental_usd"]["known_total"], 0.2)
        self.assertEqual(task["grader_actual_incremental_usd"]["known_total"], 0.05)
        self.assertEqual(task["grader_duration_ms"]["known_total"], 3)
        self.assertEqual(task["accepted_task_fixed_subscription_usd"]["distinct_values"], [20.0])
        self.assertEqual(score["routes"][0]["fixed_subscription_usd"]["aggregation"], "not-applicable")

    def test_import_requires_current_task_incarnation(self):
        manifest = self.manifest()
        manifest["task_binding"]["spawn_gen"] = "stale"
        result = self.import_manifest(manifest, ok=False)
        self.assertIn("current task incarnation", json.loads(result.stdout)["error"])

    def test_native_receipt_and_store_identity_follow_task_incarnation(self):
        self.import_manifest(self.manifest())
        self.bind_task("task-one", "spawn-2")
        stale = self.manifest(spawn_gen="spawn-2")
        result = self.import_manifest(stale, ok=False)
        self.assertIn("native Pi task incarnation", json.loads(result.stdout)["error"])
        self.write_pi(self.pi, spawn_gen="spawn-2")
        self.import_manifest(self.manifest(spawn_gen="spawn-2"))
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        self.assertEqual(score["attempt_count"], 2)
        self.assertEqual(score["task_count"], 2)
        self.assertEqual({row["spawn_gen"] for row in score["tasks"]}, {"spawn-1", "spawn-2"})

    def test_duplicate_native_message_id_is_not_double_counted(self):
        self.write_pi(self.pi, duplicate=True)
        self.import_manifest(self.manifest())
        self.assertEqual(self.latest_record()["native"]["tokens"]["input"], 100)

    def test_missing_provider_effort_stays_unknown_and_requirement_blocks(self):
        self.write_pi(self.pi, custom=False)
        blocked = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("effective effort requirement not proven", json.loads(blocked.stdout)["error"])
        allowed = self.manifest()
        allowed["requirements"] = None
        allowed["outcome"] = "unresolved"
        self.import_manifest(allowed)
        self.assertIsNone(self.latest_record()["native"]["effective_effort"])
        self.assertEqual(self.latest_record()["native"]["completeness"]["request_payload"], "missing")

    def test_mixed_pi_route_evidence_is_rejected(self):
        self.write_pi(self.pi, extra_request={"payloadReasoningEffort": None})
        result = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("mixed or incomplete effective effort", json.loads(result.stdout)["error"])
        self.write_pi(self.pi, extra_request={"payloadModel": "gpt-other"})
        result = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("mixed or incomplete effective model", json.loads(result.stdout)["error"])

    def test_manifest_route_identity_must_match_native_and_task_evidence(self):
        wrong_harness = self.manifest()
        wrong_harness["route"]["harness"] = "claude"
        result = self.import_manifest(wrong_harness, ok=False)
        self.assertIn("native receipt kind", json.loads(result.stdout)["error"])
        wrong_provider = self.manifest()
        wrong_provider["route"]["provider"] = "google"
        result = self.import_manifest(wrong_provider, ok=False)
        self.assertIn("native provider evidence", json.loads(result.stdout)["error"])
        self.write_pi(self.pi, assistant_provider="google")
        result = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("mixed or incomplete provider", json.loads(result.stdout)["error"])
        self.write_pi(self.pi)
        task_mismatch = self.manifest()
        self.bind_task("task-one", harness="pi-signed")
        result = self.import_manifest(task_mismatch, ok=False)
        self.assertIn("task metadata harness", json.loads(result.stdout)["error"])

    def test_actual_zero_allowance_and_unresolved_agy_windows_remain_literal(self):
        self.write_quota(self.quota_before, 0, "2030-01-02T00:00:00Z", provider="agy",
                         status="unknown", unresolved=["gemini_5h", "gemini_weekly"])
        self.write_quota(self.quota_after, 0, "2030-01-02T00:00:00Z", provider="agy",
                         status="unknown", unresolved=["gemini_5h", "gemini_weekly"])
        manifest = self.manifest()
        manifest["quota"].update({"provider": "agy", "concurrent_activity": True,
                                  "attribution": "shared"})
        self.import_manifest(manifest)
        quota = self.latest_record()["quota"]
        self.assertEqual(quota["before"]["windows"][0]["percentRemaining"], 0)
        self.assertEqual(quota["before"]["quota_semantics"]["unresolvedWindowIds"],
                         ["gemini_5h", "gemini_weekly"])
        self.assertIsNone(quota["window_deltas"][0]["attributed_consumption_percent_points"])

    def test_reset_and_concurrent_activity_prevent_quota_attribution(self):
        self.write_quota(self.quota_after, 100, "2030-01-09T00:00:00Z")
        manifest = self.manifest()
        manifest["quota"]["concurrent_activity"] = True
        self.import_manifest(manifest)
        quota = self.latest_record()["quota"]
        self.assertTrue(quota["reset_crossed"])
        self.assertIsNone(quota["window_deltas"][0]["attributed_consumption_percent_points"])

    def test_refreshable_auth_uncertainty_is_not_converted_to_zero(self):
        self.write_quota(self.quota_before, None, "2030-01-02T00:00:00Z", status="unknown")
        self.write_quota(self.quota_after, None, "2030-01-02T00:00:00Z", status="unknown")
        manifest = self.manifest()
        manifest["route"]["auth_category"] = "unknown"
        manifest["quota"].update({"concurrent_activity": None, "attribution": "unknown"})
        self.import_manifest(manifest)
        quota = self.latest_record()["quota"]
        self.assertEqual(quota["before"]["quota_semantics"]["status"], "unknown")
        self.assertIsNone(quota["before"]["windows"][0]["percentRemaining"])
        self.assertIsNone(quota["window_deltas"][0]["attributed_consumption_percent_points"])

    def test_claude_result_counts_auxiliary_models_and_keeps_effort_unknown(self):
        receipt = self.dir / "claude.json"
        self.write_json(receipt, {
            "type": "result", "session_id": "claude-session", "num_turns": 1,
            "duration_api_ms": 200, "total_cost_usd": 0.12, "result": "PRIVATE RESPONSE",
            "usage": {"service_tier": "standard"},
            "modelUsage": {
                "claude-sonnet-5": {"canonicalModel": "claude-sonnet-5", "provider": "firstParty",
                                    "inputTokens": 10, "outputTokens": 3,
                                    "cacheReadInputTokens": 2, "cacheCreationInputTokens": 1,
                                    "thinkingTokens": 1},
                "claude-haiku-4-5": {"canonicalModel": "claude-haiku-4-5", "provider": "firstParty",
                                     "inputTokens": 4, "outputTokens": 1,
                                     "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0,
                                     "thinkingTokens": 0},
            },
        })
        manifest = self.manifest(receipt={"kind": "claude-result", "path": str(receipt),
                                         "requested_model": "claude-sonnet-5",
                                         "requested_effort": "high"})
        manifest["route"].update({"harness": "claude", "provider": "anthropic",
                                  "requested_model": "claude-sonnet-5", "requested_effort": "high"})
        self.bind_task("task-one", harness="claude")
        manifest["requirements"] = None
        self.import_manifest(manifest)
        native = self.latest_record()["native"]
        self.assertEqual(native["tokens"]["input"], 14)
        self.assertIsNone(native["effective_effort"])
        self.assertEqual(len(native["models"]), 2)
        self.assertNotIn("PRIVATE RESPONSE", self.store.read_text())

    def test_mixed_claude_session_models_are_rejected(self):
        receipt = self.dir / "claude-session.jsonl"
        rows = [
            {"type": "assistant", "sessionId": "session-one", "uuid": "one",
             "timestamp": "2030-01-01T00:00:01Z",
             "message": {"id": "one", "model": "claude-sonnet-5",
                         "usage": {"input_tokens": 1, "output_tokens": 1}}},
            {"type": "assistant", "sessionId": "session-one", "uuid": "two",
             "timestamp": "2030-01-01T00:00:02Z",
             "message": {"id": "two", "model": "claude-opus-5",
                         "usage": {"input_tokens": 1, "output_tokens": 1}}},
        ]
        receipt.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        manifest = self.manifest(receipt={"kind": "claude-session", "path": str(receipt),
                                         "requested_model": "claude-sonnet-5",
                                         "requested_effort": "high"})
        manifest["route"].update({"harness": "claude", "provider": "anthropic",
                                  "requested_model": "claude-sonnet-5", "requested_effort": "high"})
        manifest["requirements"] = None
        self.bind_task("task-one", harness="claude")
        result = self.import_manifest(manifest, ok=False)
        self.assertIn("mixed or incomplete effective model", json.loads(result.stdout)["error"])

    def test_agy_native_model_label_proves_effective_variant(self):
        receipt = self.dir / "agy.json"
        log = self.dir / "agy.log"
        self.write_json(receipt, {"conversation_id": "agy-one", "duration_seconds": 1.5,
                                  "num_turns": 1, "status": "SUCCESS", "response": "PRIVATE RESPONSE",
                                  "usage": {"input_tokens": 20, "output_tokens": 3,
                                            "thinking_tokens": 1, "cache_read_tokens": 2,
                                            "total_tokens": 26}})
        log.write_text("Resolving model gemini-3.8-flash-medium\n"
                       "Propagating selected model override to backend: label=\"Gemini 3.8 Flash (Medium)\"\n")
        manifest = self.manifest(receipt={"kind": "agy-result", "path": str(receipt),
                                         "native_log_path": str(log),
                                         "requested_model": "gemini-3.8-flash-medium",
                                         "requested_effort": "medium"})
        manifest["route"].update({"harness": "agy", "provider": "google",
                                  "auth_category": "oauth",
                                  "requested_model": "gemini-3.8-flash-medium",
                                  "requested_effort": "medium"})
        self.bind_task("task-one", harness="agy")
        manifest["requirements"] = {"effective_model": "gemini-3.8-flash-medium",
                                    "effective_effort": "medium"}
        self.import_manifest(manifest)
        native = self.latest_record()["native"]
        self.assertEqual(native["effective_effort"], "medium")
        self.assertEqual(native["tokens"]["reasoning"], 1)
        self.assertNotIn("PRIVATE RESPONSE", self.store.read_text())

    def test_agy_requested_model_is_not_effective_proof_without_native_log(self):
        receipt = self.dir / "agy-no-log.json"
        self.write_json(receipt, {"conversation_id": "agy-two", "duration_seconds": 1,
                                  "num_turns": 1, "status": "SUCCESS", "response": "receipt-ok",
                                  "usage": {"input_tokens": 2, "output_tokens": 1,
                                            "thinking_tokens": 0, "cache_read_tokens": 0,
                                            "total_tokens": 3}})
        manifest = self.manifest(receipt={"kind": "agy-result", "path": str(receipt),
                                         "requested_model": "gemini-3.8-flash-medium",
                                         "requested_effort": "medium"})
        manifest["route"].update({"harness": "agy", "provider": "google",
                                  "auth_category": "oauth",
                                  "requested_model": "gemini-3.8-flash-medium",
                                  "requested_effort": "medium"})
        self.bind_task("task-one", harness="agy")
        manifest["requirements"] = {"effective_model": "gemini-3.8-flash-medium"}
        result = self.import_manifest(manifest, ok=False)
        self.assertIn("effective model requirement not proven", json.loads(result.stdout)["error"])
        manifest["requirements"] = None
        manifest["outcome"] = "unresolved"
        self.import_manifest(manifest)
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        self.assertEqual(
            score["routes"][0]["route"],
            "agy/google/requested-only:gemini-3.8-flash-medium/requested-only:medium")

    def test_price_requires_exact_timestamped_model_context_service_and_cache_rates(self):
        prices = self.dir / "prices.json"
        self.write_json(prices, {
            "schema": "fm-routing-prices.v1", "observed_at": "2030-01-01T00:00:00Z",
            "entries": [{"provider": "openai-codex", "model": "gpt-5.6-luna",
                         "context_tier": "all", "service_tier": "standard",
                         "source_url": "https://example.test/prices", "effective_from": "2029-01-01T00:00:00Z",
                         "effective_to": None, "currency": "USD", "reasoning": "included_in_output",
                         "per_million_tokens": {"input": 1, "output": 2,
                                                "cache_read": 0.5, "cache_write": 1}}]})
        self.import_manifest(self.manifest(), prices=prices)
        billing = self.latest_record()["billing"]
        self.assertAlmostEqual(billing["api_equivalent_usd"], 0.000145)
        self.assertIsNone(billing["actual_incremental_usd"])
        self.assertEqual(billing["fixed_subscription_usd"], 20)

    def test_unknown_price_never_uses_native_reported_cost(self):
        self.import_manifest(self.manifest())
        billing = self.latest_record()["billing"]
        self.assertIsNone(billing["api_equivalent_usd"])
        self.assertEqual(self.latest_record()["native"]["native_reported_cost_usd"], 0.5)

    def test_model_grader_cost_uses_distinct_priced_attempt(self):
        prices = self.dir / "prices.json"
        self.write_json(prices, {
            "schema": "fm-routing-prices.v1", "observed_at": "2030-01-01T00:00:00Z",
            "entries": [{"provider": "openai-codex", "model": "gpt-5.6-luna",
                         "context_tier": "all", "service_tier": "standard",
                         "source_url": "https://example.test/prices", "effective_from": "2029-01-01T00:00:00Z",
                         "effective_to": None, "currency": "USD", "reasoning": "included_in_output",
                         "per_million_tokens": {"input": 1, "output": 2,
                                                "cache_read": 0.5, "cache_write": 1}}]})
        grader = self.manifest(attempt="grader-one", outcome="unresolved")
        grader["attempt_role"] = "grader"
        grader["started_at"] = "2030-01-01T00:00:50Z"
        grader["finished_at"] = "2030-01-01T00:01:10Z"
        self.import_manifest(grader)
        work = self.manifest(attempt="work-one")
        work["grading"]["grader"]["kind"] = "model-review"
        work["grading"]["overhead"] = {"cost_basis": "grader-attempt",
                                         "grader_attempt_id": "grader-one",
                                         "duration_ms": None, "tokens": None,
                                         "actual_incremental_usd": None}
        self.import_manifest(work, prices=prices)
        task = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)["tasks"][0]
        self.assertAlmostEqual(task["accepted_execution_api_equivalent_usd"]["known_total"], 0.000145)
        self.assertIsNone(task["accepted_grader_api_equivalent_usd"]["known_total"])
        self.assertIsNone(task["accepted_complete_api_equivalent_usd"]["known_total"])
        self.assertEqual(task["accepted_task_end_to_end_ms"]["known_total"], 70000)
        self.import_manifest(grader, prices=prices)
        task = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)["tasks"][0]
        self.assertAlmostEqual(task["accepted_grader_api_equivalent_usd"]["known_total"], 0.000145)
        self.assertAlmostEqual(task["accepted_complete_api_equivalent_usd"]["known_total"], 0.00029)
        self.assertEqual(task["accepted_task_end_to_end_ms"]["known_total"], 70000)

    def test_independent_grade_and_actual_receipt_are_required_for_acceptance(self):
        manifest = self.manifest()
        manifest["grading"]["independent"] = False
        result = self.import_manifest(manifest, ok=False)
        self.assertIn("independent", json.loads(result.stdout)["error"])
        manifest = self.manifest()
        manifest["grading"]["receipts"] = []
        result = self.import_manifest(manifest, ok=False)
        self.assertIn("passing receipt", json.loads(result.stdout)["error"])
        manifest = self.manifest()
        manifest["grading"]["receipts"][0]["sha256"] = "0" * 64
        result = self.import_manifest(manifest, ok=False)
        self.assertIn("must match the check artifact", json.loads(result.stdout)["error"])

    def test_grade_artifact_is_bound_to_task_attempt_incarnation_and_criteria(self):
        source = self.manifest()
        reused = copy.deepcopy(source["grading"]["receipts"])
        target = self.manifest(task="task-two", attempt="attempt-two")
        self.write_pi(self.pi, task="task-two")
        target["grading"]["receipts"] = reused
        result = self.import_manifest(target, ok=False)
        self.assertIn("task attempt binding", json.loads(result.stdout)["error"])

        self.write_pi(self.pi)
        changed = self.manifest()
        changed["grading"]["acceptance_criteria"][0]["text"] = "focused tests and docs pass"
        result = self.import_manifest(changed, ok=False)
        self.assertIn("acceptance criteria binding", json.loads(result.stdout)["error"])

        self.bind_task("task-one", "spawn-2")
        changed_incarnation = self.manifest(spawn_gen="spawn-2")
        changed_incarnation["grading"]["receipts"] = reused
        self.write_pi(self.pi, spawn_gen="spawn-2")
        result = self.import_manifest(changed_incarnation, ok=False)
        self.assertIn("task attempt binding", json.loads(result.stdout)["error"])

    def test_handoff_is_one_alternative_and_requires_side_effect_reconciliation(self):
        manifest = self.manifest()
        manifest["handoff"] = {"alternative_attempt_id": "attempt-two", "side_effects": "none",
                               "quality_preserved": True, "privacy_preserved": True,
                               "reconciliation_receipt": "no external action was available"}
        self.import_manifest(manifest)
        self.assertEqual(self.latest_record()["handoff"]["alternative_attempt_id"], "attempt-two")
        bad = self.manifest(task="task-two", attempt="attempt-two")
        self.write_pi(self.pi, task="task-two")
        bad["handoff"] = {"alternative_attempt_id": "attempt-three", "alternatives": ["a", "b"],
                          "side_effects": "unknown", "quality_preserved": True,
                          "privacy_preserved": True, "reconciliation_receipt": "none"}
        result = self.import_manifest(bad, ok=False)
        self.assertIn("one alternative", json.loads(result.stdout)["error"])

    def test_initial_comparison_cap_is_two_low_risk_pairs_per_category(self):
        for number in (1, 2):
            manifest = self.manifest(task=f"task-{number}", attempt=f"attempt-{number}")
            self.write_pi(self.pi, task=f"task-{number}")
            manifest["comparison"] = {"pair_id": f"pair-{number}", "low_risk": True,
                                      "time_critical": False, "private_external_action": False,
                                      "external_action": False}
            self.import_manifest(manifest)
        manifest = self.manifest(task="task-three", attempt="attempt-three")
        self.write_pi(self.pi, task="task-three")
        manifest["comparison"] = {"pair_id": "pair-three", "low_risk": True,
                                  "time_critical": False, "private_external_action": False,
                                  "external_action": False}
        result = self.import_manifest(manifest, ok=False)
        self.assertIn("already has two comparison pairs", json.loads(result.stdout)["error"])

    def test_legacy_dispatch_history_is_visible_but_not_mixed_into_receipt_totals(self):
        legacy = self.dir / "dispatch-log.tsv"
        legacy.write_text("date\ttask\trepo\tdeliverable\tharness\tmodel\teffort\tshape\tr1_findings\tfix_rounds\tfirst_try\toutcome\tnotes\n"
                          "2030-01-01\told-task\trepo\tship\tpi\told-model\thigh\tcode\t1\t1\tno\taccepted\told\n")
        result = self.run_cli("legacy", "--legacy-log", legacy, "--json")
        score = json.loads(result.stdout)
        self.assertEqual(score["rows"], 1)
        self.assertIn("token, cost, quota", score["completeness"])

    def test_shadow_records_all_candidate_uncertainty_without_ranking(self):
        route_one = self.manifest()["route"]
        route_two = copy.deepcopy(route_one)
        route_two.update({"harness": "claude", "provider": "anthropic",
                          "requested_model": "claude-sonnet-5", "requested_effort": "high"})
        shadow = {
            "schema": "fm-routing-shadow.v1", "task_id": "task-one", "decision_id": "decision-one",
            "task_binding": {"spawn_gen": "spawn-1"},
            "at": "2030-01-01T00:00:00Z", "category": "1", "task_shape": "code-change",
            "candidates": [
                {"route": route_one, "eligibility": "pass", "capability_class_fit": "pass",
                 "runway_feasibility": "pass", "spend_priority": 1.2,
                 "allowance_evidence": {"snapshot_path": str(self.quota_before),
                                        "provider": "codex", "window_id": "weekly",
                                        "percent_remaining": 100},
                 "uncertainty": "none observed", "explanation": "known headroom after fit gates"},
                {"route": route_two, "eligibility": "unknown", "capability_class_fit": "pass",
                 "runway_feasibility": "unknown", "spend_priority": None,
                 "uncertainty": "refreshable auth was not refreshed", "explanation": "unknown is not exhaustion"},
            ],
            "recommended_route": route_one,
            "explanation": "Both fit; known spend priority supports the shadow recommendation while Claude remains an eligible uncertainty.",
        }
        path = self.dir / "shadow-manifest.json"
        self.write_json(path, shadow)
        first = self.run_cli("shadow", "--manifest", path, "--shadow-store", self.shadow_store, "--json")
        self.assertEqual(json.loads(first.stdout)["action"], "created")
        second = self.run_cli("shadow", "--manifest", path, "--shadow-store", self.shadow_store, "--json")
        self.assertEqual(json.loads(second.stdout)["action"], "noop")
        score = self.run_cli("scorecard", "--store", self.store,
                             "--shadow-store", self.shadow_store, "--format", "markdown")
        self.assertIn("unknown is not exhaustion", score.stdout)
        self.assertIn("eligibility=pass; capability=pass; runway=pass; spendPriority=1.2", score.stdout)
        self.assertIn("shadow-only, policy unverified, allowance evidence partial", score.stdout)
        self.assertIn("small samples do not establish a winner", score.stdout)

    def test_shadow_allowance_claims_require_matching_quota_evidence(self):
        route = self.manifest()["route"]
        base = {
            "schema": "fm-routing-shadow.v1", "task_id": "task-one", "decision_id": "decision-one",
            "task_binding": {"spawn_gen": "spawn-1"}, "at": "2030-01-01T00:00:00Z",
            "category": "1", "task_shape": "code-change", "recommended_route": route,
            "explanation": "shadow evidence check",
            "candidates": [{"route": route, "eligibility": "pass", "capability_class_fit": "pass",
                            "runway_feasibility": "pass", "spend_priority": 1,
                            "uncertainty": "none", "explanation": "available"}],
        }
        path = self.dir / "shadow-evidence.json"
        self.write_json(path, base)
        result = self.run_cli("shadow", "--manifest", path, "--shadow-store", self.shadow_store, "--json", ok=False)
        self.assertIn("require quota-axi evidence", json.loads(result.stdout)["error"])
        base["candidates"][0]["allowance_evidence"] = {
            "snapshot_path": str(self.quota_before), "provider": "codex",
            "window_id": "weekly", "percent_remaining": 99}
        self.write_json(path, base)
        result = self.run_cli("shadow", "--manifest", path, "--shadow-store", self.shadow_store, "--json", ok=False)
        self.assertIn("does not match quota-axi evidence", json.loads(result.stdout)["error"])
        unresolved = self.dir / "quota-unresolved.json"
        self.write_quota(unresolved, 100, "2030-01-02T00:00:00Z", provider="agy",
                         status="unresolved", unresolved=["weekly"])
        base["candidates"][0]["allowance_evidence"] = {
            "snapshot_path": str(unresolved), "provider": "agy",
            "window_id": "weekly", "percent_remaining": 100}
        self.write_json(path, base)
        result = self.run_cli("shadow", "--manifest", path, "--shadow-store", self.shadow_store, "--json", ok=False)
        self.assertIn("unresolved allowance evidence", json.loads(result.stdout)["error"])
        base["candidates"][0]["allowance_evidence"] = {
            "snapshot_path": str(self.quota_before), "provider": "codex",
            "window_id": "weekly", "percent_remaining": 100}
        self.write_json(path, base)
        self.run_cli("shadow", "--manifest", path, "--shadow-store", self.shadow_store, "--json")
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        evidence = score["shadow_recommendations"][0]["candidate_evidence"][0]["allowance_evidence"]
        self.assertEqual(evidence["provider"], "codex")
        self.assertEqual(evidence["percent_remaining"], 100)
        self.assertRegex(evidence["source_sha256"], r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main(verbosity=2)
PY
