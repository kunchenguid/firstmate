import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "fm_crosscheck_ledger_tested",
    ROOT / "bin" / "fm-crosscheck.py",
)
assert SPEC is not None and SPEC.loader is not None
CROSSCHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CROSSCHECK)


class CrosscheckLedgerValidationTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
