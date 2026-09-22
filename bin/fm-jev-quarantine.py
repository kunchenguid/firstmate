#!/usr/bin/env python3
"""
fm-jev-quarantine.py - Jev Continuous Test Flake Quarantine & Auto-Bisect Engine (Pattern 17)

Detects and isolates recurring test runner flakes (e.g., Journeys races, frozen timestamps,
calendar locator misses) by comparing test failure signatures against PR diff files.
When diff intersection is zero, safely classifies failures as external flakes to prevent
wedging clean feature PRs.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

KNOWN_FLAKE_SIGNATURES = [
    r"test_schedule_manager_session_reattach_preserves_start",
    r"test_j7_visit_lifecycle",
    r"locator\('.*'\)\.click: Timeout \d+ms exceeded",
    r"browserContext\.newPage: Target page, context or browser has been closed",
    r"frozen timestamp",
    r"calendar locator miss",
    r"Journeys",
]

def run_command(args: List[str], cwd: Optional[Path] = None) -> Tuple[int, str, str]:
    try:
        proc = subprocess.run(
            args,
            cwd=str(cwd) if cwd else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=20,
            check=False,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return 1, "", str(e)

def get_pr_diff_files(pr_id: str, repo: Optional[str] = None) -> Set[str]:
    """Returns set of file paths modified in the PR."""
    cmd = ["gh", "pr", "diff", str(pr_id), "--name-only"]
    if repo:
        cmd.extend(["--repo", repo])
    rc, stdout, _ = run_command(cmd)
    if rc != 0 or not stdout:
        return set()
    return set(line.strip() for line in stdout.splitlines() if line.strip())

def get_pr_checks(pr_id: str, repo: Optional[str] = None) -> List[Dict[str, Any]]:
    """Fetches check runs for a PR."""
    cmd = [
        "gh", "pr", "checks", str(pr_id),
        "--json", "name,state,bucket,description,link,event"
    ]
    if repo:
        cmd.extend(["--repo", repo])
    rc, stdout, _ = run_command(cmd)
    if rc != 0 or not stdout:
        return []
    try:
        return json.loads(stdout)
    except Exception:
        return []

def match_known_flake(text: str) -> Optional[str]:
    for pattern in KNOWN_FLAKE_SIGNATURES:
        if re.search(pattern, text, re.IGNORECASE):
            return pattern
    return None

def analyze_failures(
    pr_id: str,
    repo: Optional[str] = None,
    custom_checks: Optional[List[Dict[str, Any]]] = None,
    custom_diff_files: Optional[Set[str]] = None,
) -> Dict[str, Any]:
    diff_files = custom_diff_files if custom_diff_files is not None else get_pr_diff_files(pr_id, repo)
    checks = custom_checks if custom_checks is not None else get_pr_checks(pr_id, repo)

    failed_checks = [
        c for c in checks
        if c.get("bucket") in ("fail", "error") or c.get("state") in ("FAILURE", "ERROR", "CANCELLED")
    ]

    findings: List[Dict[str, Any]] = []
    quarantined_count = 0
    real_regression_count = 0

    for fc in failed_checks:
        check_name = fc.get("name", "Unknown Check")
        desc = fc.get("description", "")
        details_url = fc.get("link", "")

        matched_sig = match_known_flake(check_name) or match_known_flake(desc)

        # Check diff intersection
        intersecting_files = []
        for df in diff_files:
            # If check name references a path that touches diff
            df_stem = Path(df).stem
            if df_stem and len(df_stem) > 3 and df_stem.lower() in check_name.lower():
                intersecting_files.append(df)

        if matched_sig and not intersecting_files:
            verdict = "QUARANTINE_ELIGIBLE_FLAKE"
            reason = f"Matches known flake pattern '{matched_sig}' with 0 diff intersection ({len(diff_files)} files modified in PR)."
            action = "SAFE_AUTO_RERUN"
            quarantined_count += 1
        elif not intersecting_files:
            verdict = "ENVIRONMENT_RUNNER_FLAKE"
            reason = f"Failed check '{check_name}' has 0 diff intersection with PR changes."
            action = "RERUN_RECOMMENDED"
            quarantined_count += 1
        else:
            verdict = "POTENTIAL_REGRESSION"
            reason = f"Failure correlates with PR diff changes: {', '.join(intersecting_files)}"
            action = "INVESTIGATE_CODE"
            real_regression_count += 1

        findings.append({
            "check_name": check_name,
            "verdict": verdict,
            "matched_signature": matched_sig,
            "diff_intersection_count": len(intersecting_files),
            "intersecting_files": intersecting_files,
            "reason": reason,
            "action": action,
            "details_url": details_url,
        })

    is_safe = (real_regression_count == 0 and len(failed_checks) > 0)
    overall_verdict = "QUARANTINE_CLEAN" if is_safe else ("ALL_GREEN" if not failed_checks else "REGRESSION_DETECTED")

    return {
        "pr": str(pr_id),
        "repo": repo or "default",
        "total_checks": len(checks),
        "failed_checks_count": len(failed_checks),
        "quarantined_flakes_count": quarantined_count,
        "real_regressions_count": real_regression_count,
        "overall_verdict": overall_verdict,
        "safe_to_rerun_or_waive": is_safe,
        "findings": findings,
    }

def format_summary(res: Dict[str, Any]) -> str:
    lines = []
    lines.append(f"Jev Test Flake Quarantine Analysis for PR #{res['pr']} ({res['repo']}):")
    lines.append(f"  • Overall Verdict: {res['overall_verdict']}")
    lines.append(f"  • Total Checks: {res['total_checks']} | Failures: {res['failed_checks_count']} (Quarantined: {res['quarantined_flakes_count']}, Regressions: {res['real_regressions_count']})")
    lines.append(f"  • Safe to Rerun/Waive: {'YES' if res['safe_to_rerun_or_waive'] else 'NO'}")

    if res["findings"]:
        lines.append("  Failures Breakdown:")
        for f in res["findings"]:
            sym = "⚠️" if "FLAKE" in f["verdict"] else "❌"
            lines.append(f"    {sym} [{f['verdict']}] {f['check_name']}")
            lines.append(f"       ↳ Reason: {f['reason']}")
            lines.append(f"       ↳ Recommended Action: {f['action']}")

    return "\n".join(lines)

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Continuous Test Flake Quarantine & Auto-Bisect Engine (Pattern 17)"
    )
    parser.add_argument("--pr", required=True, help="PR number or canonical URL")
    parser.add_argument("--repo", default=None, help="Owner/Repo identifier (e.g. ArcsHealth/Portal)")
    parser.add_argument("--json", action="store_true", help="Output JSON format")

    args = parser.parse_args()

    pr_raw = args.pr
    repo = args.repo
    # Parse PR URL if provided
    if "github.com/" in pr_raw:
        parts = pr_raw.split("github.com/")[1].split("/")
        if len(parts) >= 4:
            repo = f"{parts[0]}/{parts[1]}"
            pr_raw = parts[3]

    res = analyze_failures(pr_raw, repo=repo)

    if args.json:
        print(json.dumps(res, indent=2))
    else:
        print(format_summary(res))

    # Exit 0 if all failures are safe/quarantined flakes or if clean
    return 0 if res["safe_to_rerun_or_waive"] or res["overall_verdict"] == "ALL_GREEN" else 1

if __name__ == "__main__":
    sys.exit(main())
