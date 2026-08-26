from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def run_behavior_suite(script: str, marker: str) -> None:
    result = subprocess.run(
        ["bash", script],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=300,
    )
    assert result.returncode == 0, result.stdout
    assert marker in result.stdout, result.stdout


def test_local_required_ci_coverage_contract() -> None:
    run_behavior_suite(
        "tests/fm-azure-runner.test.sh",
        "# fm-azure-runner.test.sh: all assertions passed",
    )


def test_quiet_working_step_has_positive_liveness_signal() -> None:
    run_behavior_suite(
        "tests/fm-nm-step-liveness.test.sh",
        "ok - regression: a one-shot call proves a quiet working step alive from child turnover",
    )
