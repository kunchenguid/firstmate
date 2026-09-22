#!/usr/bin/env python3
"""
fm-jev-worktree-sync.py - Jev Cross-Seat Worktree Convergence & Upstream Sync Engine

Audits active fleet worktrees against upstream origin/main to prevent
divergence, stale CI baselines, and merge collisions.

Computes ahead/behind status, checks working tree cleanliness, and
optionally performs automated safe rebases.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

def run_git(args: List[str], cwd: Path) -> Tuple[int, str, str]:
    try:
        proc = subprocess.run(
            ["git"] + args,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
            check=False,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except Exception as e:
        return 1, "", str(e)

def find_default_branch(worktree: Path) -> Optional[str]:
    # Check origin/main, then origin/master
    rc, _, _ = run_git(["rev-parse", "--verify", "origin/main"], worktree)
    if rc == 0:
        return "origin/main"
    rc, _, _ = run_git(["rev-parse", "--verify", "origin/master"], worktree)
    if rc == 0:
        return "origin/master"
    return None

def get_worktree_repo(worktree: Path) -> str:
    rc, url, _ = run_git(["remote", "get-url", "origin"], worktree)
    if rc == 0 and url:
        clean = url.strip().rstrip("/").removesuffix(".git")
        parts = clean.split("/")
        if len(parts) >= 1:
            last = parts[-1]
            if ":" in last:
                last = last.split(":")[-1]
            return last
    return worktree.name

def inspect_worktree(worktree: Path, auto_sync: bool = False) -> Dict[str, Any]:
    if not (worktree / ".git").exists():
        return {
            "path": str(worktree),
            "status": "NOT_A_GIT_REPO",
            "state": "UNKNOWN",
            "error": "No .git directory or file found",
        }

    # 1. Current branch
    rc, branch, _ = run_git(["rev-parse", "--abbrev-ref", "HEAD"], worktree)
    if rc != 0 or not branch:
        branch = "HEAD"

    # 2. Working tree cleanliness
    rc, status_out, _ = run_git(["status", "--porcelain"], worktree)
    is_clean = (rc == 0 and len(status_out) == 0)
    dirty_files = [line.strip() for line in status_out.splitlines() if line.strip()]

    # 3. Base branch & remote fetch
    base_ref = find_default_branch(worktree)

    def unknown(reason: str) -> Dict[str, Any]:
        return {
            "worktree": str(worktree), "branch": branch, "base_ref": base_ref,
            "ahead": None, "behind": None, "is_clean": is_clean,
            "state": "UNKNOWN", "error": reason, "recommendation": reason,
            "synced": False,
        }

    if base_ref is None:
        return unknown("No origin/main or origin/master reference found")
    base_name = base_ref.split("/", 1)[1]
    rc, _, err = run_git(["fetch", "origin", base_name, "--quiet"], worktree)
    if rc != 0:
        return unknown(f"Upstream fetch failed: {err}")

    rc, counts, err = run_git(["rev-list", "--left-right", "--count", f"HEAD...{base_ref}"], worktree)
    if rc != 0:
        return unknown(f"Upstream comparison failed: {err}")
    try:
        ahead, behind = map(int, counts.split())
        if ahead < 0 or behind < 0:
            raise ValueError("negative commit count")
    except ValueError as exc:
        return unknown(f"Invalid upstream comparison: {exc}")

    # 5. Classify state
    rebased = False
    rebase_error = None
    if behind == 0:
        state = "CONVERGED"
        recommendation = "Up to date with upstream base."
    elif ahead == 0 and behind > 0 and is_clean:
        state = "BEHIND_CLEAN_FF"
        recommendation = f"Behind {base_ref} by {behind} commit(s); eligible for fast-forward."
        if auto_sync:
            rc, _, err = run_git(["merge", "--ff-only", base_ref], worktree)
            if rc == 0:
                rebased = True
                behind = 0
                state = "CONVERGED_AFTER_SYNC"
                recommendation = f"Successfully fast-forwarded to {base_ref}."
            else:
                rebase_error = err
    elif ahead > 0 and behind > 0 and is_clean:
        state = "BEHIND_DIVERGED"
        recommendation = f"Ahead {ahead}, behind {behind} commits; rebase onto {base_ref} recommended."
        if auto_sync:
            rc, _, err = run_git(["rebase", base_ref], worktree)
            if rc == 0:
                rebased = True
                behind = 0
                state = "CONVERGED_AFTER_SYNC"
                recommendation = f"Successfully rebased {ahead} commit(s) onto {base_ref}."
            else:
                run_git(["rebase", "--abort"], worktree)
                rebase_error = f"Rebase conflict detected, aborted cleanly: {err}"
                state = "CONFLICT_REBASE_ABORTED"
                recommendation = "Manual merge resolution required."
    else:
        state = "DIRTY_BEHIND"
        recommendation = f"Behind {base_ref} by {behind} commit(s) with {len(dirty_files)} uncommitted changes; stash required before sync."

    return {
        "worktree": str(worktree),
        "branch": branch,
        "base_ref": base_ref,
        "ahead": ahead,
        "behind": behind,
        "is_clean": is_clean,
        "dirty_files_count": len(dirty_files),
        "state": state,
        "recommendation": recommendation,
        "synced": rebased,
        "sync_error": rebase_error,
    }

def scan_fleet_worktrees(repo_filter: Optional[str] = None) -> List[Path]:
    worktrees = []
    # 1. Check ~/.treehouse/*/tutti
    treehouse_root = Path.home() / ".treehouse"
    if treehouse_root.exists():
        for tutti_dir in treehouse_root.glob("*/[0-9]*/tutti"):
            if tutti_dir.is_dir() and (tutti_dir / ".git").exists():
                worktrees.append(tutti_dir)

    # 2. Check /home/jon/git/*
    git_root = Path("/home/jon/git")
    if git_root.exists():
        for p in git_root.glob("wt-*"):
            if p.is_dir() and (p / ".git").exists():
                worktrees.append(p)
        for name in ("jev", "firstmate", "Portal", "Zeta", "beads"):
            p = git_root / name
            if p.is_dir() and (p / ".git").exists():
                worktrees.append(p)

    unique_worktrees = sorted(list(set(worktrees)))
    if not repo_filter:
        return unique_worktrees

    filtered = []
    rf_lower = repo_filter.lower()
    for w in unique_worktrees:
        repo_name = get_worktree_repo(w).lower()
        if rf_lower in repo_name or rf_lower in w.name.lower():
            filtered.append(w)
    return filtered

def format_summary(results: List[Dict[str, Any]], repo_filter: Optional[str] = None) -> str:
    lines = []
    header = "Jev Worktree Convergence Audit"
    if repo_filter:
        header += f" for repository '{repo_filter}'"
    header += f" ({len(results)} worktree{'s' if len(results) != 1 else ''} scanned):"
    lines.append(header)
    if not results:
        lines.append(f"  ✓ No active fleet worktrees found matching '{repo_filter}'.")
        return "\n".join(lines)
    for r in results:
        state = r.get("state", "UNKNOWN")
        symbol = "✓" if "CONVERGED" in state else ("⚠️" if "BEHIND" in state else "❌")
        name = Path(r.get("worktree", "")).name
        parent = Path(r.get("worktree", "")).parent.name
        label = f"{parent}/{name}" if parent else name
        lines.append(f"  {symbol} {label} [{r.get('branch')}]: {state} (ahead: {r.get('ahead')}, behind: {r.get('behind')})")
        lines.append(f"     → {r.get('recommendation')}")
        if r.get("synced"):
            lines.append(f"     ✓ Auto-sync applied successfully")
        if r.get("sync_error"):
            lines.append(f"     ! Sync warning: {r.get('sync_error')}")
    return "\n".join(lines)

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Cross-Seat Worktree Convergence & Upstream Sync Engine (Pattern 15)"
    )
    parser.add_argument("--worktree", default=None, help="Specific worktree path to audit")
    parser.add_argument("--repo-name", default=None, help="Filter fleet worktrees by repository name")
    parser.add_argument("--scan-all", action="store_true", help="Scan all active fleet worktrees")
    parser.add_argument("--auto-sync", action="store_true", help="Safely fast-forward or rebase clean behind worktrees")
    parser.add_argument("--json", action="store_true", help="Output JSON format")

    args = parser.parse_args()

    targets: List[Path] = []
    if args.worktree:
        targets.append(Path(args.worktree))
    elif args.scan_all or args.repo_name or not args.worktree:
        targets = scan_fleet_worktrees(repo_filter=args.repo_name)

    results = [inspect_worktree(t, auto_sync=args.auto_sync) for t in targets]

    if args.json:
        print(json.dumps(results, indent=2))
    else:
        print(format_summary(results, repo_filter=args.repo_name))

    diverged_count = sum(1 for r in results if "CONFLICT" in r.get("state", "") or "error" in r)
    return 1 if diverged_count > 0 else 0

if __name__ == "__main__":
    sys.exit(main())
