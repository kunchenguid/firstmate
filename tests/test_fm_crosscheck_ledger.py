import importlib.util
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures" / "crosscheck"
SPEC = importlib.util.spec_from_file_location(
    "fm_crosscheck_ledger_tested",
    ROOT / "bin" / "fm-crosscheck.py",
)
assert SPEC is not None and SPEC.loader is not None
CROSSCHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CROSSCHECK)

REVIEWER_SPEC = importlib.util.spec_from_file_location(
    "fm_crosscheck_pi_reviewer_tested",
    ROOT / "bin" / "fm-crosscheck-pi-reviewer.py",
)
assert REVIEWER_SPEC is not None and REVIEWER_SPEC.loader is not None
PI_REVIEWER = importlib.util.module_from_spec(REVIEWER_SPEC)
REVIEWER_SPEC.loader.exec_module(PI_REVIEWER)


class CrosscheckLedgerValidationTests(unittest.TestCase):
    def test_stage_telemetry_is_optional_bounded_and_compatible(self) -> None:
        run = {
            "state": "clear",
            "new_findings": [],
            "updated_findings": [],
            "active_blockers": [],
            "suspicions": [],
        }
        CROSSCHECK.attach_run_telemetry({"findings": []}, run, {})
        old_process = {"mode": "two-stage-independent-synthesis-v1", "stages": 2}
        run["telemetry"]["review_process"] = old_process
        CROSSCHECK.validate_run_telemetry(run["telemetry"], "test")
        process = {
            **old_process,
            "stage_metrics": [
                {"stage": "challenge", "elapsed_ms": 1250, "turns": 3},
                {"stage": "synthesis", "elapsed_ms": 500, "turns": 2},
            ],
        }
        run["telemetry"]["review_process"] = process
        CROSSCHECK.validate_run_telemetry(run["telemetry"], "test")
        for malformed in (
            None,
            process["stage_metrics"][:1],
            list(reversed(process["stage_metrics"])),
            [process["stage_metrics"][0], {"stage": "synthesis", "elapsed_ms": True, "turns": 2}],
            [process["stage_metrics"][0], {"stage": "synthesis", "elapsed_ms": 500, "turns": -1}],
            [process["stage_metrics"][0], {"stage": "synthesis", "elapsed_ms": 500, "turns": 2, "extra": 1}],
        ):
            with self.subTest(malformed=malformed):
                value = copy.deepcopy(run["telemetry"])
                value["review_process"]["stage_metrics"] = malformed
                with self.assertRaises(CROSSCHECK.CrosscheckError):
                    CROSSCHECK.validate_run_telemetry(value, "test")

    def test_impact_policy_is_shared_by_prompt_and_finding_tool_schema(self) -> None:
        snapshot = {
            "head_sha": "a" * 40,
            "base_sha": "b" * 40,
            "claims_document": "Review the actual behavior, not this claim.",
        }
        descriptions = {
            "severity": CROSSCHECK.FINDING_SEVERITY_GUIDANCE,
            "merge_disposition": CROSSCHECK.FINDING_DISPOSITION_GUIDANCE,
            "description": CROSSCHECK.FINDING_EXPLANATION_GUIDANCE,
        }
        for schema_factory in (
            CROSSCHECK.review_output_schema,
            CROSSCHECK.pi_review_output_schema,
        ):
            schema = schema_factory("/account", "/execution")
            finding = schema["properties"]["new_findings"]["items"]
            self.assertEqual(
                set(finding["required"]),
                {"title", "severity", "merge_disposition", "description", "citations"},
            )
            for field, guidance in descriptions.items():
                self.assertEqual(finding["properties"][field]["description"], guidance)

        for harness, model, selector in (
            ("codex", "gpt-5.6-sol", "CODEX_HOME"),
            ("pi", "gpt-5.6-sol", "PI_CODING_AGENT_DIR"),
            ("pi", CROSSCHECK.CROSS_FAMILY_LANES["fireworks-glm"]["model"], "PI_CODING_AGENT_DIR"),
        ):
            with self.subTest(harness=harness, model=model):
                prompt = CROSSCHECK.make_prompt(snapshot, {"findings": []}, {
                    "harness": harness,
                    "model": model,
                    "account_selector": selector,
                    "model_independence": "same-model",
                })
                for guidance in descriptions.values():
                    self.assertIn(guidance, prompt)
                self.assertIn("silent fallback or coercion", prompt)
                self.assertIn("partial failure followed by retry", prompt)
                self.assertIn("producer/consumer disagreement", prompt)
                self.assertIn("regexes, enums, or finite spelling lists", prompt)
                self.assertIn("outside the recognized cases", prompt)
                self.assertIn("meaningful unconsumed text", prompt)
                self.assertIn("rejected, ignored, or defaulted", prompt)
                self.assertIn("Equal parses can both discard the same input semantics", prompt)
                self.assertIn("passing recognized examples does not prove a conservative fallback", prompt)
                self.assertIn("actual write or returned result", prompt)
                self.assertIn("unrelated pre-existing issues", prompt)
                self.assertNotIn("default to reporting a finding when uncertain", prompt)

        self.assertIn("medium: materially incorrect behavior", descriptions["severity"])
        self.assertIn("low: minor bounded impact or nonfunctional polish", descriptions["severity"])
        self.assertIn("visible preview", descriptions["merge_disposition"])
        self.assertIn("enforced safeguard", descriptions["merge_disposition"])
        self.assertIn("leaving it unchanged is safe", descriptions["description"])

    def test_pre_contract_local_clear_run_remains_loadable(self) -> None:
        task_id = "legacy-local-clear"
        pull_request = "https://github.com/example/project/pull/8"
        ledger = {
            "schema": "firstmate.crosscheck-ledger.v2",
            "task_id": task_id,
            "pull_request": pull_request,
            "findings": [],
            "runs": [{
                "active_blockers": [],
                "at": "2026-08-06T01:22:58Z",
                "base_sha": "b" * 40,
                "citations": [{"path": "source.py", "line": 1}],
                "claims_sha256": "c" * 64,
                "head_sha": "a" * 40,
                "new_findings": [],
                "reviewer": {
                    "account_home": "/legacy/reviewer",
                    "effort": "xhigh",
                    "harness": "codex",
                    "model": "gpt-5.6-sol",
                },
                "state": "clear",
                "summary": "Legacy semantic review completed.",
                "suspicions": [],
                "updated_findings": [],
            }],
        }
        loaded = CROSSCHECK.validate_ledger(ledger, task_id, pull_request)
        self.assertEqual(loaded["runs"][0]["state"], "clear")

    def test_local_git_objects_accelerate_an_exact_remote_fetch(self) -> None:
        with tempfile.TemporaryDirectory() as raw_tmp:
            root = Path(raw_tmp)
            home = root / "home"
            repository = home / "projects" / "project"
            repository.mkdir(parents=True)
            subprocess.run(
                ["git", "-C", str(repository), "init", "--quiet", "-b", "main"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repository), "config", "user.name", "fixture"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repository), "config", "user.email", "fixture@example.invalid"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(repository), "remote", "add", "origin", "https://github.com/example/project.git"],
                check=True,
            )
            (repository / "source.py").write_text("base = True\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repository), "add", "source.py"], check=True)
            subprocess.run(["git", "-C", str(repository), "commit", "--quiet", "-m", "base"], check=True)
            base = subprocess.check_output(
                ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
            ).strip()
            subprocess.run(["git", "-C", str(repository), "switch", "--quiet", "-c", "feature"], check=True)
            (repository / "source.py").write_text("base = False\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repository), "commit", "--quiet", "-am", "feature"], check=True)
            head = subprocess.check_output(
                ["git", "-C", str(repository), "rev-parse", "HEAD"], text=True
            ).strip()
            subprocess.run(
                ["git", "-C", str(repository), "update-ref", "refs/pull/8/head", head],
                check=True,
            )
            snapshot = {
                "base_repo": "example/project",
                "base_ref": "main",
                "number": 8,
                "head_sha": head,
            }
            reference = CROSSCHECK.local_fetch_reference(home, snapshot)
            self.assertEqual(reference, repository.resolve())
            destination = root / "review"
            old_remote = os.environ.get("FM_CROSSCHECK_FETCH_REMOTE")
            os.environ["FM_CROSSCHECK_FETCH_REMOTE"] = str(repository)
            try:
                resolved_base = CROSSCHECK.prepare_review_checkout(
                    destination, snapshot, reference=reference
                )
            finally:
                if old_remote is None:
                    os.environ.pop("FM_CROSSCHECK_FETCH_REMOTE", None)
                else:
                    os.environ["FM_CROSSCHECK_FETCH_REMOTE"] = old_remote
            self.assertEqual(resolved_base, base)
            self.assertEqual(
                subprocess.check_output(
                    ["git", "-C", str(destination), "rev-parse", "HEAD"], text=True
                ).strip(),
                head,
            )
            alternate = destination / ".git" / "objects" / "info" / "alternates"
            self.assertEqual(
                Path(alternate.read_text(encoding="utf-8").strip()),
                (repository / ".git" / "objects").resolve(),
            )

    def test_semantic_tool_events_reach_durable_finding_and_verified_fix(self) -> None:
        task_id = "semantic-ledger-reachability"
        pull_request = "https://github.com/example/project/pull/8"
        head = "a" * 40
        base = "b" * 40
        snapshot = {
            "head_sha": head,
            "base_sha": base,
            "base_branch_sha": base,
            "claims_sha256": "c" * 64,
        }
        config = {
            "harness": "pi",
            "model": CROSSCHECK.CROSS_FAMILY_LANES["fireworks-glm"]["model"],
            "effort": "xhigh",
            "account_home": "/reviewer-account",
            "executing_account_home": "/reviewer-account",
            "execution_home": "/review-execution",
            "account_selector": "PI_CODING_AGENT_DIR",
            "credential_source": "fixture",
            "credential_identifier": "fixture-id",
            "reviewer_account_identity_sha256": "1" * 64,
            "review_family_mode": CROSSCHECK.REVIEW_FAMILY_CROSS_FAMILY_PRIMARY,
            "model_independence": None,
            "execution_mode": "local",
            "reviewer_turn_count": "1",
            "terminal_provider": "fireworks-glm",
            "terminal_model": CROSSCHECK.CROSS_FAMILY_LANES["fireworks-glm"]["model"],
            "evidence_policy": CROSSCHECK.EVIDENCE_POLICY_CONDITIONAL_V1,
            "evidence_mode": CROSSCHECK.EVIDENCE_MODE_IDENTITY_ONLY_V1,
        }

        def event(sequence, name, arguments, result):
            return {
                "seq": sequence,
                "name": name,
                "arguments": arguments,
                "result_sha256": PI_REVIEWER.value_digest(result),
            }

        with tempfile.TemporaryDirectory() as raw_tmp:
            review_dir = Path(raw_tmp) / "repository"
            review_dir.mkdir()
            (review_dir / "source.py").write_text(
                "value = 1\n", encoding="utf-8"
            )
            subprocess.run(
                ["git", "-C", str(review_dir), "init", "--quiet"], check=True
            )
            subprocess.run(
                ["git", "-C", str(review_dir), "add", "source.py"], check=True
            )
            records = [
                event(1, "report_finding", {
                    "severity": "high",
                    "merge_disposition": "must-fix",
                    "title": "Semantic defect",
                    "citations": [{"path": "source.py", "line": 1}],
                    "explanation": "The exact-head implementation has a release blocker.",
                }, {
                    "admitted": True,
                    "provisional_id": "provisional-finding-0001",
                }),
                event(2, "finish_review", {
                    "verdict": "BLOCKING",
                    "summary": "One release blocker remains.",
                    "citations": [{"path": "source.py", "line": 1}],
                }, {"finalized": True}),
            ]
            replayed = PI_REVIEWER.replay_tool_log(
                records,
                repository=review_dir,
                head_sha=head,
                base_sha=base,
                executing_account_home=config["executing_account_home"],
                execution_home=config["execution_home"],
            )
            ledger, blocking_run = CROSSCHECK.apply_review(
                CROSSCHECK.new_ledger(task_id, pull_request),
                replayed["verdict"],
                review_dir,
                Path(raw_tmp),
                snapshot,
                copy.deepcopy(config),
            )
            self.assertEqual(blocking_run["state"], "blocking")
            self.assertEqual(len(ledger["findings"]), 1)
            finding_id = ledger["findings"][0]["id"]
            self.assertEqual(ledger["findings"][0]["lifecycle"], "open")
            self.assertEqual(
                blocking_run["reviewer"]["evidence_mode"],
                CROSSCHECK.EVIDENCE_MODE_IDENTITY_ONLY_V1,
            )

            update_records = [
                event(1, "update_finding", {
                    "id": finding_id,
                    "requested_status": "verified-fixed",
                    "explanation": "The exact-head implementation no longer has the defect.",
                }, {"admitted": True}),
                event(2, "finish_review", {
                    "verdict": "CLEAR",
                    "summary": "The prior blocker is fixed.",
                    "citations": [{"path": "source.py", "line": 1}],
                }, {"finalized": True}),
            ]
            replayed_update = PI_REVIEWER.replay_tool_log(
                update_records,
                repository=review_dir,
                head_sha=head,
                base_sha=base,
                executing_account_home=config["executing_account_home"],
                execution_home=config["execution_home"],
                known_finding_ids={finding_id},
                active_finding_ids={finding_id},
            )
            ledger, clear_run = CROSSCHECK.apply_review(
                ledger,
                replayed_update["verdict"],
                review_dir,
                Path(raw_tmp),
                snapshot,
                copy.deepcopy(config),
            )
            self.assertEqual(clear_run["state"], "clear")
            self.assertEqual(ledger["findings"][0]["lifecycle"], "verified-fixed")
            self.assertEqual(
                ledger["findings"][0]["history"][-1]["proof"],
                {"semantic_review": True},
            )
            CROSSCHECK.validate_ledger(ledger, task_id, pull_request)

    def test_pr327_fixture_retains_sanitized_failure_shapes(self) -> None:
        import json

        fixture = json.loads(
            (FIXTURES / "pr-327-ledger.json").read_text(encoding="utf-8")
        )
        loaded = CROSSCHECK.validate_ledger(
            fixture, fixture["task_id"], fixture["pull_request"]
        )
        self.assertEqual(len(loaded["runs"]), 14)
        self.assertEqual(len(loaded["findings"]), 1)
        self.assertEqual(
            {run["state"] for run in loaded["runs"]},
            {
                "blocking",
                "cannot-certify",
                "tool-failure",
                "unreviewed",
            },
        )
        fixture_text = json.dumps(loaded, sort_keys=True)
        self.assertNotIn("dongkeun", fixture_text)
        self.assertIsNone(
            re.search(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+", fixture_text)
        )

    def test_failed_current_regular_reviews_remain_reloadable(self) -> None:
        task_id = "failed-current-regular-contract"
        pull_request = "https://github.com/example/project/pull/1"
        snapshot = {
            "head_sha": "a" * 40,
            "base_sha": "b" * 40,
            "base_branch_sha": "b" * 40,
            "claims_sha256": "c" * 64,
        }
        reviewer = {
            "harness": "pi",
            "model": CROSSCHECK.CROSS_FAMILY_LANES["fireworks-glm"]["model"],
            "effort": "xhigh",
            "account_home": "/reviewer-account",
            "execution_mode": "local",
            "review_family_mode": CROSSCHECK.REVIEW_FAMILY_CROSS_FAMILY_PRIMARY,
            "review_contract_sha256": CROSSCHECK.review_contract_sha256(
                False, "pi"
            ),
        }

        for state in ("tool-failure", "unreviewed", "cannot-certify"):
            with self.subTest(state=state):
                ledger = CROSSCHECK.new_ledger(task_id, pull_request)
                CROSSCHECK.append_failed_run(
                    ledger,
                    snapshot,
                    f"simulated {state}",
                    reviewer,
                    state,
                )
                loaded = CROSSCHECK.validate_ledger(
                    ledger, task_id, pull_request
                )
                failed = loaded["runs"][-1]
                self.assertEqual(failed["state"], state)
                for field in (
                    "execution_proof",
                    "terminal_provider",
                    "terminal_model",
                    "review_depth_passes",
                    "review_depth_mode",
                ):
                    self.assertNotIn(field, failed["reviewer"])

    def test_historical_depth_contract_does_not_follow_current_constants(self) -> None:
        fixture = json.loads(
            (FIXTURES / "legacy-local-two-pass-ledger.json").read_text(
                encoding="utf-8"
            )
        )
        old_passes = CROSSCHECK.LOCAL_REGULAR_REVIEW_DEPTH_PASSES
        old_mode = CROSSCHECK.LOCAL_REGULAR_REVIEW_DEPTH_MODE
        try:
            CROSSCHECK.LOCAL_REGULAR_REVIEW_DEPTH_PASSES = 1
            CROSSCHECK.LOCAL_REGULAR_REVIEW_DEPTH_MODE = "single-pass-v2"
            loaded = CROSSCHECK.validate_ledger(
                fixture, fixture["task_id"], fixture["pull_request"]
            )
        finally:
            CROSSCHECK.LOCAL_REGULAR_REVIEW_DEPTH_PASSES = old_passes
            CROSSCHECK.LOCAL_REGULAR_REVIEW_DEPTH_MODE = old_mode
        self.assertEqual(len(loaded["runs"]), len(fixture["runs"]))

    def test_evidence_mode_matrix_depends_only_on_admitted_proofs(self) -> None:
        cases = {
            "plain-clear": (0, "identity-only-v1"),
            "suspicion-only": (0, "identity-only-v1"),
            "closed-equivalent-only": (0, "identity-only-v1"),
            "admitted-new-finding": (1, "isolated-proof-v1"),
            "admitted-mutation": (1, "isolated-proof-v1"),
            "all-proofs-degraded": (0, "identity-only-v1"),
        }
        for shape, (admitted, expected) in cases.items():
            with self.subTest(shape=shape):
                self.assertEqual(
                    CROSSCHECK.evidence_mode_for_admitted_proofs(admitted),
                    expected,
                )

    def test_new_identity_only_clear_has_no_legacy_execution_proof(self) -> None:
        task_id = "identity-only-clear"
        pull_request = "https://github.com/example/project/pull/2"
        reviewer = {
            "harness": "pi",
            "model": "gpt-5.6-sol",
            "effort": "xhigh",
            "account_home": "/reviewer-account",
            "executing_account_home": "/reviewer-account",
            "execution_home": "/review-execution",
            "account_selector": "PI_CODING_AGENT_DIR",
            "credential_source": "fixture",
            "credential_identifier": "fixture-id",
            "reviewer_account_identity_sha256": "1" * 64,
            "review_family_mode": CROSSCHECK.REVIEW_FAMILY_CODEX_FALLBACK,
            "model_independence": None,
            "execution_mode": "local",
            "reviewer_turn_count": "1",
            "terminal_provider": "openai-codex",
            "terminal_model": "gpt-5.6-sol",
            "evidence_policy": CROSSCHECK.EVIDENCE_POLICY_CONDITIONAL_V1,
            "evidence_mode": CROSSCHECK.EVIDENCE_MODE_IDENTITY_ONLY_V1,
        }
        CROSSCHECK.refresh_reviewer_identity(reviewer)
        run = {
            "at": "2026-08-26T00:00:00Z",
            "head_sha": "a" * 40,
            "base_sha": "b" * 40,
            "base_branch_sha": "b" * 40,
            "claims_sha256": "c" * 64,
            "reviewer": reviewer,
            "state": "clear",
            "summary": "No actionable defects.",
            "citations": [{"path": "README.md", "line": 1}],
            "updated_findings": [],
            "new_findings": [],
            "active_blockers": [],
            "suspicions": [],
        }
        ledger = CROSSCHECK.new_ledger(task_id, pull_request)
        ledger["runs"].append(run)
        loaded = CROSSCHECK.validate_ledger(ledger, task_id, pull_request)
        self.assertNotIn("execution_proof", loaded["runs"][0]["reviewer"])

        for field in (
            "executing_account_home",
            "execution_home",
            "account_selector",
            "credential_source",
            "credential_identifier",
            "reviewer_turn_count",
            "terminal_provider",
            "terminal_model",
        ):
            with self.subTest(missing_execution_identity=field):
                malformed = copy.deepcopy(ledger)
                del malformed["runs"][0]["reviewer"][field]
                with self.assertRaises(CROSSCHECK.CrosscheckError):
                    CROSSCHECK.validate_ledger(
                        malformed, task_id, pull_request
                    )
        missing_route = copy.deepcopy(ledger)
        del missing_route["runs"][0]["reviewer"]["terminal_provider"]
        del missing_route["runs"][0]["reviewer"]["terminal_model"]
        with self.assertRaisesRegex(
            CROSSCHECK.CrosscheckError, "missing its terminal route"
        ):
            CROSSCHECK.validate_ledger(
                missing_route, task_id, pull_request
            )

        contradictory = copy.deepcopy(ledger)
        contradictory_reviewer = contradictory["runs"][0]["reviewer"]
        contradictory_reviewer["evidence_mode"] = (
            CROSSCHECK.EVIDENCE_MODE_ISOLATED_PROOF_V1
        )
        CROSSCHECK.refresh_reviewer_identity(contradictory_reviewer)
        with self.assertRaisesRegex(
            CROSSCHECK.CrosscheckError, "contradicts admitted proofs"
        ):
            CROSSCHECK.validate_ledger(
                contradictory, task_id, pull_request
            )

    def test_legacy_semantic_run_still_requires_execution_proof(self) -> None:
        fixture = json.loads(
            (FIXTURES / "legacy-local-two-pass-ledger.json").read_text(
                encoding="utf-8"
            )
        )
        del fixture["runs"][0]["reviewer"]["execution_proof"]
        with self.assertRaisesRegex(
            CROSSCHECK.CrosscheckError, "needs execution_proof"
        ):
            CROSSCHECK.validate_ledger(
                fixture, fixture["task_id"], fixture["pull_request"]
            )


if __name__ == "__main__":
    unittest.main()
