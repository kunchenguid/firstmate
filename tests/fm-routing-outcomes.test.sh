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
        self.write_quota(self.quota_after, 95, "2030-01-02T00:00:00Z",
                         generated_at="2030-01-01T00:02:00Z")

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
                 assistant_model="gpt-5.6-luna", assistant_provider="openai-codex",
                 session_id="session-1", second_response=False):
        rows = [{"type": "session", "id": session_id, "timestamp": "2030-01-01T00:00:00Z"}]
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
        if extra_request is not None:
            paired = copy.deepcopy(assistant)
            paired["id"] = "assistant-extra"
            paired["parentId"] = "request-2"
            paired["timestamp"] = "2030-01-01T00:00:04Z"
            rows.append(paired)
        if second_response:
            second = copy.deepcopy(assistant)
            second["id"] = "assistant-2"
            second["timestamp"] = "2030-01-01T00:00:04Z"
            rows.append(second)
        if duplicate:
            rows.append(copy.deepcopy(assistant))
        path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")

    def write_quota(self, path, remaining, reset, *, provider="codex", status="known", unresolved=None,
                    effective_availability=None, generated_at="2030-01-01T00:00:00Z"):
        row = {
            "provider": provider,
            "windows": [{"id": "weekly", "label": "week", "kind": "weekly",
                         "resetsAt": reset, "percentRemaining": remaining}],
            "quotaSemantics": {"status": status,
                               "effectiveAvailability": effective_availability or []},
        }
        if unresolved is not None:
            row["quotaSemantics"]["unresolvedWindowIds"] = unresolved
        self.write_json(path, {"schemaVersion": 5, "generatedAt": generated_at, "providers": [row]})

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
                        "overhead": {"duration_ms": 3, "tokens": None,
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
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        quota = score["observations"][0]["quota"]
        self.assertEqual(quota["attribution"], "exclusive")
        self.assertFalse(quota["concurrent_activity"])
        self.assertTrue(quota["attempt_bracketed"])
        self.assertEqual(quota["window_deltas"][0]["attributed_consumption_percent_points"], 5)
        markdown = self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "markdown").stdout
        self.assertIn("attribution=exclusive; concurrent=false; reset_crossed=false; attempt_bracketed=true; before_semantics=known; after_semantics=known", markdown)
        self.assertIn("weekly: 100 -> 95; consumption=5 pp; reset_crossed=false", markdown)

    def test_attempt_phase_and_pi_request_alias_are_rejected(self):
        shadow_attempt = self.manifest()
        shadow_attempt["phase"] = "shadow"
        result = self.import_manifest(shadow_attempt, ok=False)
        self.assertIn("phase must be measurement", json.loads(result.stdout)["error"])

        rows = [json.loads(line) for line in self.pi.read_text().splitlines()]
        request = next(row for row in rows if row.get("customType") == "fm-routing-request")
        request["data"]["requestedModel"] = request["data"].pop("selectedModel")
        self.pi.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        result = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("unsupported requestedModel", json.loads(result.stdout)["error"])

    def test_pi_request_schema_and_response_pairing_are_required(self):
        rows = [json.loads(line) for line in self.pi.read_text().splitlines()]
        request = next(row for row in rows if row.get("customType") == "fm-routing-request")
        request["data"]["schema"] = "fm-routing-request.v2"
        self.pi.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        result = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("data.schema must be fm-routing-request.v1", json.loads(result.stdout)["error"])

        self.write_pi(self.pi, extra_request={"requestSequence": 2})
        rows = [json.loads(line) for line in self.pi.read_text().splitlines()]
        rows = [row for row in rows if row.get("parentId") != "request-2"]
        self.pi.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        result = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("routing request without an assistant response", json.loads(result.stdout)["error"])

        self.write_pi(self.pi)
        rows = [json.loads(line) for line in self.pi.read_text().splitlines()]
        assistant = next(row for row in rows if row.get("type") == "message")
        assistant["parentId"] = "unowned-request"
        self.pi.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")
        result = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("without a matching routing request", json.loads(result.stdout)["error"])

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

    def test_scorecard_keeps_attempt_observations_separate(self):
        manifest = self.manifest()
        manifest["billing"]["actual_incremental_usd"] = 0.2
        manifest["grading"]["overhead"].update({"duration_ms": 3, "actual_incremental_usd": 0.05})
        self.import_manifest(manifest)
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        observation = score["observations"][0]
        self.assertEqual(observation["aggregation_status"], "individual-attempt-only")
        self.assertEqual(observation["elapsed_ms"], 60000)
        self.assertEqual(observation["actual_incremental_usd"], 0.2)
        self.assertEqual(observation["grader_overhead"]["actual_incremental_usd"], 0.05)
        self.assertEqual(score["accepted_journey_aggregation"], "deferred-across-task-incarnations")
        self.assertEqual(score["routes"][0]["fixed_subscription_usd"]["aggregation"], "not-applicable")

    def test_scorecard_separates_route_tiers(self):
        self.import_manifest(self.manifest(attempt="attempt-one"))
        self.write_pi(self.pi, session_id="session-2")
        second = self.manifest(attempt="attempt-two")
        second["route"].update({"auth_category": "api-key", "context_tier": "extended",
                                "service_tier": "priority"})
        self.import_manifest(second)
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        self.assertEqual(len(score["routes"]), 2)
        self.assertEqual({(row["auth_category"], row["context_tier"], row["service_tier"])
                          for row in score["routes"]},
                         {("subscription", "all", "standard"), ("api-key", "extended", "priority")})
        self.assertTrue(all(row["attempts"] == 1 for row in score["routes"]))
        self.assertTrue(any("auth=api-key, context=extended, service=priority" in row["route"]
                            for row in score["routes"]))

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
        self.write_pi(self.pi, spawn_gen="spawn-2", session_id="session-2")
        self.import_manifest(self.manifest(spawn_gen="spawn-2"))
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        self.assertEqual(score["attempt_count"], 2)
        self.assertEqual(score["task_count"], 1)
        self.assertEqual(score["task_incarnation_count"], 2)
        self.assertEqual({row["spawn_gen"] for row in score["observations"]}, {"spawn-1", "spawn-2"})
        self.assertEqual(score["accepted_journey_aggregation"], "deferred-across-task-incarnations")
        markdown = self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "markdown").stdout
        self.assertIn("across 1 tasks and 2 task incarnations", markdown)

    def test_native_session_cannot_be_reused_across_attempts(self):
        self.import_manifest(self.manifest(attempt="attempt-one"))
        reused = self.manifest(attempt="attempt-two", outcome="unresolved")
        result = self.import_manifest(reused, ok=False)
        self.assertIn("already attached to another attempt", json.loads(result.stdout)["error"])
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        self.assertEqual(score["attempt_count"], 1)
        self.assertEqual(score["routes"][0]["tokens"]["input"]["known_total"], 100)

    def test_duplicate_native_message_id_is_not_double_counted(self):
        self.write_pi(self.pi, duplicate=True)
        self.import_manifest(self.manifest())
        self.assertEqual(self.latest_record()["native"]["tokens"]["input"], 100)

    def test_multi_turn_single_model_keeps_exact_route_scope(self):
        self.write_pi(self.pi, second_response=True)
        self.import_manifest(self.manifest())
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        self.assertEqual(score["routes"][0]["route"],
                         "pi/openai-codex/gpt-5.6-luna/max [auth=subscription, context=all, service=standard]")
        self.assertEqual(score["routes"][0]["measurement_scope"], "attempt-route")
        self.assertEqual(score["routes"][0]["tokens"]["input"]["known_total"], 200)

    def test_missing_provider_effort_stays_unknown_and_requirement_blocks(self):
        self.write_pi(self.pi, effort=None)
        blocked = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("effective effort requirement not proven", json.loads(blocked.stdout)["error"])
        allowed = self.manifest()
        allowed["requirements"] = None
        allowed["outcome"] = "unresolved"
        self.import_manifest(allowed)
        self.assertIsNone(self.latest_record()["native"]["effective_effort"])
        self.assertEqual(self.latest_record()["native"]["completeness"]["request_payload"], "complete")

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
        markdown = self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "markdown").stdout
        self.assertIn("before_semantics=unknown; after_semantics=unknown", markdown)

    def test_reset_and_concurrent_activity_prevent_quota_attribution(self):
        self.write_quota(self.quota_after, 100, "2030-01-09T00:00:00Z")
        manifest = self.manifest()
        manifest["quota"]["concurrent_activity"] = True
        self.import_manifest(manifest)
        quota = self.latest_record()["quota"]
        self.assertTrue(quota["reset_crossed"])
        self.assertIsNone(quota["window_deltas"][0]["attributed_consumption_percent_points"])

    def test_quota_chronology_and_increases_do_not_create_consumption(self):
        self.write_quota(self.quota_before, 95, "2030-01-02T00:00:00Z",
                         generated_at="2030-01-01T00:01:00Z")
        self.write_quota(self.quota_after, 90, "2030-01-02T00:00:00Z",
                         generated_at="2030-01-01T00:00:00Z")
        reversed_result = self.import_manifest(self.manifest(), ok=False)
        self.assertIn("must not precede", json.loads(reversed_result.stdout)["error"])

        self.write_quota(self.quota_before, 95, "2030-01-02T00:00:00Z",
                         generated_at="2030-01-01T00:00:00Z")
        self.write_quota(self.quota_after, 100, "2030-01-02T00:00:00Z",
                         generated_at="2030-01-01T00:01:00Z")
        self.import_manifest(self.manifest())
        delta = self.latest_record()["quota"]["window_deltas"][0]
        self.assertEqual(delta["before_percent_remaining"], 95)
        self.assertEqual(delta["after_percent_remaining"], 100)
        self.assertIsNone(delta["attributed_consumption_percent_points"])

    def test_quota_snapshots_must_bracket_attempt_for_attribution(self):
        self.write_quota(self.quota_before, 100, "2030-01-02T00:00:00Z",
                         generated_at="2029-12-31T23:00:00Z")
        self.write_quota(self.quota_after, 95, "2030-01-02T00:00:00Z",
                         generated_at="2029-12-31T23:01:00Z")
        self.import_manifest(self.manifest())
        quota = self.latest_record()["quota"]
        self.assertFalse(quota["attempt_bracketed"])
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
        result = self.import_manifest(manifest, ok=False)
        self.assertIn("record this receipt as an unresolved observation", json.loads(result.stdout)["error"])
        manifest["outcome"] = "unresolved"
        self.import_manifest(manifest)
        native = self.latest_record()["native"]
        self.assertEqual(native["tokens"]["input"], 14)
        self.assertIsNone(native["effective_effort"])
        self.assertEqual(len(native["models"]), 2)
        self.assertNotIn("PRIVATE RESPONSE", self.store.read_text())
        score = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        self.assertIn("whole-session-multi-model:claude-haiku-4-5+claude-sonnet-5",
                      score["routes"][0]["route"])
        self.assertEqual(score["routes"][0]["measurement_scope"], "whole-session")
        self.assertEqual(score["observations"][0]["outcome"], "unresolved")
        self.assertEqual(score["observations"][0]["outcome_authority"], "operator-observation")

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
        manifest["outcome"] = "unresolved"
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
            "agy/google/requested-only:gemini-3.8-flash-medium/requested-only:medium "
            "[auth=oauth, context=all, service=standard]")

    def test_agy_effort_is_bound_to_latest_model_resolution(self):
        receipt = self.dir / "agy-mixed-resolution.json"
        log = self.dir / "agy-mixed-resolution.log"
        self.write_json(receipt, {"conversation_id": "agy-three", "duration_seconds": 1,
                                  "num_turns": 1, "status": "SUCCESS",
                                  "usage": {"input_tokens": 2, "output_tokens": 1,
                                            "thinking_tokens": 0, "cache_read_tokens": 0,
                                            "total_tokens": 3}})
        log.write_text(
            "Resolving model gemini-a\n"
            "Propagating selected model override to backend: label=\"Gemini A (Medium)\"\n"
            "Resolving model gemini-b\n",
            encoding="utf-8")
        manifest = self.manifest(receipt={"kind": "agy-result", "path": str(receipt),
                                         "native_log_path": str(log),
                                         "requested_model": "gemini-b", "requested_effort": "high"})
        manifest["route"].update({"harness": "agy", "provider": "google",
                                  "auth_category": "oauth", "requested_model": "gemini-b",
                                  "requested_effort": "high"})
        manifest["requirements"] = {"effective_model": "gemini-b"}
        manifest["outcome"] = "unresolved"
        self.bind_task("task-one", harness="agy")
        self.import_manifest(manifest)
        native = self.latest_record()["native"]
        self.assertEqual(native["effective_model"], "gemini-b")
        self.assertIsNone(native["effective_effort"])

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
        self_ref = self.manifest(attempt="attempt-self")
        self_ref["handoff"] = {"alternative_attempt_id": "attempt-self", "side_effects": "none",
                               "quality_preserved": True, "privacy_preserved": True,
                               "reconciliation_receipt": "no external action was available"}
        result = self.import_manifest(self_ref, ok=False)
        self.assertIn("different attempt", json.loads(result.stdout)["error"])
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
            self.write_pi(self.pi, task=f"task-{number}", session_id=f"session-{number}")
            manifest["comparison"] = {"pair_id": f"pair-{number}", "low_risk": True,
                                      "time_critical": False, "private_external_action": False,
                                      "external_action": False}
            self.import_manifest(manifest)
        manifest = self.manifest(task="task-three", attempt="attempt-three")
        self.write_pi(self.pi, task="task-three", session_id="session-3")
        manifest["comparison"] = {"pair_id": "pair-three", "low_risk": True,
                                  "time_critical": False, "private_external_action": False,
                                  "external_action": False}
        result = self.import_manifest(manifest, ok=False)
        self.assertIn("already has two comparison pairs", json.loads(result.stdout)["error"])

    def test_shadow_records_all_candidate_uncertainty_without_ranking(self):
        self.write_quota(
            self.quota_before, 100, "2030-01-02T00:00:00Z",
            effective_availability=[{
                "scope": "all_models", "status": "known", "effectivePercentRemaining": 12,
                "selection": {"status": "known", "spendPriority": -0.4},
                "runway": {"status": "projected_exhaustion", "usableRunwaySeconds": 900,
                            "projectionConfidence": "established"},
            }])
        self.write_quota(
            self.quota_after, None, "2030-01-02T00:00:00Z",
            provider="claude", status="unknown")
        route_one = self.manifest()["route"]
        route_two = copy.deepcopy(route_one)
        route_two.update({"harness": "claude", "provider": "anthropic",
                          "requested_model": "claude-sonnet-5", "requested_effort": "high"})
        route_three = copy.deepcopy(route_one)
        route_three.update({"harness": "agy", "provider": "google",
                            "requested_model": "gemini-flash-3.8", "requested_effort": "high"})
        shadow = {
            "schema": "fm-routing-shadow.v1", "task_id": "task-one", "decision_id": "decision-one",
            "task_binding": {"spawn_gen": "spawn-1"},
            "at": "2030-01-01T00:00:00Z", "category": "1", "task_shape": "code-change",
            "candidates": [
                {"route": route_one, "eligibility": "pass", "capability_class_fit": "pass",
                 "runway_feasibility": "pass", "spend_priority": 1.2,
                 "quota_evidence": {"snapshot_path": str(self.quota_before),
                                    "provider": "codex"},
                 "uncertainty": "none observed", "explanation": "known headroom after fit gates"},
                {"route": route_two, "eligibility": "unknown", "capability_class_fit": "pass",
                 "runway_feasibility": "unknown", "spend_priority": None,
                 "quota_evidence": {"snapshot_path": str(self.quota_after),
                                    "provider": "claude"},
                 "uncertainty": "refreshable auth was not refreshed", "explanation": "unknown is not exhaustion"},
                {"route": route_three, "eligibility": "unknown", "capability_class_fit": "unknown",
                 "runway_feasibility": "unknown", "spend_priority": None,
                 "uncertainty": "agy quota semantics remain unresolved", "explanation": "no native quota snapshot"},
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
        self.assertIn("heuristic eligibility=pass; capability=pass; runway=pass; spendPriority=1.2", score.stdout)
        self.assertIn("shadow-only heuristic", score.stdout)
        self.assertIn("raw quota codex at 2030-01-01T00:00:00Z (weekly=100)", score.stdout)
        self.assertIn(
            'native quota semantics={"effectiveAvailability":[{"effectivePercentRemaining":12,'
            '"runway":{"projectionConfidence":"established","status":"projected_exhaustion",'
            '"usableRunwaySeconds":900},"scope":"all_models","selection":{"spendPriority":-0.4,'
            '"status":"known"},"status":"known"}],"status":"known"}',
            score.stdout)
        self.assertIn("spendPriority=unknown; raw quota claude at 2030-01-01T00:00:00Z (weekly=unknown)",
                      score.stdout)
        self.assertIn("no quota snapshot; native quota semantics=unknown", score.stdout)
        self.assertNotIn("None", score.stdout)
        data = json.loads(self.run_cli(
            "scorecard", "--store", self.store, "--shadow-store", self.shadow_store,
            "--format", "json").stdout)
        recommendation = data["shadow_recommendations"][0]
        evidence = recommendation["candidate_evidence"][0]["quota_evidence"]
        self.assertEqual(recommendation["recommendation_status"], "heuristic")
        self.assertEqual(recommendation["candidate_evidence"][1]["judgment_status"], "heuristic")
        self.assertIsNone(recommendation["candidate_evidence"][2]["quota_evidence"])
        self.assertEqual(evidence["provider"], "codex")
        self.assertEqual(evidence["windows"][0]["percentRemaining"], 100)
        self.assertRegex(evidence["source_sha256"], r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main(verbosity=2)
PY
