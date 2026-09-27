#!/usr/bin/env python3
"""fm-jev-ref-aligner.py - Jev Cross-Seat Git Ref & Divergence Auto-Realigner (Pattern 24).

Scans registered git worktrees across treehouses and project pools, detects stale
branches tracking origin/main or origin/master following squash-merges, safely
fast-forwards clean tracking branches, and reports divergence telemetry.

Invariants:
  - Non-destructive: strictly skips dirty worktrees.
  - Fail-open: errors on individual worktrees do not block evaluation.
  - Fast-forward only: never forces, stashes, or executes non-trivial merges.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


def run_git(cwd: Path, args: List[str], timeout: int = 10) -> Optional[str]:
    try:
        res = subprocess.run(
            ["git", "-C", str(cwd)] + args,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        if res.returncode == 0:
            return res.stdout.strip()
        return None
    except Exception:
        return None


def is_git_worktree_or_repo(path: Path) -> bool:
    if not path.is_dir():
        return False
    git_dir = path / ".git"
    return git_dir.exists()


def find_git_directories(root_paths: List[Path], max_depth: int = 3) -> List[Path]:
    git_dirs: List[Path] = []
    seen = set()

    for root in root_paths:
        if not root.exists() or not root.is_dir():
            continue
        try:
            # Check root itself
            if is_git_worktree_or_repo(root):
                resolved = root.resolve()
                if resolved not in seen:
                    seen.add(resolved)
                    git_dirs.append(root)

            # Walk subdirectories up to max_depth
            for dirpath, dirnames, _ in os.walk(root):
                # Prune noisy / deep folders
                dirnames[:] = [
                    d for d in dirnames
                    if d not in (".git", "node_modules", "vendor", "dist", "build", ".venv", ".next", ".cache", "tmp")
                ]

                p = Path(dirpath)
                try:
                    rel_depth = len(p.relative_to(root).parts)
                except ValueError:
                    rel_depth = 0

                if rel_depth > max_depth:
                    dirnames.clear()
                    continue

                if is_git_worktree_or_repo(p):
                    resolved = p.resolve()
                    if resolved not in seen:
                        seen.add(resolved)
                        git_dirs.append(p)
                    # Don't recurse into children of a git repository
                    dirnames.clear()
        except Exception:
            continue


    return sorted(git_dirs)


def inspect_worktree(path: Path, auto_ff: bool = False, dry_run: bool = False) -> Dict[str, Any]:
    record: Dict[str, Any] = {
        "path": str(path),
        "name": path.name,
        "is_clean": False,
        "branch": None,
        "remote_tracking": None,
        "ahead": 0,
        "behind": 0,
        "status": "unknown",
        "action": "none",
    }

    # 1. Branch detection
    branch = run_git(path, ["rev-parse", "--abbrev-ref", "HEAD"])
    if not branch:
        record["status"] = "unreadable"
        return record
    record["branch"] = branch

    # 2. Check for dirty status
    status_out = run_git(path, ["status", "--porcelain"])
    if status_out is None:
        record["status"] = "status_failed"
        return record
    is_clean = len(status_out.strip()) == 0
    record["is_clean"] = is_clean

    # 3. Determine remote tracking branch
    upstream = run_git(path, ["rev-parse", "--abbrev-ref", f"{branch}@{{upstream}}"])
    if not upstream:
        # Fallback to origin/main or origin/master if on default branch
        if branch in ("main", "master"):
            for candidate in (f"origin/{branch}", "origin/main", "origin/master"):
                if run_git(path, ["rev-parse", "--verify", candidate]):
                    upstream = candidate
                    break

    if not upstream:
        record["status"] = "no_upstream"
        return record
    record["remote_tracking"] = upstream

    # 4. Count divergence
    counts = run_git(path, ["rev-list", "--left-right", "--count", f"HEAD...{upstream}"])
    if counts:
        parts = counts.split()
        if len(parts) == 2:
            record["ahead"] = int(parts[0])
            record["behind"] = int(parts[1])

    ahead = record["ahead"]
    behind = record["behind"]

    if ahead == 0 and behind == 0:
        record["status"] = "up_to_date"
    elif ahead == 0 and behind > 0:
        record["status"] = "behind"
        if is_clean and auto_ff:
            if dry_run:
                record["action"] = f"would_ff_{behind}_commits"
            else:
                ff_res = run_git(path, ["merge", "--ff-only", upstream])
                if ff_res is not None:
                    record["action"] = f"fast_forwarded_{behind}_commits"
                    record["status"] = "up_to_date"
                    record["behind"] = 0
                else:
                    record["action"] = "ff_failed"
        else:
            record["action"] = "ff_skipped_dirty" if not is_clean else "ff_disabled"
    elif ahead > 0 and behind == 0:
        record["status"] = "ahead"
    else:
        record["status"] = "diverged"
        record["action"] = "rebase_required"

    return record


def main() -> int:
    parser = argparse.ArgumentParser(description="Jev Cross-Seat Git Ref & Divergence Auto-Realigner (Pattern 24)")
    parser.add_argument(
        "--roots",
        type=str,
        default=os.environ.get("FM_REF_ALIGNER_ROOTS", "~/.treehouse,/home/jon/git,/opt/ra/firstmate/projects"),
        help="Comma-separated paths to scan for git worktrees",
    )
    parser.add_argument("--auto-ff", action="store_true", help="Automatically fast-forward clean tracking branches behind remote")
    parser.add_argument("--dry-run", action="store_true", help="Simulate actions without modifying git state")
    parser.add_argument("--max-depth", type=int, default=3, help="Max scan depth")
    parser.add_argument("--json", action="store_true", help="Output JSON format")

    args = parser.parse_args()

    raw_roots = [p.strip() for p in args.roots.split(",") if p.strip()]
    root_paths = [Path(os.path.expanduser(p)) for p in raw_roots]

    git_dirs = find_git_directories(root_paths, max_depth=args.max_depth)

    results: List[Dict[str, Any]] = []
    clean_count = 0
    dirty_count = 0
    behind_count = 0
    up_to_date_count = 0
    diverged_count = 0
    realigned_count = 0

    for gd in git_dirs:
        info = inspect_worktree(gd, auto_ff=args.auto_ff, dry_run=args.dry_run)
        results.append(info)
        if info["is_clean"]:
            clean_count += 1
        else:
            dirty_count += 1

        status = info["status"]
        if status == "up_to_date":
            up_to_date_count += 1
        elif status == "behind":
            behind_count += 1
        elif status == "diverged":
            diverged_count += 1

        if "fast_forwarded" in info.get("action", "") or "would_ff" in info.get("action", ""):
            realigned_count += 1

    telemetry = {
        "timestamp": os.popen("date -u +%Y-%m-%dT%H:%M:%SZ").read().strip(),
        "summary": {
            "total_scanned": len(results),
            "clean_worktrees": clean_count,
            "dirty_worktrees": dirty_count,
            "up_to_date": up_to_date_count,
            "behind": behind_count,
            "diverged": diverged_count,
            "realigned": realigned_count,
        },
        "worktrees": results,
    }

    if args.json:
        print(json.dumps(telemetry, indent=2))
    else:
        s = telemetry["summary"]
        print(f"Jev Git Ref & Divergence Realigner (Pattern 24):")
        print(f"  • Total Scanned Worktrees: {s['total_scanned']}")
        print(f"  • Clean: {s['clean_worktrees']} | Dirty: {s['dirty_worktrees']}")
        print(f"  • Up to date: {s['up_to_date']} | Behind: {s['behind']} | Diverged: {s['diverged']}")
        print(f"  • Realigned: {s['realigned']}")
        for w in results:
            if w["status"] in ("behind", "diverged") or w["action"] != "none":
                print(f"    - {w['name']} ({w['branch']} -> {w['remote_tracking']}): {w['status']} (ahead={w['ahead']}, behind={w['behind']}) => action: {w['action']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
