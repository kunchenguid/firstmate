#!/usr/bin/env python3
"""
fm-jev-port-guard.py - Jev Multi-Agent Ephemeral Port & Socket Bind Exhaustion Guard (Pattern 41)

Audits host TCP socket state distribution and ephemeral port range utilization
(/proc/sys/net/ipv4/ip_local_port_range) to detect TIME_WAIT socket accumulation,
leaked CLOSE_WAIT connections, and port starvation across concurrent multi-agent servers.

Invariants:
  - Read-only diagnostics.
  - Fail-open: Never crashes on missing tools or permission restrictions.
  - Strict bounded runtime (< 1.5s overhead).
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Tuple


def get_ephemeral_port_range() -> Tuple[int, int]:
    """Reads the ephemeral port range from /proc/sys/net/ipv4/ip_local_port_range."""
    min_port, max_port = 32768, 60999  # Linux defaults
    try:
        with open("/proc/sys/net/ipv4/ip_local_port_range", "r") as f:
            parts = f.read().strip().split()
            if len(parts) == 2:
                min_port, max_port = int(parts[0]), int(parts[1])
    except Exception:
        pass
    return min_port, max_port


def parse_ss_summary() -> Dict[str, int]:
    """Parses `ss -s` for overall socket counts."""
    counts = {
        "total": 0,
        "tcp_total": 0,
        "established": 0,
        "closed": 0,
        "orphaned": 0,
        "timewait": 0,
    }
    try:
        proc = subprocess.run(["ss", "-s"], capture_output=True, text=True, timeout=2)
        for line in proc.stdout.splitlines():
            line = line.strip()
            if line.startswith("Total:"):
                m = re.search(r"Total:\s*(\d+)", line)
                if m:
                    counts["total"] = int(m.group(1))
            elif line.startswith("TCP:"):
                m_tot = re.search(r"TCP:\s*(\d+)", line)
                if m_tot:
                    counts["tcp_total"] = int(m_tot.group(1))
                m_est = re.search(r"estab\s+(\d+)", line)
                if m_est:
                    counts["established"] = int(m_est.group(1))
                m_closed = re.search(r"closed\s+(\d+)", line)
                if m_closed:
                    counts["closed"] = int(m_closed.group(1))
                m_orph = re.search(r"orphaned\s+(\d+)", line)
                if m_orph:
                    counts["orphaned"] = int(m_orph.group(1))
                m_tw = re.search(r"timewait\s+(\d+)", line)
                if m_tw:
                    counts["timewait"] = int(m_tw.group(1))
    except Exception:
        pass
    return counts


def parse_tcp_states() -> Dict[str, int]:
    """Parses active TCP socket states directly from /proc/net/tcp and /proc/net/tcp6."""
    state_names = {
        "01": "ESTABLISHED",
        "02": "SYN_SENT",
        "03": "SYN_RECV",
        "04": "FIN_WAIT1",
        "05": "FIN_WAIT2",
        "06": "TIME_WAIT",
        "07": "CLOSE",
        "08": "CLOSE_WAIT",
        "09": "LAST_ACK",
        "0A": "LISTEN",
        "0B": "CLOSING",
    }
    distribution: Dict[str, int] = {v: 0 for v in state_names.values()}

    for path in ["/proc/net/tcp", "/proc/net/tcp6"]:
        try:
            with open(path, "r") as f:
                next(f, None)  # skip header
                for line in f:
                    parts = line.strip().split()
                    if len(parts) >= 4:
                        st = parts[3].upper()
                        name = state_names.get(st, "UNKNOWN")
                        distribution[name] = distribution.get(name, 0) + 1
        except Exception:
            continue

    return distribution


def audit_port_exhaustion(
    warning_timewait: int = 5000,
    critical_timewait: int = 15000,
    warning_closewait: int = 50,
) -> Dict[str, Any]:
    """Conducts full audit of socket states, ephemeral headroom, and bind saturation."""
    min_port, max_port = get_ephemeral_port_range()
    total_ephemeral_capacity = max(1, (max_port - min_port + 1))

    summary = parse_ss_summary()
    tcp_states = parse_tcp_states()

    timewait_count = max(summary.get("timewait", 0), tcp_states.get("TIME_WAIT", 0))
    closewait_count = tcp_states.get("CLOSE_WAIT", 0)
    established_count = max(summary.get("established", 0), tcp_states.get("ESTABLISHED", 0))
    listen_count = tcp_states.get("LISTEN", 0)

    # Ephemeral port saturation estimate (sockets in TIME_WAIT + ESTABLISHED)
    ephemeral_in_use = timewait_count + established_count
    saturation_pct = round((ephemeral_in_use / total_ephemeral_capacity) * 100.0, 2)

    healthy = (
        timewait_count < warning_timewait
        and closewait_count < warning_closewait
        and saturation_pct < 75.0
    )

    status = "HEALTHY"
    if timewait_count >= critical_timewait or saturation_pct >= 90.0:
        status = "CRITICAL"
    elif timewait_count >= warning_timewait or closewait_count >= warning_closewait or saturation_pct >= 75.0:
        status = "WARNING"

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "status": status,
            "healthy": healthy,
            "ephemeral_port_range": f"{min_port}-{max_port}",
            "total_ephemeral_capacity": total_ephemeral_capacity,
            "ephemeral_in_use_est": ephemeral_in_use,
            "saturation_pct": saturation_pct,
            "timewait_count": timewait_count,
            "closewait_count": closewait_count,
            "established_count": established_count,
            "listen_count": listen_count,
            "total_tcp_sockets": summary.get("tcp_total", 0),
        },
        "state_distribution": tcp_states,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Ephemeral Port & Socket Bind Exhaustion Guard (Pattern 41)"
    )
    parser.add_argument(
        "--warning-timewait",
        type=int,
        default=5000,
        help="Warning threshold for TIME_WAIT socket count (default: 5000)",
    )
    parser.add_argument(
        "--warning-closewait",
        type=int,
        default=50,
        help="Warning threshold for CLOSE_WAIT leaked socket count (default: 50)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if thresholds exceeded",
    )

    args = parser.parse_args()
    report = audit_port_exhaustion(
        warning_timewait=args.warning_timewait,
        warning_closewait=args.warning_closewait,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        s = report["summary"]
        print(f"Jev Port & Socket Guard (Pattern 41) — {report['timestamp']}")
        print(f"  • Status: {s['status']}")
        print(f"  • Ephemeral Range: {s['ephemeral_port_range']} ({s['total_ephemeral_capacity']:,} ports)")
        print(f"  • Ephemeral In-Use: ~{s['ephemeral_in_use_est']:,} ({s['saturation_pct']}%)")
        print(f"  • Sockets: {s['established_count']} ESTAB, {s['timewait_count']} TIME_WAIT, {s['closewait_count']} CLOSE_WAIT, {s['listen_count']} LISTEN")
        print(f"  • Total TCP Sockets: {s['total_tcp_sockets']}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
