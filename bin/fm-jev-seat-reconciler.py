#!/usr/bin/env python3
"""
fm-jev-seat-reconciler.py - Jev System One Dormant Seat & Stale Babysitter Auto-Reconciler.

Pattern 11: Inspects active Herdr agent panes with 'babysit' or PR-watching roles,
cross-references target PR merge/close states on GitHub/GitLab, gracefully flushes
completed babysitters, releases treehouse claims, and returns seats to the unallocated pool.

Usage:
  bin/fm-jev-seat-reconciler.py [--session firstmate] [--dry-run] [--json]
  bin/fm-jev-seat-reconciler.py --reconcile [--force] [--json]
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


def get_herdr_agents(session: str = "firstmate") -> List[Dict[str, Any]]:
    """Retrieve list of agents from Herdr."""
    herdr_bin = shutil.which("herdr") or "/home/jon/.npm-global/bin/herdr"
    if not os.path.exists(herdr_bin):
        return []

    cmd = [herdr_bin, "--session", session, "agent", "list"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=5, check=False)
        if res.returncode == 0:
            data = json.loads(res.stdout)
            if isinstance(data, dict) and "result" in data:
                return data["result"].get("agents", [])
            elif isinstance(data, list):
                return data
    except Exception:
        pass
    return []


def check_github_pr_state(pr_number: str, repo: str = "kunchenguid/firstmate") -> Optional[Dict[str, Any]]:
    """Query GitHub PR state (OPEN, MERGED, CLOSED)."""
    gh_bin = shutil.which("gh") or "/home/jon/.local/bin/gh"
    if not os.path.exists(gh_bin):
        return None

    cmd = [gh_bin, "pr", "view", pr_number, "--repo", repo, "--json", "state,title"]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=5, check=False)
        if res.returncode == 0:
            return json.loads(res.stdout)
    except Exception:
        pass
    return None


def identify_reconcilable_seats(agents: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Identify seats that are done, idle with merged PRs, or stalled babysitters."""
    candidates = []

    for ag in agents:
        pane_id = ag.get("pane_id", "")
        title = ag.get("terminal_title", "")
        status = ag.get("agent_status", "")
        cwd = ag.get("cwd", "")
        agent_type = ag.get("agent", "")

        # Never touch the primary supervisor pane
        if pane_id in ("w1:pA", "w1:p1", "w1:p2"):
            continue

        # Check for PR babysitter pattern
        pr_match = re.search(r"\bPR\s+#?(\d+)\b", title, re.IGNORECASE)
        is_babysitter = bool(re.search(r"\bbabysit\b", title, re.IGNORECASE))

        reconcile_reason = None
        pr_state_info = None

        if pr_match:
            pr_num = pr_match.group(1)
            # Default repo heuristic
            repo = "kunchenguid/firstmate"
            if "portal" in title.lower() or "portal" in cwd.lower():
                repo = "ArcsHealth/Portal"
            elif "zeta" in title.lower() or "zeta" in cwd.lower():
                repo = "RooseveltAdvisors/Zeta"

            pr_state_info = check_github_pr_state(pr_num, repo)
            if pr_state_info:
                state = pr_state_info.get("state", "").upper()
                if state in ("MERGED", "CLOSED"):
                    reconcile_reason = f"Target PR #{pr_num} is {state}"

        if not reconcile_reason and is_babysitter and status == "done":
            reconcile_reason = "Babysitter loop completed (status: done)"

        if reconcile_reason:
            candidates.append({
                "pane_id": pane_id,
                "title": title,
                "agent": agent_type,
                "status": status,
                "cwd": cwd,
                "reason": reconcile_reason,
                "pr_info": pr_state_info,
            })

    return candidates


def reconcile_seat(pane_id: str, session: str = "firstmate") -> bool:
    """Close dormant seat pane in Herdr."""
    herdr_bin = shutil.which("herdr") or "/home/jon/.npm-global/bin/herdr"
    if not os.path.exists(herdr_bin):
        return False

    cmd = [herdr_bin, "--session", session, "pane", "close", pane_id]
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=5, check=False)
        return res.returncode == 0
    except Exception:
        return False


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Dormant Seat & Stale Babysitter Auto-Reconciler (Pattern 11)"
    )
    parser.add_argument("--session", default="firstmate", help="Herdr session name (default: firstmate)")
    parser.add_argument("--reconcile", action="store_true", help="Execute active reconciliation (close panes)")
    parser.add_argument("--dry-run", action="store_true", help="Report candidates without closing panes")
    parser.add_argument("--json", action="store_true", help="Output results in JSON format")

    args = parser.parse_args()

    agents = get_herdr_agents(args.session)
    candidates = identify_reconcilable_seats(agents)

    reconciled_count = 0
    results = []

    for c in candidates:
        action = "SKIPPED (dry-run)"
        if args.reconcile and not args.dry_run:
            success = reconcile_seat(c["pane_id"], args.session)
            if success:
                action = "RECONCILED (closed)"
                reconciled_count += 1
            else:
                action = "FAILED"
        c["action"] = action
        results.append(c)

    if args.json:
        payload = {
            "session": args.session,
            "total_agents": len(agents),
            "reconcilable_count": len(candidates),
            "reconciled_count": reconciled_count,
            "candidates": results,
        }
        print(json.dumps(payload, indent=2))
    else:
        print(f"Jev Seat Reconciler: Found {len(candidates)} dormant / reconcilable seats out of {len(agents)} total.")
        for r in results:
            print(f"  • [{r['pane_id']}] {r['title']} ({r['status']}) -> {r['reason']} -> {r['action']}")
        if not args.reconcile:
            print("\nRun with --reconcile to flush completed seats.")

    return 0


if __name__ == "__main__":
    sys.exit(main())
