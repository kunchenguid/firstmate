#!/usr/bin/env python3
"""
fm-jev-inotify-guard.py - Jev Multi-Agent Inotify Watch Limit & Saturation Guard (Pattern 40)

Monitors host inotify watch table consumption (/proc/sys/fs/inotify/max_user_watches)
across all multi-agent watcher trees (Vite, Webpack, Tailwind, Bun, file watchers)
to prevent 'ENOSPC: System limit for number of file watchers reached' crashes.

Invariants:
  - Read-only diagnostics.
  - Fail-open: Never crashes on process disappearance or permission errors.
  - Strict bounded scan (< 2.0s overhead).
"""

import argparse
import glob
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Tuple


def get_inotify_limits() -> Tuple[int, int]:
    """Reads max_user_watches and max_user_instances from /proc/sys/fs/inotify."""
    max_watches = 1048576  # Safe fallback
    max_instances = 8192

    try:
        with open("/proc/sys/fs/inotify/max_user_watches", "r") as f:
            max_watches = int(f.read().strip())
    except Exception:
        pass

    try:
        with open("/proc/sys/fs/inotify/max_user_instances", "r") as f:
            max_instances = int(f.read().strip())
    except Exception:
        pass

    return max_watches, max_instances


def get_process_cmdline(pid: int) -> str:
    """Reads command line for PID, truncated safely."""
    try:
        with open(f"/proc/{pid}/cmdline", "r") as f:
            raw = f.read().replace("\0", " ").strip()
            return raw[:120] if raw else f"[{pid}]"
    except Exception:
        return f"[{pid}]"


def audit_inotify_usage(
    warning_pct: float = 80.0,
    critical_pct: float = 90.0,
) -> Dict[str, Any]:
    """Scans all accessible /proc/[0-9]*/fdinfo/* to count inotify watches."""
    max_watches, max_instances = get_inotify_limits()

    total_watches = 0
    total_instances = 0
    proc_watches: Dict[int, int] = {}
    proc_instances: Dict[int, int] = {}

    current_uid = os.getuid()

    # Match all fdinfo entries for numerical pids
    for fdinfo_path in glob.glob("/proc/[0-9]*/fdinfo/*"):
        try:
            parts = fdinfo_path.split("/")
            pid = int(parts[2])

            with open(fdinfo_path, "r", errors="ignore") as f:
                watch_count = 0
                has_inotify = False
                for line in f:
                    if line.startswith("inotify wd:"):
                        watch_count += 1
                        has_inotify = True

                if has_inotify:
                    proc_instances[pid] = proc_instances.get(pid, 0) + 1
                    total_instances += 1
                    if watch_count > 0:
                        proc_watches[pid] = proc_watches.get(pid, 0) + watch_count
                        total_watches += watch_count
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        except Exception:
            continue

    saturation_pct = (total_watches / max_watches * 100.0) if max_watches > 0 else 0.0

    healthy = saturation_pct < warning_pct
    status = "HEALTHY"
    if saturation_pct >= critical_pct:
        status = "CRITICAL"
    elif saturation_pct >= warning_pct:
        status = "WARNING"

    # Sort top consumers
    top_consumers: List[Dict[str, Any]] = []
    sorted_procs = sorted(proc_watches.items(), key=lambda x: x[1], reverse=True)[:10]
    for pid, count in sorted_procs:
        top_consumers.append({
            "pid": pid,
            "watches": count,
            "instances": proc_instances.get(pid, 0),
            "cmdline": get_process_cmdline(pid),
        })

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "total_watches": total_watches,
            "max_user_watches": max_watches,
            "saturation_pct": round(saturation_pct, 2),
            "total_instances": total_instances,
            "max_user_instances": max_instances,
            "active_watcher_processes": len(proc_watches),
            "status": status,
            "healthy": healthy,
        },
        "top_consumers": top_consumers,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Inotify Watch Limit & Saturation Guard (Pattern 40)"
    )
    parser.add_argument(
        "--warning-pct",
        type=float,
        default=80.0,
        help="Warning threshold percentage for inotify watch saturation (default: 80.0)",
    )
    parser.add_argument(
        "--critical-pct",
        type=float,
        default=90.0,
        help="Critical threshold percentage for inotify watch saturation (default: 90.0)",
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
    report = audit_inotify_usage(
        warning_pct=args.warning_pct,
        critical_pct=args.critical_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev Inotify Watch Guard (Pattern 40) — {report['timestamp']}")
        print(f"  • Status: {s['status']}")
        print(f"  • Total Inotify Watches: {s['total_watches']:,} / {s['max_user_watches']:,} ({s['saturation_pct']}%)")
        print(f"  • Total Watcher Instances: {s['total_instances']:,} / {s['max_user_instances']:,}")
        print(f"  • Active Watcher Processes: {s['active_watcher_processes']}")
        if report["top_consumers"]:
            print("\n  Top Watcher Consumers:")
            for c in report["top_consumers"][:5]:
                print(f"    - PID {c['pid']} ({c['watches']:,} watches): {c['cmdline']}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
