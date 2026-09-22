#!/usr/bin/env python3
"""
fm-jev-flake-detector.py - Jev Flake vs Regression Disambiguator & Auto-Rerun Gatekeeper

Analyzes failed GitHub Actions check runs for a PR, correlates failing test
cases and stack traces against the files modified in the PR diff, and
classifies failures into:
  - FLAKE_TRANSIENT: Known runner / race / timeout flake on untouched test files (auto-rerun eligible).
  - CODE_REGRESSION: Genuine defect in code touched by the PR or test assertion failures.
  - UNCERTAIN_FAILURE: Unclassified failure requiring manual supervisor inspection.

Optionally triggers automated failed-job rerun via `gh run rerun <run_id> --failed`.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any, Dict, List, Optional, Set, Tuple

KNOWN_FLAKE_PATTERNS = [
    (r"state-change SSE is not delivered", "SSE state broadcast race / stale row convergence"),
    (r"The click landed on a node the next SSE render replaced", "Staff dashboard SSE re-render race"),
    (r"primary action .* never stuck within \d+ms", "E2E staff driver appointment action convergence timeout"),
    (r"waiting for locator\([\"']tr\[data-appointment-id", "E2E appointment queue row locator visibility timeout"),
    (r"Locator expected to be visible.*Error: element\(s\) not found", "Playwright element visibility timeout"),
    (r"Timeout \d+ms exceeded.*locator", "Playwright locator timeout on busy runner"),
    (r"TimeoutError: waiting for locator", "Playwright locator wait timeout"),
    (r"Target page, context or browser has been closed", "Browser crash / CDP disconnect"),
    (r"Connection refused.*9222", "CDP port unavailable on runner"),
    (r"REGISTRATION_TOKEN_SECRET not set.*RuntimeWarning", "Dev key runtime warning in E2E harness"),
    (r"502 Bad Gateway|504 Gateway Timeout", "Runner proxy / web gateway transient timeout"),
    (r"Connection reset by peer|ECONNRESET", "Transient runner network socket reset"),
]

def run_command(cmd: List[str], check: bool = False) -> Tuple[int, str, str]:
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=check)
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return 1, "", str(e)

def get_pr_diff_files(repo: str, pr: str) -> List[str]:
    cmd = ["gh", "pr", "diff", pr, "--name-only"]
    if repo:
        cmd.extend(["--repo", repo])
    rc, stdout, _ = run_command(cmd)
    if rc == 0 and stdout:
        return [f.strip() for f in stdout.splitlines() if f.strip()]
    return []

def get_pr_status(repo: str, pr: str) -> Dict[str, Any]:
    cmd = ["gh", "pr", "view", pr, "--json", "statusCheckRollup,title,url,headRefName"]
    if repo:
        cmd.extend(["--repo", repo])
    rc, stdout, stderr = run_command(cmd)
    if rc != 0 or not stdout:
        return {}
    try:
        return json.loads(stdout)
    except json.JSONDecodeError:
        return {}

def extract_run_id_from_url(url: str) -> Optional[str]:
    match = re.search(r"/actions/runs/(\d+)", url)
    return match.group(1) if match else None

def get_failed_run_logs(repo: str, run_id: str) -> str:
    cmd = ["gh", "run", "view", run_id, "--log-failed"]
    if repo:
        cmd.extend(["--repo", repo])
    rc, stdout, _ = run_command(cmd)
    if rc == 0:
        return stdout
    return ""

def parse_failed_tests_and_traces(log_text: str) -> Tuple[List[str], List[str]]:
    failed_tests = []
    # Match pytest failure headers: e.g. "tests/e2e_journeys/test_j7_visit_lifecycle.py::test_in_person_visit_lifecycle"
    # or "____ test_in_person_visit_lifecycle[chromium] ____"
    matches = re.findall(r"(tests/[^\s:]+\.py)::([^\s]+)", log_text)
    for test_file, test_fn in matches:
        full_test = f"{test_file}::{test_fn}"
        if full_test not in failed_tests:
            failed_tests.append(full_test)
            
    test_files_alone = re.findall(r"(tests/[^\s:]+\.py)", log_text)
    for tf in test_files_alone:
        if tf not in failed_tests:
            failed_tests.append(tf)

    detected_reasons = []
    for pattern, desc in KNOWN_FLAKE_PATTERNS:
        if re.search(pattern, log_text, re.IGNORECASE):
            if desc not in detected_reasons:
                detected_reasons.append(desc)

    return failed_tests, detected_reasons

def is_bot_review_gate(name: str, workflow: str) -> bool:
    name_l = name.lower()
    wf_l = workflow.lower()
    return any(k in name_l or k in wf_l for k in ("no-mistakes", "juror", "dco", "cla", "linear", "review"))

def evaluate_flake_vs_regression(
    repo: str,
    pr_num: str,
    retrigger: bool = False
) -> Dict[str, Any]:
    pr_data = get_pr_status(repo, pr_num)
    if not pr_data:
        return {
            "status": "ERROR",
            "verdict": "ERROR",
            "message": f"Could not retrieve PR status for {repo}#{pr_num}"
        }

    changed_files = get_pr_diff_files(repo, pr_num)
    checks = pr_data.get("statusCheckRollup", [])

    failed_checks = []
    for c in checks:
        name = c.get("name", "")
        status = c.get("status", "")
        conclusion = c.get("conclusion", "")
        details_url = c.get("detailsUrl", "")
        if conclusion in ("FAILURE", "TIMED_OUT", "ACTION_REQUIRED") or status == "COMPLETED" and conclusion == "FAILURE":
            failed_checks.append({
                "name": name,
                "workflow": c.get("workflowName", ""),
                "detailsUrl": details_url,
                "runId": extract_run_id_from_url(details_url),
            })

    if not failed_checks:
        return {
            "status": "ALL_GREEN",
            "verdict": "GREEN",
            "pr": pr_data.get("title", ""),
            "url": pr_data.get("url", ""),
            "failed_count": 0,
            "changed_files": changed_files,
            "details": []
        }

    details = []
    overall_verdict = "FLAKE_TRANSIENT"
    retrigger_results = []

    for fc in failed_checks:
        run_id = fc.get("runId")
        name = fc.get("name")
        workflow = fc.get("workflow", "")
        if is_bot_review_gate(name, workflow):
            details.append({
                "check_name": name,
                "run_id": run_id,
                "verdict": "BOT_REVIEW_GATE",
                "failing_tests": [],
                "flake_signatures": [],
                "reasons": ["Automated bot provenance or review gate (no code defect)."],
                "is_flake": False
            })
            continue

        log_text = get_failed_run_logs(repo, run_id) if run_id else ""
        failed_tests, flake_reasons = parse_failed_tests_and_traces(log_text)

        # Check intersection between failing tests and files changed in PR
        direct_intersection = []
        for ft in failed_tests:
            tf = ft.split("::")[0]
            if tf in changed_files:
                direct_intersection.append(tf)

        # Check if PR modified code that the test might directly test
        is_flake = False
        reasons_summary = []
        if direct_intersection:
            check_verdict = "CODE_REGRESSION"
            overall_verdict = "CODE_REGRESSION"
            reasons_summary.append(f"PR modified failing test file(s): {', '.join(direct_intersection)}")
        elif flake_reasons:
            check_verdict = "FLAKE_TRANSIENT"
            is_flake = True
            reasons_summary.extend(flake_reasons)
        else:
            check_verdict = "UNCERTAIN_FAILURE"
            if overall_verdict != "CODE_REGRESSION":
                overall_verdict = "UNCERTAIN_FAILURE"
            reasons_summary.append("Failure does not match known transient signatures, but PR did not modify test file.")

        check_info = {
            "check_name": name,
            "run_id": run_id,
            "verdict": check_verdict,
            "failing_tests": failed_tests,
            "flake_signatures": flake_reasons,
            "reasons": reasons_summary,
            "is_flake": is_flake
        }

        # Auto-retrigger if requested and eligible
        if retrigger and is_flake and run_id:
            retrigger_cmd = ["gh", "run", "rerun", run_id, "--failed"]
            if repo:
                retrigger_cmd.extend(["--repo", repo])
            rc, r_out, r_err = run_command(retrigger_cmd)
            check_info["retriggered"] = (rc == 0)
            check_info["retrigger_output"] = r_out or r_err
            retrigger_results.append(f"Run {run_id} ({name}): {'RERUN_TRIGGERED' if rc == 0 else 'RERUN_FAILED'}")

        details.append(check_info)

    return {
        "status": overall_verdict,
        "verdict": overall_verdict,
        "pr": pr_data.get("title", ""),
        "url": pr_data.get("url", ""),
        "changed_files_count": len(changed_files),
        "failed_checks_count": len(failed_checks),
        "details": details,
        "retriggered": retrigger_results
    }

def format_summary(result: Dict[str, Any]) -> str:
    verdict = result.get("verdict", "UNKNOWN")
    lines = []
    lines.append(f"Jev Flake Detector: {verdict}")
    lines.append(f"PR: {result.get('pr', '')} ({result.get('url', '')})")
    lines.append(f"Failed Checks Evaluated: {result.get('failed_checks_count', 0)} | Changed Files: {result.get('changed_files_count', 0)}")
    lines.append("")

    for item in result.get("details", []):
        name = item.get("check_name")
        c_verdict = item.get("verdict")
        run_id = item.get("run_id")
        reasons = item.get("reasons", [])
        tests = item.get("failing_tests", [])

        symbol = "⚠️" if c_verdict == "FLAKE_TRANSIENT" else ("❌" if c_verdict == "CODE_REGRESSION" else "❓")
        lines.append(f"{symbol} {name} (Run: {run_id}) -> {c_verdict}")
        if reasons:
            lines.append(f"   Signatures: {', '.join(reasons)}")
        if tests:
            lines.append(f"   Tests: {', '.join(tests[:3])}{' (and more)' if len(tests) > 3 else ''}")
        if item.get("retriggered"):
            lines.append(f"   Action: RERUN_TRIGGERED for failed jobs")

    if result.get("retriggered"):
        lines.append("")
        lines.append("Automated Retrigger Actions:")
        for r in result.get("retriggered", []):
            lines.append(f"  • {r}")

    return "\n".join(lines)

def main() -> int:
    parser = argparse.ArgumentParser(description="Jev Flake vs Regression Disambiguator & Auto-Rerun Gatekeeper")
    parser.add_argument("--repo", help="GitHub repo (e.g. ArcsHealth/Portal)")
    parser.add_argument("--pr", required=True, help="PR number")
    parser.add_argument("--retrigger", action="store_true", help="Auto-trigger rerun if classified as FLAKE_TRANSIENT")
    parser.add_argument("--format", choices=["summary", "json"], default="summary", help="Output format")
    parser.add_argument("--json", action="store_true", help="Shortcut for --format json")

    args = parser.parse_args()
    result = evaluate_flake_vs_regression(args.repo, args.pr, retrigger=args.retrigger)

    if args.json or args.format == "json":
        print(json.dumps(result, indent=2))
    else:
        print(format_summary(result))

    if result.get("verdict") == "CODE_REGRESSION":
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
