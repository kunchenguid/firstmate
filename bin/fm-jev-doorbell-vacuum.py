#!/usr/bin/env python3
"""
fm-jev-doorbell-vacuum.py - Jev Cross-Seat Doorbell & Stale Notification Vacuum (Pattern 18)

Scans firstmate state inbox directories and treehouse doorbells, identifies
acknowledged steer messages (handled/*.msg) older than retention TTL, abandoned
.ring-state files, and stale escalation markers on dormant seats, and safely
vacuums them to reclaim inodes and prevent spurious watcher wake loops.

Safety invariants:
- Never deletes unhandled messages in active inboxes.
- Preserves handled messages newer than retention TTL (default: 24h).
- Preserves ring states on active inboxes with pending messages.
- Fails open gracefully on filesystem permissions or IO errors.
- Fully supports dry-run mode for safe previewing.
"""

import argparse
import glob
import json
import os
import sys
import time
from typing import Dict, List, Any


def scan_and_vacuum(
    state_dir: str,
    handled_retention_hours: float = 24.0,
    stale_ring_hours: float = 24.0,
    dry_run: bool = False,
) -> Dict[str, Any]:
    now = time.time()
    handled_ttl_sec = handled_retention_hours * 3600.0
    stale_ring_ttl_sec = stale_ring_hours * 3600.0

    report: Dict[str, Any] = {
        "state_dir": state_dir,
        "dry_run": dry_run,
        "inboxes_scanned": 0,
        "handled_pruned": 0,
        "handled_preserved": 0,
        "ring_states_pruned": 0,
        "ring_states_preserved": 0,
        "escalations_pruned": 0,
        "unhandled_pending": 0,
        "bytes_reclaimed": 0,
        "pruned_files": [],
    }

    if not os.path.exists(state_dir):
        return report

    inbox_pattern = os.path.join(state_dir, "*.inbox")
    inbox_dirs = glob.glob(inbox_pattern)
    report["inboxes_scanned"] = len(inbox_dirs)

    for inbox in inbox_dirs:
        try:
            # 1. Check unhandled messages in inbox root
            unhandled_files = [
                f for f in glob.glob(os.path.join(inbox, "*.msg"))
                if os.path.isfile(f)
            ]
            has_pending = len(unhandled_files) > 0
            report["unhandled_pending"] += len(unhandled_files)

            # 2. Check handled/ directory
            handled_dir = os.path.join(inbox, "handled")
            if os.path.isdir(handled_dir):
                for msg_path in glob.glob(os.path.join(handled_dir, "*.msg")):
                    if not os.path.isfile(msg_path):
                        continue
                    try:
                        st = os.stat(msg_path)
                        age_sec = now - st.st_mtime
                        if age_sec > handled_ttl_sec:
                            report["handled_pruned"] += 1
                            report["bytes_reclaimed"] += st.st_size
                            report["pruned_files"].append(msg_path)
                            if not dry_run:
                                os.unlink(msg_path)
                        else:
                            report["handled_preserved"] += 1
                    except OSError:
                        pass

            # 3. Check .ring-state
            ring_state_path = os.path.join(inbox, ".ring-state")
            if os.path.isfile(ring_state_path):
                try:
                    st = os.stat(ring_state_path)
                    age_sec = now - st.st_mtime
                    # Only prune .ring-state if older than TTL AND no pending unhandled messages
                    if not has_pending and age_sec > stale_ring_ttl_sec:
                        report["ring_states_pruned"] += 1
                        report["bytes_reclaimed"] += st.st_size
                        report["pruned_files"].append(ring_state_path)
                        if not dry_run:
                            os.unlink(ring_state_path)
                    else:
                        report["ring_states_preserved"] += 1
                except OSError:
                    pass

            # 4. Check .escalated
            escalated_path = os.path.join(inbox, ".escalated")
            if os.path.isfile(escalated_path):
                try:
                    st = os.stat(escalated_path)
                    age_sec = now - st.st_mtime
                    if not has_pending and age_sec > stale_ring_ttl_sec:
                        report["escalations_pruned"] += 1
                        report["bytes_reclaimed"] += st.st_size
                        report["pruned_files"].append(escalated_path)
                        if not dry_run:
                            os.unlink(escalated_path)
                except OSError:
                    pass

        except OSError:
            continue

    return report


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Jev Cross-Seat Doorbell & Stale Notification Vacuum (Pattern 18)"
    )
    parser.add_argument(
        "--state-dir",
        default=os.environ.get("FM_STATE", "/opt/ra/firstmate/state"),
        help="Path to Firstmate state directory containing *.inbox folders",
    )
    parser.add_argument(
        "--handled-retention-hours",
        type=float,
        default=float(os.environ.get("FM_HANDLED_RETENTION_HOURS", "24.0")),
        help="Retention period in hours for acknowledged handled/*.msg files (default: 24.0)",
    )
    parser.add_argument(
        "--stale-ring-hours",
        type=float,
        default=float(os.environ.get("FM_STALE_RING_HOURS", "24.0")),
        help="TTL in hours for idle .ring-state files with zero pending messages (default: 24.0)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Simulate vacuum scan and report planned actions without deleting files",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Output structured JSON summary",
    )

    args = parser.parse_args()

    report = scan_and_vacuum(
        state_dir=args.state_dir,
        handled_retention_hours=args.handled_retention_hours,
        stale_ring_hours=args.stale_ring_hours,
        dry_run=args.dry_run,
    )

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        status_tag = "[DRY_RUN]" if report["dry_run"] else "[VACUUM_APPLIED]"
        print(f"Jev Doorbell & Stale Notification Vacuum {status_tag}:")
        print(f"  • Inboxes Scanned: {report['inboxes_scanned']}")
        print(f"  • Handled Messages Pruned: {report['handled_pruned']} (Preserved: {report['handled_preserved']})")
        print(f"  • Stale Ring States Pruned: {report['ring_states_pruned']} (Preserved: {report['ring_states_preserved']})")
        print(f"  • Stale Escalations Pruned: {report['escalations_pruned']}")
        print(f"  • Pending Unhandled Messages Protected: {report['unhandled_pending']}")
        kb = report['bytes_reclaimed'] / 1024.0
        print(f"  • Space Reclaimed: {kb:.2f} KB across {len(report['pruned_files'])} files")

    return 0


if __name__ == "__main__":
    sys.exit(main())
