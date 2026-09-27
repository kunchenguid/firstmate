#!/usr/bin/env python3
"""
fm-jev-pr-triage.py - Jev System One PR Failure Classifier & Root-Cause Triage Engine.

Pattern 12: Inspects statusCheckRollup for any GitHub PR, differentiates actively
running checks (in_progress) from genuine failures, disambiguates bot attestation
gates (no-mistakes, juror) from code test failures, and formats structured triage directives.

Usage:
  bin/fm-jev-pr-triage.py --pr <pr-url-or-number> [--repo <owner/repo>] [--json]
  bin/fm-jev-pr-triage.py --pr <pr-url-or-number> [--format markdown|summary|json]
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


def get_pr_status(pr: str, repo: Optional[str] = None) -> Dict[str, Any]:
    """Fetch structured statusCheckRollup from GitHub CLI."""
    gh_bin = shutil.which("gh") or "/home/jon/.local/bin/gh"
    if not os.path.exists(gh_bin):
        return {"error": "gh CLI not found on PATH"}

    cmd = [gh_bin, "pr", "view", pr, "--json", "statusCheckRollup,title,state,mergeable,headRefOid,url"]
    if repo:
        cmd.extend(["--repo", repo])

    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=8, check=False)
        if res.returncode == 0:
            return json.loads(res.stdout)
        return {"error": res.stderr.strip()}
    except Exception as e:
        return {"error": str(e)}


def classify_checks(checks: List[Dict[str, Any]]) -> Dict[str, Any]:
    """Classify checks into running, passed, code defects, bot gates, and infra bottlenecks."""
    in_progress = []
    passed = []
    code_defects = []
    bot_gates = []
    infra_failures = []

    bot_gate_patterns = [
        r"no-mistakes",
        r"juror",
        r"axi\b",
        r"review\s+attestation",
        r"code-review",
        r"approval",
    ]

    for c in checks:
        name = c.get("name") or c.get("context") or "unknown"
        status = (c.get("status") or "").upper()
        conclusion = (c.get("conclusion") or c.get("state") or "").upper()

        is_bot_gate = any(re.search(pat, name, re.IGNORECASE) for pat in bot_gate_patterns)

        if status in ("IN_PROGRESS", "QUEUED", "PENDING", "WAITING"):
            in_progress.append({"name": name, "status": status})
        elif status == "COMPLETED":
            if conclusion in ("SUCCESS", "SKIPPED", "NEUTRAL"):
                passed.append({"name": name, "conclusion": conclusion})
            elif conclusion in ("TIMED_OUT", "CANCELLED"):
                infra_failures.append({"name": name, "conclusion": conclusion})
            elif is_bot_gate:
                bot_gates.append({"name": name, "conclusion": conclusion})
            else:
                code_defects.append({"name": name, "conclusion": conclusion})
        else:
            # Context state format (e.g. pending / success / failure)
            if conclusion in ("SUCCESS", "SKIPPED", "NEUTRAL"):
                passed.append({"name": name, "conclusion": conclusion})
            elif conclusion in ("PENDING", ""):
                in_progress.append({"name": name, "status": "PENDING"})
            elif is_bot_gate:
                bot_gates.append({"name": name, "conclusion": conclusion})
            else:
                code_defects.append({"name": name, "conclusion": conclusion})

    # High-level diagnosis
    if in_progress:
        verdict = "IN_FLIGHT"
        summary = f"{len(in_progress)} check(s) currently running. Do not treat as failed."
        action = "WAIT_FOR_RUNNERS"
    elif code_defects:
        verdict = "CODE_REGRESSION"
        summary = f"{len(code_defects)} genuine code/test failure(s) detected."
        action = "FIX_CODE_DEFECTS"
    elif bot_gates:
        verdict = "BLOCKED_ON_BOT_GATE"
        summary = f"All functional tests passed! Waiting on {len(bot_gates)} bot attestation gate(s)."
        action = "DISPATCH_REVIEW_ATTESTATION"
    elif infra_failures:
        verdict = "INFRA_BOTTLENECK"
        summary = f"{len(infra_failures)} check(s) timed out or were cancelled due to runner capacity."
        action = "RETRIGGER_RUNNER"
    else:
        verdict = "ALL_GREEN"
        summary = "All checks passed green."
        action = "PROCEED_TO_MERGE"

    return {
        "verdict": verdict,
        "action": action,
        "summary": summary,
        "counts": {
            "total": len(checks),
            "passed": len(passed),
            "in_progress": len(in_progress),
            "code_defects": len(code_defects),
            "bot_gates": len(bot_gates),
            "infra_failures": len(infra_failures),
        },
        "in_progress": in_progress,
        "code_defects": code_defects,
        "bot_gates": bot_gates,
        "infra_failures": infra_failures,
    }


def format_triage_summary(pr_data: Dict[str, Any], triage: Dict[str, Any]) -> str:
    """Format human-readable CLI summary."""
    title = pr_data.get("title", "")
    url = pr_data.get("url", "")
    counts = triage["counts"]

    lines = [
        f"Jev PR Triage: {triage['verdict']} [{triage['action']}]",
        f"PR: {title} ({url})",
        f"Checks Breakdown: {counts['passed']} passed, {counts['in_progress']} running, {counts['code_defects']} code defects, {counts['bot_gates']} bot gates, {counts['infra_failures']} infra timeouts (Total: {counts['total']})",
        f"Diagnosis: {triage['summary']}",
    ]

    if triage["in_progress"]:
        lines.append("\nActive In-Progress Checks:")
        for c in triage["in_progress"]:
            lines.append(f"  ⏳ {c['name']} ({c['status']})")

    if triage["code_defects"]:
        lines.append("\nCode/Test Defect Checks:")
        for c in triage["code_defects"]:
            lines.append(f"  ❌ {c['name']} ({c['conclusion']})")

    if triage["bot_gates"]:
        lines.append("\nBlocked Bot Review Gates:")
        for c in triage["bot_gates"]:
            lines.append(f"  🤖 {c['name']} ({c['conclusion']})")

    if triage["infra_failures"]:
        lines.append("\nInfra/Timeout Failures:")
        for c in triage["infra_failures"]:
            lines.append(f"  ⚠️ {c['name']} ({c['conclusion']})")

    return "\n".join(lines)


def format_triage_markdown(pr_data: Dict[str, Any], triage: Dict[str, Any]) -> str:
    """Format GitHub PR markdown comment."""
    title = pr_data.get("title", "")
    url = pr_data.get("url", "")
    counts = triage["counts"]
    icon = "⏳" if triage["verdict"] == "IN_FLIGHT" else ("✅" if triage["verdict"] == "ALL_GREEN" else "❌")

    lines = [
        "### 🔍 Jev PR Root-Cause Triage Report",
        "",
        f"- **Verdict**: {icon} **{triage['verdict']}** (`{triage['action']}`)",
        f"- **Summary**: {triage['summary']}",
        f"- **Breakdown**: `{counts['passed']}` passed | `{counts['in_progress']}` in-flight | `{counts['code_defects']}` code defects | `{counts['bot_gates']}` bot gates",
        "",
    ]

    if triage["in_progress"]:
        lines.append("**In-Flight Checks (Running):**")
        for c in triage["in_progress"]:
            lines.append(f"- ⏳ `{c['name']}`")
        lines.append("")

    if triage["code_defects"]:
        lines.append("**Genuine Code/Test Defects:**")
        for c in triage["code_defects"]:
            lines.append(f"- ❌ `{c['name']}`")
        lines.append("")

    if triage["bot_gates"]:
        lines.append("**Bot Review Attestation Gates:**")
        for c in triage["bot_gates"]:
            lines.append(f"- 🤖 `{c['name']}`")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev PR Failure Classifier & Root-Cause Triage Engine (Pattern 12)"
    )
    parser.add_argument("--pr", required=True, help="GitHub PR number or URL")
    parser.add_argument("--repo", default=None, help="GitHub owner/repo")
    parser.add_argument("--format", choices=["summary", "markdown", "json"], default="summary", help="Output format")
    parser.add_argument("--json", action="store_true", help="Shortcut for --format json")

    args = parser.parse_args()
    if args.json:
        args.format = "json"

    data = get_pr_status(args.pr, args.repo)
    if "error" in data:
        print(f"error: {data['error']}", file=sys.stderr)
        return 1

    checks = data.get("statusCheckRollup") or []
    triage = classify_checks(checks)

    if args.format == "json":
        payload = {
            "pr": {
                "title": data.get("title"),
                "url": data.get("url"),
                "mergeable": data.get("mergeable"),
                "state": data.get("state"),
            },
            "triage": triage,
        }
        print(json.dumps(payload, indent=2))
    elif args.format == "markdown":
        print(format_triage_markdown(data, triage))
    else:
        print(format_triage_summary(data, triage))

    return 0


if __name__ == "__main__":
    sys.exit(main())
