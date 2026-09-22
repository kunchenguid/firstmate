#!/usr/bin/env python3
"""
fm-jev-ipc-watchdog.py - Jev Multi-Agent IPC & UNIX Domain Socket Leak Watchdog (Pattern 32)

Audits lingering UNIX domain sockets under /tmp and user runtime dirs (e.g., Playwright Chrome
SingletonSockets, tmux sockets, agent RPC sockets) to detect abandoned socket files whose owning
processes no longer exist.

Invariants:
  - Read-only diagnostics by default (--dry-run).
  - Strict bounded scan (caps at max 200 sockets examined to avoid filesystem lag).
  - Fail-open: Never crashes on permission errors or missing dirs.
"""

import argparse
import glob
import json
import os
import socket
import sys
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


DEFAULT_SOCKET_PATTERNS = [
    "/tmp/com.google.Chrome.*/SingletonSocket",
    "/tmp/playwright-*/socket",
    "/tmp/tmux-*/default",
    "/tmp/herdr-*/server.sock",
]


def is_socket_alive(sock_path: str, timeout_sec: float = 0.2) -> bool:
    """Tests if a UNIX domain socket is actively listening by attempting a connection."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout_sec)
        res = s.connect_ex(sock_path)
        s.close()
        # connect_ex returns 0 on successful connection
        # If ECONNREFUSED (111) or ENOENT (2), socket is dead/abandoned
        return res == 0
    except Exception:
        return False


def get_chrome_singleton_pid(sock_path: str) -> Optional[int]:
    """Reads PID from companion SingletonLock if available."""
    lock_file = os.path.join(os.path.dirname(sock_path), "SingletonLock")
    if os.path.islink(lock_file):
        try:
            target = os.readlink(lock_file)
            # Link target is usually HOSTNAME-PID
            parts = target.rsplit("-", 1)
            if len(parts) == 2 and parts[1].isdigit():
                return int(parts[1])
        except Exception:
            pass
    return None


def is_pid_alive(pid: int) -> bool:
    """Checks if a process exists."""
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError):
        # PermissionError means process exists but belongs to another user
        return True
    except Exception:
        return False


def audit_unix_sockets(patterns: List[str], max_scan: int = 150) -> Dict[str, Any]:
    """Scans and audits UNIX domain sockets matching specified patterns."""
    matched_files: List[str] = []
    for pat in patterns:
        try:
            matched_files.extend(glob.glob(pat))
        except Exception:
            pass

    # Cap to avoid filesystem latency
    audited = matched_files[:max_scan]

    live_sockets: List[str] = []
    abandoned_sockets: List[Dict[str, Any]] = []

    for sock in audited:
        if not os.path.exists(sock):
            continue

        alive = is_socket_alive(sock)
        owner_pid = get_chrome_singleton_pid(sock)
        pid_alive = is_pid_alive(owner_pid) if owner_pid else None

        if alive or (pid_alive is True):
            live_sockets.append(sock)
        else:
            abandoned_sockets.append({
                "path": sock,
                "dir": os.path.dirname(sock),
                "owner_pid": owner_pid,
                "listening": alive,
                "pid_alive": pid_alive,
            })

    healthy = len(abandoned_sockets) == 0

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "summary": {
            "total_sockets_found": len(matched_files),
            "sockets_audited": len(audited),
            "live_sockets_count": len(live_sockets),
            "abandoned_sockets_count": len(abandoned_sockets),
            "healthy": healthy,
        },
        "abandoned_sample": abandoned_sockets[:10],
    }


def main():
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent IPC & UNIX Domain Socket Leak Watchdog (Pattern 32)"
    )
    parser.add_argument(
        "--patterns",
        type=str,
        default=",".join(DEFAULT_SOCKET_PATTERNS),
        help="Comma-separated glob patterns for UNIX sockets",
    )
    parser.add_argument(
        "--max-scan",
        type=int,
        default=100,
        help="Maximum socket files to audit per cycle (default: 100)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry to stdout",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit with code 0 if healthy, code 1 if abandoned sockets detected",
    )

    args = parser.parse_args()
    patterns = [p.strip() for p in args.patterns.split(",") if p.strip()]
    report = audit_unix_sockets(patterns, args.max_scan)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"Jev IPC Socket Watchdog (Pattern 32) — {report['timestamp']}")
        s = report["summary"]
        print(f"  • Total Sockets Discovered: {s['total_sockets_found']}")
        print(f"  • Audited Sockets: {s['sockets_audited']}")
        print(f"  • Active/Listening Sockets: {s['live_sockets_count']}")
        print(f"  • Abandoned/Dead Sockets: {s['abandoned_sockets_count']}")
        print(f"  • Health Status: {'HEALTHY' if s['healthy'] else 'DEGRADED / ACTION REQUIRED'}")
        if report["abandoned_sample"]:
            print("\n  Sample Abandoned Sockets:")
            for item in report["abandoned_sample"][:5]:
                print(f"    - {item['path']} (PID: {item['owner_pid']}, listening: {item['listening']})")

    if args.check and not report["summary"]["healthy"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
