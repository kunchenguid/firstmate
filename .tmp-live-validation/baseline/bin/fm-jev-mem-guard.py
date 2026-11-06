#!/usr/bin/env python3
"""
fm-jev-mem-guard.py - Jev Multi-Agent Memory RSS & Swap Thrashing Guard (Pattern 46)

Audits host memory availability (/proc/meminfo) and swap utilization to detect memory
starvation, swap thrashing, and out-of-control worker RSS expansion across multi-agent seats.
Prevents catastrophic OOM killer invocations against persistent agent supervisors and tmux sessions.

Thresholds (each named for the CLI flag that carries its operational default; run --help for current values):
  - --warn-mem-pct: memory utilization warning, percent of MemTotal not available.
  - --crit-mem-pct: memory utilization critical, percent of MemTotal not available.
  - --warn-swap-pct: swap utilization warning, percent of SwapTotal in use.
  - --crit-swap-pct: swap utilization critical, percent of SwapTotal in use.

Invariants:
  - Read-only diagnostics.
  - Fail-open: an unreadable or incomplete /proc/meminfo degrades to a graceful status
    UNKNOWN with a machine-readable reason and a 0 --check exit, never a crash and never
    a false alarm; an unassessed host reports null measured percentages (JSON null,
    "unavailable" in human output) instead of fabricated numbers.
  - Swap with SwapTotal > 0 but no SwapFree line is reported as unknown and never
    classifies the verdict; a failed top-process listing degrades to an empty list.
  - Bounded sub-second execution (< 500ms).
  - Status is OK, WARNING, CRITICAL, or UNKNOWN; recommendation is diagnostic text
    for the operator, never a command.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


def read_meminfo() -> Dict[str, int]:
    """Reads and parses /proc/meminfo in kB."""
    info: Dict[str, int] = {}
    try:
        with open("/proc/meminfo", "r") as f:
            for line in f:
                parts = line.split(":")
                if len(parts) == 2:
                    key = parts[0].strip()
                    val_parts = parts[1].strip().split()
                    if val_parts and val_parts[0].isdigit():
                        info[key] = int(val_parts[0])
    except Exception:
        pass
    return info


def get_top_rss_processes(top_n: int = 10) -> List[Dict[str, Any]]:
    """Inspects /proc to find top memory-consuming processes by RSS; a listing failure degrades to []."""
    procs: List[Dict[str, Any]] = []
    try:
        page_size_kb = os.sysconf("SC_PAGE_SIZE") // 1024
    except Exception:
        return []

    try:
        entries = os.listdir("/proc")
    except Exception:
        return []

    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            with open(f"/proc/{pid}/statm", "r") as f:
                parts = f.read().strip().split()
            if len(parts) < 2 or not parts[1].isdigit():
                continue
            rss_kb = int(parts[1]) * page_size_kb
            if rss_kb < 10240:  # Skip procs using < 10MB
                continue

            comm = f"pid_{pid}"
            try:
                with open(f"/proc/{pid}/comm", "r", errors="replace") as f:
                    comm = f.read().strip()
            except Exception:
                pass

            procs.append({
                "pid": pid,
                "comm": comm,
                "rss_mb": round(rss_kb / 1024.0, 1),
            })
        except Exception:
            continue

    procs.sort(key=lambda p: p["rss_mb"], reverse=True)
    return procs[:top_n]


def audit_memory(
    warn_mem_pct: float,
    crit_mem_pct: float,
    warn_swap_pct: float,
    crit_swap_pct: float,
) -> Dict[str, Any]:
    """Audits system memory and swap usage, failing open to status UNKNOWN when unmeasurable."""
    mem = read_meminfo()
    mem_total_kb = mem.get("MemTotal")
    mem_avail_kb = mem.get("MemAvailable")
    swap_total_kb = mem.get("SwapTotal")
    swap_free_kb = mem.get("SwapFree")

    reason: Optional[str] = None
    mem_total_gb: Optional[float] = None
    mem_available_gb: Optional[float] = None
    mem_used_pct: Optional[float] = None
    swap_total_gb: Optional[float] = None
    swap_used_gb: Optional[float] = None
    swap_used_pct: Optional[float] = None

    if mem_total_kb is None or mem_total_kb <= 0 or mem_avail_kb is None:
        status = "UNKNOWN"
        reason = "meminfo-unavailable"
        recommendation = (
            "/proc/meminfo is unreadable or incomplete on this host; "
            "the verdict is withheld rather than fabricated."
        )
    else:
        mem_used_kb = max(0, mem_total_kb - mem_avail_kb)
        mem_total_gb = round(mem_total_kb / (1024.0 * 1024.0), 2)
        mem_available_gb = round(mem_avail_kb / (1024.0 * 1024.0), 2)
        mem_used_pct = round((mem_used_kb / mem_total_kb) * 100.0, 1)

        if swap_total_kb is not None:
            swap_total_gb = round(swap_total_kb / (1024.0 * 1024.0), 2)
            if swap_total_kb == 0:
                swap_used_gb = 0.0
                swap_used_pct = 0.0
            elif swap_free_kb is not None:
                swap_used_kb = max(0, swap_total_kb - swap_free_kb)
                swap_used_gb = round(swap_used_kb / (1024.0 * 1024.0), 2)
                swap_used_pct = round((swap_used_kb / swap_total_kb) * 100.0, 1)

        crit = mem_used_pct >= crit_mem_pct or (
            swap_used_pct is not None and swap_used_pct >= crit_swap_pct
        )
        warn = mem_used_pct >= warn_mem_pct or (
            swap_used_pct is not None and swap_used_pct >= warn_swap_pct
        )
        if crit:
            status = "CRITICAL"
            recommendation = (
                "Memory or swap utilization is at or above a critical threshold; "
                "this host condition can explain worker silence while it holds."
            )
        elif warn:
            status = "WARNING"
            recommendation = (
                "Memory or swap utilization is above a warning threshold but below a "
                "critical one; degraded but explained, see the top RSS processes."
            )
        else:
            status = "OK"
            recommendation = (
                "Memory and swap utilization are within thresholds; "
                "the caller should continue unchanged."
            )

    top_procs = get_top_rss_processes()

    return {
        "name": "fm-jev-mem-guard",
        "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": status,
        "recommendation": recommendation,
        "reason": reason,
        "summary": {
            "mem_total_gb": mem_total_gb,
            "mem_available_gb": mem_available_gb,
            "mem_used_pct": mem_used_pct,
            "swap_total_gb": swap_total_gb,
            "swap_used_gb": swap_used_gb,
            "swap_used_pct": swap_used_pct,
        },
        "top_processes": top_procs,
    }


def main():
    sys.stdout.reconfigure(errors="replace")
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Memory RSS & Swap Thrashing Guard (Pattern 46)"
    )
    parser.add_argument(
        "--warn-mem-pct",
        type=float,
        default=90.0,
        help="Warning threshold for memory utilization %% (default: %(default)s)",
    )
    parser.add_argument(
        "--crit-mem-pct",
        type=float,
        default=95.0,
        help="Critical threshold for memory utilization %% (default: %(default)s)",
    )
    parser.add_argument(
        "--warn-swap-pct",
        type=float,
        default=85.0,
        help="Warning threshold for swap utilization %% (default: %(default)s)",
    )
    parser.add_argument(
        "--crit-swap-pct",
        type=float,
        default=95.0,
        help="Critical threshold for swap utilization %% (default: %(default)s)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 0 for OK or unknown (fail-open), exit 1 for WARNING or CRITICAL",
    )

    args = parser.parse_args()
    report = audit_memory(
        warn_mem_pct=args.warn_mem_pct,
        crit_mem_pct=args.crit_mem_pct,
        warn_swap_pct=args.warn_swap_pct,
        crit_swap_pct=args.crit_swap_pct,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"{report['name']} — {report['checked_at']}")
        if s["mem_used_pct"] is None:
            print("  • RAM: unavailable")
        else:
            print(f"  • RAM: {s['mem_used_pct']}% used ({s['mem_available_gb']} GB available / {s['mem_total_gb']} GB total)")
        if s["swap_used_pct"] is None:
            print("  • Swap: unknown (not measurable)")
        else:
            print(f"  • Swap: {s['swap_used_pct']}% used ({s['swap_used_gb']} GB used / {s['swap_total_gb']} GB total)")
        print(f"  • Status: {report['status']}")
        print(f"  • Recommendation: {report['recommendation']}")
        if report["top_processes"]:
            print(f"\n  Top {len(report['top_processes'])} RSS Processes:")
            for p in report["top_processes"]:
                print(f"    - PID {p['pid']} ({p['comm']}): {p['rss_mb']} MB")

    if args.check and report["status"] in ("WARNING", "CRITICAL"):
        sys.exit(1)


if __name__ == "__main__":
    main()
