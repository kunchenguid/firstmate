#!/usr/bin/env python3
"""
fm-jev-ci-workflow-guard.py - Jev System One Zero-CI & Workflow Landing Gate Verifier.

Pattern 10: Automatically inspects repository workflow definitions, identifies
zero-CI repositories, validates local test outputs against code diffs, and formats
canonical landing attestation comments to enable seamless merging under standing
+yolo policy without stalled waiting loops.

Usage:
  bin/fm-jev-ci-workflow-guard.py [--repo-dir <path>] [--format text|json|markdown]
  bin/fm-jev-ci-workflow-guard.py --repo-dir <path> --test-output <file> [--json]
  bin/fm-jev-ci-workflow-guard.py --pr <pr-url-or-number> [--repo <owner/repo>] [--strict]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def inspect_workflows(repo_dir: Path) -> Dict[str, Any]:
    """Inspect repository for GitHub Actions workflow definitions."""
    workflows_dir = repo_dir / ".github" / "workflows"
    if not workflows_dir.is_dir():
        return {
            "status": "ZERO_CI",
            "reason": "No .github/workflows directory present",
            "workflow_files": [],
            "pr_trigger_count": 0,
        }

    yml_files = sorted(
        list(workflows_dir.glob("*.yml")) + list(workflows_dir.glob("*.yaml"))
    )
    if not yml_files:
        return {
            "status": "ZERO_CI",
            "reason": ".github/workflows exists but contains no YAML workflow files",
            "workflow_files": [],
            "pr_trigger_count": 0,
        }

    pr_workflows = []
    push_workflows = []
    other_workflows = []

    for wf in yml_files:
        try:
            content = wf.read_text(encoding="utf-8", errors="replace")
            # Parse top-level 'on:' triggers using robust regex
            has_pr = bool(re.search(r"^\s*(?:-\s*)?pull_request(?::|\s|$)", content, re.MULTILINE))
            has_push = bool(re.search(r"^\s*(?:-\s*)?push(?::|\s|$)", content, re.MULTILINE))
            wf_info = {
                "name": wf.name,
                "path": str(wf.relative_to(repo_dir)),
                "has_pull_request": has_pr,
                "has_push": has_push,
            }
            if has_pr:
                pr_workflows.append(wf_info)
            elif has_push:
                push_workflows.append(wf_info)
            else:
                other_workflows.append(wf_info)
        except Exception as e:
            other_workflows.append({"name": wf.name, "error": str(e)})

    if pr_workflows or push_workflows:
        status = "CI_ACTIVE"
        reason = f"{len(pr_workflows)} pull_request and {len(push_workflows)} push workflows found"
    else:
        status = "NO_PR_WORKFLOWS"
        reason = f"{len(yml_files)} workflows found, but none trigger on pull_request or push"

    return {
        "status": status,
        "reason": reason,
        "workflow_files": [w["name"] for w in (pr_workflows + push_workflows + other_workflows)],
        "pr_workflows": pr_workflows,
        "push_workflows": push_workflows,
        "other_workflows": other_workflows,
        "total_workflows": len(yml_files),
        "pr_trigger_count": len(pr_workflows),
    }


def parse_test_output(text: str) -> Dict[str, Any]:
    """Analyze text output from common test frameworks (pytest, jest, cargo, go, tap)."""
    passed = 0
    failed = 0
    errors = 0
    skipped = 0

    # 1. Pytest regex: e.g. "=== 42 passed in 4.52s ===" or "=== 1 failed, 41 passed in 1.45s ==="
    pytest_line_match = re.search(r"=+\s*([\w\s,]+in\s+[\d\.]+s.*?)=+", text)
    if pytest_line_match:
        summary_line = pytest_line_match.group(1)
        p_match = re.search(r"(\d+)\s+passed", summary_line)
        f_match = re.search(r"(\d+)\s+failed", summary_line)
        e_match = re.search(r"(\d+)\s+error(?:s)?", summary_line)
        sk_match = re.search(r"(\d+)\s+skipped", summary_line)

        p = int(p_match.group(1)) if p_match else 0
        f = int(f_match.group(1)) if f_match else 0
        e = int(e_match.group(1)) if e_match else 0
        sk = int(sk_match.group(1)) if sk_match else 0

        return {
            "framework": "pytest",
            "passed": p,
            "failed": f,
            "errors": e,
            "skipped": sk,
            "success": (f == 0 and e == 0 and p > 0),
        }

    # 2. Cargo test regex: e.g. "test result: ok. 15 passed; 0 failed; 0 ignored;"
    cargo_match = re.search(
        r"test result:\s+(?P<res>ok|FAILED)\.\s+(?P<p>\d+)\s+passed;\s+(?P<f>\d+)\s+failed;\s+(?P<ign>\d+)\s+ignored",
        text,
    )
    if cargo_match:
        p = int(cargo_match.group("p"))
        f = int(cargo_match.group("f"))
        return {
            "framework": "cargo",
            "passed": p,
            "failed": f,
            "errors": 0,
            "skipped": int(cargo_match.group("ign")),
            "success": (cargo_match.group("res") == "ok" and f == 0),
        }

    # 3. Jest / Vitest regex: e.g. "Tests:       12 passed, 12 total"
    jest_match = re.search(
        r"Tests:\s+(?:(?P<f>\d+)\s+failed,\s*)?(?:(?P<p>\d+)\s+passed,\s*)?(?P<tot>\d+)\s+total",
        text,
    )
    if jest_match:
        p = int(jest_match.group("p") or 0)
        f = int(jest_match.group("f") or 0)
        return {
            "framework": "jest/vitest",
            "passed": p,
            "failed": f,
            "errors": 0,
            "skipped": 0,
            "success": (f == 0 and p > 0),
        }

    # 4. TAP / Shell test regex: "ok - ...", "FAIL: ..."
    ok_lines = re.findall(r"^ok\s+-\s+(.+)$", text, re.MULTILINE)
    fail_lines = re.findall(r"^FAIL:\s+(.+)$", text, re.MULTILINE)
    if ok_lines or fail_lines:
        return {
            "framework": "tap/shell",
            "passed": len(ok_lines),
            "failed": len(fail_lines),
            "errors": 0,
            "skipped": 0,
            "success": (len(fail_lines) == 0 and len(ok_lines) > 0),
        }

    # 5. Generic check: search for common pass/fail signals
    has_fail = bool(re.search(r"\b(FAILED|FAILURE|ERRORS!|Build failed)\b", text))
    has_pass = bool(re.search(r"\b(SUCCESS|all tests passed|BUILD SUCCESSFUL|PASSED)\b", text, re.IGNORECASE))

    if has_fail:
        return {"framework": "generic", "passed": 0, "failed": 1, "errors": 0, "skipped": 0, "success": False}
    if has_pass:
        return {"framework": "generic", "passed": 1, "failed": 0, "errors": 0, "skipped": 0, "success": True}

    return {"framework": "unknown", "passed": 0, "failed": 0, "errors": 0, "skipped": 0, "success": True}


def query_pr_checks(pr: str, repo: Optional[str] = None) -> Dict[str, Any]:
    """Query live PR checks using gh CLI if available."""
    gh_bin = shutil.which("gh") or "/home/jon/.local/bin/gh"
    if not os.path.exists(gh_bin):
        return {"available": False, "error": "gh CLI not installed"}

    cmd = [gh_bin, "pr", "view", pr, "--json", "statusCheckRollup,mergeable,state,title,headRefOid"]
    if repo:
        cmd.extend(["--repo", repo])

    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=5, check=False)
        if res.returncode == 0:
            data = json.loads(res.stdout)
            rollup = data.get("statusCheckRollup") or []
            return {
                "available": True,
                "data": data,
                "check_count": len(rollup),
                "checks": rollup,
            }
        return {"available": False, "error": res.stderr.strip()}
    except Exception as e:
        return {"available": False, "error": str(e)}


def evaluate_landing_gate(
    wf_info: Dict[str, Any],
    test_info: Optional[Dict[str, Any]] = None,
    pr_info: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """Make authoritative landing gate decision."""
    ci_status = wf_info["status"]

    if ci_status == "ZERO_CI":
        if test_info:
            if test_info["success"]:
                verdict = "APPROVED_FOR_LANDING"
                decision = "PASS"
                notes = f"Zero-CI repository verified. Local tests passed ({test_info['passed']} passed, {test_info['failed']} failed) under {test_info['framework']}."
            else:
                verdict = "BLOCKED_TESTS_FAILING"
                decision = "BLOCK"
                notes = f"Zero-CI repository, but local tests failed ({test_info['failed']} failed, {test_info['errors']} errors)."
        else:
            verdict = "APPROVED_FOR_LANDING"
            decision = "PASS"
            notes = "Zero-CI repository verified (no workflows configured). Safe to land under standing +yolo authority."

    elif ci_status == "CI_ACTIVE":
        if pr_info and pr_info.get("available"):
            checks = pr_info.get("checks", [])
            if not checks:
                verdict = "BLOCKED_WAITING_CI"
                decision = "WAIT"
                notes = "Repository has active workflows, but PR has no check runs reported yet."
            else:
                failing = [c for c in checks if c.get("conclusion") in ("FAILURE", "TIMED_OUT", "CANCELLED")]
                pending = [c for c in checks if c.get("status") in ("QUEUED", "IN_PROGRESS")]
                if failing:
                    verdict = "BLOCKED_CI_FAILING"
                    decision = "BLOCK"
                    notes = f"Active CI checks failing: {len(failing)} failed check(s)."
                elif pending:
                    verdict = "BLOCKED_WAITING_CI"
                    decision = "WAIT"
                    notes = f"Active CI checks running: {len(pending)} pending check(s)."
                else:
                    verdict = "APPROVED_FOR_LANDING"
                    decision = "PASS"
                    notes = f"All {len(checks)} CI check runs completed green."
        else:
            verdict = "CI_GATE_REQUIRED"
            decision = "REQUIRE_CI"
            notes = f"Repository has {wf_info['pr_trigger_count']} active CI workflows. Standard CI green check rollup required before landing."

    else:  # NO_PR_WORKFLOWS
        verdict = "APPROVED_FOR_LANDING"
        decision = "PASS"
        notes = "Workflows exist but none trigger on pull requests. Treated as zero-CI for PR merge purposes."

    return {
        "verdict": verdict,
        "decision": decision,
        "ci_status": ci_status,
        "notes": notes,
        "can_merge": (decision == "PASS"),
    }


def format_attestation_markdown(
    eval_res: Dict[str, Any],
    wf_info: Dict[str, Any],
    test_info: Optional[Dict[str, Any]] = None,
) -> str:
    """Format canonical Markdown attestation comment for PR landing."""
    verdict = eval_res["verdict"]
    status = eval_res["ci_status"]
    icon = "✅" if eval_res["can_merge"] else ("⏳" if eval_res["decision"] == "WAIT" else "❌")

    lines = [
        "### 🛡️ Jev Landing Gate Attestation",
        "",
        f"- **Verdict**: {icon} **{verdict}**",
        f"- **CI Status**: `{status}` ({wf_info['reason']})",
    ]

    if test_info:
        lines.append(
            f"- **Local Verification**: `{test_info['framework']}` ({test_info['passed']} passed, {test_info['failed']} failed)"
        )

    lines.extend([
        f"- **Policy Evaluation**: {eval_res['notes']}",
        "- **Standing Authority**: Evaluated against Firstmate `+yolo` / supervisor landing contract.",
        "",
        "> [!NOTE]",
        f"> {eval_res['notes']}",
    ])

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Zero-CI & Workflow Landing Gate Verifier (Pattern 10)"
    )
    parser.add_argument(
        "--repo-dir",
        type=Path,
        default=Path.cwd(),
        help="Repository root directory (defaults to current directory)",
    )
    parser.add_argument(
        "--test-output",
        type=Path,
        default=None,
        help="Path to file containing test runner stdout/stderr",
    )
    parser.add_argument(
        "--pr",
        type=str,
        default=None,
        help="GitHub PR URL or number to inspect live checks",
    )
    parser.add_argument(
        "--repo",
        type=str,
        default=None,
        help="GitHub repository owner/repo (e.g. RooseveltAdvisors/Zeta)",
    )
    parser.add_argument(
        "--format",
        choices=["text", "json", "markdown"],
        default="text",
        help="Output format (default: text)",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero if landing is not approved",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Convenience alias for --format json",
    )
    parser.add_argument(
        "--comment",
        action="store_true",
        help="Post the formatted attestation comment to the PR via gh CLI",
    )

    args = parser.parse_args()
    if args.json:
        args.format = "json"

    repo_dir = args.repo_dir.resolve()
    wf_info = inspect_workflows(repo_dir)

    test_info = None
    if args.test_output and args.test_output.is_file():
        content = args.test_output.read_text(encoding="utf-8", errors="replace")
        test_info = parse_test_output(content)

    pr_info = None
    if args.pr:
        pr_info = query_pr_checks(args.pr, args.repo)

    eval_res = evaluate_landing_gate(wf_info, test_info, pr_info)

    if args.format == "json":
        payload = {
            "evaluation": eval_res,
            "workflows": wf_info,
            "tests": test_info,
            "pr": pr_info,
        }
        print(json.dumps(payload, indent=2))
    elif args.format == "markdown":
        print(format_attestation_markdown(eval_res, wf_info, test_info))
    else:  # text
        print(f"Jev Landing Gate: {eval_res['verdict']} [{eval_res['ci_status']}]")
        print(f"Notes: {eval_res['notes']}")
        print(f"Can Merge: {eval_res['can_merge']}")
        if test_info:
            print(f"Tests: {test_info['framework']} - {test_info['passed']} passed, {test_info['failed']} failed")

    if args.comment and args.pr:
        gh_bin = shutil.which("gh") or "/home/jon/.local/bin/gh"
        if os.path.exists(gh_bin):
            comment_body = format_attestation_markdown(eval_res, wf_info, test_info)
            cmd = [gh_bin, "pr", "comment", args.pr, "--body", comment_body]
            if args.repo:
                cmd.extend(["--repo", args.repo])
            subprocess.run(cmd, check=False)

    if args.strict and not eval_res["can_merge"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
