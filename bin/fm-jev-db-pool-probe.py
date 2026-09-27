#!/usr/bin/env python3
"""
fm-jev-db-pool-probe.py - Jev Multi-Agent Database Connection Pool Health Probe (Pattern 31)

Actively probes database connection latency, lock contention, and pool health across
SQLite (.beads, local state databases) and PostgreSQL (port 5432) endpoints.

Invariants:
  - Fail-open: Bounded 1.5s per-probe timeouts; never blocks execution.
  - Read-only diagnostics: No data mutations.
"""

import argparse
import json
import os
import socket
import sqlite3
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List


DEFAULT_SQLITE_TARGETS = [
    ".beads",
    "state",
]


def probe_tcp_port(host: str, port: int, timeout_sec: float = 1.0) -> Dict[str, Any]:
    """Probes a TCP endpoint (e.g. PostgreSQL 5432) and measures handshake latency."""
    start = time.perf_counter()
    status = "down"
    err = None
    try:
        with socket.create_connection((host, port), timeout=timeout_sec):
            status = "listening"
    except Exception as e:
        err = str(e)

    duration_ms = round((time.perf_counter() - start) * 1000.0, 2)
    return {
        "host": host,
        "port": port,
        "status": status,
        "latency_ms": duration_ms if status == "listening" else None,
        "error": err,
    }


def probe_sqlite_db(path: str, timeout_sec: float = 1.0) -> Dict[str, Any]:
    """Probes an SQLite database file for lock contention and query latency."""
    if not os.path.exists(path) or os.path.isdir(path):
        return {"path": path, "status": "missing_or_dir", "latency_ms": None}

    start = time.perf_counter()
    status = "healthy"
    err = None
    try:
        conn = sqlite3.connect(path, timeout=timeout_sec)
        cursor = conn.cursor()
        cursor.execute("SELECT 1;")
        cursor.fetchone()
        conn.close()
    except sqlite3.OperationalError as e:
        status = "locked" if "locked" in str(e).lower() else "operational_error"
        err = str(e)
    except Exception as e:
        status = "error"
        err = str(e)

    duration_ms = round((time.perf_counter() - start) * 1000.0, 2)
    return {
        "path": path,
        "status": status,
        "latency_ms": duration_ms,
        "error": err,
    }


def find_sqlite_dbs(root_dir: str, max_depth: int = 2) -> List[str]:
    """Finds SQLite database files (*.db, *.sqlite) in target directories."""
    db_paths = []
    try:
        for root, dirs, files in os.walk(root_dir):
            depth = root[len(root_dir):].count(os.sep)
            if depth >= max_depth:
                dirs.clear()
                continue
            for f in files:
                if f.endswith((".db", ".sqlite")):
                    db_paths.append(os.path.join(root, f))
    except Exception:
        pass
    return db_paths


def run_probe(root_dir: str = ".") -> Dict[str, Any]:
    """Runs database probes and compiles health summary."""
    # Probe PostgreSQL
    pg_probe = probe_tcp_port("127.0.0.1", 5432)

    # Discover and probe SQLite databases
    sqlite_probes = []
    discovered_dbs = []
    for d in DEFAULT_SQLITE_TARGETS:
        full_d = os.path.join(root_dir, d)
        if os.path.exists(full_d):
            discovered_dbs.extend(find_sqlite_dbs(full_d))

    for db_file in discovered_dbs[:10]:
        sqlite_probes.append(probe_sqlite_db(db_file))

    # Also test an in-memory SQLite baseline
    mem_start = time.perf_counter()
    try:
        mem_conn = sqlite3.connect(":memory:")
        mem_conn.execute("SELECT 1;")
        mem_conn.close()
        mem_lat = round((time.perf_counter() - mem_start) * 1000.0, 2)
    except Exception:
        mem_lat = None

    locked_dbs = [p for p in sqlite_probes if p["status"] == "locked"]
    healthy = len(locked_dbs) == 0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "postgres_listening": pg_probe["status"] == "listening",
            "sqlite_dbs_audited": len(sqlite_probes),
            "locked_dbs_count": len(locked_dbs),
            "memory_sqlite_latency_ms": mem_lat,
            "healthy": healthy,
        },
        "postgres": pg_probe,
        "sqlite_databases": sqlite_probes,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent Database Connection Pool Health Probe (Pattern 31)"
    )
    parser.add_argument(
        "--root-dir",
        type=str,
        default=".",
        help="Root directory for database discovery (default: .)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, 1 if lock contention detected",
    )

    args = parser.parse_args()
    report = run_probe(args.root_dir)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Jev DB Pool Health Probe (Pattern 31) — {report['timestamp']}")
        s = report["summary"]
        print(f"  • PostgreSQL (5432): {'LISTENING' if s['postgres_listening'] else 'DOWN'} ({report['postgres']['latency_ms']} ms)")
        print(f"  • SQLite Databases Audited: {s['sqlite_dbs_audited']}")
        print(f"  • Locked SQLite Contention: {s['locked_dbs_count']}")
        print(f"  • Baseline Memory SQLite Latency: {s['memory_sqlite_latency_ms']} ms")
        print(f"  • Overall Status: {'HEALTHY' if s['healthy'] else 'DEGRADED'}")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
