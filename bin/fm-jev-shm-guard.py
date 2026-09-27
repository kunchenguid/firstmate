#!/usr/bin/env python3
"""
fm-jev-shm-guard.py - Jev Multi-Agent POSIX Shared Memory & Semaphore Leak Guard (Pattern 42)

Audits /dev/shm tmpfs capacity and lingering abandoned shared memory files (e.g. dead
Chromium/Playwright render buffers, old IPC semaphores) to prevent /dev/shm exhaustion,
SIGBUS crashes, and Chromium renderer initialization failures.

Invariants:
  - Read-only diagnostics by default (--dry-run).
  - Never touches files currently held by live processes (fuser verified).
  - Only targets confirmed abandoned browser render buffers older than min age threshold.
  - Fail-open on filesystem permission errors.
"""

import argparse
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Tuple


SHM_PATH = "/dev/shm"
TARGET_PATTERNS = [
    ".com.google.Chrome.*",
    "org.chromium.*",
    "playwright-*",
    "sem.mp-*",
]
MIN_STALE_AGE_SEC = 3600  # Files must be at least 1h old to be considered abandoned


def get_shm_disk_usage() -> Tuple[int, int, float]:
    """Returns (total_bytes, used_bytes, usage_pct) for /dev/shm."""
    try:
        usage = shutil.disk_usage(SHM_PATH)
        pct = (usage.used / usage.total * 100.0) if usage.total > 0 else 0.0
        return usage.total, usage.used, round(pct, 2)
    except Exception:
        return 0, 0, 0.0


def is_file_open(file_path: str) -> bool | None:
    """Checks if any active process holds an open file descriptor to the file."""
    try:
        res = subprocess.run(
            ["fuser", file_path],
            capture_output=True,
            text=True,
            check=False,
            timeout=1.0,
        )
        if res.returncode == 0:
            return True
        if res.returncode == 1 and not res.stderr.strip():
            return False
        print(f"Ownership probe failed for {file_path}: {res.stderr.strip()}", file=sys.stderr)
    except Exception as exc:
        print(f"Ownership probe unavailable: {exc}", file=sys.stderr)
    return None


def get_sysv_ipc_counts() -> Tuple[int, int]:
    """Returns count of active SysV shared memory segments and semaphores."""
    shm_count = 0
    sem_count = 0
    try:
        res = subprocess.run(["ipcs", "-m"], capture_output=True, text=True, check=False, timeout=1.0)
        lines = [line.strip() for line in res.stdout.splitlines() if line.strip() and line[0].isdigit()]
        shm_count = len(lines)
    except Exception:
        pass

    try:
        res = subprocess.run(["ipcs", "-s"], capture_output=True, text=True, check=False, timeout=1.0)
        lines = [line.strip() for line in res.stdout.splitlines() if line.strip() and line[0].isdigit()]
        sem_count = len(lines)
    except Exception:
        pass

    return shm_count, sem_count


def audit_shm(
    warning_pct: float = 75.0,
    critical_pct: float = 90.0,
    stale_age_sec: int = MIN_STALE_AGE_SEC,
    sweep: bool = False,
) -> Dict[str, Any]:
    """Audits /dev/shm usage and candidate abandoned files."""
    total_bytes, used_bytes, usage_pct = get_shm_disk_usage()
    sysv_shm, sysv_sem = get_sysv_ipc_counts()

    now = time.time()
    candidates: List[Dict[str, Any]] = []
    reclaimed_bytes = 0
    reclaimed_count = 0

    if os.path.exists(SHM_PATH):
        try:
            for entry in os.listdir(SHM_PATH):
                full_path = os.path.join(SHM_PATH, entry)
                if os.path.islink(full_path):
                    continue

                # Match patterns
                matches = any(fnmatch.fnmatch(entry, pat) for pat in TARGET_PATTERNS)
                if not matches:
                    continue

                try:
                    stat = os.stat(full_path)
                    age = now - stat.st_mtime
                    if age >= stale_age_sec:
                        open_by_proc = is_file_open(full_path)
                        is_safe = open_by_proc is False

                        if is_safe and sweep:
                            try:
                                if os.path.isfile(full_path):
                                    os.remove(full_path)
                                    reclaimed_bytes += stat.st_size
                                    reclaimed_count += 1
                            except Exception:
                                pass

                        candidates.append({
                            "path": full_path,
                            "filename": entry,
                            "size_bytes": stat.st_size,
                            "size_mb": round(stat.st_size / (1024.0 * 1024.0), 2),
                            "age_hours": round(age / 3600.0, 1),
                            "is_open": open_by_proc,
                            "safe_to_reclaim": is_safe,
                        })
                except Exception:
                    continue
        except Exception:
            pass

    healthy = usage_pct < warning_pct
    status = "HEALTHY"
    if usage_pct >= critical_pct:
        status = "CRITICAL"
    elif usage_pct >= warning_pct:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": healthy,
            "shm_total_bytes": total_bytes,
            "shm_total_gb": round(total_bytes / (1024.0 ** 3), 2),
            "shm_used_bytes": used_bytes,
            "shm_used_mb": round(used_bytes / (1024.0 * 1024.0), 2),
            "usage_pct": usage_pct,
            "abandoned_candidates_count": len(candidates),
            "reclaimed_count": reclaimed_count,
            "reclaimed_bytes": reclaimed_bytes,
            "sysv_shm_segments": sysv_shm,
            "sysv_semaphores": sysv_sem,
            "mode": "sweep" if sweep else "dry-run",
        },
        "candidates_sample": candidates[:10],
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent POSIX Shared Memory & Semaphore Leak Guard (Pattern 42)"
    )
    parser.add_argument(
        "--warning-pct",
        type=float,
        default=75.0,
        help="Warning threshold percentage for /dev/shm usage (default: 75.0)",
    )
    parser.add_argument(
        "--critical-pct",
        type=float,
        default=90.0,
        help="Critical threshold percentage for /dev/shm usage (default: 90.0)",
    )
    parser.add_argument(
        "--stale-age-sec",
        type=int,
        default=MIN_STALE_AGE_SEC,
        help=f"Minimum age in seconds to consider shared memory stale (default: {MIN_STALE_AGE_SEC})",
    )
    parser.add_argument(
        "--sweep",
        action="store_true",
        help="Reclaim confirmed abandoned files (dry-run by default)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if warning or critical threshold exceeded",
    )

    args = parser.parse_args()
    report = audit_shm(
        warning_pct=args.warning_pct,
        critical_pct=args.critical_pct,
        stale_age_sec=args.stale_age_sec,
        sweep=args.sweep,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev POSIX Shared Memory Guard (Pattern 42) — {report['timestamp']}")
        print(f"  • Status: {s['status']} ({s['mode']})")
        print(f"  • /dev/shm Usage: {s['shm_used_mb']:.2f} MB / {s['shm_total_gb']:.2f} GB ({s['usage_pct']}%)")
        print(f"  • Stale Browser Candidates: {s['abandoned_candidates_count']} found")
        print(f"  • SysV IPC: {s['sysv_shm_segments']} shm segments, {s['sysv_semaphores']} semaphores")
        if report["candidates_sample"]:
            print("\n  Sample Stale Shared Memory Files:")
            for item in report["candidates_sample"][:5]:
                print(f"    - {item['filename']} ({item['size_mb']} MB, {item['age_hours']}h old, safe: {item['safe_to_reclaim']})")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
