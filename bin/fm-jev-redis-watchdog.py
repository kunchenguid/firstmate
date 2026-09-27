#!/usr/bin/env python3
"""
fm-jev-redis-watchdog.py - Jev Multi-Agent Memory & DB/Redis Leaked Connection Watchdog (Pattern 29)

Audits lingering, abandoned, or leaked TCP connections to database, cache, and RPC endpoints
(e.g., PostgreSQL 5432, Redis/Dragonfly 6379, CDP 9222/19222, Rest-Server 8000, Llama-Swap 5000)
across multi-agent worker processes.

Zero-disruption guarantee:
  - Read-only diagnostics by default.
  - Detects CLOSE_WAIT leaks and high-connection-count worker processes.
  - Fail-open on inspection errors.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


DEFAULT_PORTS = [5432, 6379, 8000, 9222, 19222, 5000]
DEFAULT_MAX_CONNS_PER_PID = 25


def parse_ss_output(ports: List[int]) -> List[Dict[str, Any]]:
    """Runs `ss -t -a -n -p` and extracts socket connections matching target ports."""
    connections: List[Dict[str, Any]] = []
    try:
        cmd = ["ss", "-t", "-a", "-n", "-p"]
        res = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if res.returncode != 0:
            return connections
        lines = res.stdout.strip().splitlines()
        if len(lines) <= 1:
            return connections

        port_set = set(ports)

        # Skip header
        for line in lines[1:]:
            parts = line.split()
            if len(parts) < 4:
                continue
            state = parts[0]
            local_addr = parts[3]
            peer_addr = parts[4] if len(parts) > 4 else "*:*"
            proc_info_raw = parts[5] if len(parts) > 5 else ""

            # Extract local port
            local_port = None
            if ":" in local_addr:
                try:
                    local_port = int(local_addr.rsplit(":", 1)[1])
                except ValueError:
                    pass

            # Extract peer port
            peer_port = None
            if ":" in peer_addr:
                try:
                    peer_port = int(peer_addr.rsplit(":", 1)[1])
                except ValueError:
                    pass

            # Check if socket involves any target port
            matched_port = None
            if local_port in port_set:
                matched_port = local_port
            elif peer_port in port_set:
                matched_port = peer_port

            if matched_port is None:
                continue

            # Parse process info: users:(("postgres",pid=2765042,fd=7),...)
            pid = None
            proc_name = None
            if proc_info_raw:
                pid_match = re.search(r"pid=(\d+)", proc_info_raw)
                name_match = re.search(r'"([^"]+)"', proc_info_raw)
                if pid_match:
                    pid = int(pid_match.group(1))
                if name_match:
                    proc_name = name_match.group(1)

            connections.append({
                "port": matched_port,
                "state": state,
                "local_addr": local_addr,
                "peer_addr": peer_addr,
                "pid": pid,
                "process": proc_name,
                "raw_proc": proc_info_raw,
            })
    except Exception as e:
        # Fail-open
        sys.stderr.write(f"Warning: error parsing ss output: {e}\n")

    return connections


def audit_connections(
    ports: List[int],
    max_conns_per_pid: int = DEFAULT_MAX_CONNS_PER_PID
) -> Dict[str, Any]:
    """Audits connections across target ports and checks for leaked/excessive sockets."""
    conns = parse_ss_output(ports)

    port_summary: Dict[int, Dict[str, int]] = {p: {"total": 0, "LISTEN": 0, "ESTAB": 0, "CLOSE_WAIT": 0, "TIME_WAIT": 0, "OTHER": 0} for p in ports}
    pid_conns: Dict[int, Dict[str, Any]] = {}
    leaked_connections: List[Dict[str, Any]] = []

    for c in conns:
        p = c["port"]
        st = c["state"]
        if p in port_summary:
            port_summary[p]["total"] += 1
            if st in port_summary[p]:
                port_summary[p][st] += 1
            else:
                port_summary[p]["OTHER"] += 1

        pid = c["pid"]
        if pid:
            if pid not in pid_conns:
                pid_conns[pid] = {
                    "pid": pid,
                    "process": c["process"],
                    "total_connections": 0,
                    "close_wait_count": 0,
                    "ports": set(),
                }
            pid_conns[pid]["total_connections"] += 1
            pid_conns[pid]["ports"].add(p)
            if st == "CLOSE_WAIT":
                pid_conns[pid]["close_wait_count"] += 1

        # Flag CLOSE_WAIT sockets lingering
        if st == "CLOSE_WAIT":
            leaked_connections.append(c)

    # Convert sets to lists for JSON serialization
    serialized_pids = []
    flagged_pids = []
    for pid, data in pid_conns.items():
        entry = {
            "pid": pid,
            "process": data["process"],
            "total_connections": data["total_connections"],
            "close_wait_count": data["close_wait_count"],
            "ports": sorted(list(data["ports"])),
        }
        serialized_pids.append(entry)
        if data["total_connections"] > max_conns_per_pid or data["close_wait_count"] > 3:
            flagged_pids.append(entry)

    healthy = len(leaked_connections) == 0 and len(flagged_pids) == 0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "target_ports": ports,
            "total_connections": len(conns),
            "total_pids_audited": len(pid_conns),
            "leaked_sockets_count": len(leaked_connections),
            "flagged_pids_count": len(flagged_pids),
            "healthy": healthy,
        },
        "ports": {str(k): v for k, v in port_summary.items()},
        "flagged_processes": flagged_pids,
        "active_processes_sample": serialized_pids[:10],
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Memory & Redis Leaked Connection Watchdog (Pattern 29)"
    )
    parser.add_argument(
        "--ports",
        type=str,
        default=",".join(str(p) for p in DEFAULT_PORTS),
        help=f"Comma-separated list of target ports (default: {','.join(str(p) for p in DEFAULT_PORTS)})",
    )
    parser.add_argument(
        "--max-conns-per-pid",
        type=int,
        default=DEFAULT_MAX_CONNS_PER_PID,
        help=f"Threshold of connections before flagging a process (default: {DEFAULT_MAX_CONNS_PER_PID})",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        default=True,
        help="Diagnostic check only (always true)",
    )

    args = parser.parse_args()

    try:
        ports = [int(p.strip()) for p in args.ports.split(",") if p.strip().isdigit()]
    except Exception:
        ports = DEFAULT_PORTS

    report = audit_connections(ports, args.max_conns_per_pid)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Jev Leaked Connection Watchdog (Pattern 29) — {report['timestamp']}")
        s = report["summary"]
        print(f"  • Monitored Ports: {s['target_ports']}")
        print(f"  • Total Active Connections: {s['total_connections']}")
        print(f"  • PIDs Audited: {s['total_pids_audited']}")
        print(f"  • Leaked CLOSE_WAIT Sockets: {s['leaked_sockets_count']}")
        print(f"  • Flagged Processes: {s['flagged_pids_count']}")
        print(f"  • Health Status: {'HEALTHY' if s['healthy'] else 'ACTION REQUIRED'}")
        if report["flagged_processes"]:
            print("\n  Flagged Processes:")
            for p in report["flagged_processes"]:
                print(f"    - PID {p['pid']} ({p['process']}): {p['total_connections']} conns, {p['close_wait_count']} CLOSE_WAIT")


if __name__ == "__main__":
    main()
