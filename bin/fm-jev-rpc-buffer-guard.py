#!/usr/bin/env python3
"""fm-jev-rpc-buffer-guard.py - Jev Multi-Agent JSON-RPC & Subagent Message Buffer Leak Guard

Audits pending inter-agent message queues, inbox buffer depths, and wake-queue sizes
across Firstmate worker seats and JSON-RPC bridges. Detects queue backlog and buffer leaks
before memory bloat or message drop cascading failures occur.

Invariants:
- Fail-open: Never crashes caller; returns non-destructive status on probe errors.
- Non-destructive: Read-only inspection of state directories and inboxes.
- Structured telemetry: Emits machine-readable JSON for supervisor logging.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time
from typing import Any, Dict, List, Optional


def audit_inboxes(
    state_dir: str, max_inbox_msgs: int = 50
) -> Tuple[List[Dict[str, Any]], List[Dict[str, Any]], int]:
    """Audit all worker inboxes in the given state directory."""
    inboxes_data: List[Dict[str, Any]] = []
    flagged_inboxes: List[Dict[str, Any]] = []
    total_msgs = 0

    inbox_pattern = os.path.join(state_dir, "*.inbox")
    for inbox_path in glob.glob(inbox_pattern):
        if not os.path.isdir(inbox_path):
            continue
        inbox_name = os.path.basename(inbox_path)
        seat_name = inbox_name.replace(".inbox", "")
        try:
            msg_files = [
                f for f in os.listdir(inbox_path) if f.endswith(".msg")
            ]
            count = len(msg_files)
            total_msgs += count

            entry = {
                "seat": seat_name,
                "inbox_path": inbox_path,
                "pending_messages": count,
            }
            if count > 0:
                inboxes_data.append(entry)

            if count > max_inbox_msgs:
                entry["reason"] = f"pending_msgs_{count}_exceeds_{max_inbox_msgs}"
                flagged_inboxes.append(entry)
        except Exception:
            continue

    # Sort inboxes by message count descending
    inboxes_data.sort(key=lambda x: x["pending_messages"], reverse=True)
    return inboxes_data, flagged_inboxes, total_msgs


def audit_wake_queue(state_dir: str, max_queue_bytes: int = 102400) -> Dict[str, Any]:
    """Audit the centralized wake-queue file."""
    queue_path = os.path.join(state_dir, ".wake-queue")
    exists = os.path.exists(queue_path)
    size_bytes = 0
    line_count = 0
    flagged = False

    if exists:
        try:
            size_bytes = os.path.getsize(queue_path)
            with open(queue_path, "r", encoding="utf-8", errors="replace") as f:
                line_count = sum(1 for _ in f)
            if size_bytes > max_queue_bytes:
                flagged = True
        except Exception:
            pass

    return {
        "exists": exists,
        "path": queue_path,
        "size_bytes": size_bytes,
        "line_count": line_count,
        "flagged": flagged,
    }


def audit_rpc_buffers(
    state_dir: str,
    max_inbox_msgs: int = 50,
    max_queue_bytes: int = 102400,
) -> Dict[str, Any]:
    """Perform comprehensive audit of all message buffers and queue depths."""
    inboxes_data, flagged_inboxes, total_msgs = audit_inboxes(
        state_dir, max_inbox_msgs=max_inbox_msgs
    )
    wake_q = audit_wake_queue(state_dir, max_queue_bytes=max_queue_bytes)

    healthy = (len(flagged_inboxes) == 0) and not wake_q["flagged"]

    return {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "healthy": healthy,
        "state_dir": state_dir,
        "total_active_inboxes": len(inboxes_data),
        "total_pending_messages": total_msgs,
        "flagged_inboxes_count": len(flagged_inboxes),
        "flagged_inboxes": flagged_inboxes,
        "top_inboxes": inboxes_data[:10],
        "wake_queue": wake_q,
        "thresholds": {
            "max_inbox_messages": max_inbox_msgs,
            "max_queue_bytes": max_queue_bytes,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Multi-Agent JSON-RPC & Subagent Message Buffer Leak Guard"
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Run health check and return 0 if healthy, 1 if queue depths exceed threshold",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit structured JSON telemetry",
    )
    parser.add_argument(
        "--state-dir",
        default=os.environ.get("FM_STATE_DIR") or os.path.expanduser("/opt/ra/firstmate/state"),
        help="Path to state directory containing inboxes and wake-queue",
    )
    parser.add_argument(
        "--max-inbox-msgs",
        type=int,
        default=50,
        help="Maximum allowed pending messages per inbox (default: 50)",
    )
    parser.add_argument(
        "--max-queue-bytes",
        type=int,
        default=102400,
        help="Maximum allowed size in bytes for .wake-queue (default: 102400)",
    )
    args = parser.parse_args()

    result = audit_rpc_buffers(
        state_dir=args.state_dir,
        max_inbox_msgs=args.max_inbox_msgs,
        max_queue_bytes=args.max_queue_bytes,
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        status_str = "HEALTHY" if result.get("healthy") else "QUEUE_BACKLOG_WARNING"
        print(f"RPC Buffer Guard: {status_str}")
        print(f"  • Total Pending Messages: {result.get('total_pending_messages', 0)}")
        print(f"  • Active Inboxes: {result.get('total_active_inboxes', 0)}")
        print(f"  • Flagged Inboxes: {result.get('flagged_inboxes_count', 0)}")
        wq = result.get("wake_queue", {})
        print(f"  • Wake Queue: {wq.get('size_bytes', 0)} bytes ({wq.get('line_count', 0)} lines)")
        top = result.get("top_inboxes", [])
        if top:
            print("  • Top Queued Inboxes:")
            for ib in top[:5]:
                print(f"    - [{ib['seat']}]: {ib['pending_messages']} msgs")

    if args.check:
        return 0 if result.get("healthy", True) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
