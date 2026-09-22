#!/usr/bin/env python3
"""
fm-jev-load-throttler.py - Jev Host CPU & Memory Pressure Adaptive Throttler (Pattern 30)

Dynamically monitors system load average and available RAM across multi-agent worker seats,
calculating normalized load per core and computing adaptive concurrency throttles to prevent
host starvation, thread contention, and OOM killer events.

Invariants:
  - Fail-open: Never crashes on missing proc files; falls back safely.
  - Read-only diagnostics: Emits recommendations and status codes.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from typing import Any, Dict, Tuple


DEFAULT_BASE_CONCURRENCY = 8


def get_memory_info() -> Dict[str, Any]:
    """Parses /proc/meminfo to get RAM metrics in megabytes."""
    mem = {"total_mb": 0.0, "available_mb": 0.0, "used_mb": 0.0, "used_percent": 0.0}
    try:
        if os.path.exists("/proc/meminfo"):
            with open("/proc/meminfo", "r") as f:
                for line in f:
                    parts = line.split(":")
                    if len(parts) == 2:
                        key = parts[0].strip()
                        val_str = parts[1].strip().split()[0]
                        if key == "MemTotal":
                            mem["total_mb"] = round(int(val_str) / 1024.0, 1)
                        elif key == "MemAvailable":
                            mem["available_mb"] = round(int(val_str) / 1024.0, 1)

            if mem["total_mb"] > 0:
                mem["used_mb"] = round(mem["total_mb"] - mem["available_mb"], 1)
                mem["used_percent"] = round((mem["used_mb"] / mem["total_mb"]) * 100.0, 1)
    except Exception as e:
        sys.stderr.write(f"Warning: error reading /proc/meminfo: {e}\n")

    return mem


def get_system_load() -> Tuple[float, float, float, int, float]:
    """Returns (load_1m, load_5m, load_15m, cpu_count, load_per_core_1m)."""
    cpu_count = os.cpu_count() or 1
    try:
        load_1m, load_5m, load_15m = os.getloadavg()
    except Exception:
        load_1m, load_5m, load_15m = (0.0, 0.0, 0.0)

    load_per_core = round(load_1m / max(cpu_count, 1), 2)
    return (round(load_1m, 2), round(load_5m, 2), round(load_15m, 2), cpu_count, load_per_core)


def evaluate_throttle(base_concurrency: int = DEFAULT_BASE_CONCURRENCY) -> Dict[str, Any]:
    """Calculates pressure status and recommended concurrency level."""
    l1, l5, l15, cpus, load_per_core = get_system_load()
    mem = get_memory_info()

    # Throttling policy logic:
    # CLEAR: load_per_core < 1.0 and mem used < 80%
    # THROTTLED: 1.0 <= load_per_core < 2.0 or 80% <= mem used < 90%
    # PAUSED / HIGH_PRESSURE: load_per_core >= 2.0 or mem used >= 90%
    state = "CLEAR"
    multiplier = 1.0

    if load_per_core >= 2.0 or mem["used_percent"] >= 90.0:
        state = "HIGH_PRESSURE"
        multiplier = 0.25
    elif load_per_core >= 1.0 or mem["used_percent"] >= 80.0:
        state = "THROTTLED"
        multiplier = 0.50

    recommended_workers = max(1, int(round(base_concurrency * multiplier)))

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": state,
        "recommended_workers": recommended_workers,
        "throttle_multiplier": multiplier,
        "load": {
            "load_1m": l1,
            "load_5m": l5,
            "load_15m": l15,
            "cpu_cores": cpus,
            "load_per_core": load_per_core,
        },
        "memory": mem,
        "healthy": state != "HIGH_PRESSURE",
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Host CPU & Memory Pressure Adaptive Throttler (Pattern 30)"
    )
    parser.add_argument(
        "--base-concurrency",
        type=int,
        default=DEFAULT_BASE_CONCURRENCY,
        help=f"Base unthrottled worker concurrency (default: {DEFAULT_BASE_CONCURRENCY})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--recommended-parallel",
        action="store_true",
        help="Output only the recommended integer concurrency count",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if system healthy/clear, code 1 if under high pressure",
    )

    args = parser.parse_args()
    report = evaluate_throttle(args.base_concurrency)

    if args.recommended_parallel:
        print(report["recommended_workers"])
        sys.exit(0)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Jev Load Throttler (Pattern 30) — {report['timestamp']}")
        print(f"  • Pressure State: {report['status']}")
        print(f"  • Recommended Parallel Workers: {report['recommended_workers']} (base: {args.base_concurrency})")
        l = report["load"]
        print(f"  • Load Avg: {l['load_1m']}, {l['load_5m']}, {l['load_15m']} ({l['cpu_cores']} cores, {l['load_per_core']} load/core)")
        m = report["memory"]
        print(f"  • Memory: {m['used_mb']} MB / {m['total_mb']} MB used ({m['used_percent']}%)")

    if args.check and not report["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
