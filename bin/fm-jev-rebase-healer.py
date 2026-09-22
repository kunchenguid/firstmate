#!/usr/bin/env python3
"""
fm-jev-rebase-healer.py - Jev Git Index & Rebase State Lock Auto-Healer (Pattern 33)

Detects and safely reconciles stale .git/index.lock or abandoned rebase/merge states
left behind when autonomous worker containers, sub-agents, or terminal panes terminate
abruptly mid-operation.

Invariants:
  - Safety first: Never touches locks held by live processes (verified via /proc or fuser).
  - Dry-run by default (--dry-run). Requires explicit --heal flag to mutate.
  - Fail-open on filesystem permission errors.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


DEFAULT_SEARCH_PATHS = [
    "/home/jon/git",
    "/opt/ra/firstmate",
    "/home/jon/Obsidian/second-brain",
]
DEFAULT_STALE_AGE_SEC = 120.0


def is_lock_held_by_process(lock_path: str) -> bool | None:
    """Checks if any active process has the lock file open."""
    try:
        res = subprocess.run(
            ["fuser", lock_path],
            capture_output=True,
            text=True,
            check=False,
        )
        if res.returncode == 0:
            return True
        if res.returncode == 1 and not res.stderr.strip():
            return False
        print(f"Ownership probe failed for {lock_path}: {res.stderr.strip()}", file=sys.stderr)
    except Exception as exc:
        print(f"Ownership probe unavailable: {exc}", file=sys.stderr)
    return None


def find_git_repos(search_dirs: List[str], max_depth: int = 3) -> List[str]:
    """Finds .git directories within target search directories."""
    repos = []
    for s_dir in search_dirs:
        if not os.path.exists(s_dir):
            continue
        if os.path.exists(os.path.join(s_dir, ".git")):
            repos.append(s_dir)
            continue
        try:
            for root, dirs, _ in os.walk(s_dir):
                depth = root[len(s_dir):].count(os.sep)
                if depth >= max_depth:
                    dirs.clear()
                    continue
                if ".git" in dirs:
                    repos.append(root)
                    dirs.remove(".git")
        except Exception:
            pass
    return repos


def inspect_git_repo(repo_path: str, stale_age_sec: float) -> Optional[Dict[str, Any]]:
    """Inspects a git repo for stale index.lock or interrupted rebase state."""
    git_dir = os.path.join(repo_path, ".git")
    if os.path.isfile(git_dir):
        # Worktree gitdir pointer
        try:
            with open(git_dir, "r") as f:
                line = f.read().strip()
                if line.startswith("gitdir:"):
                    git_dir = line.split(":", 1)[1].strip()
        except Exception:
            return None

    if not os.path.exists(git_dir):
        return None

    index_lock = os.path.join(git_dir, "index.lock")
    rebase_merge = os.path.join(git_dir, "rebase-merge")
    rebase_apply = os.path.join(git_dir, "rebase-apply")

    issues = []
    now = time.time()

    if os.path.exists(index_lock):
        try:
            stat = os.stat(index_lock)
            age = now - stat.st_mtime
            is_held = is_lock_held_by_process(index_lock)
            is_stale = age > stale_age_sec and is_held is False

            issues.append({
                "type": "index.lock",
                "path": index_lock,
                "age_seconds": round(age, 1),
                "is_held_by_proc": is_held,
                "is_stale": is_stale,
            })
        except Exception:
            pass

    if os.path.exists(rebase_merge) or os.path.exists(rebase_apply):
        issues.append({
            "type": "interrupted_rebase",
            "path": rebase_merge if os.path.exists(rebase_merge) else rebase_apply,
            "is_stale": True,
        })

    if issues:
        return {
            "repo": repo_path,
            "git_dir": git_dir,
            "issues": issues,
        }
    return None


def run_audit(
    search_dirs: List[str],
    stale_age_sec: float,
    heal: bool = False,
) -> Dict[str, Any]:
    """Scans repositories and reconciles stale locks if heal=True."""
    repos = find_git_repos(search_dirs)
    findings = []
    healed_count = 0

    for r in repos:
        res = inspect_git_repo(r, stale_age_sec)
        if res:
            for issue in res["issues"]:
                if issue.get("is_stale") and issue["type"] == "index.lock" and heal:
                    try:
                        os.remove(issue["path"])
                        issue["healed"] = True
                        healed_count += 1
                    except Exception as e:
                        issue["heal_error"] = str(e)
            findings.append(res)

    healthy = len(findings) == 0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "total_repos_audited": len(repos),
            "repos_with_locks_or_issues": len(findings),
            "healed_count": healed_count,
            "mode": "heal" if heal else "dry-run",
            "healthy": healthy,
        },
        "findings": findings,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Git Index & Rebase State Lock Auto-Healer (Pattern 33)"
    )
    parser.add_argument(
        "--dirs",
        type=str,
        default=",".join(DEFAULT_SEARCH_PATHS),
        help="Comma-separated search paths for git repos",
    )
    parser.add_argument(
        "--stale-age-sec",
        type=float,
        default=DEFAULT_STALE_AGE_SEC,
        help=f"Threshold in seconds to classify an unheld lock as stale (default: {DEFAULT_STALE_AGE_SEC})",
    )
    parser.add_argument(
        "--heal",
        action="store_true",
        help="Safely remove stale, unheld index.lock files",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if stale locks exist",
    )

    args = parser.parse_args()
    search_dirs = [d.strip() for d in args.dirs.split(",") if d.strip()]
    report = run_audit(search_dirs, args.stale_age_sec, args.heal)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Jev Git Lock Auto-Healer (Pattern 33) — {report['timestamp']}")
        s = report["summary"]
        print(f"  • Repos Audited: {s['total_repos_audited']}")
        print(f"  • Repos with Locks/Issues: {s['repos_with_locks_or_issues']}")
        print(f"  • Execution Mode: {s['mode']}")
        print(f"  • Health Status: {'HEALTHY' if s['healthy'] else 'ACTION REQUIRED'}")
        if report["findings"]:
            print("\n  Findings:")
            for f in report["findings"]:
                print(f"    - {f['repo']}: {[i['type'] for i in f['issues']]}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
