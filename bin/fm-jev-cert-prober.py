#!/usr/bin/env python3
"""fm-jev-cert-prober.py - Jev Multi-Agent SSL/TLS Certificate Expiration Prober

Audits SSL/TLS certificates across fleet APIs and external LLM/egress endpoints.
Measures TLS handshake latency, extracts SANs and expiry dates, and flags certificates
approaching expiration before silent TLS handshake failures stall autonomous workers.

Invariants:
- Fail-open: Never crashes caller; returns non-destructive status on network/probe errors.
- Non-destructive: Read-only TLS handshake probes.
- Structured telemetry: Emits machine-readable JSON for supervisor logging.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import socket
import ssl
import sys
import time
from typing import Any, Dict, List, Optional, Tuple


DEFAULT_CANARY_TARGETS = [
    "api.github.com:443",
    "api.typesafe.ai:443",
]


def parse_target(target_str: str) -> Tuple[str, int]:
    """Parse host and optional port from target string."""
    target_str = target_str.strip()
    if ":" in target_str and not target_str.endswith("]"):
        parts = target_str.rsplit(":", 1)
        host = parts[0]
        try:
            port = int(parts[1])
        except ValueError:
            port = 443
        return host, port
    return target_str, 443


def probe_tls_endpoint(
    host: str, port: int = 443, timeout: float = 3.0, min_days: int = 14
) -> Dict[str, Any]:
    """Initiate TLS handshake and extract certificate metadata."""
    t0 = time.time()
    ctx = ssl.create_default_context()
    # Allow inspection even if self-signed or custom CA if explicitly specified
    # but by default verify against system CAs

    try:
        with socket.create_connection((host, port), timeout=timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                cert = ssock.getpeercert()
                handshake_latency_ms = round((time.time() - t0) * 1000, 2)
                if not cert:
                    return {
                        "host": host,
                        "port": port,
                        "success": False,
                        "error": "empty_certificate",
                        "handshake_latency_ms": handshake_latency_ms,
                    }

                # Parse notAfter date string (e.g. 'Nov 12 12:00:00 2026 GMT')
                not_after_str = cert.get("notAfter", "")
                not_after_dt = datetime.datetime.strptime(
                    not_after_str, "%b %d %H:%M:%S %Y %Z"
                ).replace(tzinfo=datetime.timezone.utc)

                now_utc = datetime.datetime.now(datetime.timezone.utc)
                delta = not_after_dt - now_utc
                days_remaining = delta.days

                # Extract SANs
                sans = [
                    v for (t, v) in cert.get("subjectAltName", []) if t == "DNS"
                ]

                # Extract Issuer commonName or org
                issuer = dict(x[0] for x in cert.get("issuer", []))
                issuer_name = issuer.get("organizationName") or issuer.get("commonName") or "unknown"

                expiring_soon = days_remaining < min_days
                expired = days_remaining < 0

                return {
                    "host": host,
                    "port": port,
                    "success": True,
                    "handshake_latency_ms": handshake_latency_ms,
                    "days_remaining": days_remaining,
                    "expiration_iso": not_after_dt.isoformat(),
                    "issuer": issuer_name,
                    "sans_count": len(sans),
                    "expiring_soon": expiring_soon,
                    "expired": expired,
                    "error": None,
                }
    except Exception as e:
        handshake_latency_ms = round((time.time() - t0) * 1000, 2)
        return {
            "host": host,
            "port": port,
            "success": False,
            "handshake_latency_ms": handshake_latency_ms,
            "days_remaining": None,
            "error": str(e),
            "expiring_soon": False,
            "expired": False,
        }


def audit_certificates(
    targets: Optional[List[str]] = None,
    min_days: int = 14,
    timeout: float = 3.0,
) -> Dict[str, Any]:
    """Audit TLS certificates across all targets."""
    if not targets:
        targets = DEFAULT_CANARY_TARGETS

    probed_results = []
    flagged_certs = []

    for t in targets:
        host, port = parse_target(t)
        res = probe_tls_endpoint(host, port, timeout=timeout, min_days=min_days)
        probed_results.append(res)
        if not res["success"] or res.get("expiring_soon") or res.get("expired"):
            flagged_certs.append(res)

    healthy = len(flagged_certs) == 0

    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "healthy": healthy,
        "audited_targets_count": len(probed_results),
        "flagged_targets_count": len(flagged_certs),
        "probed_endpoints": probed_results,
        "flagged_endpoints": flagged_certs,
        "min_days_threshold": min_days,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent SSL/TLS Certificate Expiration Prober"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Run health check and return 0 if healthy, 1 if cert expiring/expired",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry",
    )
    parser.add_argument(
        "--min-days",
        type=int,
        default=14,
        help="Warning threshold for days remaining until certificate expiry (default: 14)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=3.0,
        help="Socket timeout in seconds (default: 3.0)",
    )
    parser.add_argument(
        "--targets",
        nargs="+",
        help="List of host:port targets to probe",
    )
    args = parser.parse_args()

    result = audit_certificates(
        targets=args.targets, min_days=args.min_days, timeout=args.timeout
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_str = "HEALTHY" if result.get("healthy") else "CERT_EXPIRING_WARNING"
        print(f"SSL/TLS Certificate Prober: {status_str}")
        print(f"  • Audited Targets: {result.get('audited_targets_count', 0)}")
        print(f"  • Flagged Targets: {result.get('flagged_targets_count', 0)}")
        for ep in result.get("probed_endpoints", []):
            if ep["success"]:
                print(
                    f"  • {ep['host']}:{ep['port']} - {ep['days_remaining']} days remaining (issuer: {ep['issuer']}, latency: {ep['handshake_latency_ms']}ms)"
                )
            else:
                print(f"  • {ep['host']}:{ep['port']} - FAILED ({ep['error']})")

    if args.check:
        return 0 if result.get("healthy", True) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
