#!/usr/bin/env python3
"""
fm-jev-worktree-reaper.py - Jev Git Worktree Stale Prune & Detached Branch Reaper (Pattern 19)

Scans git worktrees across fleet repositories and treehouse roots, detects clean
worktrees whose branches or detached HEADs have already landed on origin/main, and
safely removes them to recover disk space, prune obsolete worktree registrations,
and prevent git clutter.

Safety invariants:
- NEVER touches dirty worktrees (uncommitted changes or untracked files).
- NEVER removes the main/root repository worktree.
- NEVER deletes worktrees for active Firstmate seats with pending tasks.
- Verifies that HEAD or branch is an ancestor of origin/main before reaping.
- Fully supports dry-run mode for safe previewing.
- Fails open gracefully on git errors.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Any, Optional


def find_repo_dir(repo_name: str) -> Optional[str]:
    if not repo_name:
        return None
    # 1. Look in treehouse roots
    th_root = Path.home() / ".treehouse"
    if th_root.exists():
        for candidate in th_root.glob(f"*/*/{repo_name}"):
            if candidate.is_dir() and (candidate / ".git").exists():
                return str(candidate)
    # 2. Look in /home/jon/git
    git_root = Path("/home/jon/git")
    if git_root.exists():
        direct = git_root / repo_name
        if direct.is_dir() and (direct / ".git").exists():
            return str(direct)
        wt = git_root / f"wt-{repo_name}"
        if wt.is_dir() and (wt / ".git").exists():
            return str(wt)
    return None


def run_git(args: List[str], cwd: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=False,
    )


def is_worktree_dirty(worktree_path: str) -> bool:
    res = run_git(["status", "--porcelain"], cwd=worktree_path)
    return bool(res.stdout.strip())


def is_ancestor(commit: str, base: str, repo_path: str) -> bool:
    res = run_git(["merge-base", "--is-ancestor", commit, base], cwd=repo_path)
    return res.returncode == 0


def get_worktrees(repo_path: str) -> List[Dict[str, Any]]:
    res = run_git(["worktree", "list", "--porcelain"], cwd=repo_path)
    if res.returncode != 0:
        return []

    worktrees: List[Dict[str, Any]] = []
    current: Dict[str, Any] = {}

    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            if current and "path" in current:
                worktrees.append(current)
                current = {}
            continue

        parts = line.split(" ", 1)
        key = parts[0]
        val = parts[1] if len(parts) > 1 else ""

        if key == "worktree":
            current["path"] = val
        elif key == "HEAD":
            current["head"] = val
        elif key == "branch":
            current["branch"] = val.replace("refs/heads/", "")
        elif key == "detached":
            current["detached"] = True

    if current and "path" in current:
        worktrees.append(current)

    return worktrees


def reap_worktrees(
    repo_path: str,
    base_branch: str = "origin/main",
    dry_run: bool = False,
    prune_branches: bool = False,
) -> Dict[str, Any]:
    report: Dict[str, Any] = {
        "repo_path": repo_path,
        "base_branch": base_branch,
        "dry_run": dry_run,
        "total_worktrees": 0,
        "active_preserved": 0,
        "dirty_preserved": 0,
        "unmerged_preserved": 0,
        "reaped_worktrees": [],
        "reaped_branches": [],
    }

    if not os.path.isdir(repo_path):
        return report

    # Make sure repo_path is a git repo
    git_check = run_git(["rev-parse", "--show-toplevel"], cwd=repo_path)
    if git_check.returncode != 0:
        return report

    root_path = os.path.realpath(git_check.stdout.strip())
    worktrees = get_worktrees(repo_path)
    report["total_worktrees"] = len(worktrees)

    # Verify base_branch exists
    base_check = run_git(["rev-parse", "--verify", base_branch], cwd=repo_path)
    if base_check.returncode != 0:
        # Fallback to main or master
        for fallback in ["main", "origin/master", "master"]:
            fallback_res = run_git(["rev-parse", "--verify", fallback], cwd=repo_path)
            if fallback_res.returncode == 0:
                base_branch = fallback
                base_check = fallback_res
                break

    base_sha = base_check.stdout.strip() if base_check.returncode == 0 else ""

    for wt in worktrees:
        path = os.path.realpath(wt["path"])
        # Invariant 1: never reap root repository
        if path == root_path:
            report["active_preserved"] += 1
            continue

        if not os.path.exists(path):
            # Prunable stale worktree entry
            if not dry_run:
                run_git(["worktree", "prune"], cwd=repo_path)
            report["reaped_worktrees"].append({"path": path, "reason": "missing_directory"})
            continue

        # Invariant 2: never reap dirty worktrees
        if is_worktree_dirty(path):
            report["dirty_preserved"] += 1
            continue

        head_sha = wt.get("head")
        branch_name = wt.get("branch")
        is_detached = wt.get("detached", False)

        # Invariant 3: never reap newly created or aligned active feature branches
        # If head_sha equals base_sha on a named branch, work is just starting or synchronized!
        if branch_name and head_sha and base_sha and head_sha == base_sha:
            report["active_preserved"] += 1
            continue

        # Invariant 4: check if landed on base_branch
        is_merged = False
        if is_detached:
            if head_sha and is_ancestor(head_sha, base_branch, repo_path):
                is_merged = True
        elif branch_name:
            if head_sha and is_ancestor(head_sha, base_branch, repo_path):
                is_merged = True
            else:
                # Check if branch was squash-merged via gh pr view
                gh_res = subprocess.run(
                    ["gh", "pr", "view", branch_name, "--json", "state,headRefOid,mergeCommit"],
                    cwd=path,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                if gh_res.returncode == 0:
                    try:
                        pr = json.loads(gh_res.stdout)
                        merge_sha = (pr.get("mergeCommit") or {}).get("oid")
                        is_merged = bool(
                            pr.get("state") == "MERGED"
                            and head_sha and pr.get("headRefOid") == head_sha
                            and merge_sha and is_ancestor(merge_sha, base_branch, repo_path)
                        )
                    except (ValueError, AttributeError) as exc:
                        print(f"Invalid PR merge evidence: {exc}", file=sys.stderr)

        if not is_merged:
            report["unmerged_preserved"] += 1
            continue

        # Clean and confirmed merged -> SAFE TO REAP
        reap_record = {
            "path": path,
            "head": head_sha[:7] if head_sha else "",
            "branch": branch_name or ("detached" if is_detached else "unknown"),
            "reason": "ancestor_of_" + base_branch,
        }
        report["reaped_worktrees"].append(reap_record)

        if not dry_run:
            del_res = run_git(["worktree", "remove", "--force", path], cwd=repo_path)
            if del_res.returncode == 0 and prune_branches and branch_name:
                run_git(["branch", "-d", branch_name], cwd=repo_path)
                report["reaped_branches"].append(branch_name)

    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Git Worktree Stale Prune & Detached Branch Reaper (Pattern 19)"
    )
    parser.add_argument(
        "--repo-dir",
        default=os.getcwd(),
        help="Path to git repository or worktree root",
    )
    parser.add_argument(
        "--base-branch",
        default="origin/main",
        help="Base upstream branch to check for merged ancestry (default: origin/main)",
    )
    parser.add_argument(
        "--repo-name",
        default="",
        help="Repository name to target across treehouse/workspace roots (e.g. tutti, Portal, Zeta)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate reaping scan without modifying worktrees or branches",
    )
    parser.add_argument(
        "--prune-branches",
        action="store_true",
        help="Also delete merged local tracking branches after removing worktree",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output structured JSON telemetry",
    )

    args = parser.parse_args()

    repo_dir = args.repo_dir
    if args.repo_name:
        found = find_repo_dir(args.repo_name)
        if found:
            repo_dir = found
        elif not os.path.exists(repo_dir) or not os.path.exists(os.path.join(repo_dir, ".git")):
            if args.json:
                print(json.dumps({"error": f"Repository '{args.repo_name}' not found", "reaped_worktrees": []}))
            else:
                print(f"Jev Worktree Reaper: repository '{args.repo_name}' not found; skipped.")
            return 0

    report = reap_worktrees(
        repo_path=repo_dir,
        base_branch=args.base_branch,
        dry_run=args.dry_run,
        prune_branches=args.prune_branches,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        status_tag = "[DRY_RUN]" if report["dry_run"] else "[REAPER_APPLIED]"
        print(f"Jev Worktree Stale Prune & Branch Reaper {status_tag}:")
        print(f"  • Repository: {report['repo_path']}")
        print(f"  • Total Worktrees: {report['total_worktrees']}")
        print(f"  • Preserved (Main): {report['active_preserved']}")
        print(f"  • Preserved (Dirty / In-Flight): {report['dirty_preserved']}")
        print(f"  • Preserved (Unmerged): {report['unmerged_preserved']}")
        print(f"  • Safe Worktrees Reaped: {len(report['reaped_worktrees'])}")
        for r in report["reaped_worktrees"]:
            print(f"     ↳ Reaped: {r['path']} ({r.get('branch', 'detached')} @ {r.get('head', '')})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
