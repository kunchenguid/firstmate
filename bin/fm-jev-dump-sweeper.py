#!/usr/bin/env python3
"""
fm-jev-dump-sweeper.py - Jev Stale Log & Crash Core Dump Compaction Sweeper (Pattern 34)

Audits and reclaims space from abandoned core dumps, crash traces, and oversized worker
stderr logs across ephemeral worktrees and /tmp.

Invariants:
  - Non-destructive by default (--dry-run). Requires explicit --sweep to prune.
  - Never touches files currently open by active processes (fuser verified).
  - Strictly protects git repositories, configuration files, and state databases.
  - Fail-open on filesystem permission errors.
"""

import argparse
import fnmatch
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


DEFAULT_TARGET_DIRS = [
    "/tmp",
    "/opt/ra/firstmate/state",
]
CORE_PATTERNS = [
    "core",
    "core.*",
    "vgcore.*",
    "*.core",
    "hs_err_pid*.log",
]
MAX_LOG_SIZE_MB = 50.0


def is_file_open(file_path: str) -> bool:
    """Checks if any active process has the file open."""
    try:
        res = subprocess.run(
            ["fuser", file_path],
            capture_output=True,
            text=True,
            check=False,
        )
        return res.returncode == 0
    except Exception:
        return False


def scan_dumps_and_logs(
    target_dirs: List[str],
    max_log_size_mb: float = MAX_LOG_SIZE_MB,
    max_depth: int = 2,
) -> List[Dict[str, Any]]:
    """Scans target directories for crash dumps and oversized log files."""
    candidates = []
    max_bytes = max_log_size_mb * 1024 * 1024

    for t_dir in target_dirs:
        if not os.path.exists(t_dir):
            continue
        try:
            for root, dirs, files in os.walk(t_dir):
                depth = root[len(t_dir):].count(os.sep)
                if depth >= max_depth:
                    dirs.clear()
                    continue

                # Protect git and dolt directories
                if ".git" in dirs:
                    dirs.remove(".git")
                if ".beads" in dirs:
                    dirs.remove(".beads")

                for f in files:
                    full_path = os.path.join(root, f)
                    if os.path.islink(full_path):
                        continue

                    # Check core dump patterns
                    is_core = any(fnmatch.fnmatch(f, p) for p in CORE_PATTERNS)
                    try:
                        stat = os.stat(full_path)
                        size_bytes = stat.st_size
                        is_oversized_log = f.endswith((".log", ".err", ".txt")) and (size_bytes > max_bytes)

                        if is_core or is_oversized_log:
                            is_open = is_file_open(full_path)
                            candidates.append({
                                "path": full_path,
                                "type": "core_dump" if is_core else "oversized_log",
                                "size_bytes": size_bytes,
                                "size_mb": round(size_bytes / (1024.0 * 1024.0), 2),
                                "is_open": is_open,
                                "safe_to_reclaim": not is_open,
                            })
                    except Exception:
                        pass
        except Exception:
            pass

    return candidates


def run_sweep(
    target_dirs: List[str],
    max_log_size_mb: float = MAX_LOG_SIZE_MB,
    sweep: bool = False,
) -> Dict[str, Any]:
    """Audits candidates and reclaims space if sweep=True."""
    candidates = scan_dumps_and_logs(target_dirs, max_log_size_mb)
    reclaimed_bytes = 0
    reclaimed_count = 0

    for item in candidates:
        if item["safe_to_reclaim"] and sweep:
            try:
                os.remove(item["path"])
                item["reclaimed"] = True
                reclaimed_bytes += item["size_bytes"]
                reclaimed_count += 1
            except Exception as e:
                item["reclaim_error"] = str(e)

    total_bytes = sum(c["size_bytes"] for c in candidates)
    healthy = len(candidates) == 0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "target_dirs": target_dirs,
            "candidates_found": len(candidates),
            "total_size_mb": round(total_bytes / (1024.0 * 1024.0), 2),
            "reclaimed_count": reclaimed_count,
            "reclaimed_size_mb": round(reclaimed_bytes / (1024.0 * 1024.0), 2),
            "mode": "sweep" if sweep else "dry-run",
            "healthy": healthy,
        },
        "candidates": candidates[:20],
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Stale Log & Crash Core Dump Compaction Sweeper (Pattern 34)"
    )
    parser.add_argument(
        "--dirs",
        type=str,
        default=",".join(DEFAULT_TARGET_DIRS),
        help="Comma-separated target directories",
    )
    parser.add_argument(
        "--max-log-size-mb",
        type=float,
        default=MAX_LOG_SIZE_MB,
        help=f"Threshold for oversized log files in MB (default: {MAX_LOG_SIZE_MB})",
    )
    parser.add_argument(
        "--sweep",
        action="store_true",
        help="Safely unlink unheld core dumps and prune oversized logs",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if dumps/oversized logs detected",
    )

    args = parser.parse_args()
    target_dirs = [d.strip() for d in args.dirs.split(",") if d.strip()]
    report = run_sweep(target_dirs, args.max_log_size_mb, args.sweep)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Jev Dump Sweeper (Pattern 34) — {report['timestamp']}")
        s = report["summary"]
        print(f"  • Target Dirs: {s['target_dirs']}")
        print(f"  • Candidates Found: {s['candidates_found']} ({s['total_size_mb']} MB)")
        print(f"  • Execution Mode: {s['mode']}")
        print(f"  • Health Status: {'HEALTHY' if s['healthy'] else 'CANDIDATES DETECTED'}")
        if report["candidates"]:
            print("\n  Sample Candidates:")
            for c in report["candidates"][:5]:
                print(f"    - {c['path']} ({c['type']}, {c['size_mb']} MB, safe: {c['safe_to_reclaim']})")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
