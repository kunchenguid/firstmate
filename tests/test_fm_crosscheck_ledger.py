import importlib.util
import copy
import json
from pathlib import Path
import re
import tempfile
import time
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


class CrosscheckLedgerValidationTests(unittest.TestCase):
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

    def test_semantically_discarded_clean_evidence_stays_identity_only(self) -> None:
        task_id = "discarded-clean-evidence"
        pull_request = "https://github.com/example/project/pull/3"
        snapshot = {
            "head_sha": "a" * 40,
            "base_sha": "b" * 40,
            "base_branch_sha": "b" * 40,
            "claims_sha256": "c" * 64,
        }
        config = {
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

        class EvidenceExecutor:
            batch_deadline = time.monotonic() + 300

            def __init__(self) -> None:
                self.calls = 0

            def __call__(self, value, *_args, **_kwargs):
                self.calls += 1
                return {
                    "test_path": value["test_path"],
                    "command": value["command"],
                    "expected_exit": value["expected_exit"],
                    "actual_exit": value["expected_exit"],
                    "output_contains": value["output_contains"],
                    "output": "fixture clean execution",
                }

        reproduction = {
            "test_path": ".crosscheck/reproductions/proof.sh",
            "command": "bash .crosscheck/reproductions/proof.sh",
            "expected_exit": 0,
            "output_contains": "fixture",
        }
        with tempfile.TemporaryDirectory() as raw_tmp:
            review_dir = Path(raw_tmp)
            (review_dir / "source.py").write_text("value = 1\n", encoding="utf-8")
            proof_root = review_dir / "proofs"
            proof_root.mkdir()

            # A clean reproduction cannot become evidence for an inadmissible
            # new finding whose citation is outside the file.
            executor = EvidenceExecutor()
            ledger = CROSSCHECK.new_ledger(task_id, pull_request)
            review = {
                "head_sha": snapshot["head_sha"],
                "executing_account_home": config["executing_account_home"],
                "execution_home": config["execution_home"],
                "summary": "One discarded candidate.",
                "citations": [],
                "finding_updates": [],
                "new_findings": [{
                    "title": "Discarded candidate",
                    "severity": "blocking",
                    "description": "The citation is invalid.",
                    "citations": [{"path": "source.py", "line": 9}],
                    "reproduction": reproduction,
                }],
                "suspicions": [],
            }
            applied, run = CROSSCHECK.apply_review(
                ledger,
                review,
                review_dir,
                proof_root,
                snapshot,
                copy.deepcopy(config),
                evidence_executor=executor,
            )
            self.assertEqual(executor.calls, 1)
            self.assertEqual(run["state"], "blocking")
            self.assertEqual(
                run["reviewer"]["evidence_mode"],
                CROSSCHECK.EVIDENCE_MODE_IDENTITY_ONLY_V1,
            )
            CROSSCHECK.validate_ledger(applied, task_id, pull_request)

            # A verified-fixed request whose mutation proof degrades does not
            # promote its superseded reproduction into certification.
            executor = EvidenceExecutor()
            ledger = CROSSCHECK.new_ledger(task_id, pull_request)
            ledger["findings"].append({
                "id": "cc-aaaaaaaaaaaa",
                "lifecycle": "open",
                "title": "Existing defect",
                "severity": "blocking",
                "description": "Still open.",
                "citations": [{"path": "source.py", "line": 1}],
                "history": [{
                    "at": "2026-08-26T00:00:00Z",
                    "head_sha": snapshot["head_sha"],
                    "status": "open",
                    "note": "Seeded fixture.",
                    "proof": None,
                }],
            })
            review["new_findings"] = []
            review["finding_updates"] = [{
                "id": "cc-aaaaaaaaaaaa",
                "status": "verified-fixed",
                "note": "Candidate closure.",
                "reproduction": reproduction,
                "mutation_proof": {
                    "test_path": "tests/test_source.py",
                    "test_invocation": {"runner": "pytest", "arguments": []},
                    "mutation_patch_path": ".crosscheck/mutations/revert.patch",
                },
                "equivalent_to": None,
            }]

            def reject_mutation(*_args, **_kwargs):
                raise CROSSCHECK.CrosscheckError("fixture mutation refused")

            applied, run = CROSSCHECK.apply_review(
                ledger,
                review,
                review_dir,
                proof_root,
                snapshot,
                copy.deepcopy(config),
                evidence_executor=executor,
                mutation_executor=reject_mutation,
            )
            self.assertEqual(executor.calls, 1)
            self.assertEqual(
                run["reviewer"]["evidence_mode"],
                CROSSCHECK.EVIDENCE_MODE_IDENTITY_ONLY_V1,
            )
            CROSSCHECK.validate_ledger(applied, task_id, pull_request)

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
