#!/usr/bin/env python3
"""fm-jev-fd-guard.py - Jev Multi-Agent Host Open File Descriptor & ulimit Exhaustion Guard

Audits open file descriptor consumption across multi-agent processes (e.g., herdr, runners,
language servers, test workers) and compares against system-wide and per-process ulimits.
Detects fd leaks before 'EMFILE: Too many open files' breaks autonomous workers.

Invariants:
- Fail-open: Never crashes caller; returns non-destructive status on probe errors.
- Non-destructive: Read-only inspection via /proc filesystem; never mutates processes.
- Structured telemetry: Emits machine-readable JSON for supervisor logging.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from typing import Any, Dict, List, Optional, Tuple


def get_system_file_nr() -> Dict[str, int]:
    """Read system-wide file descriptor allocation from /proc/sys/fs/file-nr."""
    try:
        with open("/proc/sys/fs/file-nr", "r", encoding="utf-8") as f:
            parts = f.readline().split()
            allocated = int(parts[0])
            unused = int(parts[1])
            maximum = int(parts[2])
            return {
                "allocated": allocated,
                "unused": unused,
                "maximum": maximum,
            }
    except Exception:
        return {"allocated": 0, "unused": 0, "maximum": 0}


def get_process_limits(pid: int) -> Tuple[int, int]:
    """Read soft and hard Max open files limit from /proc/[pid]/limits."""
    soft, hard = 1024, 1048576
    try:
        with open(f"/proc/{pid}/limits", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("Max open files"):
                    parts = line.split()[3:5]
                    soft = int(parts[0]) if parts[0] != "unlimited" else 1048576
                    hard = int(parts[1]) if parts[1] != "unlimited" else 1048576
                    break
    except Exception:
        pass
    return soft, hard


def get_process_comm(pid: int) -> str:
    """Read process command name from /proc/[pid]/comm."""
    try:
        with open(f"/proc/{pid}/comm", "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return "unknown"


def audit_process_fds(
    warn_threshold: float = 0.75, warn_count: int = 5000
) -> Dict[str, Any]:
    """Audit open file descriptors across all user-accessible processes."""
    my_uid = os.getuid()
    audited_procs: List[Dict[str, Any]] = []
    flagged_procs: List[Dict[str, Any]] = []
    total_fds = 0

    try:
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            pid = int(entry)
            fd_dir = f"/proc/{pid}/fd"
            if not os.path.isdir(fd_dir) or not os.access(fd_dir, os.R_OK):
                continue

            try:
                # Check process ownership
                stat_info = os.stat(f"/proc/{pid}")
                if stat_info.st_uid != my_uid:
                    continue

                fd_entries = os.listdir(fd_dir)
                fd_count = len(fd_entries)
                total_fds += fd_count

                if fd_count < 10:
                    continue  # Skip trivial processes to keep telemetry concise

                soft_limit, hard_limit = get_process_limits(pid)
                comm = get_process_comm(pid)
                ratio = fd_count / max(soft_limit, 1)

                proc_info = {
                    "pid": pid,
                    "comm": comm,
                    "open_fds": fd_count,
                    "soft_limit": soft_limit,
                    "hard_limit": hard_limit,
                    "usage_ratio": round(ratio, 4),
                }
                audited_procs.append(proc_info)

                if ratio >= warn_threshold or fd_count >= warn_count:
                    proc_info["reason"] = (
                        f"usage_ratio_{round(ratio*100, 1)}%_exceeds_{int(warn_threshold*100)}%"
                        if ratio >= warn_threshold
                        else f"fd_count_{fd_count}_exceeds_{warn_count}"
                    )
                    flagged_procs.append(proc_info)

            except (PermissionError, FileNotFoundError, ProcessLookupError):
                continue
    except Exception as e:
        return {
            "error": str(e),
            "healthy": True,  # Fail open
            "audited_processes_count": 0,
            "flagged_processes_count": 0,
        }

    # Sort audited processes by open_fds descending
    audited_procs.sort(key=lambda x: x["open_fds"], reverse=True)
    top_procs = audited_procs[:15]

    sys_file_nr = get_system_file_nr()
    healthy = len(flagged_procs) == 0

    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "healthy": healthy,
        "total_user_open_fds": total_fds,
        "audited_processes_count": len(audited_procs),
        "flagged_processes_count": len(flagged_procs),
        "flagged_processes": flagged_procs,
        "top_processes_by_fds": top_procs,
        "system_file_nr": sys_file_nr,
        "warn_threshold_ratio": warn_threshold,
        "warn_count_threshold": warn_count,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Host Open File Descriptor & ulimit Exhaustion Guard"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Run health check and return 0 if healthy, 1 if any process exceeds limit threshold",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry",
    )
    parser.add_argument(
        "--warn-threshold",
        type=float,
        default=0.75,
        help="Warning ratio of open fds to soft limit (default: 0.75)",
    )
    parser.add_argument(
        "--warn-count",
        type=int,
        default=5000,
        help="Absolute open fd count threshold to flag (default: 5000)",
    )
    args = parser.parse_args()

    result = audit_process_fds(
        warn_threshold=args.warn_threshold, warn_count=args.warn_count
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_str = "HEALTHY" if result.get("healthy") else "EXHAUSTION_WARNING"
        print(f"File Descriptor Guard: {status_str}")
        print(f"  • Total User Open FDs: {result.get('total_user_open_fds', 0)}")
        print(f"  • Audited Processes: {result.get('audited_processes_count', 0)}")
        print(f"  • Flagged Processes: {result.get('flagged_processes_count', 0)}")
        sys_nr = result.get("system_file_nr", {})
        if sys_nr.get("allocated"):
            print(f"  • System-Wide FDs: {sys_nr['allocated']} allocated")
        top = result.get("top_processes_by_fds", [])
        if top:
            print("  • Top FD Consumers:")
            for p in top[:5]:
                print(
                    f"    - [{p['pid']}] {p['comm']}: {p['open_fds']} fds ({round(p['usage_ratio']*100, 1)}% of {p['soft_limit']})"
                )

    if args.check:
        return 0 if result.get("healthy", True) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
