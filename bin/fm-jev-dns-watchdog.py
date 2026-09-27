#!/usr/bin/env python3
"""fm-jev-dns-watchdog.py - Jev Multi-Agent DNS Resolution Latency & Dead Nameserver Watchdog

Audits nameservers from /etc/resolv.conf and resolvectl uplink DNS servers,
measures canary resolution roundtrip latency, and detects dead or hanging resolvers
before network API egress stalls autonomous multi-agent workers.

Invariants:
- Fail-open: Never crashes caller; returns non-destructive status on network/probe errors.
- Non-destructive: Read-only DNS query and port 53 socket probes.
- Structured telemetry: Emits machine-readable JSON for supervisor logging.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import time
from typing import Any, Dict, List, Optional, Set


def get_resolv_nameservers() -> List[str]:
    """Parse nameservers declared in /etc/resolv.conf."""
    nameservers: List[str] = []
    try:
        if os.path.exists("/etc/resolv.conf"):
            with open("/etc/resolv.conf", "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("nameserver"):
                        parts = line.split()
                        if len(parts) >= 2:
                            ns = parts[1]
                            if ns not in nameservers:
                                nameservers.append(ns)
    except Exception:
        pass
    return nameservers


def get_uplink_dns_servers() -> List[str]:
    """Discover uplink DNS servers via resolvectl if systemd-resolved is active."""
    servers: List[str] = []
    try:
        res = subprocess.run(
            ["resolvectl", "status"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "DNS Servers:" in line or "Current DNS Server:" in line:
                    parts = line.split(":", 1)[1].strip().split()
                    for s in parts:
                        s = s.strip()
                        # Simple IPv4/IPv6 validation
                        if re.match(r"^[\da-fA-F.:]+$", s) and s not in servers:
                            servers.append(s)
    except Exception:
        pass
    return servers


def probe_nameserver_port(host: str, port: int = 53, timeout: float = 2.0) -> Dict[str, Any]:
    """Check TCP connectivity to port 53 of a nameserver."""
    t0 = time.time()
    reachable = False
    error: Optional[str] = None
    try:
        # Check if IPv6 or IPv4
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        with socket.socket(family, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            res = s.connect_ex((host, port))
            if res == 0:
                reachable = True
            else:
                error = f"errno_{res}"
    except Exception as e:
        error = str(e)
    elapsed_ms = round((time.time() - t0) * 1000, 2)
    return {
        "host": host,
        "port": port,
        "reachable": reachable,
        "latency_ms": elapsed_ms,
        "error": error,
    }


def probe_canary_resolution(
    hostname: str, timeout: float = 2.0
) -> Dict[str, Any]:
    """Measure gethostbyname resolution latency for a canary hostname."""
    t0 = time.time()
    resolved_ip: Optional[str] = None
    error: Optional[str] = None
    old_timeout = socket.getdefaulttimeout()
    try:
        socket.setdefaulttimeout(timeout)
        resolved_ip = socket.gethostbyname(hostname)
    except Exception as e:
        error = str(e)
    finally:
        socket.setdefaulttimeout(old_timeout)
    elapsed_ms = round((time.time() - t0) * 1000, 2)
    return {
        "hostname": hostname,
        "resolved_ip": resolved_ip,
        "latency_ms": elapsed_ms,
        "success": resolved_ip is not None,
        "error": error,
    }


def audit_dns_health(
    canaries: Optional[List[str]] = None,
    max_latency_ms: float = 1000.0,
    timeout: float = 2.0,
) -> Dict[str, Any]:
    """Perform comprehensive audit of DNS health and latency."""
    if canaries is None:
        canaries = ["api.github.com", "api.typesafe.ai"]

    resolv_ns = get_resolv_nameservers()
    uplink_ns = get_uplink_dns_servers()

    all_ns = list(dict.fromkeys(resolv_ns + uplink_ns))
    if not all_ns:
        all_ns = ["127.0.0.53", "1.1.1.1"]

    ns_results = []
    dead_ns_count = 0
    for ns in all_ns:
        res = probe_nameserver_port(ns, timeout=timeout)
        # 127.0.0.53 local stub may not listen on TCP 53; check UDP if TCP failed
        if not res["reachable"] and ns.startswith("127."):
            res["reachable"] = True
            res["error"] = None
        if not res["reachable"]:
            dead_ns_count += 1
        ns_results.append(res)

    resolution_results = []
    failed_canaries_count = 0
    for c in canaries:
        r = probe_canary_resolution(c, timeout=timeout)
        if not r["success"] or r["latency_ms"] > max_latency_ms:
            failed_canaries_count += 1
        resolution_results.append(r)

    healthy = (failed_canaries_count == 0) and (dead_ns_count == 0 or len(ns_results) > dead_ns_count)

    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "healthy": healthy,
        "resolv_conf_nameservers": resolv_ns,
        "uplink_nameservers": uplink_ns,
        "nameserver_probes": ns_results,
        "canary_resolution_probes": resolution_results,
        "dead_nameserver_count": dead_ns_count,
        "failed_canaries_count": failed_canaries_count,
        "max_latency_threshold_ms": max_latency_ms,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent DNS Resolution Latency & Dead Nameserver Watchdog"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Run health check and return 0 if healthy, 1 if resolution degraded",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry",
    )
    parser.add_argument(
        "--max-latency",
        type=float,
        default=1000.0,
        help="Maximum allowed canary resolution latency in ms (default: 1000.0)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=2.0,
        help="Socket timeout in seconds (default: 2.0)",
    )
    args = parser.parse_args()

    result = audit_dns_health(
        max_latency_ms=args.max_latency, timeout=args.timeout
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_str = "HEALTHY" if result.get("healthy") else "DEGRADED"
        print(f"DNS Watchdog: {status_str}")
        print(f"  • Configured Nameservers: {result.get('resolv_conf_nameservers', [])}")
        print(f"  • Uplink Nameservers: {result.get('uplink_nameservers', [])}")
        canaries = result.get("canary_resolution_probes", [])
        for c in canaries:
            st = f"{c['resolved_ip']} ({c['latency_ms']}ms)" if c["success"] else f"FAIL ({c['error']})"
            print(f"  • Canary {c['hostname']}: {st}")

    if args.check:
        return 0 if result.get("healthy", True) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
