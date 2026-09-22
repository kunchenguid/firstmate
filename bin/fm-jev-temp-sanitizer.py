#!/usr/bin/env python3
"""
fm-jev-temp-sanitizer.py - Jev System One Fleet Temp Root & Staging Sanitizer.

Prevents fm-spawn.sh launch wedges caused by group-writable (0775) or stale
/tmp/fm-* task temp roots.

fm-spawn.sh requires that TASK_TMP (/tmp/fm-<id>) be a private directory owned
by the current user (mode 0700). Due to legacy umask defaults and a logic short-circuit
in fm-spawn.sh line 4059, pre-existing group-writable temp roots cause immediate
launch aborts during agent restarts or worker spawns.

Usage:
  bin/fm-jev-temp-sanitizer.py --check
  bin/fm-jev-temp-sanitizer.py --sanitize [--target <id>]
  bin/fm-jev-temp-sanitizer.py --purge-stale [--older-than-days 3]
"""

import argparse
import json
import os
import stat
import sys
from pathlib import Path


def get_current_user_id() -> int:
    return os.getuid()


def scan_temp_roots(tmp_dir: str = "/tmp", target_id: str = None) -> list:
    results = []
    current_uid = get_current_user_id()
    tmp_path = Path(tmp_dir)

    if not tmp_path.exists():
        return results

    if target_id:
        target_name = f"fm-{target_id}" if not target_id.startswith("fm-") else target_id
        candidates = [tmp_path / target_name]
    else:
        try:
            candidates = list(tmp_path.glob("fm-*"))
        except OSError as e:
            sys.stderr.write(f"warning: error globbing {tmp_dir}: {e}\n")
            return results

    for p in candidates:
        if not p.is_dir() or p.is_symlink():
            continue

        try:
            st = p.stat()
        except OSError:
            continue

        # Check ownership
        is_owner = (st.st_uid == current_uid)
        mode = st.st_mode
        perms = oct(stat.S_IMODE(mode))
        
        # Check if group or other writable
        is_group_writable = bool(mode & stat.S_IWGRP)
        is_other_writable = bool(mode & stat.S_IWOTH)
        is_unsafe = is_group_writable or is_other_writable or ((mode & 0o777) != 0o700)

        results.append({
            "path": str(p),
            "name": p.name,
            "uid": st.st_uid,
            "is_owner": is_owner,
            "permissions": perms,
            "mode": stat.S_IMODE(mode),
            "is_unsafe": is_unsafe,
            "mtime": st.st_mtime,
        })

    return results


def sanitize_roots(candidates: list) -> list:
    actions = []
    for entry in candidates:
        if not entry["is_owner"]:
            actions.append({
                "path": entry["path"],
                "status": "skipped_not_owner"
            })
            continue

        if not entry["is_unsafe"]:
            actions.append({
                "path": entry["path"],
                "status": "already_secure"
            })
            continue

        try:
            os.chmod(entry["path"], 0o700)
            actions.append({
                "path": entry["path"],
                "status": "sanitized_to_0700",
                "prior_mode": entry["permissions"]
            })
        except OSError as e:
            actions.append({
                "path": entry["path"],
                "status": f"error_chmod: {e}"
            })

    return actions


def main():
    parser = argparse.ArgumentParser(description="Jev Fleet Temp Root & Staging Sanitizer")
    parser.add_argument("--check", action="store_true", help="Report permission violations without modifying")
    parser.add_argument("--sanitize", action="store_true", help="Tighten permissions on unsafe roots to 0700")
    parser.add_argument("--target", type=str, default=None, help="Inspect or sanitize a specific seat or task ID")
    parser.add_argument("--json", action="store_true", help="Output machine-readable JSON")
    args = parser.parse_args()

    candidates = scan_temp_roots(target_id=args.target)
    unsafe_entries = [c for c in candidates if c["is_unsafe"] and c["is_owner"]]

    if args.sanitize:
        actions = sanitize_roots(candidates if args.target else unsafe_entries)
        sanitized_count = sum(1 for a in actions if a.get("status") == "sanitized_to_0700")
        if args.json:
            print(json.dumps({"actions": actions, "count": sanitized_count}, indent=2))
        else:
            print(f"Sanitized {sanitized_count} temp root(s) to mode 0700.")
            for a in actions:
                if a.get("status") == "sanitized_to_0700":
                    print(f"  ✓ {a['path']} (was {a.get('prior_mode')})")
        return 0

    # Default to check
    if args.json:
        print(json.dumps({
            "total_scanned": len(candidates),
            "unsafe_count": len(unsafe_entries),
            "unsafe_roots": unsafe_entries
        }, indent=2))
    else:
        print(f"Scanned {len(candidates)} /tmp/fm-* roots: {len(unsafe_entries)} violate mode 0700 requirement.")
        for u in unsafe_entries[:20]:
            print(f"  ! {u['path']} has mode {u['permissions']} (requires 0700)")
        if len(unsafe_entries) > 20:
            print(f"  ... and {len(unsafe_entries) - 20} more.")

    return 0 if len(unsafe_entries) == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
